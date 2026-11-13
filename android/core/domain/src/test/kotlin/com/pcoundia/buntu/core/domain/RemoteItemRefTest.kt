package com.pcoundia.buntu.core.domain

import com.pcoundia.buntu.core.domain.model.containerExtOf
import com.pcoundia.buntu.core.domain.model.providerRefOf
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** What leaves the device in a `play_request` (PRD-42 § 6): the provider's id, never the address. */
class RemoteItemRefTest {

    @Test
    fun providerRefIsTheLastSegmentWithoutExtension() {
        assertEquals("1234", providerRefOf("http://srv.example:8080/live/user/secret/1234.ts"))
        assertEquals("5002", providerRefOf("https://srv.example/movie/user/secret/5002.mkv?token=x"))
        assertEquals("777", providerRefOf("http://srv.example/series/user/secret/777"))
    }

    @Test
    fun providerRefIsNullWhenItDoesNotLookLikeAnId() {
        assertNull(providerRefOf("file:///storage/emulated/0/film.mkv"))
        assertNull(providerRefOf("http://srv.example/playlist/chaîne.m3u8"))
        assertNull(providerRefOf("http://srv.example/"))
    }

    @Test
    fun containerExtIsLowercaseAndPlausible() {
        assertEquals("mkv", containerExtOf("http://srv.example/movie/u/p/5002.MKV"))
        assertEquals("ts", containerExtOf("http://srv.example/live/u/p/1234.ts?x=1"))
        assertNull(containerExtOf("http://srv.example/series/u/p/777"))
    }
}
