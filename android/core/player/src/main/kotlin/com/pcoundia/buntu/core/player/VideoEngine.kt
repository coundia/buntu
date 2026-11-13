package com.pcoundia.buntu.core.player

import androidx.compose.runtime.Immutable
import com.pcoundia.buntu.core.domain.model.BandwidthAssessment
import com.pcoundia.buntu.core.domain.model.PlayableStream
import com.pcoundia.buntu.core.domain.model.StreamDiagnosis
import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.persistentListOf
import kotlinx.coroutines.flow.StateFlow

@Immutable
data class TrackOption(
    val id: String,
    val groupIndex: Int,
    val trackIndex: Int,
    val label: String,
    val language: String?,
    val isSelected: Boolean,
)

@Immutable
data class PlayerEngineState(
    val activeStream: PlayableStream? = null,
    val isPlaying: Boolean = false,
    val isBuffering: Boolean = false,
    /** The film or episode reached its end (ExoPlayer `STATE_ENDED`); reset when another stream opens. */
    val isEnded: Boolean = false,
    /** 1.0 = normal speed. Always 1.0 on a live channel. */
    val playbackSpeed: Float = 1.0f,
    val positionMs: Long = 0L,
    val durationMs: Long = 0L,
    val bufferedPositionMs: Long = 0L,
    val measuredBitrateBps: Long = 0L,
    val audioTracks: ImmutableList<TrackOption> = persistentListOf(),
    val subtitleTracks: ImmutableList<TrackOption> = persistentListOf(),
    val subtitlesDisabled: Boolean = false,
    val subtitleOffsetMs: Long = 0L,
    val diagnosis: StreamDiagnosis? = null,
    val bandwidthWarning: BandwidthAssessment? = null,
)

/**
 * PRD-37 § 4.1 - § 4.4:
 * Single abstraction for video playback (`ExoPlayerVideoEngine` today; optional `libmpv` fallback in 37.9).
 * Feature modules interact with playback through domain/state without owning Media3 internals.
 */
interface VideoEngine {
    val state: StateFlow<PlayerEngineState>

    fun play(stream: PlayableStream)
    fun zap(stream: PlayableStream)
    fun togglePlayPause()
    fun pause()
    fun resume()
    fun seekTo(positionMs: Long)
    fun seekBy(deltaMs: Long)
    fun selectAudioTrack(groupIndex: Int, trackIndex: Int)
    fun selectSubtitleTrack(groupIndex: Int?, trackIndex: Int?)
    fun setSubtitleOffsetMs(offsetMs: Long)
    /** Ignored on a live channel, which always plays at normal speed. */
    fun setPlaybackSpeed(speed: Float)
    fun dismissBandwidthWarning()
    fun stop()
}

