package com.pcoundia.buntu.core.domain

import androidx.paging.PagingData
import com.pcoundia.buntu.core.domain.model.AiProviderType
import com.pcoundia.buntu.core.domain.model.AiSettingsConfig
import com.pcoundia.buntu.core.domain.model.AppPreferences
import com.pcoundia.buntu.core.domain.model.CatalogQuery
import com.pcoundia.buntu.core.domain.model.CategoryFacet
import com.pcoundia.buntu.core.domain.model.ChannelItem
import com.pcoundia.buntu.core.domain.model.ConnectionBudget
import com.pcoundia.buntu.core.domain.model.DownloadItem
import com.pcoundia.buntu.core.domain.model.EpisodeItem
import com.pcoundia.buntu.core.domain.model.MediaDetail
import com.pcoundia.buntu.core.domain.model.MovieItem
import com.pcoundia.buntu.core.domain.model.PlayableStream
import com.pcoundia.buntu.core.domain.model.ProfileSummary
import com.pcoundia.buntu.core.domain.model.RecoCardItem
import com.pcoundia.buntu.core.domain.model.RecoDomainKind
import com.pcoundia.buntu.core.domain.model.RecoShelfGroup
import com.pcoundia.buntu.core.domain.model.SeriesItem
import com.pcoundia.buntu.core.domain.model.SourceKind
import com.pcoundia.buntu.core.domain.model.SourceSummary
import com.pcoundia.buntu.core.domain.model.StreamDiagnosis
import com.pcoundia.buntu.core.domain.model.StreamKind
import com.pcoundia.buntu.core.domain.repository.CatalogRepository
import com.pcoundia.buntu.core.domain.repository.DownloadsRepository
import com.pcoundia.buntu.core.domain.repository.ProfilesRepository
import com.pcoundia.buntu.core.domain.repository.RecommendationsRepository
import com.pcoundia.buntu.core.domain.repository.SecretStore
import com.pcoundia.buntu.core.domain.repository.SettingsRepository
import com.pcoundia.buntu.core.domain.usecase.AssessStreamBandwidthUseCase
import com.pcoundia.buntu.core.domain.usecase.LoadShelvesUseCase
import com.pcoundia.buntu.core.domain.usecase.NextEpisodeUseCase
import com.pcoundia.buntu.core.domain.usecase.ZapToChannelUseCase
import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.persistentListOf
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DomainUseCasesTest {

    @Test
    fun `single connection budget pauses downloads during playback and clamps segments`() {
        val single = ConnectionBudget(1)
        assertTrue(single.pausesDownloadsDuringPlayback)
        assertFalse(single.allowsParallelPreload)
        assertEquals(1 to 1, single.clampDownloads(requestedSegments = 6, requestedFiles = 3))

        val multi = ConnectionBudget(4)
        assertFalse(multi.pausesDownloadsDuringPlayback)
        assertTrue(multi.allowsParallelPreload)
        assertEquals(3, multi.downloadConnections)
        assertEquals(3 to 1, multi.clampDownloads(requestedSegments = 6, requestedFiles = 3))
    }

    @Test
    fun `forHost never exceeds user assumed limit or provider reported limit`() {
        val sources = listOf(
            SourceSummary(
                id = 1L,
                uuid = "u1",
                name = "Main",
                kind = SourceKind.XTREAM,
                serverOrUrl = "http://tv.provider.example:8080",
                username = "alice",
                passwordRef = "sec_1",
                epgUrl = null,
                maxConnections = 1,
                activeConnections = 0,
                expDateEpochSecs = null,
                accountStatus = "Active",
                lastSyncEpochSecs = null,
            )
        )
        val budget = ConnectionBudget.forHost("tv.provider.example", sources, assumedLimit = 4)
        assertEquals(1, budget.limit)
        assertTrue(budget.pausesDownloadsDuringPlayback)
    }

    @Test
    fun `stream diagnosis explains HTTP 429 in plain actionable French`() {
        val diag = StreamDiagnosis.Http(429)
        assertTrue(diag.isFinalError)
        assertTrue(diag.userMessage.contains("une connexion"))
    }

    @Test
    fun `insufficient bandwidth detector flags heavy 4K remux on slow link`() {
        val useCase = AssessStreamBandwidthUseCase()
        // 18 GB movie over 2 hours (7200 s) => ~20 Mbps nominal (~22.4 Mbps with headroom)
        val slow = useCase(
            measuredBitsPerSec = 10_000_000L,
            fileSizeBytes = 18_000_000_000L,
            durationMs = 7_200_000L,
            hasLighterVersions = true,
        )
        assertNotNull(slow)
        assertTrue(slow!!.isInsufficient)
        assertTrue(slow.hasLighterVersions)

        val fast = useCase(
            measuredBitsPerSec = 45_000_000L,
            fileSizeBytes = 18_000_000_000L,
            durationMs = 7_200_000L,
        )
        assertNotNull(fast)
        assertFalse(fast!!.isInsufficient)
    }

    @Test
    fun `next episode picks in-progress episode or successor of completed episode`() {
        val ep1 = EpisodeItem(
            id = 1, seriesId = 10, sourceId = 1, stableHash = "h1",
            title = "Ep 1", seasonNumber = 1, episodeNumber = 1, posterUrl = null,
            streamUrl = "http://s/1.mkv", containerExtension = "mkv", host = "s",
            userAgent = null, referer = null, watchPositionMs = 2_950_000L, watchDurationMs = 3_000_000L,
        )
        val ep2 = ep1.copy(id = 2, stableHash = "h2", title = "Ep 2", episodeNumber = 2, watchPositionMs = 0L, watchDurationMs = 0L)
        val detail = MediaDetail(
            id = 10, isSeries = true, stableHash = "series_h", title = "Severance",
            year = 2022, rating = "8.7", runtimeMinutes = 50, genre = "Sci-Fi",
            plot = null, cast = null, director = null, posterUrl = null, backdropUrl = null,
            containerExtension = null, isFavorite = false,
            episodes = persistentListOf(ep1, ep2),
        )
        val picked = NextEpisodeUseCase()(detail)
        assertEquals(2L, picked?.id)
    }

    @Test
    fun `kids profile never calls remote AI when loading shelves`() = runTest {
        var aiCalled = false
        val recoRepo = object : RecommendationsRepository {
            override suspend fun loadLocalShelves(
                kind: RecoDomainKind,
                limitPerShelf: Int,
                utcOffsetMinutes: Int,
            ): ImmutableList<RecoShelfGroup> = persistentListOf(
                RecoShelfGroup(
                    id = "local_kids",
                    title = "Pour vous",
                    kind = kind,
                    refinedByAi = "",
                    cards = persistentListOf(
                        RecoCardItem(1L, null, "h1", kind, "Dessin animé", null, null, "Favoris")
                    ),
                )
            )

            override suspend fun refineShelvesWithAi(
                kind: RecoDomainKind,
                aiConfig: AiSettingsConfig,
                apiKey: String,
                limitPerShelf: Int,
                locale: String,
                utcOffsetMinutes: Int,
            ): ImmutableList<RecoShelfGroup> {
                aiCalled = true
                return persistentListOf()
            }

            override suspend fun markLessLikeThis(kind: RecoDomainKind, stableHash: String) = Unit
            override suspend fun resetTaste(kind: RecoDomainKind) = Unit
            override suspend fun upNextFor(itemId: Long, context: com.pcoundia.buntu.core.domain.model.UpNextContext, limit: Int) = kotlinx.collections.immutable.persistentListOf<com.pcoundia.buntu.core.domain.model.UpNextItem>()
            override suspend fun nextUpAfter(itemId: Long): com.pcoundia.buntu.core.domain.model.UpNextItem? = null
            override suspend fun dismissUpNext(stableHash: String) = Unit
        }
        val profilesRepo = FakeProfilesRepository(isKids = true)
        val settingsRepo = FakeSettingsRepository(
            AppPreferences(
                aiConfig = AiSettingsConfig(provider = AiProviderType.GEMINI, model = "gemini-2.5-flash")
            )
        )
        val secretStore = object : SecretStore {
            override suspend fun putSecret(alias: String, plaintext: String) = Unit
            override suspend fun getSecret(alias: String): String = "secret_key"
            override suspend fun deleteSecret(alias: String) = Unit
        }

        val emissions = LoadShelvesUseCase(recoRepo, profilesRepo, settingsRepo, secretStore)(RecoDomainKind.MOVIES).toList()
        assertEquals(1, emissions.size)
        assertFalse("Kids profile must never trigger remote AI calls", aiCalled)
    }

    @Test
    fun `zapping on single-connection source pauses background downloads`() = runTest {
        var pausedForPlayback = false
        val downloadsRepo = object : DownloadsRepository {
            override val downloadsFlow: Flow<ImmutableList<DownloadItem>> = MutableStateFlow(persistentListOf())
            override suspend fun refreshDownloads(): ImmutableList<DownloadItem> = persistentListOf()
            override suspend fun enqueueDownload(itemId: Long): Long = 1L
            override suspend fun pauseDownload(taskId: Long) = Unit
            override suspend fun resumeDownload(taskId: Long) = Unit
            override suspend fun removeDownload(taskId: Long, deleteFiles: Boolean) = Unit
            override suspend fun pauseAllForPlayback() { pausedForPlayback = true }
            override suspend fun resumeAfterPlayback() = Unit
        }
        val settingsRepo = FakeSettingsRepository(AppPreferences(assumedMaxConnections = 1))
        val catalogRepo = FakeCatalogRepository()

        val zap = ZapToChannelUseCase(catalogRepo, settingsRepo, downloadsRepo)
        val stream = zap.byId(42L)
        assertNotNull(stream)
        assertTrue(pausedForPlayback)
        assertEquals(42L, settingsRepo.currentPreferences().lastChannelId)
    }
}

private class FakeProfilesRepository(private val isKids: Boolean) : ProfilesRepository {
    private val profile = ProfileSummary(1L, "Enfants", "kids", isKids = isKids, isActive = true)
    override val profilesFlow: Flow<ImmutableList<ProfileSummary>> = MutableStateFlow(persistentListOf(profile))
    override suspend fun refreshProfiles(): ImmutableList<ProfileSummary> = persistentListOf(profile)
    override suspend fun activeProfile(): ProfileSummary = profile
    override suspend fun selectProfile(profileId: Long) = Unit
    override suspend fun createProfile(name: String, avatar: String, isKids: Boolean): ProfileSummary = profile
    override suspend fun deleteProfile(profileId: Long) = Unit
    override suspend fun setAdultContentVisible(visible: Boolean) = Unit
    override suspend fun setGroupAllowedForKids(profileId: Long, kind: String, groupName: String, allowed: Boolean) = Unit
}

private class FakeSettingsRepository(initial: AppPreferences) : SettingsRepository {
    private val state = MutableStateFlow(initial)
    override val preferencesFlow: Flow<AppPreferences> = state
    override suspend fun currentPreferences(): AppPreferences = state.value
    override suspend fun setOnboardingCompleted(completed: Boolean) { state.value = state.value.copy(onboardingCompleted = completed) }
    override suspend fun setAssumedMaxConnections(limit: Int) { state.value = state.value.copy(assumedMaxConnections = limit) }
    override suspend fun setUiScale(scale: Float) { state.value = state.value.copy(uiScale = scale) }
    override suspend fun setTvPlaybackOptions(autoFrameRate: Boolean, audioPassthrough: Boolean, tunneling: Boolean) = Unit
    override suspend fun setDownloadOverCellular(allowed: Boolean) = Unit
    override suspend fun setAdultCategoriesUnlocked(unlocked: Boolean) = Unit
    override suspend fun setLastChannelId(channelId: Long) { state.value = state.value.copy(lastChannelId = channelId) }
    override suspend fun updateAiConfig(config: AiSettingsConfig) { state.value = state.value.copy(aiConfig = config) }
    override suspend fun setUpNextPreferences(preferences: com.pcoundia.buntu.core.domain.model.UpNextPreferences) = Unit
}

private class FakeCatalogRepository : CatalogRepository {
    override fun pagedLiveChannels(query: CatalogQuery): Flow<PagingData<ChannelItem>> = emptyFlow()
    override fun pagedMovies(query: CatalogQuery): Flow<PagingData<MovieItem>> = emptyFlow()
    override fun pagedSeries(query: CatalogQuery): Flow<PagingData<SeriesItem>> = emptyFlow()
    override suspend fun getGroups(kind: String, sourceId: Long?): ImmutableList<CategoryFacet> = persistentListOf()
    override suspend fun getChannelById(itemId: Long): ChannelItem? = null
    override suspend fun getAdjacentChannel(currentItemId: Long, delta: Int, groupName: String?): ChannelItem? = null
    override suspend fun getChannelByNumber(number: Int): ChannelItem? = null
    override suspend fun listFavoriteChannels(): ImmutableList<ChannelItem> = persistentListOf()
    override suspend fun listRecentChannels(limit: Int): ImmutableList<ChannelItem> = persistentListOf()
    override suspend fun getMovieDetail(itemId: Long, metadataApiKey: String?): MediaDetail? = null
    override suspend fun getSeriesDetail(seriesId: Long, selectedSeason: Int?, xtreamPassword: String?, metadataApiKey: String?): MediaDetail? = null
    override suspend fun getEpisodeById(episodeId: Long): EpisodeItem? = null
    override suspend fun toggleFavorite(stableHash: String, kind: String): Boolean = true
    override suspend fun isFavoriteForPlayback(itemId: Long): Boolean = false
    override suspend fun toggleFavoriteForPlayback(itemId: Long): Boolean = true
    override suspend fun recordWatchProgress(stableHash: String, positionMs: Long, durationMs: Long) = Unit
    override suspend fun resolvePlayableStream(itemId: Long, startPositionMs: Long): PlayableStream = PlayableStream(
        itemId = itemId,
        stableHash = "ch_$itemId",
        title = "France 24",
        originalUrl = "http://tv.local/live/1.ts",
        playbackUrl = "http://tv.local/live/1.ts",
        kind = StreamKind.LIVE,
        host = "tv.local",
        maxConnectionsForSource = 1,
    )
}

