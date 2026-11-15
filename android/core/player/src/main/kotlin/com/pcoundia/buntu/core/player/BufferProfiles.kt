package com.pcoundia.buntu.core.player

import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.Timeline
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.LoadControl
import androidx.media3.exoplayer.upstream.DefaultAllocator
import com.pcoundia.buntu.core.domain.model.LiveBuffer
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
        // Automatic mode keeps fast zapping and deep VOD buffering.
        val spec = BufferProfileSpec(
            minBufferMs = if (isLowRamDevice) 12_000 else 25_000,
            maxBufferMs = if (isLowRamDevice) 45_000 else 120_000,
            bufferForPlaybackMs = 850,
            bufferForPlaybackAfterRebufferMs = 2_500,
            targetBufferBytes = if (isLowRamDevice) 28 * 1024 * 1024 else 128 * 1024 * 1024,
        )
        return LiveBufferLoadControl(spec, backBufferMs = if (isLowRamDevice) 5_000 else 20_000)
    }

    @UnstableApi
    private class LiveBufferLoadControl(
        private val automatic: BufferProfileSpec,
        backBufferMs: Int,
    ) : DefaultLoadControl(
        DefaultAllocator(true, C.DEFAULT_BUFFER_SEGMENT_SIZE),
        automatic.minBufferMs,
        automatic.maxBufferMs,
        automatic.bufferForPlaybackMs,
        automatic.bufferForPlaybackAfterRebufferMs,
        automatic.targetBufferBytes,
        true,
        backBufferMs,
        false,
    ) {
        private val period = Timeline.Period()
        private val window = Timeline.Window()

        private fun liveBufferTargetUs(parameters: LoadControl.Parameters): Long? {
            if (parameters.timeline.isEmpty) return null
            val periodIndex = parameters.timeline.getIndexOfPeriod(parameters.mediaPeriodId.periodUid)
            if (periodIndex == C.INDEX_UNSET) return null
            val windowIndex = parameters.timeline.getPeriod(periodIndex, period).windowIndex
            val tag = parameters.timeline.getWindow(windowIndex, window).mediaItem.localConfiguration?.tag
            val requestedUs = (tag as? LiveBuffer)?.seconds?.times(1_000_000L) ?: return null
            // HLS may publish less history than requested. Its timeline clamps the available offset.
            if (!window.isLive || window.durationUs <= 0L) return requestedUs
            val windowLimitUs = minOf(requestedUs, window.durationUs)
            return if (parameters.targetLiveOffsetUs > 0) {
                minOf(windowLimitUs, parameters.targetLiveOffsetUs)
            } else {
                windowLimitUs
            }
        }

        override fun shouldContinueLoading(parameters: LoadControl.Parameters): Boolean {
            val targetUs = liveBufferTargetUs(parameters) ?: return super.shouldContinueLoading(parameters)
            return parameters.bufferedDurationUs < targetUs &&
                (!memoryBudgetReached() || parameters.bufferedDurationUs < 500_000L)
        }

        override fun shouldStartPlayback(parameters: LoadControl.Parameters): Boolean {
            val targetUs = liveBufferTargetUs(parameters) ?: return super.shouldStartPlayback(parameters)
            // Start with the available reserve if memory fills first, including on high-bitrate channels.
            // The last buffered sample can precede the reported end of the live window.
            val startupTargetUs = (targetUs - 250_000L).coerceAtLeast(minOf(targetUs, 500_000L))
            return parameters.bufferedDurationUs >= startupTargetUs ||
                (memoryBudgetReached() && parameters.bufferedDurationUs >= 500_000L)
        }

        private fun memoryBudgetReached(): Boolean =
            allocator.totalBytesAllocated >= automatic.targetBufferBytes
    }
}
