package com.pcoundia.buntu.core.platform.sync

import com.pcoundia.buntu.core.domain.repository.DomainHouseholdSealedEnvelope
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.long
import org.junit.Assert.assertEquals
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.BufferedInputStream
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.net.InetAddress
import java.net.ServerSocket

/** Format of the Samsung channel (PRD-45 § 3.1), same as the Apple `SamsungChannelTransportTests`. */
class SamsungChannelTransportTest {

    private val envelope = DomainHouseholdSealedEnvelope(
        householdId = "hh_1",
        senderDeviceId = "android_1",
        sequence = 42uL,
        nonceHex = "00",
        ciphertextHex = "ff",
    )

    @Test
    fun emitFrameCarriesTheEnvelopeWithANumericSequence() {
        val root = Json.parseToJsonElement(emitFrame(envelope)).jsonObject
        assertEquals("ms.channel.emit", (root["method"] as JsonPrimitive).content)
        val params = root["params"]!!.jsonObject
        assertEquals("broadcast", (params["to"] as JsonPrimitive).content)
        val data = params["data"]!!.jsonObject
        val sequence = data["sequence"] as JsonPrimitive
        assertEquals(false, sequence.isString)
        assertEquals(42L, sequence.long)
        assertEquals(envelope, parseEnvelope(data))
    }

    @Test
    fun envelopeAsJsonStringIsRead() {
        val data = Json.parseToJsonElement(emitFrame(envelope)).jsonObject["params"]!!.jsonObject["data"]!!
        assertEquals(envelope, parseEnvelope(JsonPrimitive(data.toString())))
    }

    @Test
    fun sequenceAsStringIsRejected() {
        val bad = Json.parseToJsonElement(
            """{"household_id":"hh_1","sender_device_id":"x","sequence":"42","nonce_hex":"00","ciphertext_hex":"ff"}""",
        )
        assertNull(parseEnvelope(bad))
    }

    @Test
    fun maskedFragmentedTextIsJoinedAndPingAnswered() {
        val out = ByteArrayOutputStream()
        WebSocketFrames.writeFrame(out, 0x01, "hel".toByteArray()) // text, not final
        WebSocketFrames.writeFrame(out, 0x89, "p".toByteArray()) // ping in between
        WebSocketFrames.writeFrame(out, 0x80, "lo".toByteArray()) // continuation, final
        val pings = mutableListOf<String>()
        val text = WebSocketFrames.readText(BufferedInputStream(ByteArrayInputStream(out.toByteArray()))) {
            pings.add(String(it))
        }
        assertEquals("hello", text)
        assertEquals(listOf("p"), pings)
    }

    @Test
    fun base64MatchesTheStandard() {
        assertEquals("AAECAwQ=", WebSocketFrames.base64(byteArrayOf(0, 1, 2, 3, 4)))
    }

    /** A relay that accepts the upgrade, says `ms.channel.connect`, then stays silent (a dead TV link). */
    @Test
    fun silentChannelIsDetectedAndCanBeDropped() {
        val server = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1"))
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val relay = Thread {
            runCatching {
                server.accept().use { client ->
                    val input = BufferedInputStream(client.getInputStream())
                    while (!WebSocketFrames.readHttpLine(input).isNullOrEmpty()) { /* request headers */ }
                    val out = client.getOutputStream()
                    out.write("HTTP/1.1 101 Switching Protocols\r\n\r\n".toByteArray())
                    val payload = """{"event":"ms.channel.connect"}""".toByteArray()
                    out.write(byteArrayOf(0x81.toByte(), payload.size.toByte()))
                    out.write(payload)
                    out.flush()
                    Thread.sleep(10_000) // silent from now on
                }
            }
        }.apply { isDaemon = true; start() }
        val transport = SamsungChannelTransport(scope, port = server.localPort)
        try {
            assertEquals(0L, transport.silentForMs())
            transport.start("hh_1")
            transport.connectToTv("127.0.0.1")
            val deadline = System.currentTimeMillis() + 5_000
            while (!transport.isConnected && System.currentTimeMillis() < deadline) Thread.sleep(25)
            assertTrue(transport.isConnected)

            assertTrue(transport.silentForMs() < 5_000)
            assertTrue(transport.silentForMs(now = System.currentTimeMillis() + 120_000) > 90_000)

            transport.drop()
            assertFalse(transport.isConnected)
            assertNull(transport.currentHost)
            assertEquals(0L, transport.silentForMs())
        } finally {
            transport.stop()
            scope.cancel()
            server.close()
            relay.interrupt()
        }
    }
}
