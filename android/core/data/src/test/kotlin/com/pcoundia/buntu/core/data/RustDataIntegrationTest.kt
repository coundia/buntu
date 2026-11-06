package com.pcoundia.buntu.core.data

import com.pcoundia.buntu.core.data.mapper.EngineMappers
import com.pcoundia.buntu.core.data.mapper.EngineMappers.toDomain
import com.pcoundia.buntu.core.engine.ffi.CndEngine
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class RustDataIntegrationTest {

    @Test
    fun `parseHeadersJson extracts HTTP headers into ImmutableMap safely`() {
        val headers = EngineMappers.parseHeadersJson("""{"X-Custom":"abc","Origin":"https://tv.example"}""")
        assertEquals("abc", headers["X-Custom"])
        assertEquals("https://tv.example", headers["Origin"])
        assertTrue(EngineMappers.parseHeadersJson("not-json").isEmpty())
    }

    @Test
    fun `in-memory Rust CndEngine works end-to-end via Kotlin UniFFI bindings`() {
        val engine = CndEngine.inMemory()
        assertEquals("1.0.0-native-rust", engine.version())

        val srcId = engine.addSource(
            name = "Buntu Test M3U",
            sourceType = "m3u",
            url = "http://iptv.local/playlist.m3u",
            server = null,
            username = null,
            passwordRef = null,
        )
        assertTrue(srcId > 0L)

        val sources = engine.listSources().map { it.toDomain() }
        assertEquals(1, sources.size)
        assertEquals("Buntu Test M3U", sources.first().name)

        // Verify single-connection local relay binds on 127.0.0.1 for VOD playback (PRD-37 § 4.2)
        val relayed = engine.singleConnectionUrl(
            url = "http://provider.example:8080/movie/u/p/42.mkv",
            userAgent = "Buntu/1.0",
            referer = null,
            headers = hashMapOf("X-Token" to "ok"),
        )
        assertTrue("Expected 127.0.0.1 relay URL, got $relayed", relayed.startsWith("http://127.0.0.1:"))
    }
}

