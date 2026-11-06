package com.pcoundia.buntu.feature.onboarding

import androidx.compose.runtime.Immutable
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.pcoundia.buntu.core.domain.model.ProfileSummary
import com.pcoundia.buntu.core.domain.model.SourceKind
import com.pcoundia.buntu.core.domain.repository.ProfilesRepository
import com.pcoundia.buntu.core.domain.repository.SettingsRepository
import com.pcoundia.buntu.core.domain.usecase.SyncSourceUseCase
import com.pcoundia.buntu.core.platform.device.DeviceCapabilities
import com.pcoundia.buntu.core.platform.tv.PairedSourcePayload
import com.pcoundia.buntu.core.platform.tv.QrMatrix
import com.pcoundia.buntu.core.platform.tv.QrPairingServer
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.persistentListOf
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject

@Immutable
data class OnboardingUiState(
    val step: Int = 1,
    val isTv: Boolean = false,
    val sourceKind: SourceKind = SourceKind.XTREAM,
    val name: String = "Mon IPTV",
    val serverOrUrl: String = "",
    val username: String = "",
    val password: String = "",
    val pairingUrl: String? = null,
    val qrMatrix: QrMatrix? = null,
    val isSyncing: Boolean = false,
    val errorMessage: String? = null,
    val profiles: ImmutableList<ProfileSummary> = persistentListOf(),
    val selectedProfileId: Long = 1L,
)

@HiltViewModel
class OnboardingViewModel @Inject constructor(
    private val syncSourceUseCase: SyncSourceUseCase,
    private val profilesRepository: ProfilesRepository,
    private val settingsRepository: SettingsRepository,
    private val qrPairingServer: QrPairingServer,
    deviceCapabilities: DeviceCapabilities,
) : ViewModel() {

    private val _uiState = MutableStateFlow(OnboardingUiState(isTv = deviceCapabilities.isTelevision))
    val uiState: StateFlow<OnboardingUiState> = _uiState.asStateFlow()

    init {
        viewModelScope.launch {
            val profiles = profilesRepository.refreshProfiles()
            val active = profiles.firstOrNull { it.isActive }?.id ?: 1L
            _uiState.update { it.copy(profiles = profiles, selectedProfileId = active) }
        }
        if (deviceCapabilities.isTelevision) {
            startTvQrPairing()
        }
    }

    fun selectSourceKind(kind: SourceKind) {
        _uiState.update { it.copy(sourceKind = kind, errorMessage = null) }
    }

    fun updateFields(
        name: String = _uiState.value.name,
        serverOrUrl: String = _uiState.value.serverOrUrl,
        username: String = _uiState.value.username,
        password: String = _uiState.value.password,
    ) {
        _uiState.update {
            it.copy(
                name = name,
                serverOrUrl = serverOrUrl,
                username = username,
                password = password,
                errorMessage = null,
            )
        }
    }

    fun submitSourceAndSync() {
        val current = _uiState.value
        if (current.serverOrUrl.isBlank()) {
            _uiState.update { it.copy(errorMessage = "Veuillez renseigner l'adresse du serveur ou de la playlist.") }
            return
        }
        viewModelScope.launch {
            _uiState.update { it.copy(isSyncing = true, errorMessage = null) }
            runCatching {
                if (current.sourceKind == SourceKind.XTREAM) {
                    syncSourceUseCase.addAndSyncXtream(
                        name = current.name.ifBlank { "Mon IPTV" },
                        server = current.serverOrUrl,
                        username = current.username,
                        password = current.password,
                    )
                } else {
                    syncSourceUseCase.addAndSyncM3u(
                        name = current.name.ifBlank { "Playlist M3U" },
                        url = current.serverOrUrl,
                    )
                }
            }.onSuccess {
                qrPairingServer.stop()
                val profiles = profilesRepository.refreshProfiles()
                _uiState.update {
                    it.copy(
                        isSyncing = false,
                        step = 2,
                        profiles = profiles,
                    )
                }
            }.onFailure { err ->
                _uiState.update {
                    it.copy(
                        isSyncing = false,
                        errorMessage = err.message ?: "Échec de la synchronisation de la source.",
                    )
                }
            }
        }
    }

    fun selectProfileAndAdvance(profileId: Long) {
        viewModelScope.launch {
            profilesRepository.selectProfile(profileId)
            _uiState.update { it.copy(selectedProfileId = profileId, step = 3) }
        }
    }

    fun finishOnboarding(onCompleted: () -> Unit) {
        viewModelScope.launch {
            settingsRepository.setOnboardingCompleted(true)
            onCompleted()
        }
    }

    private fun startTvQrPairing() {
        val url = qrPairingServer.startPairingEndpoint(viewModelScope) { payload ->
            _uiState.update { it.copy(isSyncing = true, errorMessage = null) }
            runCatching {
                when (payload) {
                    is PairedSourcePayload.M3u -> syncSourceUseCase.addAndSyncM3u(payload.name, payload.url)
                    is PairedSourcePayload.Xtream -> syncSourceUseCase.addAndSyncXtream(
                        name = payload.name,
                        server = payload.server,
                        username = payload.username,
                        password = payload.password,
                    )
                    is PairedSourcePayload.ShareJson -> Unit
                }
            }.onSuccess {
                val profiles = profilesRepository.refreshProfiles()
                _uiState.update { it.copy(isSyncing = false, step = 2, profiles = profiles) }
            }.onFailure { err ->
                _uiState.update { it.copy(isSyncing = false, errorMessage = err.message) }
            }
        }
        if (url != null) {
            val matrix = qrPairingServer.encodeQrMatrix(url, sizePx = 220)
            _uiState.update { it.copy(pairingUrl = url, qrMatrix = matrix) }
        }
    }

    override fun onCleared() {
        qrPairingServer.stop()
        super.onCleared()
    }
}

