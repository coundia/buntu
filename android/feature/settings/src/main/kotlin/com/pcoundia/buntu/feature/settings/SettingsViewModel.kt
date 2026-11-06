package com.pcoundia.buntu.feature.settings

import androidx.compose.runtime.Immutable
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.pcoundia.buntu.core.domain.model.AiProviderType
import com.pcoundia.buntu.core.domain.model.AiSettingsConfig
import com.pcoundia.buntu.core.domain.model.AppPreferences
import com.pcoundia.buntu.core.domain.model.NetworkLogItem
import com.pcoundia.buntu.core.domain.repository.EngineDiagnosticsRepository
import com.pcoundia.buntu.core.domain.repository.SecretStore
import com.pcoundia.buntu.core.domain.repository.SettingsRepository
import com.pcoundia.buntu.core.platform.device.DeviceCapabilities
import com.pcoundia.buntu.core.platform.logging.FramePerformanceSummary
import com.pcoundia.buntu.core.platform.logging.RedactedAppLogger
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.persistentListOf
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
    val frameStats: FramePerformanceSummary = FramePerformanceSummary(),
    val networkLogs: ImmutableList<NetworkLogItem> = persistentListOf(),
    val apiKeyDraft: String = "",
    val hasSavedApiKey: Boolean = false,
    val statusMessage: String? = null,
)

private data class SettingsLocalDraft(
    val engineVersion: String = "…",
    val networkLogs: ImmutableList<NetworkLogItem> = persistentListOf(),
    val apiKeyDraft: String = "",
    val hasSavedApiKey: Boolean = false,
    val statusMessage: String? = null,
)

/**
 * PRD-37 § 5.1, § 7, § 8:
 * Unified Settings & Diagnostics ViewModel:
 * - Connection budget (`1..10`), UI scale, cellular downloads, TV HDMI/audio/tunneling options
 * - Optional BYOK AI configuration stored in Android Keystore
 * - Redacted network logs + `JankStats` frame budget monitor
 */
@HiltViewModel
class SettingsViewModel @Inject constructor(
    private val settingsRepository: SettingsRepository,
    private val secretStore: SecretStore,
    private val diagnosticsRepository: EngineDiagnosticsRepository,
    appLogger: RedactedAppLogger,
    deviceCapabilities: DeviceCapabilities,
) : ViewModel() {

    private val localDraft = MutableStateFlow(SettingsLocalDraft())
    private val isTvDevice = deviceCapabilities.isTelevision

    val uiState: StateFlow<SettingsUiState> = combine(
        settingsRepository.preferencesFlow,
        appLogger.frameStats,
        localDraft,
    ) { prefs, frames, draft ->
        SettingsUiState(
            preferences = prefs,
            isTv = isTvDevice,
            engineVersion = draft.engineVersion,
            frameStats = frames,
            networkLogs = draft.networkLogs,
            apiKeyDraft = draft.apiKeyDraft,
            hasSavedApiKey = draft.hasSavedApiKey,
            statusMessage = draft.statusMessage,
        )
    }.stateIn(
        scope = viewModelScope,
        started = SharingStarted.WhileSubscribed(5_000L),
        initialValue = SettingsUiState(isTv = isTvDevice),
    )

    init {
        viewModelScope.launch {
            val ver = runCatching { diagnosticsRepository.engineVersion() }.getOrDefault("cnd-core")
            val prefs = settingsRepository.currentPreferences()
            val savedKey = !secretStore.getSecret(prefs.aiConfig.keyAlias).isNullOrBlank()
            val logs = runCatching { diagnosticsRepository.pollNetworkLogs() }.getOrDefault(persistentListOf())
            localDraft.update {
                it.copy(
                    engineVersion = ver,
                    hasSavedApiKey = savedKey,
                    networkLogs = logs,
                )
            }
        }
    }

    fun setAssumedMaxConnections(limit: Int) {
        viewModelScope.launch { settingsRepository.setAssumedMaxConnections(limit) }
    }

    fun setUiScale(scale: Float) {
        viewModelScope.launch { settingsRepository.setUiScale(scale) }
    }

    fun setDownloadOverCellular(allowed: Boolean) {
        viewModelScope.launch { settingsRepository.setDownloadOverCellular(allowed) }
    }

    fun setTvOptions(autoFrameRate: Boolean, audioPassthrough: Boolean, tunneling: Boolean) {
        viewModelScope.launch {
            settingsRepository.setTvPlaybackOptions(autoFrameRate, audioPassthrough, tunneling)
        }
    }

    fun updateAiProvider(provider: AiProviderType, model: String, endpoint: String) {
        viewModelScope.launch {
            val current = settingsRepository.currentPreferences().aiConfig
            settingsRepository.updateAiConfig(
                current.copy(
                    provider = provider,
                    model = model,
                    endpointUrl = endpoint,
                )
            )
        }
    }

    fun updateApiKeyDraft(value: String) {
        localDraft.update { it.copy(apiKeyDraft = value, statusMessage = null) }
    }

    fun saveApiKeyToKeystore() {
        val draft = localDraft.value.apiKeyDraft.trim()
        viewModelScope.launch {
            val alias = settingsRepository.currentPreferences().aiConfig.keyAlias
            if (draft.isEmpty()) {
                secretStore.deleteSecret(alias)
                localDraft.update {
                    it.copy(hasSavedApiKey = false, statusMessage = "Clé API supprimée du Keystore.")
                }
            } else {
                secretStore.putSecret(alias, draft)
                localDraft.update {
                    it.copy(
                        apiKeyDraft = "",
                        hasSavedApiKey = true,
                        statusMessage = "Clé API chiffrée dans Android Keystore.",
                    )
                }
            }
        }
    }

    fun refreshDiagnostics() {
        viewModelScope.launch {
            val logs = runCatching { diagnosticsRepository.pollNetworkLogs() }.getOrDefault(persistentListOf())
            localDraft.update { it.copy(networkLogs = logs) }
        }
    }

    fun clearDiagnostics() {
        viewModelScope.launch {
            runCatching { diagnosticsRepository.clearLogs() }
            localDraft.update { it.copy(networkLogs = persistentListOf()) }
        }
    }
}

