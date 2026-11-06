package com.pcoundia.buntu.feature.player

import androidx.lifecycle.SavedStateHandle
import androidx.paging.PagingData
import com.pcoundia.buntu.core.domain.model.AppPreferences
import com.pcoundia.buntu.core.domain.model.CatalogQuery
import com.pcoundia.buntu.core.domain.model.CategoryFacet
import com.pcoundia.buntu.core.domain.model.ChannelGuideRow
import com.pcoundia.buntu.core.domain.model.ChannelItem
import com.pcoundia.buntu.core.domain.model.DownloadItem
import com.pcoundia.buntu.core.domain.model.EpisodeItem
import com.pcoundia.buntu.core.domain.model.EpgSlot
import com.pcoundia.buntu.core.domain.model.MediaDetail
import com.pcoundia.buntu.core.domain.model.MovieItem
import com.pcoundia.buntu.core.domain.model.PlayableStream
import com.pcoundia.buntu.core.domain.model.SeriesItem
import com.pcoundia.buntu.core.domain.model.StreamKind
import com.pcoundia.buntu.core.domain.repository.CatalogRepository
import com.pcoundia.buntu.core.domain.repository.DownloadsRepository
import com.pcoundia.buntu.core.domain.repository.EpgRepository
import com.pcoundia.buntu.core.domain.repository.SettingsRepository
import com.pcoundia.buntu.core.domain.repository.WatchNextPublisher
import com.pcoundia.buntu.core.domain.usecase.ZapToChannelUseCase
import com.pcoundia.buntu.core.platform.device.DeviceCapabilities
import com.pcoundia.buntu.core.player.PlayerEngineState
import com.pcoundia.buntu.core.player.VideoEngine
import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.persistentListOf
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class PlayerViewModelTest {

    private val testDispatcher = UnconfinedTestDispatcher()

    @Before
    fun setUp() {
        Dispatchers.setMain(testDispatcher)
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    @Test
    fun `vod playback pauses 1-conn downloads, persists progress to WatchNext, and resumes downloads on stop`() = runTest {
        var pausedDownloads = false
        var resumedDownloads = false
        var savedPosMs = 0L
        var publishedWatchNextId = -1L

        val fakeEngine = FakePlayerVideoEngine()
        val catalogRepo = FakePlayerCatalogRepository { _, pos, _ -> savedPosMs = pos }
        val epgRepo = object : EpgRepository {
            override suspend fun loadGuideGrid(
                groupName: String?,
                fromEpochSecs: Long,
                toEpochSecs: Long,
                limitChannels: Int,
            ): ImmutableList<ChannelGuideRow> = persistentListOf()
            override suspend fun getChannelPrograms(
                tvgId: String,
                fromEpochSecs: Long,
                toEpochSecs: Long,
            ): ImmutableList<EpgSlot> = persistentListOf()
            override suspend fun buildCatchupStream(
                channelItemId: Long,
                startEpochSecs: Long,
                endEpochSecs: Long,
            ): PlayableStream? = null
        }
        val downloadsRepo = object : DownloadsRepository {
            override val downloadsFlow: Flow<ImmutableList<DownloadItem>> = flowOf(persistentListOf())
            override suspend fun refreshDownloads(): ImmutableList<DownloadItem> = persistentListOf()
            override suspend fun enqueueDownload(itemId: Long): Long = 1L
            override suspend fun pauseDownload(taskId: Long) = Unit
            override suspend fun resumeDownload(taskId: Long) = Unit
            override suspend fun removeDownload(taskId: Long, deleteFiles: Boolean) = Unit
            override suspend fun pauseAllForPlayback() { pausedDownloads = true }
            override suspend fun resumeAfterPlayback() { resumedDownloads = true }
        }
        val settingsRepo = object : SettingsRepository {
            private val prefs = AppPreferences(assumedMaxConnections = 1)
            override val preferencesFlow: Flow<AppPreferences> = flowOf(prefs)
            override suspend fun currentPreferences(): AppPreferences = prefs
            override suspend fun setOnboardingCompleted(completed: Boolean) = Unit
            override suspend fun setAssumedMaxConnections(limit: Int) = Unit
            override suspend fun setUiScale(scale: Float) = Unit
            override suspend fun setTvPlaybackOptions(autoFrameRate: Boolean, audioPassthrough: Boolean, tunneling: Boolean) = Unit
            override suspend fun setDownloadOverCellular(allowed: Boolean) = Unit
            override suspend fun setAdultCategoriesUnlocked(unlocked: Boolean) = Unit
            override suspend fun setLastChannelId(channelId: Long) = Unit
            override suspend fun updateAiConfig(config: com.pcoundia.buntu.core.domain.model.AiSettingsConfig) = Unit
        }
        val watchNext = object : WatchNextPublisher {
            override suspend fun publishContinueWatching(
                itemId: Long,
                title: String,
                posterUrl: String?,
                positionMs: Long,
                durationMs: Long,
                isEpisode: Boolean,
            ) {
                publishedWatchNextId = itemId
            }
            override suspend fun removeFromWatchNext(itemId: Long) = Unit
        }

        val stubContext = android.content.ContextWrapper(null)
        val vm = PlayerViewModel(
            savedStateHandle = SavedStateHandle(mapOf("itemId" to 99L, "startPositionMs" to 60_000L)),
            appContext = stubContext,
            catalogRepository = catalogRepo,
            epgRepository = epgRepo,
            downloadsRepository = downloadsRepo,
            settingsRepository = settingsRepo,
            watchNextPublisher = watchNext,
            zapToChannelUseCase = ZapToChannelUseCase(catalogRepo, settingsRepo, downloadsRepo),
            videoEngine = fakeEngine,
            deviceCapabilities = DeviceCapabilities(isTelevision = false),
        )

        assertTrue(pausedDownloads)
        assertEquals(99L, fakeEngine.state.value.activeStream?.itemId)
        assertTrue(fakeEngine.state.value.activeStream?.usesSingleConnectionRelay == true)

        fakeEngine.advancePosition(positionMs = 180_000L, durationMs = 7_200_000L)
        vm.stopPlaybackAndCleanup()

        assertEquals(180_000L, savedPosMs)
        assertEquals(99L, publishedWatchNextId)
        assertTrue(resumedDownloads)
    }
}

private class FakePlayerVideoEngine : VideoEngine {
    private val _state = MutableStateFlow(PlayerEngineState())
    override val state: StateFlow<PlayerEngineState> = _state

    override fun play(stream: PlayableStream) {
        _state.value = PlayerEngineState(
            activeStream = stream,
            isPlaying = true,
            positionMs = stream.startPositionMs,
            durationMs = 7_200_000L,
        )
    }

    fun advancePosition(positionMs: Long, durationMs: Long) {
        _state.value = _state.value.copy(positionMs = positionMs, durationMs = durationMs)
    }

    override fun zap(stream: PlayableStream) = play(stream)
    override fun togglePlayPause() = Unit
    override fun pause() = Unit
    override fun resume() = Unit
    override fun seekTo(positionMs: Long) = Unit
    override fun seekBy(deltaMs: Long) = Unit
    override fun selectAudioTrack(groupIndex: Int, trackIndex: Int) = Unit
    override fun selectSubtitleTrack(groupIndex: Int?, trackIndex: Int?) = Unit
    override fun setSubtitleOffsetMs(offsetMs: Long) = Unit
    override fun dismissBandwidthWarning() = Unit
    override fun stop() { _state.value = PlayerEngineState() }
}

private class FakePlayerCatalogRepository(
    private val onSaveProgress: (String, Long, Long) -> Unit,
) : CatalogRepository {
    override fun pagedLiveChannels(query: CatalogQuery): Flow<PagingData<ChannelItem>> = flowOf(PagingData.empty())
    override fun pagedMovies(query: CatalogQuery): Flow<PagingData<MovieItem>> = flowOf(PagingData.empty())
    override fun pagedSeries(query: CatalogQuery): Flow<PagingData<SeriesItem>> = flowOf(PagingData.empty())
    override suspend fun getGroups(kind: String, sourceId: Long?): ImmutableList<CategoryFacet> = persistentListOf()
    override suspend fun getChannelById(itemId: Long): ChannelItem? = null
    override suspend fun getAdjacentChannel(currentItemId: Long, delta: Int, groupName: String?): ChannelItem? = null
    override suspend fun getChannelByNumber(number: Int): ChannelItem? = null
    override suspend fun listFavoriteChannels(): ImmutableList<ChannelItem> = persistentListOf()
    override suspend fun listRecentChannels(limit: Int): ImmutableList<ChannelItem> = persistentListOf()
    override suspend fun getMovieDetail(itemId: Long, metadataApiKey: String?): MediaDetail? = null
    override suspend fun getSeriesDetail(
        seriesId: Long,
        selectedSeason: Int?,
        xtreamPassword: String?,
        metadataApiKey: String?,
    ): MediaDetail? = null
    override suspend fun getEpisodeById(episodeId: Long): EpisodeItem? = null
    override suspend fun toggleFavorite(stableHash: String, kind: String): Boolean = false
    override suspend fun recordWatchProgress(stableHash: String, positionMs: Long, durationMs: Long) {
        onSaveProgress(stableHash, positionMs, durationMs)
    }
    override suspend fun resolvePlayableStream(itemId: Long, startPositionMs: Long): PlayableStream =
        PlayableStream(
            itemId = itemId,
            stableHash = "atlantique_2019",
            title = "Atlantique (2019)",
            originalUrl = "http://provider.tv/movie/99.mkv",
            playbackUrl = "http://127.0.0.1:49152/stream/99.mkv",
            kind = StreamKind.VOD_MOVIE,
            host = "provider.tv",
            containerExtension = "mkv",
            startPositionMs = startPositionMs,
            maxConnectionsForSource = 1,
        )
}
