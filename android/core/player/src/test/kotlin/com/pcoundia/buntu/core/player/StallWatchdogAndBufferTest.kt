package com.pcoundia.buntu.core.player

import androidx.media3.common.PlaybackException
import com.pcoundia.buntu.core.domain.model.StreamDiagnosis
import com.pcoundia.buntu.core.domain.model.StreamKind
import com.pcoundia.buntu.core.domain.model.redactStreamUrls
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
    fun `manual live prebuffer tolerates slower segment publication before retrying`() {
        val watchdog = StallWatchdog(stallThresholdMs = 10_000L)
        watchdog.reset(nowMs = 1_000L)

        assertFalse(watchdog.shouldRestartStalledStream(true, 0L, 11_000L, minimumStallThresholdMs = 15_000L))
        assertTrue(watchdog.shouldRestartStalledStream(true, 0L, 16_000L, minimumStallThresholdMs = 15_000L))
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

    @Test
    fun `decoder error maps to UnsupportedFormat with no auto-retry and redacts URLs`() {
        val watchdog = StallWatchdog()
        val cause = IllegalStateException(
            "MediaCodecAudioRenderer error for http://alice:secret123@iptv.example.com:8080/live/42.ts",
        )
        val diagnosis = StallWatchdog.classifyFailure(
            httpStatusCode = null,
            cause = cause,
            media3ErrorCode = PlaybackException.ERROR_CODE_DECODING_FAILED,
        )

        assertTrue(diagnosis is StreamDiagnosis.UnsupportedFormat)
        assertNull(watchdog.computeRetryDelayMs(diagnosis, attempt = 1))
        assertFalse(diagnosis.userMessage.contains("secret123"))
        assertFalse(diagnosis.userMessage.contains("iptv.example.com"))
        assertTrue(diagnosis.userMessage.contains("Format audio/vidéo non pris en charge"))
    }

    @Test
    fun `unknown playback error surfaces readable message without leaking stream URL`() {
        val cause = RuntimeException(
            "Failed reading http://bob:hunter2@provider.test/movie/99.mkv near byte 1024",
        )
        val diagnosis = StallWatchdog.classifyFailure(httpStatusCode = null, cause = cause)

        assertTrue(diagnosis is StreamDiagnosis.Generic)
        assertFalse(diagnosis.userMessage.contains("hunter2"))
        assertFalse(diagnosis.userMessage.contains("provider.test"))
        assertTrue(diagnosis.userMessage.contains("<lien masqué>"))
        assertTrue(redactStreamUrls("http://127.0.0.1:49152/stream/1.ts").contains("<relais>"))
    }
}

