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
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.security.SecureRandom
import java.util.Base64
import kotlin.coroutines.coroutineContext

/**
 * Samsung Smart TV MSF 2.0 Channel Transport for Android (PRD-45 § 3.2 & Lot 45.4).
 *
 * Connects to the Samsung TV's internal WebSocket channel (`ws://<tv_host>:8001/api/v2/channels/buntu.sync.<household_id>`),
 * framing outgoing messages with `ms.channel.emit` and listening for `buntu-sync-envelope`.
 */
class SamsungChannelTransport(
    private val scope: CoroutineScope,
) {
    var onEnvelopeReceived: ((DomainHouseholdSealedEnvelope) -> Unit)? = null
    var onConnected: (() -> Unit)? = null
    var onDisconnected: (() -> Unit)? = null

    private var currentHost: String? = null
    private var householdId: String? = null
    private var isRunning = false
    private var isConnected = false
    private var socket: Socket? = null
    private var writeMutex = Mutex()
    private var connectionJob: Job? = null
    private var reconnectJob: Job? = null
    private var reconnectAttempts = 0

    var connectedTvDeviceId: String? = null
        private set

    fun start(householdId: String) {
        this.householdId = householdId
        isRunning = true
    }

    fun stop() {
        isRunning = false
        connectionJob?.cancel()
        connectionJob = null
        reconnectJob?.cancel()
        reconnectJob = null
        closeSocket()
        connectedTvDeviceId = null
    }

    fun ensureRunning() {
        if (!isRunning || householdId.isNullOrEmpty()) return
        if (socket == null || socket?.isClosed == true) {
            currentHost?.let { connectToTv(it) }
        }
    }

    fun isPeer(deviceId: String): Boolean {
        return connectedTvDeviceId != null && connectedTvDeviceId == deviceId
    }

    fun recordPeerId(deviceId: String) {
        connectedTvDeviceId = deviceId
    }

    fun connectToTv(host: String) {
        if (!isRunning || householdId.isNullOrEmpty()) return
        if (isConnected && currentHost == host && socket?.isConnected == true && socket?.isClosed == false) return

        currentHost = host
        reconnectJob?.cancel()
        connectionJob?.cancel()

        connectionJob = scope.launch(Dispatchers.IO) {
            runConnectionLoop(host, householdId!!)
        }
    }

    private suspend fun runConnectionLoop(host: String, hId: String) {
        while (coroutineContext.isActive && isRunning) {
            closeSocket()
            try {
                val sock = Socket()
                sock.connect(InetSocketAddress(host, 8001), 5000)
                sock.tcpNoDelay = true
                socket = sock

                val input = BufferedInputStream(sock.getInputStream())
                val output = sock.getOutputStream()

                // Perform WebSocket HTTP Upgrade Handshake
                val randomBytes = ByteArray(16).also { SecureRandom().nextBytes(it) }
                val key = Base64.getEncoder().encodeToString(randomBytes)
                val upgradeReq = "GET /api/v2/channels/buntu.sync.$hId HTTP/1.1\r\n" +
                    "Host: $host:8001\r\n" +
                    "Upgrade: websocket\r\n" +
                    "Connection: Upgrade\r\n" +
                    "Sec-WebSocket-Key: $key\r\n" +
                    "Sec-WebSocket-Version: 13\r\n\r\n"

                writeMutex.withLock {
                    output.write(upgradeReq.toByteArray(Charsets.US_ASCII))
                    output.flush()
                }

                sock.soTimeout = 8000
                val statusLine = readHttpLine(input) ?: throw Exception("Handshake failed")
                if (!statusLine.contains("101")) throw Exception("Invalid status: $statusLine")

                while (true) {
                    val line = readHttpLine(input)
                    if (line.isNullOrEmpty()) break
                }

                sock.soTimeout = 0 // Infinite timeout for read loop

                // Read frames continuously
                while (coroutineContext.isActive && isRunning && !sock.isClosed) {
                    val text = readFrameText(input, output) ?: break
                    handleIncomingJson(text)
                }
            } catch (_: Exception) {
                // Connection failed or dropped
            }

            closeSocket()
            if (!isRunning) break

            reconnectAttempts++
            val delayMs = (2000L * (1 shl reconnectAttempts.coerceAtMost(4))).coerceAtMost(30000L)
            delay(delayMs)
        }
    }

    private fun closeSocket() {
        if (isConnected) {
            isConnected = false
            onDisconnected?.invoke()
        }
        try {
            socket?.close()
        } catch (_: Exception) {}
        socket = null
    }

    private fun handleIncomingJson(text: String) {
        try {
            val root = JSONObject(text)
            val event = root.optString("event")

            if (event == "ms.channel.connect") {
                isConnected = true
                reconnectAttempts = 0
                onConnected?.invoke()
                return
            }

            if (event == "buntu-sync-envelope") {
                val dataObj = when (val raw = root.opt("data")) {
                    is JSONObject -> raw
                    is String -> JSONObject(raw)
                    else -> null
                } ?: return

                val envelope = DomainHouseholdSealedEnvelope(
                    householdId = dataObj.getString("household_id"),
                    senderDeviceId = dataObj.getString("sender_device_id"),
                    sequence = dataObj.getLong("sequence").toULong(),
                    nonceHex = dataObj.getString("nonce_hex"),
                    ciphertextHex = dataObj.getString("ciphertext_hex"),
                )

                recordPeerId(envelope.senderDeviceId)
                onEnvelopeReceived?.invoke(envelope)
            }
        } catch (_: Exception) {}
    }

    suspend fun sendEnvelope(envelope: DomainHouseholdSealedEnvelope): Boolean {
        val sock = socket ?: return false
        if (!isConnected || sock.isClosed) return false

        val wireDict = JSONObject().apply {
            put("household_id", envelope.householdId)
            put("sender_device_id", envelope.senderDeviceId)
            put("sequence", envelope.sequence)
            put("nonce_hex", envelope.nonceHex)
            put("ciphertext_hex", envelope.ciphertextHex)
        }

        val frame = JSONObject().apply {
            put("method", "ms.channel.emit")
            put("params", JSONObject().apply {
                put("event", "buntu-sync-envelope")
                put("to", "broadcast")
                put("data", wireDict)
            })
        }.toString()

        return try {
            writeMutex.withLock {
                val out = sock.getOutputStream()
                writeFrame(out, 0x81, frame.toByteArray(Charsets.UTF_8))
                out.flush()
            }
            true
        } catch (_: Exception) {
            false
        }
    }

    // MARK: - RFC 6455 WebSocket Framing

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
        if (b < 0) throw Exception("EOF")
        return b
    }

    private fun readFrameText(input: BufferedInputStream, output: OutputStream): String? {
        while (true) {
            val first = input.read()
            if (first < 0) return null
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
            if (length !in 0..10_000_000) return null
            val maskKey = if (masked) ByteArray(4) { readByteOrEof(input).toByte() } else null
            val payload = ByteArray(length.toInt())
            var read = 0
            while (read < payload.size) {
                val n = input.read(payload, read, payload.size - read)
                if (n <= 0) return null
                read += n
            }
            if (maskKey != null) {
                for (i in payload.indices) {
                    payload[i] = (payload[i].toInt() xor maskKey[i % 4].toInt()).toByte()
                }
            }
            when (opcode) {
                0x8 -> return null // Close
                0x9 -> {
                    // Ping -> Pong (0x8A)
                    scope.launch(Dispatchers.IO) {
                        try {
                            writeMutex.withLock {
                                writeFrame(output, 0x8A, payload)
                                output.flush()
                            }
                        } catch (_: Exception) {}
                    }
                }
                0x1 -> return String(payload, Charsets.UTF_8)
            }
        }
    }

    private fun writeFrame(out: OutputStream, firstByte: Int, data: ByteArray) {
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
        val masked = ByteArray(data.size) { (data[it].toInt() xor mask[it % 4].toInt()).toByte() }
        out.write(masked)
    }
}
