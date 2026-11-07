package com.pcoundia.buntu.core.platform.phone

import com.pcoundia.buntu.core.domain.repository.PairingRepository
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.OutputStream
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.net.Socket
import java.net.URL
import java.security.SecureRandom
import javax.inject.Inject

sealed interface PairingSendResult {
    data class Added(val count: Int) : PairingSendResult
    data object Refused : PairingSendResult
    data class Failed(val reason: PairingFailure) : PairingSendResult
}

enum class PairingFailure { InvalidLink, UnsupportedTv, Unreachable, TvNotListening, TimedOut, BadAnswer }

fun PairingFailure.userMessage(): String = when (this) {
    PairingFailure.InvalidLink -> "Ce QR code Buntu est invalide ou a expiré : affichez-en un nouveau sur la TV."
    PairingFailure.UnsupportedTv -> "Ce type de TV n'est pas encore pris en charge depuis Android."
    PairingFailure.Unreachable -> "Votre téléphone ne voit pas la TV : vérifiez qu'ils sont sur le même Wi-Fi (pas un réseau invité)."
    PairingFailure.TvNotListening -> "La TV n'écoute plus ce QR code : rouvrez l'écran d'ajout sur la TV."
    PairingFailure.TimedOut -> "Aucune confirmation reçue sur la TV dans le temps imparti."
    PairingFailure.BadAnswer -> "Réponse de la TV illisible : affichez un nouveau QR code sur la TV."
}

/**
 * PRD-39 § 5.5: the phone sends its accounts to the TV of a scanned QR code. It seals them with the shared
 * Rust protocol, carries the message (Android TV: HTTP, Samsung: the TV's own channel) and waits for the
 * answer, which comes after the user confirmed with the remote.
 */
class PairingSender @Inject constructor(
    private val pairing: PairingRepository,
) {
    private val random = SecureRandom()

    suspend fun send(
        link: String,
        shareJson: String,
        phoneName: String,
        nowSeconds: Long = System.currentTimeMillis() / 1000,
        waitSeconds: Int = 330,
    ): PairingSendResult = withContext(Dispatchers.IO) {
        val parsed = runCatching { pairing.parseLink(link, nowSeconds) }.getOrNull()
            ?: return@withContext PairingSendResult.Failed(PairingFailure.InvalidLink)
        val sealed = runCatching {
            pairing.seal(link, ByteArray(SEAL_ENTROPY).also(random::nextBytes), shareJson, phoneName, nowSeconds)
        }.getOrNull() ?: return@withContext PairingSendResult.Failed(PairingFailure.InvalidLink)

        val answer = try {
            when (parsed.transport) {
                "http" -> postHttp(parsed.host, parsed.port, sealed.message, waitSeconds)
                "msf" -> MsfClient.exchange(parsed.host, parsed.port, parsed.session, sealed.message, waitSeconds)
                else -> return@withContext PairingSendResult.Failed(PairingFailure.UnsupportedTv)
            }
        } catch (e: PairingTransportException) {
            return@withContext PairingSendResult.Failed(e.failure)
        } catch (e: IOException) {
            return@withContext PairingSendResult.Failed(PairingFailure.Unreachable)
        }
        val reply = runCatching { pairing.openReply(sealed.replyKey, parsed.session, answer) }.getOrNull()
            ?: return@withContext PairingSendResult.Failed(PairingFailure.BadAnswer)
        when (reply.result) {
            "added" -> PairingSendResult.Added(reply.count)
            "refused" -> PairingSendResult.Refused
            else -> PairingSendResult.Failed(PairingFailure.BadAnswer)
        }
    }

    private fun postHttp(host: String, port: Int, message: String, waitSeconds: Int): String {
        val connection = URL("http://$host:$port/pair").openConnection() as HttpURLConnection
        try {
            connection.requestMethod = "POST"
            connection.doOutput = true
            connection.connectTimeout = 8_000
            connection.readTimeout = waitSeconds * 1000
            connection.setRequestProperty("Content-Type", "application/json")
            connection.outputStream.use { it.write(message.toByteArray(Charsets.UTF_8)) }
            if (connection.responseCode != 200) throw PairingTransportException(PairingFailure.BadAnswer)
            return connection.inputStream.use { String(it.readBytes(), Charsets.UTF_8) }
        } catch (e: java.net.SocketTimeoutException) {
            throw PairingTransportException(PairingFailure.TimedOut)
        } finally {
            connection.disconnect()
        }
    }

    companion object {
        const val SEAL_ENTROPY = 44
    }
}

class PairingTransportException(val failure: PairingFailure) : IOException(failure.name)

/**
 * A minimal WebSocket client for the Samsung TV's own channel (`ws://<tv>:8001/api/v2/channels/<name>`):
 * text + ping/pong frames, no extensions. Enough to hand one message to the TV app and wait for its answer.
 */
internal object MsfClient {
    fun exchange(host: String, port: Int, session: String, message: String, waitSeconds: Int): String {
        val socket = Socket()
        try {
            socket.connect(InetSocketAddress(host, port), 8_000)
        } catch (e: IOException) {
            throw PairingTransportException(PairingFailure.Unreachable)
        }
        socket.use { sock ->
            val input = BufferedInputStream(sock.getInputStream())
            val output = sock.getOutputStream()
            val key = base64(ByteArray(16).also(SecureRandom()::nextBytes))
            val request = "GET /api/v2/channels/buntu.pair.$session HTTP/1.1\r\nHost: $host:$port\r\n" +
                "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: $key\r\nSec-WebSocket-Version: 13\r\n\r\n"
            output.write(request.toByteArray(Charsets.US_ASCII))
            output.flush()

            sock.soTimeout = 8_000
            val status = readHttpLine(input) ?: throw PairingTransportException(PairingFailure.Unreachable)
            if (!status.contains("101")) throw PairingTransportException(PairingFailure.Unreachable)
            while (true) if (readHttpLine(input).isNullOrEmpty()) break

            val deadline = System.currentTimeMillis() + waitSeconds * 1000L
            // Welcome: the TV's app must be on the channel too, or nobody would hear us.
            val welcomeRaw = readText(input, output, sock, deadline)
            val welcome = runCatching { Json.parseToJsonElement(welcomeRaw).jsonObject }.getOrNull()
                ?: throw PairingTransportException(PairingFailure.Unreachable)
            val welcomeEvent = (welcome["event"] as? JsonPrimitive)?.contentOrNull
            if (welcomeEvent != "ms.channel.connect") {
                throw PairingTransportException(PairingFailure.Unreachable)
            }
            val clients = (welcome["data"] as? JsonObject)?.get("clients")?.jsonArray?.size ?: 0
            if (clients < 2) throw PairingTransportException(PairingFailure.TvNotListening)

            val frame = buildJsonObject {
                put("method", "ms.channel.emit")
                putJsonObject("params") {
                    put("event", "buntu.pair")
                    put("to", "broadcast")
                    put("data", message)
                }
            }.toString()
            writeFrame(output, 0x81, frame.toByteArray(Charsets.UTF_8))

            while (true) {
                val text = readText(input, output, sock, deadline)
                val envelope = runCatching { Json.parseToJsonElement(text).jsonObject }.getOrNull() ?: continue
                val event = (envelope["event"] as? JsonPrimitive)?.contentOrNull
                if (event == "buntu.pair.reply") {
                    val dataEl = envelope["data"]
                    return when (dataEl) {
                        is JsonPrimitive -> dataEl.contentOrNull
                        is JsonObject -> dataEl.toString()
                        else -> null
                    } ?: throw PairingTransportException(PairingFailure.BadAnswer)
                }
            }
        }
    }

    /** Standard base64 (java.util.Base64 needs API 26; this app supports 24). */
    private fun base64(bytes: ByteArray): String {
        val table = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
        val sb = StringBuilder()
        var i = 0
        while (i < bytes.size) {
            val b0 = bytes[i].toInt() and 0xff
            val b1 = if (i + 1 < bytes.size) bytes[i + 1].toInt() and 0xff else 0
            val b2 = if (i + 2 < bytes.size) bytes[i + 2].toInt() and 0xff else 0
            sb.append(table[b0 shr 2]).append(table[((b0 and 3) shl 4) or (b1 shr 4)])
            sb.append(if (i + 1 < bytes.size) table[((b1 and 15) shl 2) or (b2 shr 6)] else '=')
            sb.append(if (i + 2 < bytes.size) table[b2 and 63] else '=')
            i += 3
        }
        return sb.toString()
    }

    private fun readHttpLine(input: BufferedInputStream): String? {
        val sb = StringBuilder()
        while (sb.length < 8192) {
            val b = input.read()
            if (b < 0) return null
            if (b == '\n'.code) return sb.toString().trimEnd('\r')
            sb.append(b.toChar())
        }
        return null
    }

    private fun readByteOrEof(input: BufferedInputStream): Int {
        val b = input.read()
        if (b < 0) throw PairingTransportException(PairingFailure.Unreachable)
        return b
    }

    private fun readText(input: BufferedInputStream, output: OutputStream, sock: Socket, deadline: Long): String {
        while (true) {
            val remaining = deadline - System.currentTimeMillis()
            if (remaining <= 0) throw PairingTransportException(PairingFailure.TimedOut)
            sock.soTimeout = remaining.toInt().coerceAtMost(60_000)
            val first = try {
                input.read()
            } catch (e: java.net.SocketTimeoutException) {
                continue
            }
            if (first < 0) throw PairingTransportException(PairingFailure.Unreachable)
            val opcode = first and 0x0f
            val second = readByteOrEof(input)
            val masked = (second and 0x80) != 0
            var length = (second and 0x7f).toLong()
            if (length == 126L) {
                val hi = readByteOrEof(input)
                val lo = readByteOrEof(input)
                length = ((hi shl 8) or lo).toLong()
            } else if (length == 127L) {
                length = 0
                repeat(8) {
                    length = (length shl 8) or readByteOrEof(input).toLong()
                }
            }
            if (length !in 0..MAX_FRAME) throw PairingTransportException(PairingFailure.BadAnswer)
            val maskKey = if (masked) {
                ByteArray(4) { readByteOrEof(input).toByte() }
            } else {
                null
            }
            val payload = ByteArray(length.toInt())
            var read = 0
            while (read < payload.size) {
                val n = input.read(payload, read, payload.size - read)
                if (n <= 0) throw PairingTransportException(PairingFailure.Unreachable)
                read += n
            }
            if (maskKey != null) {
                for (i in payload.indices) {
                    payload[i] = (payload[i].toInt() xor maskKey[i % 4].toInt()).toByte()
                }
            }
            when (opcode) {
                0x8 -> throw PairingTransportException(PairingFailure.Unreachable)
                0x9 -> {
                    // Respond to Samsung TV WebSocket Ping with Pong so socket stays open while waiting for remote confirmation
                    runCatching { writeFrame(output, 0x8A, payload) }
                }
                0x1 -> return String(payload, Charsets.UTF_8)
                else -> continue
            }
        }
    }

    private fun writeFrame(out: OutputStream, firstByte: Int, data: ByteArray) {
        val mask = ByteArray(4).also(SecureRandom()::nextBytes)
        val header = ByteArrayOutputStream()
        header.write(firstByte)
        when {
            data.size < 126 -> header.write(0x80 or data.size)
            data.size < 65_536 -> {
                header.write(0x80 or 126)
                header.write(data.size shr 8)
                header.write(data.size and 0xff)
            }
            else -> {
                header.write(0x80 or 127)
                for (i in 7 downTo 0) header.write(((data.size.toLong() shr (8 * i)) and 0xff).toInt())
            }
        }
        header.write(mask)
        out.write(header.toByteArray())
        out.write(ByteArray(data.size) { (data[it].toInt() xor mask[it % 4].toInt()).toByte() })
        out.flush()
    }

    private const val MAX_FRAME = 256 * 1024L
}
