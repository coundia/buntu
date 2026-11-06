package com.pcoundia.buntu.feature.live

import androidx.paging.PagingData
import com.pcoundia.buntu.core.domain.model.AppPreferences
import com.pcoundia.buntu.core.domain.model.CatalogQuery
import com.pcoundia.buntu.core.domain.model.CategoryFacet
import com.pcoundia.buntu.core.domain.model.ChannelItem
import com.pcoundia.buntu.core.domain.model.DownloadItem
import com.pcoundia.buntu.core.domain.model.EpisodeItem
import com.pcoundia.buntu.core.domain.model.MediaDetail
import com.pcoundia.buntu.core.domain.model.MovieItem
import com.pcoundia.buntu.core.domain.model.PlayableStream
import com.pcoundia.buntu.core.domain.model.ProfileSummary
import com.pcoundia.buntu.core.domain.model.RecoDomainKind
import com.pcoundia.buntu.core.domain.model.RecoShelfGroup
import com.pcoundia.buntu.core.domain.model.SeriesItem
import com.pcoundia.buntu.core.domain.model.StreamKind
import com.pcoundia.buntu.core.domain.repository.CatalogRepository
import com.pcoundia.buntu.core.domain.repository.DownloadsRepository
import com.pcoundia.buntu.core.domain.repository.ProfilesRepository
import com.pcoundia.buntu.core.domain.repository.RecommendationsRepository
import com.pcoundia.buntu.core.domain.repository.SecretStore
import com.pcoundia.buntu.core.domain.repository.SettingsRepository
import com.pcoundia.buntu.core.domain.usecase.LoadShelvesUseCase
import com.pcoundia.buntu.core.domain.usecase.ZapToChannelUseCase
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
class LiveViewModelTest {

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
    fun `numeric keypad entry zaps to matching channel and pauses 1-connection downloads`() = runTest {
        var pausedDownloads = false
        val fakeEngine = FakeVideoEngine()
        val catalogRepo = FakeLiveCatalogRepository()
        val settingsRepo = FakeLiveSettingsRepository()
        val downloadsRepo = object : DownloadsRepository {
            override val downloadsFlow: Flow<ImmutableList<DownloadItem>> = flowOf(persistentListOf())
            override suspend fun refreshDownloads(): ImmutableList<DownloadItem> = persistentListOf()
            override suspend fun enqueueDownload(itemId: Long): Long = 1L
            override suspend fun pauseDownload(taskId: Long) = Unit
            override suspend fun resumeDownload(taskId: Long) = Unit
            override suspend fun removeDownload(taskId: Long, deleteFiles: Boolean) = Unit
            override suspend fun pauseAllForPlayback() { pausedDownloads = true }
            override suspend fun resumeAfterPlayback() = Unit
        }
        val recoRepo = object : RecommendationsRepository {
            override suspend fun loadLocalShelves(
                kind: RecoDomainKind,
                limitPerShelf: Int,
                utcOffsetMinutes: Int,
            ): ImmutableList<RecoShelfGroup> = persistentListOf()
            override suspend fun refineShelvesWithAi(
                kind: RecoDomainKind,
                aiConfig: com.pcoundia.buntu.core.domain.model.AiSettingsConfig,
                apiKey: String,
                limitPerShelf: Int,
                locale: String,
                utcOffsetMinutes: Int,
            ): ImmutableList<RecoShelfGroup> = persistentListOf()
            override suspend fun markLessLikeThis(kind: RecoDomainKind, stableHash: String) = Unit
            override suspend fun resetTaste(kind: RecoDomainKind) = Unit
        }
        val profilesRepo = object : ProfilesRepository {
            override val profilesFlow: Flow<ImmutableList<ProfileSummary>> = flowOf(persistentListOf())
            override suspend fun refreshProfiles(): ImmutableList<ProfileSummary> = persistentListOf()
            override suspend fun activeProfile(): ProfileSummary =
                ProfileSummary(1L, "Principal", "🦁", isKids = false, isActive = true)
            override suspend fun selectProfile(profileId: Long) = Unit
            override suspend fun createProfile(name: String, avatar: String, isKids: Boolean) = activeProfile()
            override suspend fun deleteProfile(profileId: Long) = Unit
            override suspend fun setAdultContentVisible(visible: Boolean) = Unit
            override suspend fun setGroupAllowedForKids(profileId: Long, kind: String, groupName: String, allowed: Boolean) = Unit
        }
        val secretStore = object : SecretStore {
            override suspend fun putSecret(alias: String, plaintext: String) = Unit
            override suspend fun getSecret(alias: String): String? = null
            override suspend fun deleteSecret(alias: String) = Unit
        }

        val vm = LiveViewModel(
            catalogRepository = catalogRepo,
            settingsRepository = settingsRepo,
            zapToChannelUseCase = ZapToChannelUseCase(catalogRepo, settingsRepo, downloadsRepo),
            loadShelvesUseCase = LoadShelvesUseCase(recoRepo, profilesRepo, settingsRepo, secretStore),
            videoEngine = fakeEngine,
        )

        vm.appendChannelDigit('1')
        vm.appendChannelDigit('2')
        vm.confirmNumericZap()

        assertEquals(42L, fakeEngine.state.value.activeStream?.itemId)
        assertTrue(pausedDownloads)
    }
}

private class FakeVideoEngine : VideoEngine {
    private val _state = MutableStateFlow(PlayerEngineState())
    override val state: StateFlow<PlayerEngineState> = _state

    override fun play(stream: PlayableStream) {
        _state.value = _state.value.copy(activeStream = stream, isPlaying = true)
    }

    override fun zap(stream: PlayableStream) {
        _state.value = _state.value.copy(activeStream = stream, isPlaying = true)
    }

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

private class FakeLiveCatalogRepository : CatalogRepository {
    private val channel = ChannelItem(
        id = 42L,
        sourceId = 1L,
        stableHash = "rts1",
        name = "RTS 1 HD",
        channelNumber = 12,
        groupTitle = "Sénégal",
        logoUrl = null,
        tvgId = "rts1.sn",
        streamUrl = "http://example.com/live/42.ts",
        containerExtension = "ts",
        host = "example.com",
        userAgent = null,
        referer = null,
        catchupDays = 3,
        isFavorite = false,
        isBroken = false,
    )

    override fun pagedLiveChannels(query: CatalogQuery): Flow<PagingData<ChannelItem>> =
        flowOf(PagingData.from(listOf(channel)))
    override fun pagedMovies(query: CatalogQuery): Flow<PagingData<MovieItem>> = flowOf(PagingData.empty())
    override fun pagedSeries(query: CatalogQuery): Flow<PagingData<SeriesItem>> = flowOf(PagingData.empty())
    override suspend fun getGroups(kind: String, sourceId: Long?): ImmutableList<CategoryFacet> =
        persistentListOf(CategoryFacet("Sénégal", 1))
    override suspend fun getChannelById(itemId: Long): ChannelItem? = channel.takeIf { it.id == itemId }
    override suspend fun getAdjacentChannel(currentItemId: Long, delta: Int, groupName: String?): ChannelItem = channel
    override suspend fun getChannelByNumber(number: Int): ChannelItem? = channel.takeIf { number == 12 }
    override suspend fun listFavoriteChannels(): ImmutableList<ChannelItem> = persistentListOf()
    override suspend fun listRecentChannels(limit: Int): ImmutableList<ChannelItem> = persistentListOf(channel)
    override suspend fun getMovieDetail(itemId: Long, metadataApiKey: String?): MediaDetail? = null
    override suspend fun getSeriesDetail(
        seriesId: Long,
        selectedSeason: Int?,
        xtreamPassword: String?,
        metadataApiKey: String?,
    ): MediaDetail? = null
    override suspend fun getEpisodeById(episodeId: Long): EpisodeItem? = null
    override suspend fun toggleFavorite(stableHash: String, kind: String): Boolean = true
    override suspend fun recordWatchProgress(stableHash: String, positionMs: Long, durationMs: Long) = Unit
    override suspend fun resolvePlayableStream(itemId: Long, startPositionMs: Long): PlayableStream =
        PlayableStream(
            itemId = itemId,
            stableHash = "rts1",
            title = "RTS 1 HD",
            originalUrl = channel.streamUrl,
            playbackUrl = channel.streamUrl,
            kind = StreamKind.LIVE,
            host = "example.com",
            maxConnectionsForSource = 1,
        )
}

private class FakeLiveSettingsRepository : SettingsRepository {
    private val prefs = MutableStateFlow(AppPreferences(assumedMaxConnections = 1))
    override val preferencesFlow: Flow<AppPreferences> = prefs
    override suspend fun currentPreferences(): AppPreferences = prefs.value
    override suspend fun setOnboardingCompleted(completed: Boolean) = Unit
    override suspend fun setAssumedMaxConnections(limit: Int) = Unit
    override suspend fun setUiScale(scale: Float) = Unit
    override suspend fun setTvPlaybackOptions(autoFrameRate: Boolean, audioPassthrough: Boolean, tunneling: Boolean) = Unit
    override suspend fun setDownloadOverCellular(allowed: Boolean) = Unit
    override suspend fun setAdultCategoriesUnlocked(unlocked: Boolean) = Unit
    override suspend fun setLastChannelId(channelId: Long) {
        prefs.value = prefs.value.copy(lastChannelId = channelId)
    }
    override suspend fun updateAiConfig(config: com.pcoundia.buntu.core.domain.model.AiSettingsConfig) = Unit
}

