package com.pcoundia.buntu.core.player

import com.pcoundia.buntu.core.domain.model.StreamDiagnosis
import com.pcoundia.buntu.core.domain.model.StreamKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class StallWatchdogAndBufferTest {

    @Test
    fun `stream receiving bytes is NEVER restarted even while buffering`() {
        val watchdog = StallWatchdog(stallThresholdMs = 8_000L, maxAutoRetries = 3)
        watchdog.reset(nowMs = 1_000L)

        // Buffering for 20s, but bytes keep arriving -> must NOT restart (PRD-37 § 4.3)
        assertFalse(watchdog.shouldRestartStalledStream(isBuffering = true, totalBytesReceived = 50_000L, nowMs = 6_000L))
        assertFalse(watchdog.shouldRestartStalledStream(isBuffering = true, totalBytesReceived = 120_000L, nowMs = 15_000L))
        assertFalse(watchdog.shouldRestartStalledStream(isBuffering = true, totalBytesReceived = 250_000L, nowMs = 22_000L))

        // Now bytes stop arriving for >= 8_000ms -> triggers 1 restart
        assertTrue(watchdog.shouldRestartStalledStream(isBuffering = true, totalBytesReceived = 250_000L, nowMs = 31_000L))
    }

    @Test
    fun `HTTP 429 waits for provider socket release while 401 and 404 fail fast`() {
        val watchdog = StallWatchdog()
        val delay429 = watchdog.computeRetryDelayMs(StreamDiagnosis.Http(429), attempt = 1)
        assertNotNull(delay429)
        assertTrue("Expected >= 4s wait on 429, got $delay429", (delay429 ?: 0L) >= 4_000L)

        assertNull(watchdog.computeRetryDelayMs(StreamDiagnosis.Http(401), attempt = 1))
        assertNull(watchdog.computeRetryDelayMs(StreamDiagnosis.Http(404), attempt = 1))
    }

    @Test
    fun `low-RAM devices get reduced VOD buffer ceiling while Live TV stays sub-second`() {
        val liveLowRam = BufferProfiles.specFor(StreamKind.LIVE, isLowRamDevice = true)
        val vodStandard = BufferProfiles.specFor(StreamKind.VOD_MOVIE, isLowRamDevice = false)
        val vodLowRam = BufferProfiles.specFor(StreamKind.VOD_MOVIE, isLowRamDevice = true)

        assertEquals(800, liveLowRam.bufferForPlaybackMs)
        assertTrue(vodLowRam.maxBufferMs < vodStandard.maxBufferMs)
        assertTrue(vodLowRam.targetBufferBytes < vodStandard.targetBufferBytes)
    }
}

