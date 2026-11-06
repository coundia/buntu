package com.pcoundia.buntu.core.player

import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DefaultLoadControl
import com.pcoundia.buntu.core.domain.model.StreamKind

data class BufferProfileSpec(
    val minBufferMs: Int,
    val maxBufferMs: Int,
    val bufferForPlaybackMs: Int,
    val bufferForPlaybackAfterRebufferMs: Int,
    val targetBufferBytes: Int,
)

/**
 * PRD-37 § 4.3 & § 5.3:
 * - Live TV: fast start (`bufferForPlaybackMs = 800 ms`) for sub-second zapping.
 * - VOD Movie / Episode: deep buffer (up to 120 s / 128 MB on standard RAM, scaled down on 2 GB low-RAM devices).
 */
object BufferProfiles {

    fun specFor(kind: StreamKind, isLowRamDevice: Boolean): BufferProfileSpec = when (kind) {
        StreamKind.LIVE, StreamKind.CATCHUP -> BufferProfileSpec(
            minBufferMs = if (isLowRamDevice) 3_000 else 5_000,
            maxBufferMs = if (isLowRamDevice) 12_000 else 25_000,
            bufferForPlaybackMs = 800,
            bufferForPlaybackAfterRebufferMs = 1_600,
            targetBufferBytes = if (isLowRamDevice) 12 * 1024 * 1024 else 32 * 1024 * 1024,
        )
        StreamKind.VOD_MOVIE, StreamKind.VOD_EPISODE, StreamKind.LOCAL_FILE -> BufferProfileSpec(
            minBufferMs = if (isLowRamDevice) 15_000 else 30_000,
            maxBufferMs = if (isLowRamDevice) 45_000 else 120_000,
            bufferForPlaybackMs = 2_000,
            bufferForPlaybackAfterRebufferMs = 4_500,
            targetBufferBytes = if (isLowRamDevice) 32 * 1024 * 1024 else 128 * 1024 * 1024,
        )
    }

    @OptIn(UnstableApi::class)
    fun createLoadControl(isLowRamDevice: Boolean): DefaultLoadControl {
        // Unified load control accommodating both fast start (800 ms) and deep VOD buffering
        val spec = BufferProfileSpec(
            minBufferMs = if (isLowRamDevice) 12_000 else 25_000,
            maxBufferMs = if (isLowRamDevice) 45_000 else 120_000,
            bufferForPlaybackMs = 850,
            bufferForPlaybackAfterRebufferMs = 2_500,
            targetBufferBytes = if (isLowRamDevice) 28 * 1024 * 1024 else 128 * 1024 * 1024,
        )
        return DefaultLoadControl.Builder()
            .setBufferDurationsMs(
                spec.minBufferMs,
                spec.maxBufferMs,
                spec.bufferForPlaybackMs,
                spec.bufferForPlaybackAfterRebufferMs,
            )
            .setTargetBufferBytes(spec.targetBufferBytes)
            .setPrioritizeTimeOverSizeThresholds(true)
            .setBackBuffer(if (isLowRamDevice) 5_000 else 20_000, false)
            .build()
    }
}

