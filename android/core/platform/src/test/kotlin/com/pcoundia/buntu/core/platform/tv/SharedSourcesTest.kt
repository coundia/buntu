package com.pcoundia.buntu.core.platform.tv

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class SharedSourcesTest {
    private val doc = """{"format":"cnd-source-share","version":1,"sources":[
        {"name":"Premium","type":"xtream","server":"http://srv.example:8080","username":"alice","password":"secret"},
        {"name":"Liste","type":"m3u","url":"http://lists.example/a.m3u"}]}"""

    @Test
    fun `shows the host and the presence of a password, never the password or the address`() {
        val sources = SharedSources.parse(doc)
        assertEquals(2, sources.size)
        assertEquals("srv.example:8080", sources[0].host)
        assertTrue(sources[0].hasPassword)
        assertEquals("lists.example", sources[1].host)
        assertFalse(sources[1].hasPassword)
    }

    @Test
    fun `refuses what is not a share, an expired share and a share with nothing usable`() {
        assertThrows(IllegalArgumentException::class.java) { SharedSources.parse("not json") }
        assertThrows(IllegalArgumentException::class.java) { SharedSources.parse("""{"format":"other"}""") }
        assertThrows(IllegalArgumentException::class.java) {
            SharedSources.parse("""{"format":"cnd-source-share","version":1,"expires_at":5,"sources":[]}""", nowSeconds = 100)
        }
        assertThrows(IllegalArgumentException::class.java) {
            SharedSources.parse("""{"format":"cnd-source-share","version":1,"sources":[{"type":"xtream","server":"ftp://x","username":"a"}]}""")
        }
    }

    @Test
    fun `cleans names and keeps at most twenty sources`() {
        val many = (0 until 30).joinToString(",") { """{"name":"S\u0007$it","type":"m3u","url":"http://h/$it.m3u"}""" }
        val out = SharedSources.parse("""{"format":"cnd-source-share","version":1,"sources":[$many]}""")
        assertEquals(20, out.size)
        assertEquals("S0", out[0].name)
    }
}
