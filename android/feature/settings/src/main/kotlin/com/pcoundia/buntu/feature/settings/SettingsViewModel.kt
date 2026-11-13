package com.pcoundia.buntu.feature.settings

import androidx.compose.runtime.Immutable
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.pcoundia.buntu.core.domain.model.AiProviderTestResult
import com.pcoundia.buntu.core.domain.model.AiProviderType
import com.pcoundia.buntu.core.domain.model.AiSettingsConfig
import com.pcoundia.buntu.core.domain.model.AppPreferences
import com.pcoundia.buntu.core.domain.model.ConnectionBudget
import com.pcoundia.buntu.core.domain.model.EngineDbStats
import com.pcoundia.buntu.core.domain.model.EngineRuntimeConfig
import com.pcoundia.buntu.core.domain.model.NetworkLogItem
import com.pcoundia.buntu.core.domain.model.RecoDomainKind
import com.pcoundia.buntu.core.domain.model.UpNextPreferences
import com.pcoundia.buntu.core.domain.repository.EngineDiagnosticsRepository
import com.pcoundia.buntu.core.domain.repository.ProfilesRepository
import com.pcoundia.buntu.core.domain.repository.RecommendationsRepository
import com.pcoundia.buntu.core.domain.repository.SecretStore
import com.pcoundia.buntu.core.domain.repository.SettingsRepository
import com.pcoundia.buntu.core.platform.device.DeviceCapabilities
import com.pcoundia.buntu.core.platform.logging.FramePerformanceSummary
import com.pcoundia.buntu.core.platform.logging.RedactedAppLogger
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.persistentListOf
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject

@Immutable
data class SettingsUiState(
    val preferences: AppPreferences = AppPreferences(),
    val isTv: Boolean = false,
    val engineVersion: String = "…",
    val dbStats: EngineDbStats = EngineDbStats(),
    val runtimeConfig: EngineRuntimeConfig = EngineRuntimeConfig(),
    val frameStats: FramePerformanceSummary = FramePerformanceSummary(),
    val networkLogs: ImmutableList<NetworkLogItem> = persistentListOf(),
    val aiModelDraft: String = "",
    val aiEndpointDraft: String = "",
    val apiKeyDraft: String = "",
    val hasSavedApiKey: Boolean = false,
    val showApiKey: Boolean = false,
    val isTestingAi: Boolean = false,
    val aiTestResult: AiProviderTestResult? = null,
    val omdbKeyDraft: String = "",
    val hasSavedOmdbKey: Boolean = false,
    val showOmdbKey: Boolean = false,
    val openSubtitlesKeyDraft: String = "",
    val hasSavedOpenSubtitlesKey: Boolean = false,
    val showOpenSubtitlesKey: Boolean = false,
    val statusMessage: String? = null,
    val recoFeedbackMessage: String? = null,
)

private data class SettingsLocalDraft(
    val engineVersion: String = "…",
    val dbStats: EngineDbStats = EngineDbStats(),
    val runtimeConfig: EngineRuntimeConfig = EngineRuntimeConfig(),
    val networkLogs: ImmutableList<NetworkLogItem> = persistentListOf(),
    val aiDraftsInitialized: Boolean = false,
    val aiModelDraft: String = "",
    val aiEndpointDraft: String = "",
    val apiKeyDraft: String = "",
    val hasSavedApiKey: Boolean = false,
    val showApiKey: Boolean = false,
    val isTestingAi: Boolean = false,
    val aiTestResult: AiProviderTestResult? = null,
    val omdbKeyDraft: String = "",
    val hasSavedOmdbKey: Boolean = false,
    val showOmdbKey: Boolean = false,
    val openSubtitlesKeyDraft: String = "",
    val hasSavedOpenSubtitlesKey: Boolean = false,
    val showOpenSubtitlesKey: Boolean = false,
    val statusMessage: String? = null,
    val recoFeedbackMessage: String? = null,
)

/**
 * PRD-37 § 5.1, § 7, § 8 & Apple `SettingsView.swift` / `AiProviderSettings.swift` parity:
 * Unified Settings & Diagnostics ViewModel:
 * - Connection budget (`1..10`), download engine settings (`RuntimeSettings`), UI scale, cellular downloads, TV HDMI/audio/tunneling options
 * - BYOK AI configuration stored in Android Keystore + live connection test (`testAiProvider`)
 * - Recommendations & "Pour vous" taste reset + dismissed items reset
 * - OMDb & OpenSubtitles Keystore keys + HTTP User-Agent / Referer
 * - Parental control adult categories lock/unlock
 * - Database statistics (`DbStats`), redacted network logs + `JankStats` frame budget monitor
 */
@HiltViewModel
class SettingsViewModel @Inject constructor(
    private val settingsRepository: SettingsRepository,
    private val secretStore: SecretStore,
    private val diagnosticsRepository: EngineDiagnosticsRepository,
    private val recommendationsRepository: RecommendationsRepository,
    private val profilesRepository: ProfilesRepository,
    appLogger: RedactedAppLogger,
    deviceCapabilities: DeviceCapabilities,
) : ViewModel() {

    companion object {
        const val OMDB_KEY_ALIAS = "omdb_api_key"
        const val OPENSUBTITLES_KEY_ALIAS = "opensubtitles_api_key"
    }

    private val localDraft = MutableStateFlow(SettingsLocalDraft())
    private val isTvDevice = deviceCapabilities.isTelevision
    private var aiPersistJob: Job? = null

    val uiState: StateFlow<SettingsUiState> = combine(
        settingsRepository.preferencesFlow,
        appLogger.frameStats,
        localDraft,
    ) { prefs, frames, draft ->
        SettingsUiState(
            preferences = prefs,
            isTv = isTvDevice,
            engineVersion = draft.engineVersion,
            dbStats = draft.dbStats,
            runtimeConfig = draft.runtimeConfig,
            frameStats = frames,
            networkLogs = draft.networkLogs,
            aiModelDraft = if (draft.aiDraftsInitialized) draft.aiModelDraft else prefs.aiConfig.model,
            aiEndpointDraft = if (draft.aiDraftsInitialized) draft.aiEndpointDraft else prefs.aiConfig.endpointUrl,
            apiKeyDraft = draft.apiKeyDraft,
            hasSavedApiKey = draft.hasSavedApiKey,
            showApiKey = draft.showApiKey,
            isTestingAi = draft.isTestingAi,
            aiTestResult = draft.aiTestResult,
            omdbKeyDraft = draft.omdbKeyDraft,
            hasSavedOmdbKey = draft.hasSavedOmdbKey,
            showOmdbKey = draft.showOmdbKey,
            openSubtitlesKeyDraft = draft.openSubtitlesKeyDraft,
            hasSavedOpenSubtitlesKey = draft.hasSavedOpenSubtitlesKey,
            showOpenSubtitlesKey = draft.showOpenSubtitlesKey,
            statusMessage = draft.statusMessage,
            recoFeedbackMessage = draft.recoFeedbackMessage,
        )
    }.stateIn(
        scope = viewModelScope,
        started = SharingStarted.WhileSubscribed(5_000L),
        initialValue = SettingsUiState(isTv = isTvDevice),
    )

    init {
        viewModelScope.launch {
            val ver = runCatching { diagnosticsRepository.engineVersion() }.getOrDefault("cnd-core")
            val stats = runCatching { diagnosticsRepository.getDbStats() }.getOrDefault(EngineDbStats())
            val runtime = runCatching { diagnosticsRepository.getRuntimeConfig() }.getOrDefault(EngineRuntimeConfig())
            val prefs = settingsRepository.currentPreferences()
            val savedAiKey = !secretStore.getSecret(prefs.aiConfig.keyAlias).isNullOrBlank()
            val savedOmdbKey = !secretStore.getSecret(OMDB_KEY_ALIAS).isNullOrBlank()
            val savedSubKey = !secretStore.getSecret(OPENSUBTITLES_KEY_ALIAS).isNullOrBlank()
            val logs = runCatching { diagnosticsRepository.pollNetworkLogs() }.getOrDefault(persistentListOf())
            localDraft.update { draft ->
                draft.copy(
                    engineVersion = ver,
                    dbStats = stats,
                    runtimeConfig = runtime,
                    aiDraftsInitialized = true,
                    aiModelDraft = if (draft.aiDraftsInitialized) draft.aiModelDraft else prefs.aiConfig.model,
                    aiEndpointDraft = if (draft.aiDraftsInitialized) draft.aiEndpointDraft else prefs.aiConfig.endpointUrl,
                    hasSavedApiKey = savedAiKey,
                    hasSavedOmdbKey = savedOmdbKey,
                    hasSavedOpenSubtitlesKey = savedSubKey,
                    networkLogs = logs,
                )
            }
        }
    }

    fun setAssumedMaxConnections(limit: Int) {
        val clampedLimit = limit.coerceIn(ConnectionBudget.MIN_LIMIT, ConnectionBudget.MAX_LIMIT)
        viewModelScope.launch {
            settingsRepository.setAssumedMaxConnections(clampedLimit)
            val budget = ConnectionBudget(clampedLimit)
            val currentRuntime = localDraft.value.runtimeConfig
            val (clampedSegments, clampedFiles) = budget.clampDownloads(
                requestedSegments = currentRuntime.segmentsPerFile,
                requestedFiles = currentRuntime.maxActiveFiles,
            )
            if (clampedSegments != currentRuntime.segmentsPerFile || clampedFiles != currentRuntime.maxActiveFiles) {
                val updated = currentRuntime.copy(
                    segmentsPerFile = clampedSegments,
                    maxActiveFiles = clampedFiles,
                )
                localDraft.update { it.copy(runtimeConfig = updated) }
                runCatching {
                    val omdbRef = if (localDraft.value.hasSavedOmdbKey) OMDB_KEY_ALIAS else null
                    diagnosticsRepository.updateRuntimeConfig(updated, omdbRef)
                }
            }
        }
    }

    fun updateDownloadEngineSettings(
        segmentsPerFile: Int = localDraft.value.runtimeConfig.segmentsPerFile,
        partSizeMb: Int = localDraft.value.runtimeConfig.partSizeMb,
        maxActiveFiles: Int = localDraft.value.runtimeConfig.maxActiveFiles,
    ) {
        viewModelScope.launch {
            val prefs = settingsRepository.currentPreferences()
            val budget = ConnectionBudget(prefs.assumedMaxConnections)
            val (clampedSegments, clampedFiles) = budget.clampDownloads(
                requestedSegments = segmentsPerFile.coerceIn(1, 16),
                requestedFiles = maxActiveFiles.coerceIn(1, 8),
            )
            val updated = localDraft.value.runtimeConfig.copy(
                segmentsPerFile = clampedSegments,
                partSizeMb = partSizeMb.coerceIn(1, 256),
                maxActiveFiles = clampedFiles,
            )
            localDraft.update { it.copy(runtimeConfig = updated) }
            runCatching {
                val omdbRef = if (localDraft.value.hasSavedOmdbKey) OMDB_KEY_ALIAS else null
                diagnosticsRepository.updateRuntimeConfig(updated, omdbRef)
            }
        }
    }

    fun updateNetworkHeaders(userAgent: String, referer: String) {
        val updated = localDraft.value.runtimeConfig.copy(
            defaultUserAgent = userAgent,
            defaultReferer = referer,
        )
        localDraft.update { it.copy(runtimeConfig = updated) }
        viewModelScope.launch {
            runCatching {
                val omdbRef = if (localDraft.value.hasSavedOmdbKey) OMDB_KEY_ALIAS else null
                diagnosticsRepository.updateRuntimeConfig(updated, omdbRef)
            }
        }
    }

    fun setShowNetworkConsole(show: Boolean) {
        val updated = localDraft.value.runtimeConfig.copy(showNetworkConsole = show)
        localDraft.update { it.copy(runtimeConfig = updated) }
        viewModelScope.launch {
            runCatching {
                val omdbRef = if (localDraft.value.hasSavedOmdbKey) OMDB_KEY_ALIAS else null
                diagnosticsRepository.updateRuntimeConfig(updated, omdbRef)
            }
        }
    }

    fun setUiScale(scale: Float) {
        viewModelScope.launch { settingsRepository.setUiScale(scale) }
    }

    fun setDownloadOverCellular(allowed: Boolean) {
        viewModelScope.launch { settingsRepository.setDownloadOverCellular(allowed) }
    }

    fun setAdultCategoriesUnlocked(unlocked: Boolean) {
        viewModelScope.launch {
            settingsRepository.setAdultCategoriesUnlocked(unlocked)
            runCatching { profilesRepository.setAdultContentVisible(unlocked) }
        }
    }

    fun setTvOptions(autoFrameRate: Boolean, audioPassthrough: Boolean, tunneling: Boolean) {
        viewModelScope.launch {
            settingsRepository.setTvPlaybackOptions(autoFrameRate, audioPassthrough, tunneling)
        }
    }

    fun setUpNextPreferences(preferences: UpNextPreferences) {
        viewModelScope.launch { settingsRepository.setUpNextPreferences(preferences) }
    }

    fun resetDismissedRecommendations() {
        viewModelScope.launch {
            runCatching { diagnosticsRepository.resetDismissedRecommendations() }
            localDraft.update {
                it.copy(recoFeedbackMessage = "Contenus « Pas intéressé » réinitialisés.")
            }
        }
    }

    fun resetTaste(kind: RecoDomainKind) {
        val label = when (kind) {
            RecoDomainKind.MOVIES -> "films"
            RecoDomainKind.SERIES -> "séries"
            RecoDomainKind.LIVE_TV -> "TV en direct"
        }
        viewModelScope.launch {
            runCatching { recommendationsRepository.resetTaste(kind) }
            localDraft.update {
                it.copy(recoFeedbackMessage = "Goûts réinitialisés pour : $label.")
            }
        }
    }

    fun updateAiModelDraft(model: String) {
        localDraft.update {
            it.copy(
                aiDraftsInitialized = true,
                aiModelDraft = model,
                aiTestResult = null,
                statusMessage = null,
            )
        }
        scheduleAiDraftPersist()
    }

    fun updateAiEndpointDraft(endpoint: String) {
        localDraft.update {
            it.copy(
                aiDraftsInitialized = true,
                aiEndpointDraft = endpoint,
                aiTestResult = null,
                statusMessage = null,
            )
        }
        scheduleAiDraftPersist()
    }

    private fun scheduleAiDraftPersist() {
        aiPersistJob?.cancel()
        aiPersistJob = viewModelScope.launch {
            delay(300L)
            persistAiDrafts()
        }
    }

    private suspend fun persistAiDrafts() {
        val draft = localDraft.value
        if (!draft.aiDraftsInitialized) return
        val current = settingsRepository.currentPreferences().aiConfig
        if (current.model != draft.aiModelDraft || current.endpointUrl != draft.aiEndpointDraft) {
            settingsRepository.updateAiConfig(
                current.copy(
                    model = draft.aiModelDraft,
                    endpointUrl = draft.aiEndpointDraft,
                )
            )
        }
    }

    fun updateAiProvider(provider: AiProviderType, model: String, endpoint: String) {
        aiPersistJob?.cancel()
        val currentProvider = uiState.value.preferences.aiConfig.provider
        val resolvedModel = if (currentProvider != provider) provider.defaultModel else model
        localDraft.update {
            it.copy(
                aiDraftsInitialized = true,
                aiModelDraft = resolvedModel,
                aiEndpointDraft = endpoint,
                aiTestResult = null,
                statusMessage = null,
            )
        }
        viewModelScope.launch {
            val current = settingsRepository.currentPreferences().aiConfig
            val persistedModel = if (current.provider != provider) provider.defaultModel else model
            settingsRepository.updateAiConfig(
                current.copy(
                    provider = provider,
                    model = persistedModel,
                    endpointUrl = endpoint,
                )
            )
        }
    }

    fun setAiConsent(consent: Boolean) {
        viewModelScope.launch {
            val current = settingsRepository.currentPreferences().aiConfig
            settingsRepository.updateAiConfig(current.copy(consent = consent))
        }
    }

    fun setAiAutoSearch(autoSearch: Boolean) {
        viewModelScope.launch {
            val current = settingsRepository.currentPreferences().aiConfig
            settingsRepository.updateAiConfig(current.copy(autoSearch = autoSearch))
        }
    }

    fun setAiSendRecentTitles(sendRecentTitles: Boolean) {
        viewModelScope.launch {
            val current = settingsRepository.currentPreferences().aiConfig
            settingsRepository.updateAiConfig(current.copy(sendRecentTitles = sendRecentTitles))
        }
    }

    fun updateApiKeyDraft(value: String) {
        localDraft.update { it.copy(apiKeyDraft = value, statusMessage = null, aiTestResult = null) }
    }

    fun toggleShowApiKey() {
        localDraft.update { it.copy(showApiKey = !it.showApiKey) }
    }

    fun saveApiKeyToKeystore() {
        val draft = localDraft.value.apiKeyDraft.trim()
        viewModelScope.launch {
            val alias = settingsRepository.currentPreferences().aiConfig.keyAlias
            if (draft.isEmpty()) {
                secretStore.deleteSecret(alias)
                localDraft.update {
                    it.copy(
                        hasSavedApiKey = false,
                        aiTestResult = null,
                        statusMessage = "Clé API supprimée du Keystore.",
                    )
                }
            } else {
                secretStore.putSecret(alias, draft)
                localDraft.update {
                    it.copy(
                        apiKeyDraft = "",
                        showApiKey = false,
                        hasSavedApiKey = true,
                        statusMessage = "Clé API chiffrée dans Android Keystore.",
                    )
                }
            }
        }
    }

    fun deleteApiKeyFromKeystore() {
        viewModelScope.launch {
            val alias = settingsRepository.currentPreferences().aiConfig.keyAlias
            secretStore.deleteSecret(alias)
            localDraft.update {
                it.copy(
                    apiKeyDraft = "",
                    showApiKey = false,
                    hasSavedApiKey = false,
                    aiTestResult = null,
                    statusMessage = "Clé API supprimée du Keystore.",
                )
            }
        }
    }

    /**
     * Tests the currently selected AI provider via `EngineDiagnosticsRepository.testAiProvider`
     * (mirrors `SettingsView.runAiTest` / `AssistantModel.testProvider()` on macOS).
     * If the user typed a key into the field without pressing "Enregistrer" yet, it is persisted
     * to Keystore and used for the test.
     */
    fun testAiProvider() {
        if (localDraft.value.isTestingAi) return
        aiPersistJob?.cancel()
        viewModelScope.launch {
            persistAiDrafts()
            val aiConfig = settingsRepository.currentPreferences().aiConfig
            val effectiveModel = aiConfig.model.trim().ifBlank { aiConfig.provider.defaultModel }
            if (aiConfig.provider == AiProviderType.NONE) {
                localDraft.update {
                    it.copy(
                        aiTestResult = AiProviderTestResult(
                            ok = true,
                            latencyMs = 0L,
                            model = "local",
                            message = "Résolution locale active (aucun serveur distant)",
                        )
                    )
                }
                return@launch
            }

            val typedKey = localDraft.value.apiKeyDraft.trim()
            if (typedKey.isNotEmpty()) {
                secretStore.putSecret(aiConfig.keyAlias, typedKey)
                localDraft.update {
                    it.copy(
                        apiKeyDraft = "",
                        showApiKey = false,
                        hasSavedApiKey = true,
                        statusMessage = "Clé API chiffrée dans Android Keystore.",
                    )
                }
            }

            val effectiveKey = typedKey.ifEmpty { secretStore.getSecret(aiConfig.keyAlias)?.trim().orEmpty() }
            if (aiConfig.provider.requiresApiKey && effectiveKey.isEmpty()) {
                localDraft.update {
                    it.copy(
                        isTestingAi = false,
                        aiTestResult = AiProviderTestResult(
                            ok = false,
                            latencyMs = 0L,
                            model = effectiveModel,
                            message = "Saisissez une clé API avant de tester ce fournisseur.",
                        ),
                    )
                }
                return@launch
            }

            localDraft.update { it.copy(isTestingAi = true, aiTestResult = null) }
            val configForTest = aiConfig.copy(model = effectiveModel)
            val result = runCatching {
                diagnosticsRepository.testAiProvider(
                    aiConfig = configForTest,
                    apiKey = effectiveKey.takeIf { it.isNotEmpty() },
                )
            }.getOrElse { err ->
                AiProviderTestResult(
                    ok = false,
                    latencyMs = 0L,
                    model = effectiveModel,
                    message = err.message ?: "Échec du test de connexion IA.",
                )
            }
            localDraft.update {
                it.copy(
                    isTestingAi = false,
                    aiTestResult = result,
                )
            }
        }
    }

    fun updateOmdbKeyDraft(value: String) {
        localDraft.update { it.copy(omdbKeyDraft = value) }
    }

    fun toggleShowOmdbKey() {
        localDraft.update { it.copy(showOmdbKey = !it.showOmdbKey) }
    }

    fun saveOmdbKey() {
        val draft = localDraft.value.omdbKeyDraft.trim()
        viewModelScope.launch {
            if (draft.isEmpty()) {
                secretStore.deleteSecret(OMDB_KEY_ALIAS)
                localDraft.update { it.copy(hasSavedOmdbKey = false, showOmdbKey = false) }
                runCatching {
                    diagnosticsRepository.updateRuntimeConfig(localDraft.value.runtimeConfig, null)
                }
            } else {
                secretStore.putSecret(OMDB_KEY_ALIAS, draft)
                localDraft.update {
                    it.copy(omdbKeyDraft = "", hasSavedOmdbKey = true, showOmdbKey = false)
                }
                runCatching {
                    diagnosticsRepository.updateRuntimeConfig(localDraft.value.runtimeConfig, OMDB_KEY_ALIAS)
                }
            }
        }
    }

    fun updateOpenSubtitlesKeyDraft(value: String) {
        localDraft.update { it.copy(openSubtitlesKeyDraft = value) }
    }

    fun toggleShowOpenSubtitlesKey() {
        localDraft.update { it.copy(showOpenSubtitlesKey = !it.showOpenSubtitlesKey) }
    }

    fun saveOpenSubtitlesKey() {
        val draft = localDraft.value.openSubtitlesKeyDraft.trim()
        viewModelScope.launch {
            if (draft.isEmpty()) {
                secretStore.deleteSecret(OPENSUBTITLES_KEY_ALIAS)
                localDraft.update { it.copy(hasSavedOpenSubtitlesKey = false, showOpenSubtitlesKey = false) }
            } else {
                secretStore.putSecret(OPENSUBTITLES_KEY_ALIAS, draft)
                localDraft.update {
                    it.copy(openSubtitlesKeyDraft = "", hasSavedOpenSubtitlesKey = true, showOpenSubtitlesKey = false)
                }
            }
        }
    }

    fun refreshDiagnostics() {
        viewModelScope.launch {
            val logs = runCatching { diagnosticsRepository.pollNetworkLogs() }.getOrDefault(persistentListOf())
            val stats = runCatching { diagnosticsRepository.getDbStats() }.getOrDefault(localDraft.value.dbStats)
            localDraft.update { it.copy(networkLogs = logs, dbStats = stats) }
        }
    }

    fun clearDiagnostics() {
        viewModelScope.launch {
            runCatching { diagnosticsRepository.clearLogs() }
            localDraft.update { it.copy(networkLogs = persistentListOf()) }
        }
    }
}


