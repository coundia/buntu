package com.pcoundia.buntu.core.platform.sync

import com.pcoundia.buntu.core.domain.repository.DomainHouseholdSealedEnvelope
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.security.SecureRandom
import java.util.Collections
import kotlin.coroutines.coroutineContext

/**
 * Samsung TV link of the household (PRD-45 § 3.2, lot 45.4), same behaviour as the Apple
 * `SamsungChannelTransport.swift`.
 *
 * A Tizen web app cannot open a port: every device connects as a client to the relay of the TV,
 * `ws://<tv>:8001/api/v2/channels/buntu.sync.<household_id>`. Envelopes are the `data` of an
 * `ms.channel.emit` (`event: buntu-sync-envelope`, `to: broadcast`). The TV is found by NSD
 * (`_samsungmsf._tcp`) in [LocalSyncService].
 *
 * Which device is a TV is decided by [LocalSyncService] after decryption ([markTv]), never from the
 * clear envelope: any client of the relay can send one.
 */
class SamsungChannelTransport(private val scope: CoroutineScope) {

    companion object {
        const val SERVICE_TYPE = "_samsungmsf._tcp."
        const val CHANNEL_PORT = 8001
        const val EVENT = "buntu-sync-envelope"
    }

    var onEnvelopeReceived: ((DomainHouseholdSealedEnvelope) -> Unit)? = null
    var onConnected: (() -> Unit)? = null
    /** Called with the TVs that were reachable on the closed connection. */
    var onDisconnected: ((Set<String>) -> Unit)? = null

    @Volatile private var householdId: String? = null
    @Volatile private var isRunning = false
    @Volatile private var connected = false
    @Volatile private var socket: Socket? = null
    @Volatile var currentHost: String? = null
        private set
    private val writeMutex = Mutex()
    private var connectionJob: Job? = null
    private val tvDeviceIds = Collections.synchronizedSet(mutableSetOf<String>())

    val isConnected: Boolean get() = connected

    fun start(householdId: String) {
        if (this.householdId != householdId) {
            connectionJob?.cancel()
            connectionJob = null
            closeSocket()
        }
        this.householdId = householdId
        isRunning = true
    }

    fun stop() {
        isRunning = false
        connectionJob?.cancel()
        connectionJob = null
        closeSocket()
        currentHost = null
    }

    /** `true` while a connection to [host] is open or being opened. */
    fun isActiveFor(host: String): Boolean = currentHost == host && connectionJob?.isActive == true

    fun isTv(deviceId: String): Boolean = connected && tvDeviceIds.contains(deviceId)

    fun markTv(deviceId: String) {
        tvDeviceIds.add(deviceId)
    }

    /** Opens (or keeps) the channel on [host]; one TV at a time (PRD-45 § 8, question 3). */
    fun connectToTv(host: String) {
        val hId = householdId
        if (!isRunning || hId.isNullOrEmpty()) return
        if (isActiveFor(host)) return
        connectionJob?.cancel()
        closeSocket()
        currentHost = host
        connectionJob = scope.launch(Dispatchers.IO) { runConnectionLoop(host, hId) }
    }

    private suspend fun runConnectionLoop(host: String, hId: String) {
        var attempts = 0
        while (coroutineContext.isActive && isRunning) {
            val sock = Socket()
            try {
                socket = sock
                sock.connect(InetSocketAddress(host, CHANNEL_PORT), 5000)
                sock.tcpNoDelay = true
                val input = BufferedInputStream(sock.getInputStream())
                val output = sock.getOutputStream()

                val key = WebSocketFrames.base64(ByteArray(16).also { SecureRandom().nextBytes(it) })
                val upgrade = "GET /api/v2/channels/buntu.sync.$hId HTTP/1.1\r\n" +
                    "Host: $host:$CHANNEL_PORT\r\n" +
                    "Upgrade: websocket\r\n" +
                    "Connection: Upgrade\r\n" +
                    "Sec-WebSocket-Key: $key\r\n" +
                    "Sec-WebSocket-Version: 13\r\n\r\n"
                writeMutex.withLock {
                    output.write(upgrade.toByteArray(Charsets.US_ASCII))
                    output.flush()
                }

                sock.soTimeout = 8000
                val status = WebSocketFrames.readHttpLine(input) ?: throw IOException("no answer")
                if (!status.contains(" 101")) throw IOException("upgrade refused")
                while (!WebSocketFrames.readHttpLine(input).isNullOrEmpty()) { /* headers */ }
                sock.soTimeout = 0

                while (coroutineContext.isActive && isRunning && !sock.isClosed) {
                    val text = WebSocketFrames.readText(input) { pong ->
                        scope.launch(Dispatchers.IO) {
                            runCatching { writeMutex.withLock { WebSocketFrames.writeFrame(output, 0x8A, pong); output.flush() } }
                        }
                    } ?: break
                    if (handleIncoming(text)) attempts = 0
                }
            } catch (_: Exception) {
                // Unreachable, refused or dropped: retried below.
            }
            // A newer connection (other host) may already own `socket`: close only ours.
            if (socket === sock) closeSocket() else runCatching { sock.close() }
            if (!isRunning || !coroutineContext.isActive) break
            attempts++
            delay((2000L shl attempts.coerceAtMost(4)).coerceAtMost(30_000L))
        }
    }

    private fun closeSocket() {
        val wasConnected = connected
        connected = false
        val tvs = synchronized(tvDeviceIds) { tvDeviceIds.toSet().also { tvDeviceIds.clear() } }
        runCatching { socket?.close() }
        socket = null
        if (wasConnected) onDisconnected?.invoke(tvs)
    }

    /** Returns `true` when the channel answered (connected or relayed a message). */
    private fun handleIncoming(text: String): Boolean {
        val root = runCatching { Json.parseToJsonElement(text).jsonObject }.getOrNull() ?: return false
        return when ((root["event"] as? JsonPrimitive)?.contentOrNull) {
            "ms.channel.connect" -> {
                connected = true
                onConnected?.invoke()
                true
            }
            EVENT -> {
                parseEnvelope(root["data"])?.let { onEnvelopeReceived?.invoke(it) }
                true
            }
            else -> false
        }
    }

    suspend fun sendEnvelope(envelope: DomainHouseholdSealedEnvelope): Boolean {
        val sock = socket ?: return false
        if (!connected || sock.isClosed) return false
        val frame = emitFrame(envelope).toByteArray(Charsets.UTF_8)
        return try {
            writeMutex.withLock {
                val out = sock.getOutputStream()
                WebSocketFrames.writeFrame(out, 0x81, frame)
                out.flush()
            }
            true
        } catch (_: Exception) {
            false
        }
    }
}

/** `ms.channel.emit` of an envelope: the `data` is the same JSON as on TCP, `sequence` a number. */
internal fun emitFrame(envelope: DomainHouseholdSealedEnvelope): String = buildJsonObject {
    put("method", "ms.channel.emit")
    putJsonObject("params") {
        put("event", SamsungChannelTransport.EVENT)
        put("to", "broadcast")
        putJsonObject("data") {
            put("household_id", envelope.householdId)
            put("sender_device_id", envelope.senderDeviceId)
            put("sequence", envelope.sequence.toLong())
            put("nonce_hex", envelope.nonceHex)
            put("ciphertext_hex", envelope.ciphertextHex)
        }
    }
}.toString()

/** The relay may hand `data` back as an object or as a JSON string. */
internal fun parseEnvelope(raw: kotlinx.serialization.json.JsonElement?): DomainHouseholdSealedEnvelope? {
    val obj: JsonObject = when (raw) {
        is JsonObject -> raw
        is JsonPrimitive -> raw.contentOrNull?.let { runCatching { Json.parseToJsonElement(it).jsonObject }.getOrNull() }
        else -> null
    } ?: return null
    fun str(name: String) = (obj[name] as? JsonPrimitive)?.takeIf { it.isString }?.content
    val sequence = (obj["sequence"] as? JsonPrimitive)?.takeIf { !it.isString }?.longOrNull ?: return null
    return DomainHouseholdSealedEnvelope(
        householdId = str("household_id") ?: return null,
        senderDeviceId = str("sender_device_id") ?: return null,
        sequence = sequence.toULong(),
        nonceHex = str("nonce_hex") ?: return null,
        ciphertextHex = str("ciphertext_hex") ?: return null,
    )
}

/** Minimal RFC 6455 client framing (the client masks what it sends). */
internal object WebSocketFrames {
    private const val MAX_MESSAGE = 4_000_000

    /** Standard base64 (java.util.Base64 needs API 26; this app supports 24). */
    fun base64(bytes: ByteArray): String {
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

    fun readHttpLine(input: BufferedInputStream): String? {
        val sb = StringBuilder()
        while (sb.length < 8192) {
            val b = input.read()
            if (b < 0) return null
            if (b == '\n'.code) return sb.toString().trimEnd('\r')
            sb.append(b.toChar())
        }
        return null
    }

    private fun byte(input: BufferedInputStream): Int {
        val b = input.read()
        if (b < 0) throw IOException("end of stream")
        return b
    }

    /**
     * Next complete text message (fragments joined), `null` on close or end of stream.
     * A ping is answered through [onPing] with its payload.
     */
    fun readText(input: BufferedInputStream, onPing: (ByteArray) -> Unit): String? {
        val message = ByteArrayOutputStream()
        var inText = false
        while (true) {
            val first = input.read()
            if (first < 0) return null
            val fin = (first and 0x80) != 0
            val opcode = first and 0x0f
            val second = byte(input)
            var length = (second and 0x7f).toLong()
            if (length == 126L) {
                length = ((byte(input) shl 8) or byte(input)).toLong()
            } else if (length == 127L) {
                length = 0
                repeat(8) { length = (length shl 8) or byte(input).toLong() }
            }
            if (length < 0 || length > MAX_MESSAGE) return null
            val mask = if ((second and 0x80) != 0) ByteArray(4) { byte(input).toByte() } else null
            val payload = ByteArray(length.toInt())
            var read = 0
            while (read < payload.size) {
                val n = input.read(payload, read, payload.size - read)
                if (n <= 0) return null
                read += n
            }
            if (mask != null) for (i in payload.indices) payload[i] = (payload[i].toInt() xor mask[i % 4].toInt()).toByte()

            when (opcode) {
                0x8 -> return null
                0x9 -> onPing(payload)
                0x1, 0x0 -> {
                    if (opcode == 0x1) { message.reset(); inText = true }
                    if (!inText) continue
                    message.write(payload)
                    if (message.size() > MAX_MESSAGE) return null
                    if (fin) return message.toString(Charsets.UTF_8.name())
                }
            }
        }
    }

    fun writeFrame(out: OutputStream, firstByte: Int, data: ByteArray) {
        val mask = ByteArray(4).also { SecureRandom().nextBytes(it) }
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
    }
}
