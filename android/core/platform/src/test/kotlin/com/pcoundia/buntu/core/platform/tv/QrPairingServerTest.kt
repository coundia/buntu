package com.pcoundia.buntu.core.platform.tv

import com.pcoundia.buntu.core.domain.repository.PairingLink
import com.pcoundia.buntu.core.domain.repository.PairingOffer
import com.pcoundia.buntu.core.domain.repository.PairingOpenOutcome
import com.pcoundia.buntu.core.domain.repository.PairingReply
import com.pcoundia.buntu.core.domain.repository.PairingRepository
import com.pcoundia.buntu.core.domain.repository.PairingSealed
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.net.Socket
import java.util.concurrent.CopyOnWriteArrayList

/** The Rust protocol is tested in Rust; here the server's job: HTTP handling, confirmation, closing. */
private class FakePairing : PairingRepository {
    var failures = 0
    override fun createOffer(entropy: ByteArray, tvName: String, transport: String, host: String, port: Int, nowSeconds: Long) =
        PairingOffer("SESSION", "buntu://pair?v=1&s=SESSION&t=http&h=$host&p=$port", "state0", nowSeconds + 300)
    override fun parseLink(link: String, nowSeconds: Long) = PairingLink("SESSION", "TV", "http", "h", 1, nowSeconds + 300)
    override fun seal(link: String, entropy: ByteArray, shareJson: String, phoneName: String, nowSeconds: Long) = PairingSealed("m", "k")
    override fun open(state: String, message: String, nowSeconds: Long): PairingOpenOutcome {
        if (state == "used") return PairingOpenOutcome.Rejected("closed", state, true)
        if (message == "GOOD") return PairingOpenOutcome.Opened("{\"sources\":[]}", "Pixel de Papa", "replykey", "used")
        failures++
        return PairingOpenOutcome.Rejected("bad", "failures-$failures", failures >= 3)
    }
    override fun sealReply(replyKey: String, session: String, entropy: ByteArray, result: String, count: Int) = "REPLY:$result:$count"
    override fun openReply(replyKey: String, session: String, reply: String) = PairingReply("added", 1)
}

class QrPairingServerTest {
    private lateinit var scope: CoroutineScope
    private lateinit var server: QrPairingServer
    private val closed = CopyOnWriteArrayList<PairingClosedReason>()

    @Before
    fun setUp() {
        scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        server = QrPairingServer(FakePairing())
    }

    @After
    fun tearDown() {
        server.stop()
        scope.cancel()
    }

    private fun http(port: Int, method: String, path: String, body: String? = null, declaredLength: Int? = null): Pair<Int, String> {
        Socket("127.0.0.1", port).use { s ->
            val bytes = body?.toByteArray()
            val len = declaredLength ?: (bytes?.size ?: 0)
            s.getOutputStream().write(("$method $path HTTP/1.1\r\nHost: x\r\nContent-Length: $len\r\n\r\n").toByteArray())
            if (bytes != null && declaredLength == null) s.getOutputStream().write(bytes)
            s.getOutputStream().flush()
            val text = s.getInputStream().readBytes().toString(Charsets.UTF_8)
            val status = text.substringAfter("HTTP/1.1 ").substringBefore(' ').toIntOrNull() ?: 0
            return status to text.substringAfter("\r\n\r\n", "")
        }
    }

    private fun startServer(decision: suspend (IncomingPairing) -> PairingDecision = { PairingDecision.Refused }): PairingSession {
        val session = server.start(scope, onIncoming = decision, onClosed = { closed.add(it) })
        assertNotNull("the test machine has a network address", session)
        return session!!
    }

    @Test
    fun `a browser gets a pointer to the app and never a form`() {
        val session = startServer()
        val (status, body) = http(session.port, "GET", "/pair")
        assertEquals(200, status)
        assertFalse("no input field: a password must never be typed into a plain HTTP page", body.contains("<input") || body.contains("<form"))
        assertTrue(body.contains("Buntu"))
    }

    @Test
    fun `the QR code holds the link and fits a camera`() {
        val session = startServer()
        assertTrue(session.link.startsWith("buntu://pair"))
        assertTrue(session.qr.size > 0 && session.qr.pixels.any { it } && session.qr.pixels.any { !it })
    }

    @Test
    fun `nothing is answered before the user decides, then the sealed answer comes back`() = runBlocking {
        val decision = CompletableDeferred<PairingDecision>()
        val seen = CompletableDeferred<IncomingPairing>()
        val session = startServer { incoming -> seen.complete(incoming); decision.await() }
        val reply = CompletableDeferred<Pair<Int, String>>()
        Thread { reply.complete(http(session.port, "POST", "/pair", "GOOD")) }.start()

        val incoming = withTimeout(5_000) { seen.await() }
        assertEquals("Pixel de Papa", incoming.from)
        assertFalse("the phone still waits: the user has not pressed Ajouter", reply.isCompleted)

        decision.complete(PairingDecision.Added(2))
        val (status, body) = withTimeout(5_000) { reply.await() }
        assertEquals(200, status)
        assertEquals("REPLY:added:2", body)
        Thread.sleep(200)
        assertEquals(listOf(PairingClosedReason.Done), closed.toList())
    }

    @Test
    fun `a refusal is reported to the phone`() = runBlocking {
        val session = startServer { PairingDecision.Refused }
        val (status, body) = http(session.port, "POST", "/pair", "GOOD")
        assertEquals(200, status)
        assertEquals("REPLY:refused:0", body)
    }

    @Test
    fun `three bad messages close the session`() {
        val session = startServer()
        repeat(3) {
            val (status, _) = http(session.port, "POST", "/pair", "garbage")
            assertEquals(400, status)
        }
        Thread.sleep(300)
        assertEquals(listOf(PairingClosedReason.Closed), closed.toList())
        assertTrue("the port is closed", runCatching { Socket("127.0.0.1", session.port).close() }.isFailure)
    }

    @Test
    fun `an oversized body is refused without being read`() {
        val session = startServer()
        val (status, _) = http(session.port, "POST", "/pair", declaredLength = 10_000_000)
        assertEquals(413, status)
    }

    @Test
    fun `stopping closes the port`() {
        val session = startServer()
        server.stop()
        assertTrue(runCatching { Socket("127.0.0.1", session.port).close() }.isFailure)
    }
}
