package com.pcoundia.buntu.feature.player

import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.viewModelScope
import androidx.paging.PagingData
import com.pcoundia.buntu.core.domain.model.ActiveRemoteControlSession
import com.pcoundia.buntu.core.domain.model.AiSettingsConfig
import com.pcoundia.buntu.core.domain.model.AppPreferences
import com.pcoundia.buntu.core.domain.model.CatalogQuery
import com.pcoundia.buntu.core.domain.model.CategoryFacet
import com.pcoundia.buntu.core.domain.model.ChannelGuideRow
import com.pcoundia.buntu.core.domain.model.ChannelItem
import com.pcoundia.buntu.core.domain.model.DiscoveredPeer
import com.pcoundia.buntu.core.domain.model.DownloadItem
import com.pcoundia.buntu.core.domain.model.EpisodeItem
import com.pcoundia.buntu.core.domain.model.EpgSlot
import com.pcoundia.buntu.core.domain.model.IncomingPlayInstruction
import com.pcoundia.buntu.core.domain.model.MediaDetail
import com.pcoundia.buntu.core.domain.model.MovieItem
import com.pcoundia.buntu.core.domain.model.PlayableStream
import com.pcoundia.buntu.core.domain.model.RecoDomainKind
import com.pcoundia.buntu.core.domain.model.RecoShelfGroup
import com.pcoundia.buntu.core.domain.model.SeriesItem
import com.pcoundia.buntu.core.domain.model.StreamDiagnosis
import com.pcoundia.buntu.core.domain.model.StreamKind
import com.pcoundia.buntu.core.domain.model.UpNextContext
import com.pcoundia.buntu.core.domain.model.UpNextItem
import com.pcoundia.buntu.core.domain.model.UpNextPreferences
import com.pcoundia.buntu.core.domain.model.UpNextReason
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
import com.pcoundia.buntu.core.player.PlayerEngineState
import com.pcoundia.buntu.core.player.VideoAspectMode
import com.pcoundia.buntu.core.player.VideoEngine
import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.persistentListOf
import kotlinx.collections.immutable.toImmutableList
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
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

    /**
     * The view model saves the progress every 10 s forever; `runTest` would advance virtual time without end.
     * Cancelling the view models before leaving the test stops that loop, as `onCleared` does in the app.
     */
    private fun playerTest(body: suspend TestScope.() -> Unit) = runTest {
        try {
            body()
        } finally {
            openViewModels.forEach { it.viewModelScope.cancel() }
            openViewModels.clear()
        }
    }

    @Test
    fun `vod playback pauses 1-conn downloads, persists progress to WatchNext, and resumes downloads on stop`() = playerTest {
        val h = PlayerHarness()
        val vm = h.viewModel(itemId = 99L, startPositionMs = 60_000L)

        assertTrue(h.downloads.paused)
        assertEquals(99L, h.engine.state.value.activeStream?.itemId)
        assertTrue(h.engine.state.value.activeStream?.usesSingleConnectionRelay == true)

        h.engine.advancePosition(positionMs = 180_000L, durationMs = 7_200_000L)
        vm.stopPlaybackAndCleanup()

        assertEquals(180_000L, h.catalog.savedProgress["hash_99"])
        assertEquals(99L, h.watchNext.lastPublishedId)
        assertTrue(h.downloads.resumed)
    }

    @Test
    fun `end of an episode counts down, then plays the title chosen by the engine`() = playerTest {
        val h = PlayerHarness(kind = StreamKind.VOD_EPISODE)
        val vm = h.viewModel(itemId = 99L)

        h.engine.finish()
        runCurrent()

        val card = vm.screenState.value.nextUpCard
        assertEquals(100L, card?.item?.itemId)
        assertEquals(UpNextPreferences.DEFAULT_COUNTDOWN_SECONDS, card?.countdownSecondsRemaining)
        // Saved at the very end, so the engine counts the episode as watched.
        assertEquals(7_200_000L, h.catalog.savedProgress["hash_99"])

        advanceTimeBy(UpNextPreferences.DEFAULT_COUNTDOWN_SECONDS * 1_000L + 1L)
        runCurrent()

        assertEquals(100L, h.engine.state.value.activeStream?.itemId)
        assertNull(vm.screenState.value.nextUpCard)
    }

    @Test
    fun `card appears in the last minutes, credits hide it until the real end`() = playerTest {
        val h = PlayerHarness()
        val vm = h.viewModel(itemId = 99L)

        h.engine.advancePosition(positionMs = 7_200_000L - 600_000L, durationMs = 7_200_000L)
        assertNull("10 minutes before the end: too early", vm.screenState.value.nextUpCard)

        h.engine.advancePosition(positionMs = 7_200_000L - 120_000L, durationMs = 7_200_000L)
        val early = vm.screenState.value.nextUpCard
        assertEquals(100L, early?.item?.itemId)
        assertNull("no countdown before the end", early?.countdownSecondsRemaining)

        vm.dismissNextUpForCredits()
        h.engine.advancePosition(positionMs = 7_200_000L - 60_000L, durationMs = 7_200_000L)
        assertNull(vm.screenState.value.nextUpCard)

        h.engine.finish()
        runCurrent()
        assertEquals(100L, vm.screenState.value.nextUpCard?.item?.itemId)
    }

    @Test
    fun `after three titles chained alone, the player asks if someone is still watching`() = playerTest {
        val h = PlayerHarness(kind = StreamKind.VOD_EPISODE)
        val vm = h.viewModel(itemId = 99L)

        repeat(NextUpTiming.MAX_AUTO_CHAIN) {
            h.engine.finish()
            runCurrent()
            advanceTimeBy(UpNextPreferences.DEFAULT_COUNTDOWN_SECONDS * 1_000L + 1L)
            runCurrent()
        }
        assertEquals(102L, h.engine.state.value.activeStream?.itemId)

        h.engine.finish()
        runCurrent()
        val card = vm.screenState.value.nextUpCard
        assertTrue(card?.askStillWatching == true)
        assertNull(card?.countdownSecondsRemaining)
        advanceTimeBy(60_000L)
        runCurrent()
        assertEquals("nothing starts alone", 102L, h.engine.state.value.activeStream?.itemId)

        vm.confirmStillWatching()
        runCurrent()
        assertEquals(103L, h.engine.state.value.activeStream?.itemId)
    }

    @Test
    fun `without auto-play the card waits for the user`() = playerTest {
        val h = PlayerHarness(upNext = UpNextPreferences(autoPlayNext = false))
        val vm = h.viewModel(itemId = 99L)

        h.engine.finish()
        runCurrent()
        assertEquals(100L, vm.screenState.value.nextUpCard?.item?.itemId)
        assertNull(vm.screenState.value.nextUpCard?.countdownSecondsRemaining)
        advanceTimeBy(60_000L)
        runCurrent()
        assertEquals(99L, h.engine.state.value.activeStream?.itemId)

        vm.playNextUpNow()
        runCurrent()
        assertEquals(100L, h.engine.state.value.activeStream?.itemId)
    }

    @Test
    fun `up next row comes from the engine and can be turned off`() = playerTest {
        val on = PlayerHarness()
        val vmOn = on.viewModel(itemId = 99L)
        assertEquals(listOf(100L, 101L), vmOn.screenState.value.upNextShelf.map { it.itemId })
        assertEquals(UpNextContext.PLAYING, on.reco.lastContext)

        vmOn.dismissUpNextItem(vmOn.screenState.value.upNextShelf.first())
        runCurrent()
        assertEquals(listOf("hash_100"), on.reco.dismissed)
        assertEquals(listOf(101L), vmOn.screenState.value.upNextShelf.map { it.itemId })

        val off = PlayerHarness(upNext = UpNextPreferences(shelfEnabled = false))
        val vmOff = off.viewModel(itemId = 99L)
        assertTrue(vmOff.screenState.value.upNextShelf.isEmpty())
    }

    @Test
    fun `a live channel asks for live suggestions and never shows the end card`() = playerTest {
        val h = PlayerHarness(kind = StreamKind.LIVE)
        val vm = h.viewModel(itemId = 7L)

        assertEquals(UpNextContext.LIVE, h.reco.lastContext)
        assertEquals(0, h.reco.nextUpCalls)
        h.engine.advancePosition(positionMs = 1_000L, durationMs = 1_000L)
        assertNull(vm.screenState.value.nextUpCard)
    }

    @Test
    fun `favorite and speed buttons go through the repository and the engine`() = playerTest {
        val h = PlayerHarness(kind = StreamKind.VOD_EPISODE)
        val vm = h.viewModel(itemId = 99L)

        assertTrue(vm.screenState.value.canToggleFavorite)
        assertFalse(vm.screenState.value.isFavorite)
        vm.toggleFavorite()
        runCurrent()
        assertTrue(vm.screenState.value.isFavorite)
        assertEquals(listOf(99L), h.catalog.favoriteToggles)

        vm.setPlaybackSpeed(1.5f)
        assertEquals(1.5f, h.engine.state.value.playbackSpeed)
    }

    @Test
    fun `locking the screen closes open sheets and blocks sheet opening until unlocked`() = playerTest {
        val h = PlayerHarness(kind = StreamKind.VOD_EPISODE)
        val vm = h.viewModel(itemId = 99L)

        vm.toggleTrackSheet(true)
        vm.toggleVersionsSheet(true)
        assertTrue(vm.screenState.value.showTrackSheet)
        assertTrue(vm.screenState.value.showVersionsSheet)
        assertFalse(vm.screenState.value.isScreenLocked)

        vm.lockScreen()
        assertTrue(vm.screenState.value.isScreenLocked)
        assertTrue(vm.screenState.value.controlsVisible)
        assertFalse(vm.screenState.value.showTrackSheet)
        assertFalse(vm.screenState.value.showVersionsSheet)

        // While locked, sheets cannot be reopened
        vm.toggleTrackSheet(true)
        vm.toggleVersionsSheet(true)
        assertFalse(vm.screenState.value.showTrackSheet)
        assertFalse(vm.screenState.value.showVersionsSheet)

        vm.unlockScreen()
        assertFalse(vm.screenState.value.isScreenLocked)
        assertTrue(vm.screenState.value.controlsVisible)

        vm.toggleTrackSheet(true)
        assertTrue(vm.screenState.value.showTrackSheet)
    }

    @Test
    fun `live zapping debounces rapid presses at 250ms and recall restores previous channel`() = playerTest {
        val h = PlayerHarness(kind = StreamKind.LIVE)
        val ch1 = fakeChannel(1L, "TF1 HD", number = 1)
        val ch2 = fakeChannel(2L, "France 2", number = 2)
        val ch3 = fakeChannel(3L, "France 3", number = 3)
        val ch4 = fakeChannel(4L, "Canal+", number = 4)
        h.catalog.channels = listOf(ch1, ch2, ch3, ch4)

        val vm = h.viewModel(itemId = 1L)
        vm.zapDebounceMs = 250L
        h.catalog.resolvedIds.clear()

        // Three rapid CH+ clicks within 250ms: HUD updates immediately, network resolves only target #4.
        vm.zapAdjacentLive(+1)
        assertEquals("France 2", vm.screenState.value.pendingZapTitle)
        advanceTimeBy(80L)
        vm.zapAdjacentLive(+1)
        assertEquals("France 3", vm.screenState.value.pendingZapTitle)
        advanceTimeBy(80L)
        vm.zapAdjacentLive(+1)
        assertEquals("Canal+", vm.screenState.value.pendingZapTitle)
        assertTrue("No stream should resolve before debounce settles", h.catalog.resolvedIds.isEmpty())

        advanceTimeBy(300L)
        runCurrent()
        assertEquals(listOf(4L), h.catalog.resolvedIds)
        assertEquals(4L, h.engine.state.value.activeStream?.itemId)
        assertNull(vm.screenState.value.pendingZapTitle)
        assertTrue(vm.screenState.value.canRecallLive)

        vm.recallPreviousChannel()
        assertEquals(1L, h.engine.state.value.activeStream?.itemId)
    }

    @Test
    fun `numeric channel input resolves matching channel and unknown number toasts`() = playerTest {
        val h = PlayerHarness(kind = StreamKind.LIVE)
        val ch1 = fakeChannel(1L, "TF1", number = 1)
        val ch12 = fakeChannel(12L, "Arte", number = 12)
        h.catalog.channels = listOf(ch1, ch12)

        val vm = h.viewModel(itemId = 1L)
        vm.digitCommitMs = 1_200L
        vm.appendChannelDigit(1)
        vm.appendChannelDigit(2)
        assertEquals("12", vm.screenState.value.channelDigitBuffer)

        vm.commitChannelNumber()
        assertEquals("", vm.screenState.value.channelDigitBuffer)
        assertEquals(12L, h.engine.state.value.activeStream?.itemId)

        vm.appendChannelDigit(9)
        vm.appendChannelDigit(9)
        advanceTimeBy(1_300L)
        runCurrent()
        assertEquals("Chaîne 99 introuvable", vm.screenState.value.statusToast)
    }

    @Test
    fun `live failover auto-switches up to 2 mirrors on diagnosis error`() = playerTest {
        val h = PlayerHarness(kind = StreamKind.LIVE)
        val main = fakeChannel(10L, "TF1 4K", number = 1)
        val m1 = fakeChannel(11L, "TF1 FHD", number = 1)
        val m2 = fakeChannel(12L, "TF1 HD", number = 1)
        val m3 = fakeChannel(13L, "TF1 SD", number = 1)
        h.catalog.channels = listOf(main, m1, m2, m3)
        h.catalog.mirrorsById = mapOf(
            10L to listOf(main, m1, m2, m3),
            11L to listOf(main, m1, m2, m3),
            12L to listOf(main, m1, m2, m3),
        )

        val vm = h.viewModel(itemId = 10L)
        assertEquals(4, vm.screenState.value.liveMirrors.size)

        h.engine.triggerDiagnosis()
        runCurrent()
        assertEquals(11L, h.engine.state.value.activeStream?.itemId)
        assertEquals("Bascule vers TF1 FHD", vm.screenState.value.failoverBanner)

        h.engine.triggerDiagnosis()
        runCurrent()
        assertEquals(12L, h.engine.state.value.activeStream?.itemId)

        // Third failure must NOT switch to a 3rd mirror (PRD-17 cap = 2 failovers/session).
        h.engine.triggerDiagnosis()
        runCurrent()
        assertEquals(12L, h.engine.state.value.activeStream?.itemId)
    }

    @Test
    fun `live epg, start-over, mini-guide drawer, aspect toggle, and sleep timer work together`() = playerTest {
        val h = PlayerHarness(kind = StreamKind.LIVE)
        val ch1 = fakeChannel(1L, "TF1", number = 1, tvgId = "tf1.fr", catchupDays = 7)
        val ch2 = fakeChannel(2L, "France 2", number = 2, tvgId = "f2.fr")
        h.catalog.channels = listOf(ch1, ch2)
        val nowSecs = System.currentTimeMillis() / 1000L
        h.epg.slotsByTvgId["tf1.fr"] = persistentListOf(
            EpgSlot(1L, "tf1.fr", "Journal 20h", null, null, nowSecs - 600, nowSecs + 1200, true),
            EpgSlot(2L, "tf1.fr", "Film du soir", null, null, nowSecs + 1200, nowSecs + 4800, false),
        )

        val vm = h.viewModel(itemId = 1L)
        vm.sleepTimerTickMs = 50L
        assertEquals("Journal 20h", vm.screenState.value.liveNowSlot?.title)
        assertEquals("Film du soir", vm.screenState.value.liveNextSlot?.title)
        assertTrue(vm.screenState.value.canStartOverLive)

        vm.startOverCurrentProgram()
        assertEquals(StreamKind.CATCHUP, h.engine.state.value.activeStream?.kind)
        vm.returnToLive()
        assertEquals(StreamKind.LIVE, h.engine.state.value.activeStream?.kind)

        vm.toggleChannelDrawer(true)
        assertEquals(2, vm.screenState.value.drawerChannels.size)
        vm.selectChannelFromDrawer(ch2)
        assertFalse(vm.screenState.value.showChannelDrawer)
        assertEquals(2L, h.engine.state.value.activeStream?.itemId)

        vm.cycleAspectMode()
        assertEquals(VideoAspectMode.FILL, h.engine.state.value.aspectMode)
        vm.cycleAspectMode()
        assertEquals(VideoAspectMode.STRETCH, h.engine.state.value.aspectMode)

        vm.startSleepCountdownSeconds(2)
        assertEquals(2, vm.screenState.value.sleepTimerRemainingSeconds)
        advanceTimeBy(150L)
        runCurrent()
        assertNull(h.engine.state.value.activeStream)
        assertNull(vm.screenState.value.sleepTimerRemainingSeconds)
    }
}

private fun fakeChannel(
    id: Long,
    name: String,
    number: Int?,
    group: String = "Général",
    tvgId: String? = null,
    catchupDays: Int? = null,
) = ChannelItem(
    id = id,
    sourceId = 1L,
    stableHash = "hash_$id",
    name = name,
    channelNumber = number,
    groupTitle = group,
    logoUrl = null,
    tvgId = tvgId,
    streamUrl = "http://provider.tv/live/$id.ts",
    containerExtension = "ts",
    host = "provider.tv",
    userAgent = null,
    referer = null,
    catchupDays = catchupDays,
    isFavorite = false,
    isBroken = false,
)

/** View models created by the current test, cancelled when it ends. */
private val openViewModels = mutableListOf<PlayerViewModel>()

/** Builds a [PlayerViewModel] on fakes; every item `n` is followed by item `n + 1`. */
private class PlayerHarness(
    val kind: StreamKind = StreamKind.VOD_MOVIE,
    upNext: UpNextPreferences = UpNextPreferences(),
) {
    val engine = FakePlayerVideoEngine()
    val catalog = FakePlayerCatalogRepository(kind)
    val epg = FakeEpgRepository()
    val downloads = FakeDownloads()
    val watchNext = FakeWatchNext()
    val reco = FakeUpNextRecommendations(kind)
    val settings = FakePlayerSettings(AppPreferences(assumedMaxConnections = 1, upNext = upNext))

    fun viewModel(itemId: Long, startPositionMs: Long = 0L): PlayerViewModel = createViewModel(itemId, startPositionMs)
        .also { openViewModels += it }

    private fun createViewModel(itemId: Long, startPositionMs: Long): PlayerViewModel = PlayerViewModel(
        savedStateHandle = SavedStateHandle(mapOf("itemId" to itemId, "startPositionMs" to startPositionMs)),
        appContext = android.content.ContextWrapper(null),
        catalogRepository = catalog,
        epgRepository = epg,
        downloadsRepository = downloads,
        settingsRepository = settings,
        watchNextPublisher = watchNext,
        zapToChannelUseCase = ZapToChannelUseCase(catalog, settings, downloads),
        videoEngine = engine,
        deviceCapabilities = DeviceCapabilities(isTelevision = false),
        remotePlaybackRepo = NoRemotePlayback,
        recommendationsRepository = reco,
    )
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
            playbackSpeed = _state.value.playbackSpeed,
        )
    }

    fun advancePosition(positionMs: Long, durationMs: Long) {
        _state.value = _state.value.copy(positionMs = positionMs, durationMs = durationMs)
    }

    /** ExoPlayer `STATE_ENDED`. */
    fun finish() {
        val s = _state.value
        _state.value = s.copy(isPlaying = false, isEnded = true, positionMs = s.durationMs)
    }

    fun triggerDiagnosis(diagnosis: StreamDiagnosis = StreamDiagnosis.Unreachable) {
        _state.value = _state.value.copy(isPlaying = false, diagnosis = diagnosis)
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
    override fun setPlaybackSpeed(speed: Float) {
        _state.value = _state.value.copy(playbackSpeed = speed)
    }
    override fun setAspectMode(mode: VideoAspectMode) {
        _state.value = _state.value.copy(aspectMode = mode)
    }
    override fun dismissBandwidthWarning() = Unit
    override fun stop() { _state.value = PlayerEngineState(aspectMode = _state.value.aspectMode) }
}

private fun upNextItem(itemId: Long, kind: StreamKind) = UpNextItem(
    itemId = itemId,
    stableHash = "hash_$itemId",
    kind = kind,
    title = "Titre $itemId",
    subtitle = null,
    posterUrl = null,
    reason = if (kind == StreamKind.VOD_EPISODE) UpNextReason.NEXT_EPISODE else UpNextReason.SAGA_NEXT,
    reasonText = "Suivant",
    alreadyWatched = false,
    resumePositionMs = 0L,
    durationMs = 0L,
)

private class FakeUpNextRecommendations(private val kind: StreamKind) : RecommendationsRepository {
    var lastContext: UpNextContext? = null
    var nextUpCalls = 0
    val dismissed = mutableListOf<String>()

    override suspend fun loadLocalShelves(kind: RecoDomainKind, limitPerShelf: Int, utcOffsetMinutes: Int): ImmutableList<RecoShelfGroup> =
        persistentListOf()
    override suspend fun refineShelvesWithAi(
        kind: RecoDomainKind, aiConfig: AiSettingsConfig, apiKey: String, limitPerShelf: Int, locale: String, utcOffsetMinutes: Int,
    ): ImmutableList<RecoShelfGroup> = persistentListOf()
    override suspend fun markLessLikeThis(kind: RecoDomainKind, stableHash: String) = Unit
    override suspend fun resetTaste(kind: RecoDomainKind) = Unit

    override suspend fun upNextFor(itemId: Long, context: UpNextContext, limit: Int): ImmutableList<UpNextItem> {
        lastContext = context
        return persistentListOf(upNextItem(itemId + 1, kind), upNextItem(itemId + 2, kind))
    }

    override suspend fun nextUpAfter(itemId: Long): UpNextItem? {
        nextUpCalls += 1
        return upNextItem(itemId + 1, kind)
    }

    override suspend fun dismissUpNext(stableHash: String) {
        dismissed += stableHash
    }
}

private class FakeDownloads : DownloadsRepository {
    var paused = false
    var resumed = false
    override val downloadsFlow: Flow<ImmutableList<DownloadItem>> = flowOf(persistentListOf())
    override suspend fun refreshDownloads(): ImmutableList<DownloadItem> = persistentListOf()
    override suspend fun enqueueDownload(itemId: Long): Long = 1L
    override suspend fun pauseDownload(taskId: Long) = Unit
    override suspend fun resumeDownload(taskId: Long) = Unit
    override suspend fun removeDownload(taskId: Long, deleteFiles: Boolean) = Unit
    override suspend fun pauseAllForPlayback() { paused = true }
    override suspend fun resumeAfterPlayback() { resumed = true }
}

private class FakeWatchNext : WatchNextPublisher {
    var lastPublishedId = -1L
    override suspend fun publishContinueWatching(
        itemId: Long,
        title: String,
        posterUrl: String?,
        positionMs: Long,
        durationMs: Long,
        isEpisode: Boolean,
    ) {
        lastPublishedId = itemId
    }
    override suspend fun removeFromWatchNext(itemId: Long) = Unit
}

private class FakePlayerSettings(private val prefs: AppPreferences) : SettingsRepository {
    override val preferencesFlow: Flow<AppPreferences> = flowOf(prefs)
    override suspend fun currentPreferences(): AppPreferences = prefs
    override suspend fun setOnboardingCompleted(completed: Boolean) = Unit
    override suspend fun setAssumedMaxConnections(limit: Int) = Unit
    override suspend fun setUiScale(scale: Float) = Unit
    override suspend fun setTvPlaybackOptions(autoFrameRate: Boolean, audioPassthrough: Boolean, tunneling: Boolean) = Unit
    override suspend fun setDownloadOverCellular(allowed: Boolean) = Unit
    override suspend fun setAdultCategoriesUnlocked(unlocked: Boolean) = Unit
    override suspend fun setLastChannelId(channelId: Long) = Unit
    override suspend fun updateAiConfig(config: AiSettingsConfig) = Unit
    override suspend fun setUpNextPreferences(preferences: UpNextPreferences) = Unit
}

private class FakeEpgRepository : EpgRepository {
    val slotsByTvgId = mutableMapOf<String, ImmutableList<EpgSlot>>()

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
    ): ImmutableList<EpgSlot> = slotsByTvgId[tvgId] ?: persistentListOf()
    override suspend fun buildCatchupStream(
        channelItemId: Long,
        startEpochSecs: Long,
        endEpochSecs: Long,
    ): PlayableStream? = PlayableStream(
        itemId = channelItemId,
        stableHash = "catchup_$channelItemId",
        title = "Replay",
        originalUrl = "http://provider.tv/catchup/$channelItemId.ts",
        playbackUrl = "http://provider.tv/catchup/$channelItemId.ts",
        kind = StreamKind.CATCHUP,
        host = "provider.tv",
    )
}

private object NoRemotePlayback : RemotePlaybackRepository {
    override val availablePeers: StateFlow<List<DiscoveredPeer>> = MutableStateFlow(emptyList())
    override val isHouseholdActive: StateFlow<Boolean> = MutableStateFlow(false)
    override val activeHandoffStatus: StateFlow<String?> = MutableStateFlow(null)
    override val activeRemoteSession: StateFlow<ActiveRemoteControlSession?> = MutableStateFlow(null)
    override val incomingPlayInstructions: SharedFlow<IncomingPlayInstruction> = MutableSharedFlow()
    override val streamInterruptedByPeer: SharedFlow<String> = MutableSharedFlow()
    override suspend fun startHandoff(
        targetPeerId: String, contentKey: String, sourceKey: String?, itemKind: String,
        providerRef: String?, title: String?, positionMs: Long,
    ) = false
    override fun clearHandoffStatus() = Unit
    override suspend fun startHandoffForItem(targetPeerId: String, itemId: Long) = false
    override suspend fun sourceKeyForItem(itemId: Long): String? = null
    override suspend fun sendPlaybackControl(targetPeerId: String, action: String, value: Long?) = Unit
    override fun setLocalPlaybackActive(contentKey: String?, title: String?, sourceKey: String?) = Unit
    override fun onLocalPlaybackStopped() = Unit
}

private class FakePlayerCatalogRepository(private val kind: StreamKind) : CatalogRepository {
    val savedProgress = mutableMapOf<String, Long>()
    val favoriteToggles = mutableListOf<Long>()
    val resolvedIds = mutableListOf<Long>()
    var channels: List<ChannelItem> = emptyList()
    var mirrorsById: Map<Long, List<ChannelItem>> = emptyMap()
    private var favorite = false

    override fun pagedLiveChannels(query: CatalogQuery): Flow<PagingData<ChannelItem>> = flowOf(PagingData.empty())
    override fun pagedMovies(query: CatalogQuery): Flow<PagingData<MovieItem>> = flowOf(PagingData.empty())
    override fun pagedSeries(query: CatalogQuery): Flow<PagingData<SeriesItem>> = flowOf(PagingData.empty())
    override suspend fun getGroups(kind: String, sourceId: Long?): ImmutableList<CategoryFacet> = persistentListOf()
    override suspend fun getChannelById(itemId: Long): ChannelItem? = channels.firstOrNull { it.id == itemId }
    override suspend fun getAdjacentChannel(currentItemId: Long, delta: Int, groupName: String?): ChannelItem? {
        if (channels.isEmpty()) return null
        val idx = channels.indexOfFirst { it.id == currentItemId }
        val next = if (idx < 0) 0 else ((idx + delta) % channels.size + channels.size) % channels.size
        return channels[next]
    }
    override suspend fun getChannelByNumber(number: Int): ChannelItem? =
        channels.firstOrNull { it.channelNumber == number }
    override suspend fun findChannelMirrors(itemId: Long): ImmutableList<ChannelItem> =
        (mirrorsById[itemId] ?: emptyList()).toImmutableList()
    override suspend fun listChannelsInGroup(groupName: String?, limit: Int): ImmutableList<ChannelItem> =
        channels.take(limit).toImmutableList()
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
    override suspend fun isFavoriteForPlayback(itemId: Long): Boolean = favorite
    override suspend fun toggleFavoriteForPlayback(itemId: Long): Boolean {
        favoriteToggles += itemId
        favorite = !favorite
        return favorite
    }
    override suspend fun recordWatchProgress(stableHash: String, positionMs: Long, durationMs: Long) {
        savedProgress[stableHash] = positionMs
    }
    override suspend fun resolvePlayableStream(itemId: Long, startPositionMs: Long): PlayableStream {
        resolvedIds += itemId
        val ch = channels.firstOrNull { it.id == itemId }
        return PlayableStream(
            itemId = itemId,
            stableHash = ch?.stableHash ?: "hash_$itemId",
            title = ch?.name ?: "Titre $itemId",
            originalUrl = ch?.streamUrl ?: "http://provider.tv/media/$itemId.mkv",
            playbackUrl = if (kind == StreamKind.LIVE) {
                ch?.streamUrl ?: "http://provider.tv/live/$itemId.ts"
            } else {
                "http://127.0.0.1:49152/stream/$itemId.mkv"
            },
            kind = kind,
            host = "provider.tv",
            containerExtension = "mkv",
            startPositionMs = startPositionMs,
            maxConnectionsForSource = 1,
        )
    }
}
