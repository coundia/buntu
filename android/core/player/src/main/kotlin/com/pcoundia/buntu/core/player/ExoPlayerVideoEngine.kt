package com.pcoundia.buntu.core.player

import android.content.Context
import android.net.ConnectivityManager
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
import com.pcoundia.buntu.core.domain.model.LiveBuffer
import com.pcoundia.buntu.core.domain.model.StreamDiagnosis
import com.pcoundia.buntu.core.domain.model.StreamKind
import com.pcoundia.buntu.core.domain.repository.DownloadsRepository
import com.pcoundia.buntu.core.domain.repository.SettingsRepository
import com.pcoundia.buntu.core.domain.usecase.AssessStreamBandwidthUseCase
import com.pcoundia.buntu.core.platform.device.DeviceCapabilities
import com.pcoundia.buntu.core.platform.logging.RedactedAppLogger
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.collections.immutable.persistentListOf
import kotlinx.collections.immutable.toImmutableList
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineExceptionHandler
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
    private val playbackHealth: com.pcoundia.buntu.core.domain.repository.PlaybackHealthRepository,
) : VideoEngine {

    private val engineExceptionHandler = CoroutineExceptionHandler { _, throwable ->
        val diagnosis = StallWatchdog.classifyFailure(extractHttpStatusCode(throwable), throwable)
        logger.error(
            "PLAYER",
            "Exception lecteur interceptée (${RedactedAppLogger.describeStreamUrl(_state.value.activeStream?.originalUrl)}) -> ${diagnosis.userMessage}",
            throwable,
        )
        _state.update {
            it.copy(
                isPlaying = false,
                isBuffering = false,
                diagnosis = diagnosis,
            )
        }
    }

    private val mainScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate + engineExceptionHandler)
    private val ioScope = CoroutineScope(SupervisorJob() + Dispatchers.IO + engineExceptionHandler)

    private val _state = MutableStateFlow(PlayerEngineState())
    override val state: StateFlow<PlayerEngineState> = _state.asStateFlow()

    private var healthWrite: Job? = null
    private val liveHealth = LiveStreamHealthObserver { hash, broken ->
        _state.update {
            it.copy(
                isBroken = broken,
                isBuffering = if (broken) it.isBuffering else false,
                diagnosis = if (broken) it.diagnosis else null,
            )
        }
        if (!broken) { retryJob?.cancel(); retryJob = null }
        val previous = healthWrite
        healthWrite = ioScope.launch {
            previous?.join()
            runCatching { playbackHealth.setLiveBroken(hash, broken) }
        }
    }

    private val totalBytesReceived = AtomicLong(0L)
    private var windowStartMs: Long = System.currentTimeMillis()
    private var windowBytes: Long = 0L
    private var errorRetryAttempt: Int = 0
    private var bandwidthWarningDismissedForItemId: Long? = null

    private val watchdog = StallWatchdog()
    private var tickerJob: Job? = null
    private var retryJob: Job? = null
    private val connectivity = context.getSystemService(ConnectivityManager::class.java)
    private var waitingForNetwork = false
    private var openingJob: Job? = null
    private var activeLiveBuffer = LiveBuffer.AUTO

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
                _state.update { it.copy(isBuffering = false, isEnded = false, diagnosis = null) }
            } else if (playbackState == Player.STATE_ENDED) {
                val kind = _state.value.activeStream?.kind
                // A live channel never "ends": a stop there is a network problem, left to the watchdog.
                val ended = kind == StreamKind.VOD_MOVIE || kind == StreamKind.VOD_EPISODE ||
                    kind == StreamKind.LOCAL_FILE || kind == StreamKind.CATCHUP
                val dur = exoPlayer.duration.takeIf { it > 0L }
                _state.update {
                    it.copy(
                        isBuffering = false,
                        isEnded = ended,
                        positionMs = dur ?: it.positionMs,
                        durationMs = dur ?: it.durationMs,
                    )
                }
            } else {
                _state.update { it.copy(isBuffering = buffering) }
            }
        }

        override fun onTracksChanged(tracks: Tracks) {
            updateAvailableTracks(tracks)
        }

        override fun onPlayerError(error: PlaybackException) {
            liveHealth.failed()
            val httpCode = extractHttpStatusCode(error)
            val diagnosis = StallWatchdog.classifyFailure(httpCode, error.cause ?: error, error.errorCode)
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
                    if (openingJob?.isActive == true) return@launch
                    val stream = _state.value.activeStream ?: return@launch
                    if (stream.kind != StreamKind.LOCAL_FILE && connectivity != null &&
                        connectivity.activeNetwork == null
                    ) {
                        waitingForNetwork = true
                        return@launch
                    }
                    val resumePos = exoPlayer.currentPosition.coerceAtLeast(0L)
                    openInternal(stream.copy(startPositionMs = resumePos), resetRetries = false)
                }
            }
        }
    }

    override fun play(stream: PlayableStream) {
        mainScope.launch {
            if (stream.maxConnectionsForSource <= 1) {
                ioScope.launch { runCatching { downloadsRepository.pauseAllForPlayback() } }
            }
            applyTvPreferences()
            openWithPreferences(stream)
        }
    }

    override fun zap(stream: PlayableStream) {
        // PRD-37 § 4.3: Reuse the exact same ExoPlayer & video surface without recreating either!
        mainScope.launch {
            openWithPreferences(stream)
        }
    }

    private fun openWithPreferences(stream: PlayableStream) {
        openingJob?.cancel()
        retryJob?.cancel()
        openingJob = mainScope.launch {
            activeLiveBuffer = if (stream.kind == StreamKind.LIVE) {
                try {
                    settingsRepository.currentPreferences().liveBuffer
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (_: Exception) {
                    LiveBuffer.AUTO
                }
            } else {
                LiveBuffer.AUTO
            }
            openInternal(stream, resetRetries = true)
        }
    }

    private fun openInternal(stream: PlayableStream, resetRetries: Boolean) {
        try {
            val shouldPlay = resetRetries || exoPlayer.playWhenReady
            retryJob?.cancel()
            if (resetRetries) {
                errorRetryAttempt = 0
                waitingForNetwork = false
                bandwidthWarningDismissedForItemId = null
            }
            liveHealth.open(stream.stableHash.takeIf { stream.kind == StreamKind.LIVE })
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
                .apply {
                    activeLiveBuffer.seconds?.let { seconds ->
                        setTag(activeLiveBuffer)
                        setLiveConfiguration(
                            MediaItem.LiveConfiguration.Builder()
                                .setTargetOffsetMs(seconds * 1_000L)
                                .setMinPlaybackSpeed(1f)
                                .setMaxPlaybackSpeed(1f)
                                .build(),
                        )
                    }
                }
                .setMediaMetadata(
                    MediaMetadata.Builder()
                        .setTitle(stream.title)
                        .setSubtitle(stream.subtitle)
                        .setArtworkUri(stream.posterUrl?.let(Uri::parse))
                        .build()
                )
                .build()

            // A live channel always plays at normal speed; films keep the speed chosen by the user.
            val speed = if (stream.kind == StreamKind.LIVE) 1.0f else _state.value.playbackSpeed
            exoPlayer.setPlaybackSpeed(speed)
            _state.update {
                it.copy(
                    activeStream = stream,
                    isBroken = playbackHealth.brokenChannels.value[stream.stableHash] ?: false,
                    isBuffering = true,
                    isEnded = false,
                    playbackSpeed = speed,
                    diagnosis = null,
                    bandwidthWarning = null,
                    isLiveSeekable = false,
                    liveOffsetMs = 0L,
                    measuredBitrateBps = 0L,
                    bufferedDurationMs = 0L,
                    videoWidth = 0,
                    videoHeight = 0,
                )
            }

            val mediaSource = mediaSourceFactory.createMediaSource(mediaItem)
            if (stream.startPositionMs > 0L && stream.kind != StreamKind.LIVE) {
                exoPlayer.setMediaSource(mediaSource, stream.startPositionMs)
            } else {
                exoPlayer.setMediaSource(mediaSource)
            }
            exoPlayer.prepare()
            exoPlayer.playWhenReady = shouldPlay
            ensurePositionAndWatchdogTicker()
        } catch (err: Throwable) {
            liveHealth.failed()
            val diagnosis = StallWatchdog.classifyFailure(extractHttpStatusCode(err), err)
            logger.error(
                "PLAYER",
                "Impossible d'ouvrir « ${stream.title} » (${RedactedAppLogger.describeStreamUrl(stream.originalUrl)}) -> ${diagnosis.userMessage}",
                err,
            )
            _state.update {
                it.copy(
                    activeStream = stream,
                    isPlaying = false,
                    isBuffering = false,
                    diagnosis = diagnosis,
                )
            }
        }
    }

    private fun applyTvPreferences() {
        if (!deviceCapabilities.isTelevision) return
        ioScope.launch {
            val prefs = runCatching { settingsRepository.currentPreferences() }.getOrNull() ?: return@launch
            mainScope.launch {
                runCatching {
                    exoPlayer.videoChangeFrameRateStrategy = if (prefs.autoFrameRateMatchingTv) {
                        C.VIDEO_CHANGE_FRAME_RATE_STRATEGY_ONLY_IF_SEAMLESS
                    } else {
                        C.VIDEO_CHANGE_FRAME_RATE_STRATEGY_OFF
                    }
                    trackSelector.parameters = trackSelector.buildUponParameters()
                        .setTunnelingEnabled(prefs.tunnelingEnabledTv)
                        .build()
                }.onFailure { err ->
                    logger.warn("PLAYER", "Préférences TV ignorées: ${err.message ?: err.javaClass.simpleName}")
                }
            }
        }
    }

    private fun ensurePositionAndWatchdogTicker() {
        if (tickerJob?.isActive == true) return
        tickerJob = mainScope.launch {
            while (isActive) {
                delay(1_000L)
                val stream = _state.value.activeStream ?: continue
                try {
                    val now = System.currentTimeMillis()
                    val bytesNow = totalBytesReceived.get()
                    val elapsedSec = ((now - windowStartMs).coerceAtLeast(1L)) / 1000.0
                    val measuredBps = (((bytesNow - windowBytes).coerceAtLeast(0L) * 8.0) / elapsedSec).toLong()
                    if (now - windowStartMs >= 4_000L) {
                        windowStartMs = now
                        windowBytes = bytesNow
                    }

                    val pos = exoPlayer.currentPosition.coerceAtLeast(0L)
                    liveHealth.progress(pos, exoPlayer.isPlaying)
                    val dur = exoPlayer.duration.takeIf { it > 0L } ?: 0L
                    val buf = exoPlayer.bufferedPosition.coerceAtLeast(0L)
                    val bufferedDuration = exoPlayer.totalBufferedDuration.coerceAtLeast(0L)
                    val videoSize = exoPlayer.videoSize
                    val liveSeekable = stream.kind == StreamKind.LIVE &&
                        exoPlayer.isCurrentMediaItemLive &&
                        exoPlayer.isCurrentMediaItemSeekable
                    val liveOffset = if (liveSeekable && dur > 0L) (dur - pos).coerceAtLeast(0L) else 0L

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
                            bufferedDurationMs = bufferedDuration,
                            videoWidth = videoSize.width,
                            videoHeight = videoSize.height,
                            bandwidthWarning = bwAssessment ?: it.bandwidthWarning,
                            isLiveSeekable = liveSeekable,
                            liveOffsetMs = liveOffset,
                        )
                    }

                    if (stream.kind != StreamKind.LOCAL_FILE && connectivity != null) {
                        if (connectivity.activeNetwork == null) {
                            waitingForNetwork = true
                            watchdog.reset(now)
                            continue
                        }
                        if (waitingForNetwork) {
                            waitingForNetwork = false
                            errorRetryAttempt = 0
                            val diagnosis = _state.value.diagnosis
                            val recoverable = diagnosis?.isFinalError != true || diagnosis == StreamDiagnosis.UnknownHost
                            if (recoverable && exoPlayer.playerError != null && openingJob?.isActive != true) {
                                openInternal(stream.copy(startPositionMs = pos), resetRetries = false)
                                continue
                            }
                        }
                    }

                    // Stall watchdog: NEVER restarts while bytes are arriving!
                    if (openingJob?.isActive != true && watchdog.shouldRestartStalledStream(
                            isBuffering = _state.value.isBuffering,
                            totalBytesReceived = bytesNow,
                            nowMs = now,
                            minimumStallThresholdMs = if (activeLiveBuffer == LiveBuffer.AUTO) 0L else 15_000L,
                        )
                    ) {
                        liveHealth.failed()
                        logger.warn("PLAYER", "Blocage détecté sans octets reçus -> relance sur la même session")
                        openInternal(stream.copy(startPositionMs = pos), resetRetries = false)
                    }
                } catch (ce: CancellationException) {
                    throw ce
                } catch (err: Throwable) {
                    liveHealth.failed()
                    val diagnosis = StallWatchdog.classifyFailure(extractHttpStatusCode(err), err)
                    logger.error("PLAYER", "Erreur pendant la lecture: ${diagnosis.userMessage}", err)
                    _state.update { it.copy(isPlaying = false, isBuffering = false, diagnosis = diagnosis) }
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

    override fun setPlaybackSpeed(speed: Float) {
        mainScope.launch {
            if (_state.value.activeStream?.kind == StreamKind.LIVE) return@launch
            val clamped = speed.coerceIn(0.5f, 2.0f)
            exoPlayer.setPlaybackSpeed(clamped)
            _state.update { it.copy(playbackSpeed = clamped) }
        }
    }

    override fun setAspectMode(mode: VideoAspectMode) {
        _state.update { it.copy(aspectMode = mode) }
    }

    override fun setMuted(muted: Boolean) {
        mainScope.launch { exoPlayer.volume = if (muted) 0f else 1f }
        _state.update { it.copy(isMuted = muted) }
    }

    override fun seekToLiveEdge() {
        mainScope.launch {
            exoPlayer.seekToDefaultPosition()
            if (!exoPlayer.isPlaying) exoPlayer.play()
        }
    }

    override fun dismissBandwidthWarning() {
        bandwidthWarningDismissedForItemId = _state.value.activeStream?.itemId
        _state.update { it.copy(bandwidthWarning = null) }
    }

    override fun stop() {
        mainScope.launch {
            openingJob?.cancel()
            liveHealth.open(null)
            retryJob?.cancel()
            tickerJob?.cancel()
            runCatching {
                exoPlayer.stop()
                exoPlayer.clearMediaItems()
            }
            _state.value = PlayerEngineState(aspectMode = _state.value.aspectMode)
            ioScope.launch { runCatching { downloadsRepository.resumeAfterPlayback() } }
        }
    }

    private fun extractHttpStatusCode(error: Throwable?): Int? {
        var cur: Throwable? = error
        while (cur != null) {
            if (cur is HttpDataSource.InvalidResponseCodeException) {
                return cur.responseCode
            }
            cur = cur.cause
        }
        return null
    }
}

