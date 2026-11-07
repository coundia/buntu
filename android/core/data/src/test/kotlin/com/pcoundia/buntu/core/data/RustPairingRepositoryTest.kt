package com.pcoundia.buntu.core.data

import com.pcoundia.buntu.core.data.repository.RustPairingRepository
import com.pcoundia.buntu.core.domain.repository.PairingOpenOutcome
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * PRD-39 § 4.4: the Kotlin side must produce the exact bytes Swift and the TV's WebAssembly produce from the
 * same inputs (`crates/cnd-domain/src/pairing/vectors.json`), through the real Rust library.
 */
class RustPairingRepositoryTest {
    private val repo = RustPairingRepository()

    private fun vectors(): JsonObject {
        var dir: File? = File(System.getProperty("user.dir"))
        while (dir != null && !File(dir, "crates/cnd-domain/src/pairing/vectors.json").isFile) dir = dir.parentFile
        return Json.parseToJsonElement(File(dir!!, "crates/cnd-domain/src/pairing/vectors.json").readText()).jsonObject
    }

    private fun bytes(a: kotlinx.serialization.json.JsonElement) = (a as JsonArray).map { it.jsonPrimitive.int.toByte() }.toByteArray()

    @Test
    fun `reproduces the shared vectors byte for byte`() {
        val v = vectors()
        val now = v["now"]!!.jsonPrimitive.long
        val o = v["offer"]!!.jsonObject
        val offer = repo.createOffer(
            bytes(o["entropy"]!!), o["tv_name"]!!.jsonPrimitive.content, o["transport"]!!.jsonPrimitive.content,
            o["host"]!!.jsonPrimitive.content, o["port"]!!.jsonPrimitive.int, now,
        )
        assertEquals(o["link"]!!.jsonPrimitive.content, offer.link)
        assertEquals(o["session"]!!.jsonPrimitive.content, offer.session)
        assertEquals(o["state"]!!.jsonPrimitive.content, offer.state)

        val s = v["seal"]!!.jsonObject
        val sealed = repo.seal(offer.link, bytes(s["entropy"]!!), s["share_json"]!!.jsonPrimitive.content, s["phone_name"]!!.jsonPrimitive.content, now + 5)
        assertEquals(s["message"]!!.jsonPrimitive.content, sealed.message)
        assertEquals(s["reply_key"]!!.jsonPrimitive.content, sealed.replyKey)

        val r = v["reply"]!!.jsonObject
        val reply = repo.sealReply(sealed.replyKey, offer.session, bytes(r["entropy"]!!), r["result"]!!.jsonPrimitive.content, r["count"]!!.jsonPrimitive.int)
        assertEquals(r["reply"]!!.jsonPrimitive.content, reply)
    }

    @Test
    fun `a phone and a TV agree end to end through Kotlin`() {
        val now = 1_800_000_000L
        val offer = repo.createOffer(ByteArray(40) { it.toByte() }, "Salon", "http", "192.168.1.20", 41234, now)
        assertEquals("http", repo.parseLink(offer.link, now + 1).transport)

        val share = """{"format":"cnd-source-share","version":1,"sources":[]}"""
        val sealed = repo.seal(offer.link, ByteArray(44) { (it + 3).toByte() }, share, "Pixel", now + 2)
        val opened = repo.open(offer.state, sealed.message, now + 3) as PairingOpenOutcome.Opened
        assertEquals(share, opened.shareJson)
        assertEquals("Pixel", opened.from)

        val answer = repo.sealReply(opened.replyKey, offer.session, ByteArray(12) { 9 }, "added", 3)
        val body = repo.openReply(sealed.replyKey, offer.session, answer)
        assertEquals("added" to 3, body.result to body.count)
    }

    @Test
    fun `a replay and a forged message are rejected`() {
        val now = 1_800_000_000L
        val offer = repo.createOffer(ByteArray(40) { (it + 1).toByte() }, "Salon", "http", "10.0.0.2", 5000, now)
        val sealed = repo.seal(offer.link, ByteArray(44) { (it + 5).toByte() }, "{}", "p", now + 1)
        val first = repo.open(offer.state, sealed.message, now + 2) as PairingOpenOutcome.Opened
        val replay = repo.open(first.state, sealed.message, now + 3)
        assertTrue(replay is PairingOpenOutcome.Rejected && replay.closed)
        assertTrue(repo.open(offer.state, "{ not a message", now + 2) is PairingOpenOutcome.Rejected)
    }
}
