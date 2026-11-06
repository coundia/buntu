package com.pcoundia.buntu.feature.player

import android.content.Context
import androidx.compose.runtime.Immutable
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.pcoundia.buntu.core.domain.model.MovieItem
import com.pcoundia.buntu.core.domain.model.PlayableStream
import com.pcoundia.buntu.core.domain.model.StreamKind
import com.pcoundia.buntu.core.domain.repository.CatalogRepository
import com.pcoundia.buntu.core.domain.repository.DownloadsRepository
import com.pcoundia.buntu.core.domain.repository.EpgRepository
import com.pcoundia.buntu.core.domain.repository.SettingsRepository
import com.pcoundia.buntu.core.domain.repository.WatchNextPublisher
import com.pcoundia.buntu.core.domain.usecase.ZapToChannelUseCase
import com.pcoundia.buntu.core.platform.device.DeviceCapabilities
import com.pcoundia.buntu.core.platform.work.DownloadForegroundWorker
import com.pcoundia.buntu.core.player.PlayerEngineState
import com.pcoundia.buntu.core.player.VideoEngine
import dagger.hilt.android.lifecycle.HiltViewModel
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.persistentListOf
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
    val showTrackSheet: Boolean = false,
    val showVersionsSheet: Boolean = false,
    val otherVersions: ImmutableList<MovieItem> = persistentListOf(),
    val statusToast: String? = null,
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

    private var progressSaverJob: Job? = null
    private var pausedDownloadsForSession: Boolean = false

    init {
        startRequestedStream()
        startPeriodicProgressSaver()
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
        if (stream.kind != StreamKind.VOD_MOVIE) return
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

    fun showControls() {
        _screenState.update { it.copy(controlsVisible = true) }
    }

    fun toggleTrackSheet(visible: Boolean) {
        _screenState.update { it.copy(showTrackSheet = visible) }
    }

    fun toggleVersionsSheet(visible: Boolean) {
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
        super.onCleared()
    }
}

