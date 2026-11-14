package com.pcoundia.buntu.feature.player

import android.content.Context
import androidx.compose.runtime.Immutable
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.pcoundia.buntu.core.domain.model.ChannelItem
import com.pcoundia.buntu.core.domain.model.DiscoveredPeer
import com.pcoundia.buntu.core.domain.model.EpgSlot
import com.pcoundia.buntu.core.domain.model.MovieItem
import com.pcoundia.buntu.core.domain.model.PlayableStream
import com.pcoundia.buntu.core.domain.model.StreamDiagnosis
import com.pcoundia.buntu.core.domain.model.StreamKind
import com.pcoundia.buntu.core.domain.model.UpNextContext
import com.pcoundia.buntu.core.domain.model.UpNextItem
import com.pcoundia.buntu.core.domain.model.UpNextPreferences
import com.pcoundia.buntu.core.domain.repository.CatalogRepository
import com.pcoundia.buntu.core.domain.repository.DownloadsRepository
import com.pcoundia.buntu.core.domain.repository.EpgRepository
import com.pcoundia.buntu.core.domain.repository.RecommendationsRepository
import com.pcoundia.buntu.core.domain.repository.RemotePlaybackRepository
import com.pcoundia.buntu.core.domain.repository.SettingsRepository
import com.pcoundia.buntu.core.domain.repository.WatchNextPublisher
import com.pcoundia.buntu.core.domain.usecase.NextUpTiming
import com.pcoundia.buntu.core.domain.usecase.ZapToChannelUseCase
import com.pcoundia.buntu.core.platform.device.DeviceCapabilities
import com.pcoundia.buntu.core.platform.work.DownloadForegroundWorker
import com.pcoundia.buntu.core.player.PlayerEngineState
import com.pcoundia.buntu.core.player.VideoAspectMode
import com.pcoundia.buntu.core.player.VideoEngine
import dagger.hilt.android.lifecycle.HiltViewModel
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.persistentListOf
import kotlinx.collections.immutable.toImmutableList
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import javax.inject.Inject

@Immutable
data class PlayerScreenUiState(
    val isTv: Boolean = false,
    val controlsVisible: Boolean = true,
    val isScreenLocked: Boolean = false,
    val showTrackSheet: Boolean = false,
    val showVersionsSheet: Boolean = false,
    val otherVersions: ImmutableList<MovieItem> = persistentListOf(),
    val statusToast: String? = null,
    /** Favorite button: shown for channels, films and episodes (an episode stars its series). */
    val canToggleFavorite: Boolean = false,
    val isFavorite: Boolean = false,
    /** "À suivre" row under the player (PRD-27), chosen by the engine. Empty when disabled in settings. */
    val upNextShelf: ImmutableList<UpNextItem> = persistentListOf(),
    /** End-of-playback card; `null` when hidden. */
    val nextUpCard: NextUpCardState? = null,
    // PRD-46: Live TV player improvements
    val pendingZapTitle: String? = null,
    val canRecallLive: Boolean = false,
    val channelDigitBuffer: String = "",
    val liveNowSlot: EpgSlot? = null,
    val liveNextSlot: EpgSlot? = null,
    val liveProgramProgress: Float = 0f,
    val liveRemainingMinutes: Int? = null,
    val canStartOverLive: Boolean = false,
    val liveMirrors: ImmutableList<ChannelItem> = persistentListOf(),
    val failoverBanner: String? = null,
    val showChannelDrawer: Boolean = false,
    val drawerChannels: ImmutableList<ChannelItem> = persistentListOf(),
    val sleepTimerMinutes: Int? = null,
    val sleepTimerRemainingSeconds: Int? = null,
)

/** The "Film suivant / Épisode suivant" card shown near or at the end of a title. */
@Immutable
data class NextUpCardState(
    val item: UpNextItem,
    /** Seconds before the next title starts; `null` when no countdown runs. */
    val countdownSecondsRemaining: Int? = null,
    /** "Êtes-vous toujours là ?" after [NextUpTiming.MAX_AUTO_CHAIN] titles chained without a touch. */
    val askStillWatching: Boolean = false,
)

/**
 * PRD-37 § 4, § 5.2, § 5.4, § 6 (37.2, 37.3, 37.6, 37.7):
 * Fullscreen video player ViewModel shared between Phone/Tablet and Android TV:
 * - Resolves VOD via single-connection Rust relay (`127.0.0.1`), Live TV, or Catchup replay
 * - Pauses downloads during single-connection playback and resumes them on exit
 * - Saves progress every 10s + updates Google TV Watch Next channel
 * - Handles audio/subtitle tracks, subtitle offset, insufficient-bandwidth actions, D-Pad zapping
 */
@HiltViewModel
class PlayerViewModel @Inject constructor(
    savedStateHandle: SavedStateHandle,
    @ApplicationContext private val appContext: Context,
    private val catalogRepository: CatalogRepository,
    private val epgRepository: EpgRepository,
    private val downloadsRepository: DownloadsRepository,
    private val settingsRepository: SettingsRepository,
    private val watchNextPublisher: WatchNextPublisher,
    private val zapToChannelUseCase: ZapToChannelUseCase,
    val videoEngine: VideoEngine,
    deviceCapabilities: DeviceCapabilities,
    private val remotePlaybackRepo: RemotePlaybackRepository,
    private val recommendationsRepository: RecommendationsRepository,
) : ViewModel() {

    private val itemId: Long = savedStateHandle.get<Long>("itemId")
        ?: savedStateHandle.get<String>("itemId")?.toLongOrNull()
        ?: 0L
    private val startPositionMs: Long = savedStateHandle.get<Long>("startPositionMs")
        ?: savedStateHandle.get<String>("startPositionMs")?.toLongOrNull()
        ?: 0L
    private val catchupStartEpoch: Long = savedStateHandle.get<Long>("catchupStartEpoch")
        ?: savedStateHandle.get<String>("catchupStartEpoch")?.toLongOrNull()
        ?: 0L
    private val catchupEndEpoch: Long = savedStateHandle.get<Long>("catchupEndEpoch")
        ?: savedStateHandle.get<String>("catchupEndEpoch")?.toLongOrNull()
        ?: 0L

    private val _screenState = MutableStateFlow(
        PlayerScreenUiState(isTv = deviceCapabilities.isTelevision),
    )
    val screenState: StateFlow<PlayerScreenUiState> = _screenState.asStateFlow()

    val engineState: StateFlow<PlayerEngineState> = videoEngine.state
    val availablePeers: StateFlow<List<DiscoveredPeer>> = remotePlaybackRepo.availablePeers
    val handoffStatus: StateFlow<String?> = remotePlaybackRepo.activeHandoffStatus

    fun playOnPeer(targetPeerId: String, onTransferred: () -> Unit) {
        val stream = videoEngine.state.value.activeStream?.takeIf { it.kind != StreamKind.LOCAL_FILE } ?: return
        viewModelScope.launch {
            val success = remotePlaybackRepo.startHandoff(
                targetPeerId = targetPeerId,
                contentKey = stream.stableHash,
                // The account key computed in Rust (PRD-41 identity), never the server address.
                sourceKey = remotePlaybackRepo.sourceKeyForItem(stream.itemId),
                itemKind = when (stream.kind) {
                    StreamKind.LIVE, StreamKind.CATCHUP -> "live"
                    StreamKind.VOD_EPISODE -> "episode"
                    else -> "movie"
                },
                providerRef = null,
                title = stream.title,
                positionMs = videoEngine.state.value.positionMs,
            )
            if (success) {
                stopPlaybackAndCleanup()
                onTransferred()
            }
        }
    }

    private var progressSaverJob: Job? = null
    private var pausedDownloadsForSession: Boolean = false

    // PRD-27: end-of-playback state (same behaviour as Apple `UpNextModel`).
    private var upNextPrefs = UpNextPreferences()
    private var nextUp: UpNextItem? = null
    private var currentMediaItemId: Long? = null
    private var dismissedForCredits = false
    private var endHandledForItemId: Long? = null
    private var autoChainCount = 0
    private var upNextLoadJob: Job? = null
    private var countdownJob: Job? = null

    // PRD-46 Live comfort, mirrors, zapping & timer state
    internal var zapDebounceMs: Long = 250L
    internal var digitCommitMs: Long = 1_200L
    internal var sleepTimerTickMs: Long = 1_000L
    private var currentLiveChannel: ChannelItem? = null
    private var previousLiveChannelId: Long? = null
    private var pendingZapChannel: ChannelItem? = null
    private var pendingFailoverChannelId: Long? = null
    private var activeGroupTitle: String? = null
    private val attemptedMirrorIds = mutableSetOf<Long>()
    private var mirrorFailoverCount = 0
    private var lastHandledFailureKey: String? = null
    private var zapDebounceJob: Job? = null
    private var digitInputJob: Job? = null
    private var liveContextJob: Job? = null
    private var failoverBannerJob: Job? = null
    private var sleepTimerJob: Job? = null

    init {
        startRequestedStream()
        startPeriodicProgressSaver()
        observePlaybackForUpNext()
    }

    /**
     * Follows the engine: a new title (zapping, other version, next episode) reloads the "À suivre" data;
     * the last minutes show the card; the real end starts the countdown.
     */
    private fun observePlaybackForUpNext() {
        viewModelScope.launch {
            upNextPrefs = runCatching { settingsRepository.currentPreferences().upNext }.getOrDefault(UpNextPreferences())
            videoEngine.state.collect { snap ->
                val stream = snap.activeStream
                if (stream?.itemId != currentMediaItemId) {
                    onMediaChanged(stream)
                }
                if (stream == null) return@collect
                if (stream.kind == StreamKind.LIVE && snap.diagnosis != null) {
                    maybeAutoFailover(stream, snap.diagnosis)
                }
                if (snap.isEnded) {
                    if (endHandledForItemId != stream.itemId) {
                        endHandledForItemId = stream.itemId
                        onPlaybackEnded()
                    }
                } else {
                    maybePresentCardNearEnd(snap.positionMs, snap.durationMs)
                }
            }
        }
    }

    private fun onMediaChanged(stream: PlayableStream?) {
        val prevId = currentMediaItemId
        currentMediaItemId = stream?.itemId
        countdownJob?.cancel()
        upNextLoadJob?.cancel()
        liveContextJob?.cancel()
        nextUp = null
        dismissedForCredits = false
        endHandledForItemId = null
        lastHandledFailureKey = null

        val isLiveOrReplay = stream?.kind == StreamKind.LIVE || stream?.kind == StreamKind.CATCHUP
        val isFailoverHop = stream != null && stream.itemId == pendingFailoverChannelId
        if (isFailoverHop) {
            pendingFailoverChannelId = null
        } else if (stream?.kind == StreamKind.LIVE) {
            attemptedMirrorIds.clear()
            mirrorFailoverCount = 0
            if (prevId != null && prevId != stream.itemId) {
                previousLiveChannelId = prevId
            }
        } else if (stream?.kind != StreamKind.CATCHUP) {
            attemptedMirrorIds.clear()
            mirrorFailoverCount = 0
        }

        val canFavorite = stream != null &&
            (stream.kind == StreamKind.LIVE || stream.kind == StreamKind.VOD_MOVIE || stream.kind == StreamKind.VOD_EPISODE)
        _screenState.update {
            it.copy(
                nextUpCard = null,
                upNextShelf = persistentListOf(),
                canToggleFavorite = canFavorite,
                isFavorite = false,
                canRecallLive = stream?.kind == StreamKind.LIVE && previousLiveChannelId != null && previousLiveChannelId != stream.itemId,
                liveNowSlot = if (isLiveOrReplay) it.liveNowSlot else null,
                liveNextSlot = if (isLiveOrReplay) it.liveNextSlot else null,
                liveProgramProgress = if (isLiveOrReplay) it.liveProgramProgress else 0f,
                liveRemainingMinutes = if (isLiveOrReplay) it.liveRemainingMinutes else null,
                canStartOverLive = false,
                liveMirrors = if (stream?.kind == StreamKind.LIVE && isFailoverHop) it.liveMirrors else persistentListOf(),
            )
        }
        if (stream == null) return

        if (isLiveOrReplay) {
            loadLiveChannelContext(stream)
        }
        if (!canFavorite) return

        val itemId = stream.itemId
        val context = if (stream.kind == StreamKind.LIVE) UpNextContext.LIVE else UpNextContext.PLAYING
        upNextLoadJob = viewModelScope.launch {
            val favorite = runCatching { catalogRepository.isFavoriteForPlayback(itemId) }.getOrDefault(false)
            val shelf = if (upNextPrefs.shelfEnabled) {
                runCatching { recommendationsRepository.upNextFor(itemId, context) }.getOrDefault(persistentListOf())
            } else {
                persistentListOf()
            }
            // A channel has no "next" title; films and episodes ask the engine (saga, next episode…).
            val next = if (stream.kind == StreamKind.LIVE) {
                null
            } else {
                runCatching { recommendationsRepository.nextUpAfter(itemId) }.getOrNull() ?: shelf.firstOrNull()
            }
            if (currentMediaItemId != itemId) return@launch
            nextUp = next
            _screenState.update { it.copy(isFavorite = favorite, upNextShelf = shelf) }
        }
    }

    private fun maybePresentCardNearEnd(positionMs: Long, durationMs: Long) {
        val next = nextUp ?: return
        if (!upNextPrefs.nextUpCardEnabled || dismissedForCredits) return
        if (_screenState.value.nextUpCard != null) return
        if (NextUpTiming.isNearEnd(positionMs, durationMs)) {
            _screenState.update { it.copy(nextUpCard = NextUpCardState(item = next)) }
        }
    }

    private fun onPlaybackEnded() {
        viewModelScope.launch {
            // Saved at the very end, so the engine counts the title as watched.
            persistCurrentProgress()
            upNextLoadJob?.join()
            val next = nextUp
            if (next == null) {
                _screenState.update { it.copy(controlsVisible = true) }
                return@launch
            }
            dismissedForCredits = false
            if (!upNextPrefs.autoPlayNext) {
                _screenState.update { it.copy(nextUpCard = NextUpCardState(item = next)) }
            } else if (autoChainCount >= NextUpTiming.MAX_AUTO_CHAIN) {
                _screenState.update { it.copy(nextUpCard = NextUpCardState(item = next, askStillWatching = true)) }
            } else {
                startCountdown(next)
            }
        }
    }

    private fun startCountdown(next: UpNextItem) {
        countdownJob?.cancel()
        countdownJob = viewModelScope.launch {
            var remaining = upNextPrefs.countdownSeconds.coerceAtLeast(1)
            while (remaining > 0) {
                _screenState.update { it.copy(nextUpCard = NextUpCardState(item = next, countdownSecondsRemaining = remaining)) }
                delay(1_000L)
                remaining -= 1
            }
            autoChainCount += 1
            openUpNext(next)
        }
    }

    /** "Lire maintenant" on the card. */
    fun playNextUpNow() {
        val next = _screenState.value.nextUpCard?.item ?: nextUp ?: return
        countdownJob?.cancel()
        autoChainCount += 1
        openUpNext(next)
    }

    /** A title picked in the "À suivre" row: a deliberate choice, so the auto-chain counter restarts. */
    fun playUpNextItem(item: UpNextItem) {
        countdownJob?.cancel()
        autoChainCount = 0
        openUpNext(item)
    }

    /** "Générique": hides the card until the real end of the title. */
    fun dismissNextUpForCredits() {
        countdownJob?.cancel()
        dismissedForCredits = true
        _screenState.update { it.copy(nextUpCard = null) }
    }

    /** "Annuler" during the countdown: the card stays, nothing starts by itself. */
    fun cancelNextUpCountdown() {
        countdownJob?.cancel()
        autoChainCount = 0
        _screenState.update { state ->
            state.copy(nextUpCard = state.nextUpCard?.copy(countdownSecondsRemaining = null))
        }
    }

    /** "Continuer" after "Êtes-vous toujours là ?". */
    fun confirmStillWatching() {
        autoChainCount = 0
        val next = _screenState.value.nextUpCard?.item ?: return
        openUpNext(next)
    }

    /** "Arrêter" after "Êtes-vous toujours là ?", or closing the card at the end. */
    fun closeNextUpCard() {
        countdownJob?.cancel()
        autoChainCount = 0
        _screenState.update { it.copy(nextUpCard = null, controlsVisible = true) }
    }

    /** "Pas intéressé" (long press / Menu key on a card of the row). */
    fun dismissUpNextItem(item: UpNextItem) {
        viewModelScope.launch {
            runCatching { recommendationsRepository.dismissUpNext(item.stableHash) }
            val remaining = _screenState.value.upNextShelf.filterNot { it.stableHash == item.stableHash }.toImmutableList()
            if (nextUp?.stableHash == item.stableHash) {
                nextUp = remaining.firstOrNull { it.kind != StreamKind.LIVE }
            }
            _screenState.update { it.copy(upNextShelf = remaining) }
        }
    }

    private fun openUpNext(item: UpNextItem) {
        viewModelScope.launch {
            _screenState.update { it.copy(nextUpCard = null) }
            persistCurrentProgress()
            // Start 0: the repository resumes at the saved position unless the title was finished.
            val stream = catalogRepository.resolvePlayableStream(item.itemId, 0L) ?: return@launch
            if (stream.kind == StreamKind.LIVE) {
                settingsRepository.setLastChannelId(stream.itemId)
                videoEngine.zap(stream)
            } else {
                // Same player: ExoPlayer drops the previous provider connection before opening this one.
                videoEngine.play(stream)
            }
            loadAlternateVersionsIfMovie(stream)
        }
    }

    fun toggleFavorite() {
        val stream = videoEngine.state.value.activeStream ?: return
        if (!_screenState.value.canToggleFavorite) return
        viewModelScope.launch {
            val newState = runCatching { catalogRepository.toggleFavoriteForPlayback(stream.itemId) }
                .getOrElse { return@launch }
            _screenState.update { it.copy(isFavorite = newState) }
        }
    }

    fun setPlaybackSpeed(speed: Float) {
        videoEngine.setPlaybackSpeed(speed)
    }

    private fun startRequestedStream() {
        if (itemId <= 0L) return
        // Reuse already-playing stream if user expanded inline Live player to fullscreen!
        val existing = videoEngine.state.value.activeStream
        if (existing != null && existing.itemId == itemId && catchupStartEpoch <= 0L) {
            loadAlternateVersionsIfMovie(existing)
            return
        }

        viewModelScope.launch {
            val stream = if (catchupStartEpoch > 0L && catchupEndEpoch > catchupStartEpoch) {
                epgRepository.buildCatchupStream(itemId, catchupStartEpoch, catchupEndEpoch)
            } else {
                catalogRepository.resolvePlayableStream(itemId, startPositionMs)
            } ?: return@launch

            val prefs = settingsRepository.currentPreferences()
            if (minOf(prefs.assumedMaxConnections, stream.maxConnectionsForSource) <= 1) {
                pausedDownloadsForSession = true
                downloadsRepository.pauseAllForPlayback()
            }
            if (stream.kind == StreamKind.LIVE) {
                settingsRepository.setLastChannelId(stream.itemId)
            }
            loadAlternateVersionsIfMovie(stream)
            videoEngine.play(stream)
        }
    }

    private fun loadAlternateVersionsIfMovie(stream: PlayableStream) {
        if (stream.kind != StreamKind.VOD_MOVIE) {
            _screenState.update { it.copy(otherVersions = persistentListOf()) }
            return
        }
        viewModelScope.launch {
            runCatching { catalogRepository.getMovieDetail(stream.itemId) }
                .onSuccess { detail ->
                    if (detail != null && detail.otherVersions.isNotEmpty()) {
                        _screenState.update { it.copy(otherVersions = detail.otherVersions) }
                    }
                }
        }
    }

    private fun startPeriodicProgressSaver() {
        progressSaverJob?.cancel()
        progressSaverJob = viewModelScope.launch {
            while (isActive) {
                delay(10_000L)
                persistCurrentProgress()
            }
        }
    }

    suspend fun persistCurrentProgress() {
        val snap = videoEngine.state.value
        val stream = snap.activeStream ?: return
        if (stream.kind != StreamKind.VOD_MOVIE && stream.kind != StreamKind.VOD_EPISODE) return
        if (snap.positionMs <= 5_000L) return

        catalogRepository.recordWatchProgress(
            stableHash = stream.stableHash,
            positionMs = snap.positionMs,
            durationMs = snap.durationMs,
        )
        watchNextPublisher.publishContinueWatching(
            itemId = stream.itemId,
            title = stream.title,
            posterUrl = stream.posterUrl,
            positionMs = snap.positionMs,
            durationMs = snap.durationMs,
            isEpisode = stream.kind == StreamKind.VOD_EPISODE,
        )
    }

    fun toggleControls() {
        _screenState.update { it.copy(controlsVisible = !it.controlsVisible) }
    }

    fun hideControls() {
        _screenState.update { it.copy(controlsVisible = false) }
    }

    fun showControls() {
        _screenState.update { it.copy(controlsVisible = true) }
    }

    /**
     * YouTube-style screen lock: hides playback controls and sheets and ignores accidental taps/seeks
     * until [unlockScreen] is called.
     */
    fun lockScreen() {
        _screenState.update {
            it.copy(
                isScreenLocked = true,
                controlsVisible = true,
                showTrackSheet = false,
                showVersionsSheet = false,
                showChannelDrawer = false,
            )
        }
    }

    fun unlockScreen() {
        _screenState.update {
            it.copy(
                isScreenLocked = false,
                controlsVisible = true,
            )
        }
    }

    fun toggleTrackSheet(visible: Boolean) {
        if (_screenState.value.isScreenLocked && visible) return
        _screenState.update { it.copy(showTrackSheet = visible) }
    }

    fun toggleVersionsSheet(visible: Boolean) {
        if (_screenState.value.isScreenLocked && visible) return
        _screenState.update { it.copy(showVersionsSheet = visible) }
    }

    fun switchVersion(altMovie: MovieItem) {
        _screenState.update { it.copy(showVersionsSheet = false) }
        viewModelScope.launch {
            val currentPos = videoEngine.state.value.positionMs
            val nextStream = catalogRepository.resolvePlayableStream(altMovie.id, currentPos)
                ?: return@launch
            videoEngine.play(nextStream)
        }
    }

    fun zapAdjacentLive(delta: Int) {
        val current = videoEngine.state.value.activeStream ?: return
        if (current.kind != StreamKind.LIVE || delta == 0) return
        val anchorId = pendingZapChannel?.id ?: current.itemId
        zapDebounceJob?.cancel()
        zapDebounceJob = viewModelScope.launch {
            val target = runCatching {
                catalogRepository.getAdjacentChannel(anchorId, delta, activeGroupTitle)
            }.getOrNull() ?: return@launch
            pendingZapChannel = target
            _screenState.update { it.copy(pendingZapTitle = target.name) }
            delay(zapDebounceMs)
            pendingZapChannel = null
            _screenState.update { it.copy(pendingZapTitle = null) }
            val nextStream = zapToChannelUseCase.byId(target.id) ?: return@launch
            videoEngine.zap(nextStream)
        }
    }

    fun recallPreviousChannel() {
        val prevId = previousLiveChannelId ?: return
        if (prevId == videoEngine.state.value.activeStream?.itemId) return
        zapDebounceJob?.cancel()
        pendingZapChannel = null
        _screenState.update { it.copy(pendingZapTitle = null) }
        viewModelScope.launch {
            val stream = zapToChannelUseCase.byId(prevId) ?: return@launch
            videoEngine.zap(stream)
        }
    }

    fun appendChannelDigit(digit: Int) {
        if (digit !in 0..9) return
        val current = videoEngine.state.value.activeStream
        if (current?.kind != StreamKind.LIVE) return
        val updated = (_screenState.value.channelDigitBuffer + digit.toString()).take(4)
        _screenState.update { it.copy(channelDigitBuffer = updated, controlsVisible = true) }
        digitInputJob?.cancel()
        digitInputJob = viewModelScope.launch {
            delay(digitCommitMs)
            commitChannelNumber()
        }
    }

    fun commitChannelNumber() {
        digitInputJob?.cancel()
        val raw = _screenState.value.channelDigitBuffer
        _screenState.update { it.copy(channelDigitBuffer = "") }
        val number = raw.toIntOrNull()?.takeIf { it > 0 } ?: return
        viewModelScope.launch {
            val next = zapToChannelUseCase.byNumber(number)
            if (next != null) {
                pendingZapChannel = null
                _screenState.update { it.copy(pendingZapTitle = null) }
                videoEngine.zap(next)
            } else {
                _screenState.update { it.copy(statusToast = "Chaîne $number introuvable") }
            }
        }
    }

    fun startOverCurrentProgram() {
        val channelId = currentLiveChannel?.id ?: videoEngine.state.value.activeStream?.itemId ?: return
        val slot = _screenState.value.liveNowSlot ?: return
        viewModelScope.launch {
            val stream = epgRepository.buildCatchupStream(channelId, slot.startEpochSecs, slot.endEpochSecs)
            if (stream != null) {
                videoEngine.play(stream)
            } else {
                _screenState.update { it.copy(statusToast = "Replay indisponible pour ce programme") }
            }
        }
    }

    fun returnToLive() {
        val channelId = videoEngine.state.value.activeStream?.itemId ?: currentLiveChannel?.id ?: return
        viewModelScope.launch {
            val stream = zapToChannelUseCase.byId(channelId) ?: return@launch
            videoEngine.zap(stream)
        }
    }

    fun switchLiveMirror(mirror: ChannelItem) {
        if (mirror.id == videoEngine.state.value.activeStream?.itemId) return
        zapDebounceJob?.cancel()
        pendingZapChannel = null
        _screenState.update { it.copy(pendingZapTitle = null, showChannelDrawer = false) }
        viewModelScope.launch {
            val stream = zapToChannelUseCase.byId(mirror.id) ?: return@launch
            videoEngine.zap(stream)
        }
    }

    fun toggleChannelDrawer(visible: Boolean? = null) {
        val nextVisible = visible ?: !_screenState.value.showChannelDrawer
        if (_screenState.value.isScreenLocked && nextVisible) return
        _screenState.update { it.copy(showChannelDrawer = nextVisible) }
        if (nextVisible && _screenState.value.drawerChannels.isEmpty()) {
            viewModelScope.launch {
                val channels = runCatching {
                    catalogRepository.listChannelsInGroup(activeGroupTitle, limit = 150)
                }.getOrDefault(persistentListOf())
                _screenState.update { it.copy(drawerChannels = channels) }
            }
        }
    }

    fun selectChannelFromDrawer(channel: ChannelItem) {
        _screenState.update { it.copy(showChannelDrawer = false, pendingZapTitle = null) }
        zapDebounceJob?.cancel()
        pendingZapChannel = null
        if (channel.id == videoEngine.state.value.activeStream?.itemId) return
        viewModelScope.launch {
            val stream = zapToChannelUseCase.byId(channel.id) ?: return@launch
            videoEngine.zap(stream)
        }
    }

    fun cycleAspectMode() {
        val modes = VideoAspectMode.entries
        val current = videoEngine.state.value.aspectMode
        val next = modes[(modes.indexOf(current) + 1) % modes.size]
        setAspectMode(next)
    }

    fun setAspectMode(mode: VideoAspectMode) {
        videoEngine.setAspectMode(mode)
    }

    fun setSleepTimer(minutes: Int?) {
        sleepTimerJob?.cancel()
        if (minutes == null || minutes <= 0) {
            _screenState.update { it.copy(sleepTimerMinutes = null, sleepTimerRemainingSeconds = null) }
            return
        }
        _screenState.update { it.copy(sleepTimerMinutes = minutes) }
        startSleepCountdownSeconds(minutes * 60)
    }

    internal fun startSleepCountdownSeconds(seconds: Int) {
        sleepTimerJob?.cancel()
        val initial = seconds.coerceAtLeast(1)
        _screenState.update { it.copy(sleepTimerRemainingSeconds = initial) }
        sleepTimerJob = viewModelScope.launch {
            var remaining = initial
            while (remaining > 0 && isActive) {
                delay(sleepTimerTickMs)
                remaining -= 1
                if (remaining <= 0) {
                    _screenState.update {
                        it.copy(
                            sleepTimerMinutes = null,
                            sleepTimerRemainingSeconds = null,
                            statusToast = "Minuteur de veille écoulé — lecture arrêtée",
                        )
                    }
                    videoEngine.stop()
                    return@launch
                }
                _screenState.update { it.copy(sleepTimerRemainingSeconds = remaining) }
            }
        }
    }

    fun dismissStatusToast() {
        _screenState.update { it.copy(statusToast = null) }
    }

    private fun loadLiveChannelContext(stream: PlayableStream) {
        liveContextJob?.cancel()
        liveContextJob = viewModelScope.launch {
            val channel = runCatching { catalogRepository.getChannelById(stream.itemId) }.getOrNull()
            if (currentMediaItemId != stream.itemId) return@launch
            if (channel != null) {
                currentLiveChannel = channel
                val groupChanged = channel.groupTitle != activeGroupTitle
                activeGroupTitle = channel.groupTitle
                if (groupChanged) {
                    _screenState.update { it.copy(drawerChannels = persistentListOf()) }
                }
            }
            if (stream.kind == StreamKind.LIVE) {
                val mirrors = runCatching { catalogRepository.findChannelMirrors(stream.itemId) }
                    .getOrDefault(persistentListOf())
                if (currentMediaItemId == stream.itemId) {
                    _screenState.update { it.copy(liveMirrors = mirrors) }
                }
            }
            while (currentMediaItemId == stream.itemId && isActive) {
                refreshLiveEpgSlots(channel, stream.kind == StreamKind.LIVE)
                delay(30_000L)
            }
        }
    }

    private suspend fun refreshLiveEpgSlots(channel: ChannelItem?, isLiveKind: Boolean) {
        val nowSecs = System.currentTimeMillis() / 1000L
        val tvgId = channel?.tvgId?.takeIf(String::isNotBlank)
        val slots = if (tvgId != null) {
            runCatching {
                epgRepository.getChannelPrograms(tvgId, nowSecs - 4 * 3600L, nowSecs + 6 * 3600L)
            }.getOrDefault(persistentListOf())
        } else {
            persistentListOf()
        }
        val liveSlot = slots.firstOrNull { it.isLiveAt(nowSecs) }
        val nextSlot = if (liveSlot != null) {
            slots.firstOrNull { it.startEpochSecs >= liveSlot.endEpochSecs }
        } else {
            slots.firstOrNull { it.startEpochSecs > nowSecs }
        }
        val progress = when {
            liveSlot != null && liveSlot.endEpochSecs > liveSlot.startEpochSecs -> {
                ((nowSecs - liveSlot.startEpochSecs).toFloat() /
                    (liveSlot.endEpochSecs - liveSlot.startEpochSecs).toFloat()).coerceIn(0f, 1f)
            }
            channel != null && channel.nowTitle != null -> channel.nowProgress
            else -> 0f
        }
        val remainingMin = liveSlot?.let {
            val secs = (it.endEpochSecs - nowSecs).coerceAtLeast(0L)
            ((secs + 59L) / 60L).toInt()
        }
        val canStartOver = isLiveKind && liveSlot != null &&
            (liveSlot.isCatchupAvailable || (channel?.catchupDays ?: 0) > 0)
        _screenState.update {
            it.copy(
                liveNowSlot = liveSlot,
                liveNextSlot = nextSlot,
                liveProgramProgress = progress,
                liveRemainingMinutes = remainingMin,
                canStartOverLive = canStartOver,
            )
        }
    }

    private fun maybeAutoFailover(stream: PlayableStream, diagnosis: StreamDiagnosis?) {
        if (diagnosis == null || stream.kind != StreamKind.LIVE) return
        val failureKey = "${stream.itemId}:${diagnosis.userMessage}"
        if (lastHandledFailureKey == failureKey || mirrorFailoverCount >= 2) return
        val mirrors = _screenState.value.liveMirrors
        val nextMirror = mirrors.firstOrNull { it.id != stream.itemId && it.id !in attemptedMirrorIds } ?: return
        lastHandledFailureKey = failureKey
        attemptedMirrorIds += stream.itemId
        attemptedMirrorIds += nextMirror.id
        mirrorFailoverCount += 1
        pendingFailoverChannelId = nextMirror.id
        failoverBannerJob?.cancel()
        _screenState.update { it.copy(failoverBanner = "Bascule vers ${nextMirror.name}") }
        failoverBannerJob = viewModelScope.launch {
            delay(4_000L)
            _screenState.update { it.copy(failoverBanner = null) }
        }
        viewModelScope.launch {
            val nextStream = zapToChannelUseCase.byId(nextMirror.id) ?: return@launch
            videoEngine.zap(nextStream)
        }
    }

    fun downloadInsteadAndExit(onNavigateToDownloads: () -> Unit) {
        val stream = videoEngine.state.value.activeStream ?: return
        viewModelScope.launch {
            persistCurrentProgress()
            videoEngine.stop()
            runCatching {
                downloadsRepository.enqueueDownload(stream.itemId)
                val prefs = settingsRepository.currentPreferences()
                DownloadForegroundWorker.enqueue(appContext, allowCellular = prefs.downloadOverCellular)
            }
            onNavigateToDownloads()
        }
    }

    fun stopPlaybackAndCleanup() {
        viewModelScope.launch {
            persistCurrentProgress()
            val activeKind = videoEngine.state.value.activeStream?.kind
            if (activeKind != StreamKind.LIVE) {
                videoEngine.stop()
                if (pausedDownloadsForSession) {
                    downloadsRepository.resumeAfterPlayback()
                }
            }
        }
    }

    override fun onCleared() {
        progressSaverJob?.cancel()
        countdownJob?.cancel()
        zapDebounceJob?.cancel()
        digitInputJob?.cancel()
        liveContextJob?.cancel()
        failoverBannerJob?.cancel()
        sleepTimerJob?.cancel()
        super.onCleared()
    }
}

