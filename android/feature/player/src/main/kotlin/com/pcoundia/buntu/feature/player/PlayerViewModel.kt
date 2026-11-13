package com.pcoundia.buntu.feature.player

import android.content.Context
import androidx.compose.runtime.Immutable
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.pcoundia.buntu.core.domain.model.MovieItem
import com.pcoundia.buntu.core.domain.model.PlayableStream
import com.pcoundia.buntu.core.domain.model.StreamKind
import com.pcoundia.buntu.core.domain.model.DiscoveredPeer
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
        currentMediaItemId = stream?.itemId
        countdownJob?.cancel()
        upNextLoadJob?.cancel()
        nextUp = null
        dismissedForCredits = false
        endHandledForItemId = null
        val canFavorite = stream != null &&
            (stream.kind == StreamKind.LIVE || stream.kind == StreamKind.VOD_MOVIE || stream.kind == StreamKind.VOD_EPISODE)
        _screenState.update {
            it.copy(
                nextUpCard = null,
                upNextShelf = persistentListOf(),
                canToggleFavorite = canFavorite,
                isFavorite = false,
            )
        }
        if (stream == null || !canFavorite) return

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
        if (current.kind != StreamKind.LIVE) return
        viewModelScope.launch {
            val next = zapToChannelUseCase.adjacent(current.itemId, delta) ?: return@launch
            videoEngine.zap(next)
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
        super.onCleared()
    }
}

