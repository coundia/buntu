package com.pcoundia.buntu.core.platform.phone

import com.pcoundia.buntu.core.domain.repository.PairingLink
import com.pcoundia.buntu.core.domain.repository.PairingOffer
import com.pcoundia.buntu.core.domain.repository.PairingOpenOutcome
import com.pcoundia.buntu.core.domain.repository.PairingReply
import com.pcoundia.buntu.core.domain.repository.PairingRepository
import com.pcoundia.buntu.core.domain.repository.PairingSealed
import com.pcoundia.buntu.core.platform.tv.PairingDecision
import com.pcoundia.buntu.core.platform.tv.QrPairingServer
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.OutputStream
import java.net.ServerSocket
import java.security.MessageDigest
import java.util.Base64

private class FakeSenderPairing : PairingRepository {
    override fun createOffer(entropy: ByteArray, tvName: String, transport: String, host: String, port: Int, nowSeconds: Long) =
        PairingOffer("S1", "buntu://pair?v=1&s=S1&n=$tvName&t=$transport&h=$host&p=$port", "state0", nowSeconds + 300)

    override fun parseLink(link: String, nowSeconds: Long): PairingLink {
        if (!link.startsWith("buntu://pair?")) error("invalid")
        val params = link.substringAfter('?').split('&').associate {
            val parts = it.split('=', limit = 2)
            parts[0] to parts.getOrElse(1) { "" }
        }
        return PairingLink(
            session = params["s"] ?: "S1",
            tvName = params["n"] ?: "Salon TV",
            transport = params["t"] ?: "http",
            host = params["h"] ?: "127.0.0.1",
            port = params["p"]?.toInt() ?: 0,
            expiresAt = nowSeconds + 300,
        )
    }

    override fun seal(link: String, entropy: ByteArray, shareJson: String, phoneName: String, nowSeconds: Long) =
        PairingSealed("{\"sealed\":true,\"from\":\"$phoneName\"}", "rk-1")

    override fun open(state: String, message: String, nowSeconds: Long): PairingOpenOutcome =
        if (message.contains("\"sealed\":true")) {
            PairingOpenOutcome.Opened("{\"format\":\"cnd-source-share\",\"version\":1,\"sources\":[]}", "Galaxy S22", "rk-1", "used")
        } else {
            PairingOpenOutcome.Rejected("bad", state, false)
        }

    override fun sealReply(replyKey: String, session: String, entropy: ByteArray, result: String, count: Int) =
        "{\"s\":\"$session\",\"result\":\"$result\",\"count\":$count}"

    override fun openReply(replyKey: String, session: String, reply: String): PairingReply {
        if (replyKey != "rk-1" || !reply.contains("\"s\":\"$session\"")) error("bad reply")
        val result = Regex("\"result\":\"([^\"]+)\"").find(reply)!!.groupValues[1]
        val count = Regex("\"count\":(\\d+)").find(reply)!!.groupValues[1].toInt()
        return PairingReply(result, count)
    }
}

class PairingSenderTest {
    private lateinit var scope: CoroutineScope
    private lateinit var repo: FakeSenderPairing
    private lateinit var sender: PairingSender
    private lateinit var tvServer: QrPairingServer

    @Before
    fun setUp() {
        scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        repo = FakeSenderPairing()
        sender = PairingSender(repo)
        tvServer = QrPairingServer(repo)
    }

    @After
    fun tearDown() {
        tvServer.stop()
        scope.cancel()
    }

    @Test
    fun `phone sends sealed accounts to Android TV over HTTP and receives Added`() = runBlocking {
        val session = tvServer.start(
            scope = scope,
            onIncoming = { PairingDecision.Added(2) },
            onClosed = {},
        )!!
        val link = "buntu://pair?v=1&s=S1&n=Salon&t=http&h=127.0.0.1&p=${session.port}"
        val outcome = sender.send(link, "{\"sources\":[]}", "Galaxy S22")
        assertEquals(PairingSendResult.Added(2), outcome)
    }

    @Test
    fun `phone sends over Samsung MSF WebSocket, replies to Ping, and decodes JSON-escaped reply`() = runBlocking {
        val pongReceived = CompletableDeferred<ByteArray>()
        val server = ServerSocket(0)
        val serverThread = Thread {
            server.use { ss ->
                ss.accept().use { sock ->
                    val input = BufferedInputStream(sock.getInputStream())
                    val out = sock.getOutputStream()
                    var wsKey = ""
                    while (true) {
                        val line = readHttpLine(input) ?: break
                        if (line.isEmpty()) break
                        if (line.startsWith("Sec-WebSocket-Key:", ignoreCase = true)) {
                            wsKey = line.substringAfter(':').trim()
                        }
                    }
                    val accept = Base64.getEncoder().encodeToString(
                        MessageDigest.getInstance("SHA-1")
                            .digest((wsKey + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").toByteArray(Charsets.US_ASCII))
                    )
                    out.write(
                        ("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
                            "Sec-WebSocket-Accept: $accept\r\n\r\n").toByteArray(Charsets.US_ASCII)
                    )
                    out.flush()

                    // Welcome frame with 2 clients (TV + phone)
                    writeUnmaskedFrame(
                        out,
                        0x81,
                        "{\"event\":\"ms.channel.connect\",\"data\":{\"id\":\"p\",\"clients\":[{\"id\":\"tv\"},{\"id\":\"p\"}]}}"
                            .toByteArray(Charsets.UTF_8),
                    )

                    // Read phone's emit frame
                    val (_, phoneMsg) = readClientFrame(input)
                    assertTrue(String(phoneMsg, Charsets.UTF_8).contains("buntu.pair"))

                    // Send a WebSocket Ping while user grabs the TV remote
                    writeUnmaskedFrame(out, 0x89, "keepalive".toByteArray(Charsets.UTF_8))
                    val (pongOpcode, pongPayload) = readClientFrame(input)
                    if (pongOpcode == 0xA) pongReceived.complete(pongPayload)

                    // Send Samsung MSF reply with escaped JSON string + \u0022 escapes
                    val escapedReply = "{\\u0022s\\u0022:\\\"S1\\\",\\\"result\\\":\\\"added\\\",\\\"count\\\":3}"
                    writeUnmaskedFrame(
                        out,
                        0x81,
                        "{\"event\":\"buntu.pair.reply\",\"data\":\"$escapedReply\"}".toByteArray(Charsets.UTF_8),
                    )
                }
            }
        }.apply { start() }

        val link = "buntu://pair?v=1&s=S1&n=SamsungTV&t=msf&h=127.0.0.1&p=${server.localPort}"
        val outcome = sender.send(link, "{\"sources\":[]}", "Galaxy S22", waitSeconds = 10)
        serverThread.join(5_000)

        assertEquals("keepalive", String(pongReceived.await(), Charsets.UTF_8))
        assertEquals(PairingSendResult.Added(3), outcome)
    }

    @Test
    fun `Samsung MSF channel with only 1 client returns TvNotListening`() = runBlocking {
        val server = ServerSocket(0)
        val serverThread = Thread {
            server.use { ss ->
                ss.accept().use { sock ->
                    val input = BufferedInputStream(sock.getInputStream())
                    val out = sock.getOutputStream()
                    while (!readHttpLine(input).isNullOrEmpty()) { /* consume headers */ }
                    out.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n".toByteArray())
                    out.flush()
                    writeUnmaskedFrame(
                        out,
                        0x81,
                        "{\"event\":\"ms.channel.connect\",\"data\":{\"id\":\"only-phone\",\"clients\":[{\"id\":\"only-phone\"}]}}"
                            .toByteArray(Charsets.UTF_8),
                    )
                }
            }
        }.apply { start() }

        val link = "buntu://pair?v=1&s=S1&n=SamsungTV&t=msf&h=127.0.0.1&p=${server.localPort}"
        val outcome = sender.send(link, "{\"sources\":[]}", "Galaxy S22", waitSeconds = 5)
        serverThread.join(5_000)

        assertEquals(PairingSendResult.Failed(PairingFailure.TvNotListening), outcome)
        assertTrue(PairingFailure.Unreachable.userMessage().contains("même Wi-Fi"))
    }

    private fun readHttpLine(input: BufferedInputStream): String? {
        val sb = StringBuilder()
        while (true) {
            val b = input.read()
            if (b < 0) return null
            if (b == '\n'.code) return sb.toString().trimEnd('\r')
            sb.append(b.toChar())
        }
    }

    private fun writeUnmaskedFrame(out: OutputStream, firstByte: Int, payload: ByteArray) {
        val header = ByteArrayOutputStream()
        header.write(firstByte)
        if (payload.size < 126) {
            header.write(payload.size)
        } else {
            header.write(126)
            header.write(payload.size shr 8)
            header.write(payload.size and 0xff)
        }
        out.write(header.toByteArray())
        out.write(payload)
        out.flush()
    }

    private fun readClientFrame(input: BufferedInputStream): Pair<Int, ByteArray> {
        val first = input.read()
        val opcode = first and 0x0f
        val second = input.read()
        val masked = (second and 0x80) != 0
        var len = second and 0x7f
        if (len == 126) len = (input.read() shl 8) or input.read()
        val mask = if (masked) ByteArray(4) { input.read().toByte() } else null
        val payload = ByteArray(len)
        var r = 0
        while (r < len) r += input.read(payload, r, len - r)
        if (mask != null) {
            for (i in payload.indices) payload[i] = (payload[i].toInt() xor mask[i % 4].toInt()).toByte()
        }
        return opcode to payload
    }
}

