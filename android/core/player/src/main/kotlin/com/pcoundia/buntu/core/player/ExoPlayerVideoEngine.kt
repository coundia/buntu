package com.pcoundia.buntu.core.player

import android.content.Context
import android.net.Uri
import android.os.Looper
import androidx.annotation.OptIn
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.Tracks
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.HttpDataSource
import androidx.media3.datasource.TransferListener
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.trackselection.DefaultTrackSelector
import com.pcoundia.buntu.core.domain.model.PlayableStream
import com.pcoundia.buntu.core.domain.model.StreamKind
import com.pcoundia.buntu.core.domain.repository.DownloadsRepository
import com.pcoundia.buntu.core.domain.repository.SettingsRepository
import com.pcoundia.buntu.core.domain.usecase.AssessStreamBandwidthUseCase
import com.pcoundia.buntu.core.platform.device.DeviceCapabilities
import com.pcoundia.buntu.core.platform.logging.RedactedAppLogger
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.collections.immutable.persistentListOf
import kotlinx.collections.immutable.toImmutableList
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.util.concurrent.atomic.AtomicLong
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
@OptIn(UnstableApi::class)
class ExoPlayerVideoEngine @Inject constructor(
    @ApplicationContext private val context: Context,
    private val deviceCapabilities: DeviceCapabilities,
    private val settingsRepository: SettingsRepository,
    private val downloadsRepository: DownloadsRepository,
    private val assessBandwidth: AssessStreamBandwidthUseCase,
    private val logger: RedactedAppLogger,
) : VideoEngine {

    private val mainScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val ioScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private val _state = MutableStateFlow(PlayerEngineState())
    override val state: StateFlow<PlayerEngineState> = _state.asStateFlow()

    private val totalBytesReceived = AtomicLong(0L)
    private var windowStartMs: Long = System.currentTimeMillis()
    private var windowBytes: Long = 0L
    private var errorRetryAttempt: Int = 0
    private var bandwidthWarningDismissedForItemId: Long? = null

    private val watchdog = StallWatchdog()
    private var tickerJob: Job? = null
    private var retryJob: Job? = null

    private val byteCountingListener = object : TransferListener {
        override fun onTransferInitializing(source: androidx.media3.datasource.DataSource, dataSpec: DataSpec, isNetwork: Boolean) = Unit
        override fun onTransferStart(source: androidx.media3.datasource.DataSource, dataSpec: DataSpec, isNetwork: Boolean) = Unit
        override fun onBytesTransferred(
            source: androidx.media3.datasource.DataSource,
            dataSpec: DataSpec,
            isNetwork: Boolean,
            bytesTransferred: Int,
        ) {
            if (isNetwork && bytesTransferred > 0) {
                totalBytesReceived.addAndGet(bytesTransferred.toLong())
            }
        }
        override fun onTransferEnd(source: androidx.media3.datasource.DataSource, dataSpec: DataSpec, isNetwork: Boolean) = Unit
    }

    private val trackSelector: DefaultTrackSelector by lazy(LazyThreadSafetyMode.NONE) {
        DefaultTrackSelector(context)
    }

    internal val exoPlayer: ExoPlayer by lazy(LazyThreadSafetyMode.NONE) {
        check(Looper.myLooper() == Looper.getMainLooper()) {
            "ExoPlayer must be instantiated on the main looper"
        }
        val renderersFactory = DefaultRenderersFactory(context)
            .setExtensionRendererMode(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_PREFER)
            .setEnableDecoderFallback(true)

        val audioAttributes = AudioAttributes.Builder()
            .setUsage(C.USAGE_MEDIA)
            .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE)
            .build()

        ExoPlayer.Builder(context, renderersFactory)
            .setTrackSelector(trackSelector)
            .setLoadControl(BufferProfiles.createLoadControl(deviceCapabilities.isLowRamDevice))
            .setAudioAttributes(audioAttributes, true)
            .setHandleAudioBecomingNoisy(true)
            .apply {
                if (deviceCapabilities.isTelevision) {
                    // PRD-37 § 4.3 & 37.8: Seamless 23.976 / 24 / 25 / 50 Hz display frame-rate matching on TV
                    setVideoChangeFrameRateStrategy(C.VIDEO_CHANGE_FRAME_RATE_STRATEGY_ONLY_IF_SEAMLESS)
                }
            }
            .build()
            .also { player ->
                player.addListener(playerListener)
            }
    }

    private val playerListener = object : Player.Listener {
        override fun onIsPlayingChanged(isPlaying: Boolean) {
            _state.update { it.copy(isPlaying = isPlaying) }
        }

        override fun onPlaybackStateChanged(playbackState: Int) {
            val buffering = playbackState == Player.STATE_BUFFERING
            if (playbackState == Player.STATE_READY) {
                errorRetryAttempt = 0
                _state.update { it.copy(isBuffering = false, diagnosis = null) }
            } else {
                _state.update { it.copy(isBuffering = buffering) }
            }
        }

        override fun onTracksChanged(tracks: Tracks) {
            updateAvailableTracks(tracks)
        }

        override fun onPlayerError(error: PlaybackException) {
            val httpCode = extractHttpStatusCode(error)
            val diagnosis = StallWatchdog.classifyFailure(httpCode, error.cause ?: error)
            logger.warn(
                "PLAYER",
                "Erreur lecture (${RedactedAppLogger.describeStreamUrl(_state.value.activeStream?.originalUrl)}) -> ${diagnosis.userMessage}",
            )
            _state.update { it.copy(isBuffering = false, diagnosis = diagnosis) }

            errorRetryAttempt += 1
            val delayMs = watchdog.computeRetryDelayMs(diagnosis, errorRetryAttempt)
            if (delayMs != null) {
                retryJob?.cancel()
                retryJob = mainScope.launch {
                    delay(delayMs)
                    val stream = _state.value.activeStream ?: return@launch
                    val resumePos = exoPlayer.currentPosition.coerceAtLeast(0L)
                    openInternal(stream.copy(startPositionMs = resumePos), resetRetries = false)
                }
            }
        }
    }

    override fun play(stream: PlayableStream) {
        mainScope.launch {
            if (stream.maxConnectionsForSource <= 1) {
                ioScope.launch { downloadsRepository.pauseAllForPlayback() }
            }
            applyTvPreferences()
            openInternal(stream, resetRetries = true)
        }
    }

    override fun zap(stream: PlayableStream) {
        // PRD-37 § 4.3: Reuse the exact same ExoPlayer & video surface without recreating either!
        mainScope.launch {
            openInternal(stream, resetRetries = true)
        }
    }

    private fun openInternal(stream: PlayableStream, resetRetries: Boolean) {
        retryJob?.cancel()
        if (resetRetries) {
            errorRetryAttempt = 0
            bandwidthWarningDismissedForItemId = null
        }
        val now = System.currentTimeMillis()
        watchdog.reset(now)
        windowStartMs = now
        windowBytes = totalBytesReceived.get()

        logger.info(
            "PLAYER",
            "Ouverture « ${stream.title} » (${RedactedAppLogger.describeStreamUrl(stream.originalUrl)}, relay=${stream.usesSingleConnectionRelay})",
        )

        val httpFactory = DefaultHttpDataSource.Factory()
            .setAllowCrossProtocolRedirects(true)
            .setConnectTimeoutMs(10_000)
            .setReadTimeoutMs(15_000)
            .setTransferListener(byteCountingListener)

        if (!stream.usesSingleConnectionRelay) {
            val headers = buildMap {
                putAll(stream.headers)
                stream.referer?.takeIf(String::isNotBlank)?.let { put("Referer", it) }
            }
            if (headers.isNotEmpty()) {
                httpFactory.setDefaultRequestProperties(headers)
            }
            stream.userAgent?.takeIf(String::isNotBlank)?.let { httpFactory.setUserAgent(it) }
        }

        val dataSourceFactory = DefaultDataSource.Factory(context, httpFactory)
        val mediaSourceFactory = DefaultMediaSourceFactory(context).setDataSourceFactory(dataSourceFactory)

        val mediaItem = MediaItem.Builder()
            .setMediaId(stream.itemId.toString())
            .setUri(Uri.parse(stream.playbackUrl))
            .setMediaMetadata(
                MediaMetadata.Builder()
                    .setTitle(stream.title)
                    .setSubtitle(stream.subtitle)
                    .setArtworkUri(stream.posterUrl?.let(Uri::parse))
                    .build()
            )
            .build()

        _state.update {
            it.copy(
                activeStream = stream,
                isBuffering = true,
                diagnosis = null,
                bandwidthWarning = null,
            )
        }

        val mediaSource = mediaSourceFactory.createMediaSource(mediaItem)
        if (stream.startPositionMs > 0L && stream.kind != StreamKind.LIVE) {
            exoPlayer.setMediaSource(mediaSource, stream.startPositionMs)
        } else {
            exoPlayer.setMediaSource(mediaSource)
        }
        exoPlayer.prepare()
        exoPlayer.playWhenReady = true
        ensurePositionAndWatchdogTicker()
    }

    private fun applyTvPreferences() {
        if (!deviceCapabilities.isTelevision) return
        ioScope.launch {
            val prefs = settingsRepository.currentPreferences()
            mainScope.launch {
                exoPlayer.videoChangeFrameRateStrategy = if (prefs.autoFrameRateMatchingTv) {
                    C.VIDEO_CHANGE_FRAME_RATE_STRATEGY_ONLY_IF_SEAMLESS
                } else {
                    C.VIDEO_CHANGE_FRAME_RATE_STRATEGY_OFF
                }
                trackSelector.parameters = trackSelector.buildUponParameters()
                    .setTunnelingEnabled(prefs.tunnelingEnabledTv)
                    .build()
            }
        }
    }

    private fun ensurePositionAndWatchdogTicker() {
        if (tickerJob?.isActive == true) return
        tickerJob = mainScope.launch {
            while (isActive) {
                delay(1_000L)
                val stream = _state.value.activeStream ?: continue
                val now = System.currentTimeMillis()
                val bytesNow = totalBytesReceived.get()
                val elapsedSec = ((now - windowStartMs).coerceAtLeast(1L)) / 1000.0
                val measuredBps = (((bytesNow - windowBytes).coerceAtLeast(0L) * 8.0) / elapsedSec).toLong()
                if (now - windowStartMs >= 4_000L) {
                    windowStartMs = now
                    windowBytes = bytesNow
                }

                val pos = exoPlayer.currentPosition.coerceAtLeast(0L)
                val dur = exoPlayer.duration.takeIf { it > 0L } ?: 0L
                val buf = exoPlayer.bufferedPosition.coerceAtLeast(0L)

                // PRD-37 § 4.3: Check insufficient bandwidth on heavy VOD files
                val bwAssessment = if (
                    (stream.kind == StreamKind.VOD_MOVIE || stream.kind == StreamKind.VOD_EPISODE) &&
                    bandwidthWarningDismissedForItemId != stream.itemId &&
                    measuredBps > 0L
                ) {
                    assessBandwidth(
                        measuredBitsPerSec = measuredBps,
                        fileSizeBytes = stream.expectedFileSizeBytes,
                        durationMs = dur.takeIf { it > 0L } ?: stream.expectedDurationMs,
                    )?.takeIf { it.isInsufficient }
                } else {
                    null
                }

                _state.update {
                    it.copy(
                        positionMs = pos,
                        durationMs = dur,
                        bufferedPositionMs = buf,
                        measuredBitrateBps = measuredBps,
                        bandwidthWarning = bwAssessment ?: it.bandwidthWarning,
                    )
                }

                // Stall watchdog: NEVER restarts while bytes are arriving!
                if (watchdog.shouldRestartStalledStream(
                        isBuffering = _state.value.isBuffering,
                        totalBytesReceived = bytesNow,
                        nowMs = now,
                    )
                ) {
                    logger.warn("PLAYER", "Blocage détecté sans octets reçus -> relance sur la même session")
                    openInternal(stream.copy(startPositionMs = pos), resetRetries = false)
                }
            }
        }
    }

    private fun updateAvailableTracks(tracks: Tracks) {
        val audioList = mutableListOf<TrackOption>()
        val subList = mutableListOf<TrackOption>()

        tracks.groups.forEachIndexed { groupIdx, group ->
            val type = group.type
            if (type != C.TRACK_TYPE_AUDIO && type != C.TRACK_TYPE_TEXT) return@forEachIndexed
            for (trackIdx in 0 until group.length) {
                val format = group.getTrackFormat(trackIdx)
                val label = format.label
                    ?: format.language?.uppercase()
                    ?: "Piste ${trackIdx + 1}"
                val option = TrackOption(
                    id = "$type:$groupIdx:$trackIdx",
                    groupIndex = groupIdx,
                    trackIndex = trackIdx,
                    label = label,
                    language = format.language,
                    isSelected = group.isTrackSelected(trackIdx),
                )
                if (type == C.TRACK_TYPE_AUDIO) audioList += option else subList += option
            }
        }

        val textDisabled = exoPlayer.trackSelectionParameters.disabledTrackTypes.contains(C.TRACK_TYPE_TEXT)
        _state.update {
            it.copy(
                audioTracks = audioList.toImmutableList(),
                subtitleTracks = subList.toImmutableList(),
                subtitlesDisabled = textDisabled,
            )
        }
    }

    override fun togglePlayPause() {
        mainScope.launch {
            if (exoPlayer.isPlaying) exoPlayer.pause() else exoPlayer.play()
        }
    }

    override fun pause() {
        mainScope.launch { exoPlayer.pause() }
    }

    override fun resume() {
        mainScope.launch { exoPlayer.play() }
    }

    override fun seekTo(positionMs: Long) {
        mainScope.launch {
            exoPlayer.seekTo(positionMs.coerceAtLeast(0L))
        }
    }

    override fun seekBy(deltaMs: Long) {
        mainScope.launch {
            val target = (exoPlayer.currentPosition + deltaMs).coerceAtLeast(0L)
            exoPlayer.seekTo(target)
        }
    }

    override fun selectAudioTrack(groupIndex: Int, trackIndex: Int) {
        mainScope.launch {
            val group = exoPlayer.currentTracks.groups.getOrNull(groupIndex) ?: return@launch
            exoPlayer.trackSelectionParameters = exoPlayer.trackSelectionParameters
                .buildUpon()
                .setOverrideForType(TrackSelectionOverride(group.mediaTrackGroup, trackIndex))
                .build()
        }
    }

    override fun selectSubtitleTrack(groupIndex: Int?, trackIndex: Int?) {
        mainScope.launch {
            val builder = exoPlayer.trackSelectionParameters.buildUpon()
            if (groupIndex == null || trackIndex == null) {
                builder.setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true)
            } else {
                val group = exoPlayer.currentTracks.groups.getOrNull(groupIndex) ?: return@launch
                builder.setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false)
                builder.setOverrideForType(TrackSelectionOverride(group.mediaTrackGroup, trackIndex))
            }
            exoPlayer.trackSelectionParameters = builder.build()
        }
    }

    override fun setSubtitleOffsetMs(offsetMs: Long) {
        _state.update { it.copy(subtitleOffsetMs = offsetMs) }
    }

    override fun dismissBandwidthWarning() {
        bandwidthWarningDismissedForItemId = _state.value.activeStream?.itemId
        _state.update { it.copy(bandwidthWarning = null) }
    }

    override fun stop() {
        mainScope.launch {
            retryJob?.cancel()
            tickerJob?.cancel()
            exoPlayer.stop()
            exoPlayer.clearMediaItems()
            _state.value = PlayerEngineState()
            ioScope.launch { downloadsRepository.resumeAfterPlayback() }
        }
    }

    private fun extractHttpStatusCode(error: PlaybackException): Int? {
        var cur: Throwable? = error.cause
        while (cur != null) {
            if (cur is HttpDataSource.InvalidResponseCodeException) {
                return cur.responseCode
            }
            cur = cur.cause
        }
        return null
    }
}

