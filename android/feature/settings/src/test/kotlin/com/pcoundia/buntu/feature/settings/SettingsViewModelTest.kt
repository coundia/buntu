package com.pcoundia.buntu.feature.settings

import com.pcoundia.buntu.core.domain.model.AiProviderTestResult
import com.pcoundia.buntu.core.domain.model.AiProviderType
import com.pcoundia.buntu.core.domain.model.AiSettingsConfig
import com.pcoundia.buntu.core.domain.model.AppPreferences
import com.pcoundia.buntu.core.domain.model.EngineDbStats
import com.pcoundia.buntu.core.domain.model.EngineRuntimeConfig
import com.pcoundia.buntu.core.domain.model.NetworkLogItem
import com.pcoundia.buntu.core.domain.model.ProfileSummary
import com.pcoundia.buntu.core.domain.model.RecoDomainKind
import com.pcoundia.buntu.core.domain.model.RecoShelfGroup
import com.pcoundia.buntu.core.domain.model.UpNextContext
import com.pcoundia.buntu.core.domain.model.UpNextItem
import com.pcoundia.buntu.core.domain.model.UpNextPreferences
import com.pcoundia.buntu.core.domain.repository.EngineDiagnosticsRepository
import com.pcoundia.buntu.core.domain.repository.ProfilesRepository
import com.pcoundia.buntu.core.domain.repository.RecommendationsRepository
import com.pcoundia.buntu.core.domain.repository.SecretStore
import com.pcoundia.buntu.core.domain.repository.SettingsRepository
import com.pcoundia.buntu.core.platform.device.DeviceCapabilities
import com.pcoundia.buntu.core.platform.logging.RedactedAppLogger
import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.persistentListOf
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class SettingsViewModelTest {

    private val dispatcher = UnconfinedTestDispatcher()

    @Before
    fun setUp() = Dispatchers.setMain(dispatcher)

    @After
    fun tearDown() = Dispatchers.resetMain()

    @Test
    fun `testing AI provider with typed key saves key to Keystore and returns latency and model`() = runTest {
        val settingsRepo = FakeSettingsRepository(
            AppPreferences(
                aiConfig = AiSettingsConfig(
                    provider = AiProviderType.GEMINI,
                    model = "gemini-2.5-flash",
                )
            )
        )
        val secretStore = FakeSecretStore()
        val diagnosticsRepo = FakeDiagnosticsRepository()
        val vm = createViewModel(settingsRepo, secretStore, diagnosticsRepo)
        val collector = backgroundScope.launch { vm.uiState.collect {} }

        vm.updateApiKeyDraft("test-key-placeholder")
        vm.testAiProvider()
        advanceUntilIdle()

        assertTrue(vm.uiState.value.hasSavedApiKey)
        assertEquals("", vm.uiState.value.apiKeyDraft)
        val result = vm.uiState.value.aiTestResult
        assertNotNull(result)
        assertTrue(result!!.ok)
        assertEquals(142L, result.latencyMs)
        assertEquals("gemini-2.5-flash", result.model)
        assertEquals("Connexion réussie", result.message)
        assertEquals("test-key-placeholder", diagnosticsRepo.lastTestedKey)
        collector.cancel()
    }

    @Test
    fun `testing AI provider without required key fails immediately without contacting provider`() = runTest {
        val settingsRepo = FakeSettingsRepository(
            AppPreferences(
                aiConfig = AiSettingsConfig(
                    provider = AiProviderType.CLAUDE,
                    model = "claude-3-5-haiku-latest",
                )
            )
        )
        val secretStore = FakeSecretStore()
        val diagnosticsRepo = FakeDiagnosticsRepository()
        val vm = createViewModel(settingsRepo, secretStore, diagnosticsRepo)
        val collector = backgroundScope.launch { vm.uiState.collect {} }

        vm.testAiProvider()
        advanceUntilIdle()

        val result = vm.uiState.value.aiTestResult
        assertNotNull(result)
        assertFalse(result!!.ok)
        assertEquals(0, diagnosticsRepo.testCallsCount)
        collector.cancel()
    }

    @Test
    fun `testing local OpenAI-compatible endpoint succeeds without API key`() = runTest {
        val config = AiSettingsConfig(
            provider = AiProviderType.OPENAI_COMPATIBLE,
            model = "llama3.2",
            endpointUrl = "http://localhost:11434/v1",
            consent = false,
        )
        assertTrue(config.isEndpointLocal)
        assertNull(config.blocker(hasKey = false))

        val settingsRepo = FakeSettingsRepository(AppPreferences(aiConfig = config))
        val secretStore = FakeSecretStore()
        val diagnosticsRepo = FakeDiagnosticsRepository()
        val vm = createViewModel(settingsRepo, secretStore, diagnosticsRepo)
        val collector = backgroundScope.launch { vm.uiState.collect {} }

        vm.testAiProvider()
        advanceUntilIdle()

        val result = vm.uiState.value.aiTestResult
        assertNotNull(result)
        assertTrue(result!!.ok)
        assertEquals(1, diagnosticsRepo.testCallsCount)
        assertNull(diagnosticsRepo.lastTestedKey)
        collector.cancel()
    }

    @Test
    fun `switching AI provider clears previous test result and applies default model`() = runTest {
        val settingsRepo = FakeSettingsRepository(
            AppPreferences(
                aiConfig = AiSettingsConfig(
                    provider = AiProviderType.GEMINI,
                    model = "gemini-2.5-flash",
                )
            )
        )
        val secretStore = FakeSecretStore(initial = mapOf("ai_provider_key" to "saved-key"))
        val diagnosticsRepo = FakeDiagnosticsRepository()
        val vm = createViewModel(settingsRepo, secretStore, diagnosticsRepo)
        val collector = backgroundScope.launch { vm.uiState.collect {} }

        vm.testAiProvider()
        advanceUntilIdle()
        assertNotNull(vm.uiState.value.aiTestResult)

        vm.updateAiProvider(
            provider = AiProviderType.CLAUDE,
            model = vm.uiState.value.preferences.aiConfig.model,
            endpoint = "",
        )
        advanceUntilIdle()

        assertNull(vm.uiState.value.aiTestResult)
        assertEquals(AiProviderType.CLAUDE, vm.uiState.value.preferences.aiConfig.provider)
        assertEquals("claude-3-5-haiku-latest", vm.uiState.value.preferences.aiConfig.model)
        assertEquals("claude-3-5-haiku-latest", vm.uiState.value.aiModelDraft)
        collector.cancel()
    }

    @Test
    fun `typing AI model and endpoint updates draft synchronously and flushes on test`() = runTest {
        val settingsRepo = FakeSettingsRepository(
            AppPreferences(
                aiConfig = AiSettingsConfig(
                    provider = AiProviderType.OPENAI_COMPATIBLE,
                    model = "",
                    endpointUrl = "",
                )
            )
        )
        val secretStore = FakeSecretStore()
        val diagnosticsRepo = FakeDiagnosticsRepository()
        val vm = createViewModel(settingsRepo, secretStore, diagnosticsRepo)
        val collector = backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) { vm.uiState.collect {} }

        val typedModel = "llama3.2:latest"
        var prefix = ""
        for (ch in typedModel) {
            prefix += ch
            vm.updateAiModelDraft(prefix)
            assertEquals(prefix, vm.uiState.value.aiModelDraft)
        }
        vm.updateAiEndpointDraft("http://localhost:11434/v1")
        assertEquals("http://localhost:11434/v1", vm.uiState.value.aiEndpointDraft)

        // Immediately testing flushes the typed model and endpoint even before debounce completes
        vm.testAiProvider()
        advanceUntilIdle()

        assertEquals(typedModel, vm.uiState.value.preferences.aiConfig.model)
        assertEquals("http://localhost:11434/v1", vm.uiState.value.preferences.aiConfig.endpointUrl)
        assertEquals(typedModel, vm.uiState.value.aiTestResult?.model)
        assertTrue(vm.uiState.value.aiTestResult?.ok == true)
        collector.cancel()
    }

    @Test
    fun `resetting taste and dismissed recommendations updates engine and feedback message`() = runTest {
        val settingsRepo = FakeSettingsRepository()
        val secretStore = FakeSecretStore()
        val diagnosticsRepo = FakeDiagnosticsRepository()
        val recoRepo = FakeRecommendationsRepository()
        val vm = createViewModel(settingsRepo, secretStore, diagnosticsRepo, recoRepo)
        val collector = backgroundScope.launch { vm.uiState.collect {} }

        vm.resetDismissedRecommendations()
        advanceUntilIdle()
        assertTrue(diagnosticsRepo.dismissedReset)
        assertEquals("Contenus « Pas intéressé » réinitialisés.", vm.uiState.value.recoFeedbackMessage)

        vm.resetTaste(RecoDomainKind.MOVIES)
        advanceUntilIdle()
        assertEquals(listOf(RecoDomainKind.MOVIES), recoRepo.resetKinds)
        assertEquals("Goûts réinitialisés pour : films.", vm.uiState.value.recoFeedbackMessage)
        collector.cancel()
    }

    @Test
    fun `reducing subscription connection limit clamps download segments and active files`() = runTest {
        val settingsRepo = FakeSettingsRepository(AppPreferences(assumedMaxConnections = 5))
        val secretStore = FakeSecretStore()
        val diagnosticsRepo = FakeDiagnosticsRepository(
            initialRuntime = EngineRuntimeConfig(segmentsPerFile = 4, partSizeMb = 8, maxActiveFiles = 2)
        )
        val vm = createViewModel(settingsRepo, secretStore, diagnosticsRepo)
        val collector = backgroundScope.launch { vm.uiState.collect {} }

        vm.setAssumedMaxConnections(1)
        advanceUntilIdle()

        assertEquals(1, vm.uiState.value.runtimeConfig.segmentsPerFile)
        assertEquals(1, vm.uiState.value.runtimeConfig.maxActiveFiles)
        collector.cancel()
    }

    @Test
    fun `about info exposes Buntu identity, author metadata, license and neutral player notice`() {
        assertEquals("Buntu", BuntuAboutInfo.APP_NAME)
        assertEquals("1.0.0", BuntuAboutInfo.APP_VERSION)
        assertEquals("1", BuntuAboutInfo.APP_BUILD)
        assertEquals("Sa bunt ci lépp — La porte d'entrée de tous vos médias.", BuntuAboutInfo.SLOGAN)
        assertEquals("Papa COUNDIA", BuntuAboutInfo.AUTHOR_NAME)
        assertEquals("papacoundia@gmail.com", BuntuAboutInfo.AUTHOR_EMAIL)
        assertEquals("Sénégal", BuntuAboutInfo.AUTHOR_COUNTRY)
        assertEquals("MIT / Apache-2.0", BuntuAboutInfo.LICENSE)
        assertEquals(
            "Buntu est un lecteur neutre : il ne fournit aucun contenu et lit uniquement les sources que vous ajoutez. Vos données restent sur votre appareil.",
            BuntuAboutInfo.LEGAL_NOTICE,
        )
    }

    private fun createViewModel(
        settingsRepo: FakeSettingsRepository,
        secretStore: FakeSecretStore,
        diagnosticsRepo: FakeDiagnosticsRepository,
        recoRepo: FakeRecommendationsRepository = FakeRecommendationsRepository(),
    ) = SettingsViewModel(
        settingsRepository = settingsRepo,
        secretStore = secretStore,
        diagnosticsRepository = diagnosticsRepo,
        recommendationsRepository = recoRepo,
        profilesRepository = FakeProfilesRepository(),
        appLogger = RedactedAppLogger(),
        deviceCapabilities = DeviceCapabilities(isTelevision = false),
    )
}

private class FakeSettingsRepository(
    initial: AppPreferences = AppPreferences(),
) : SettingsRepository {
    private val state = MutableStateFlow(initial)
    override val preferencesFlow: Flow<AppPreferences> = state
    override suspend fun currentPreferences(): AppPreferences = state.value
    override suspend fun setOnboardingCompleted(completed: Boolean) {
        state.value = state.value.copy(onboardingCompleted = completed)
    }
    override suspend fun setAssumedMaxConnections(limit: Int) {
        state.value = state.value.copy(assumedMaxConnections = limit)
    }
    override suspend fun setUiScale(scale: Float) {
        state.value = state.value.copy(uiScale = scale)
    }
    override suspend fun setTvPlaybackOptions(autoFrameRate: Boolean, audioPassthrough: Boolean, tunneling: Boolean) {
        state.value = state.value.copy(
            autoFrameRateMatchingTv = autoFrameRate,
            audioPassthroughTv = audioPassthrough,
            tunnelingEnabledTv = tunneling,
        )
    }
    override suspend fun setDownloadOverCellular(allowed: Boolean) {
        state.value = state.value.copy(downloadOverCellular = allowed)
    }
    override suspend fun setAdultCategoriesUnlocked(unlocked: Boolean) {
        state.value = state.value.copy(adultCategoriesUnlocked = unlocked)
    }
    override suspend fun setLastChannelId(channelId: Long) {
        state.value = state.value.copy(lastChannelId = channelId)
    }
    override suspend fun updateAiConfig(config: AiSettingsConfig) {
        state.value = state.value.copy(aiConfig = config)
    }
    override suspend fun setUpNextPreferences(preferences: UpNextPreferences) {
        state.value = state.value.copy(upNext = preferences)
    }
}

private class FakeSecretStore(
    initial: Map<String, String> = emptyMap(),
) : SecretStore {
    private val map = initial.toMutableMap()
    override suspend fun putSecret(alias: String, plaintext: String) {
        map[alias] = plaintext
    }
    override suspend fun getSecret(alias: String): String? = map[alias]
    override suspend fun deleteSecret(alias: String) {
        map.remove(alias)
    }
}

private class FakeDiagnosticsRepository(
    initialRuntime: EngineRuntimeConfig = EngineRuntimeConfig(),
) : EngineDiagnosticsRepository {
    var testCallsCount = 0
    var lastTestedKey: String? = null
    var dismissedReset = false
    var runtimeConfig = initialRuntime

    override suspend fun engineVersion(): String = "1.0.0-native-rust"
    override suspend fun pollNetworkLogs(afterSeqId: Long, limit: Int): ImmutableList<NetworkLogItem> = persistentListOf()
    override suspend fun clearLogs() = Unit

    override suspend fun testAiProvider(
        aiConfig: AiSettingsConfig,
        apiKey: String?,
    ): AiProviderTestResult {
        testCallsCount += 1
        lastTestedKey = apiKey
        return AiProviderTestResult(
            ok = true,
            latencyMs = 142L,
            model = aiConfig.model.ifBlank { aiConfig.provider.defaultModel },
            message = "Connexion réussie",
        )
    }

    override suspend fun getDbStats(): EngineDbStats = EngineDbStats(
        totalSources = 2,
        totalLiveChannels = 120,
        totalMovies = 450,
        totalSeries = 80,
        totalFavorites = 12,
        totalBroken = 3,
        dbSizeBytes = 2L * 1024L * 1024L,
    )

    override suspend fun getRuntimeConfig(): EngineRuntimeConfig = runtimeConfig

    override suspend fun updateRuntimeConfig(config: EngineRuntimeConfig, omdbKeyRef: String?) {
        runtimeConfig = config
    }

    override suspend fun resetDismissedRecommendations() {
        dismissedReset = true
    }
}

private class FakeRecommendationsRepository : RecommendationsRepository {
    val resetKinds = mutableListOf<RecoDomainKind>()

    override suspend fun loadLocalShelves(
        kind: RecoDomainKind,
        limitPerShelf: Int,
        utcOffsetMinutes: Int,
    ): ImmutableList<RecoShelfGroup> = persistentListOf()

    override suspend fun refineShelvesWithAi(
        kind: RecoDomainKind,
        aiConfig: AiSettingsConfig,
        apiKey: String,
        limitPerShelf: Int,
        locale: String,
        utcOffsetMinutes: Int,
    ): ImmutableList<RecoShelfGroup> = persistentListOf()

    override suspend fun markLessLikeThis(kind: RecoDomainKind, stableHash: String) = Unit

    override suspend fun resetTaste(kind: RecoDomainKind) {
        resetKinds += kind
    }

    override suspend fun upNextFor(itemId: Long, context: UpNextContext, limit: Int): ImmutableList<UpNextItem> =
        persistentListOf()

    override suspend fun nextUpAfter(itemId: Long): UpNextItem? = null

    override suspend fun dismissUpNext(stableHash: String) = Unit
}

private class FakeProfilesRepository : ProfilesRepository {
    override val profilesFlow: Flow<ImmutableList<ProfileSummary>> = flowOf(persistentListOf())
    override suspend fun refreshProfiles(): ImmutableList<ProfileSummary> = persistentListOf()
    override suspend fun activeProfile(): ProfileSummary = ProfileSummary(1L, "Principal", "🎬", isKids = false, isActive = true)
    override suspend fun selectProfile(profileId: Long) = Unit
    override suspend fun createProfile(name: String, avatar: String, isKids: Boolean): ProfileSummary = activeProfile()
    override suspend fun deleteProfile(profileId: Long) = Unit
    override suspend fun setAdultContentVisible(visible: Boolean) = Unit
    override suspend fun setGroupAllowedForKids(profileId: Long, kind: String, groupName: String, allowed: Boolean) = Unit
}

