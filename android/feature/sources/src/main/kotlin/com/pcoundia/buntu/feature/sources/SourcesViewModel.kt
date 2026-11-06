package com.pcoundia.buntu.feature.sources

import androidx.compose.runtime.Immutable
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.pcoundia.buntu.core.domain.model.SourceKind
import com.pcoundia.buntu.core.domain.model.SourceSummary
import com.pcoundia.buntu.core.domain.repository.SourcesRepository
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
data class SourcesUiState(
    val sources: ImmutableList<SourceSummary> = persistentListOf(),
    val isTv: Boolean = false,
    val isSyncing: Boolean = false,
    val statusMessage: String? = null,
    val errorMessage: String? = null,
    val showAddForm: Boolean = false,
    val newKind: SourceKind = SourceKind.XTREAM,
    val newName: String = "",
    val newServerOrUrl: String = "",
    val newUsername: String = "",
    val newPassword: String = "",
    val pairingUrl: String? = null,
    val qrMatrix: QrMatrix? = null,
)

@HiltViewModel
class SourcesViewModel @Inject constructor(
    private val sourcesRepository: SourcesRepository,
    private val syncSourceUseCase: SyncSourceUseCase,
    private val qrPairingServer: QrPairingServer,
    deviceCapabilities: DeviceCapabilities,
) : ViewModel() {

    private val _uiState = MutableStateFlow(SourcesUiState(isTv = deviceCapabilities.isTelevision))
    val uiState: StateFlow<SourcesUiState> = _uiState.asStateFlow()

    init {
        viewModelScope.launch {
            sourcesRepository.sourcesFlow.collect { list ->
                _uiState.update { it.copy(sources = list) }
            }
        }
        viewModelScope.launch {
            sourcesRepository.refreshSourcesList()
        }
    }

    fun toggleAddForm(show: Boolean) {
        _uiState.update { it.copy(showAddForm = show, errorMessage = null) }
        if (show && _uiState.value.isTv) {
            startQrPairing()
        } else {
            qrPairingServer.stop()
        }
    }

    fun updateNewSourceForm(
        kind: SourceKind = _uiState.value.newKind,
        name: String = _uiState.value.newName,
        serverOrUrl: String = _uiState.value.newServerOrUrl,
        username: String = _uiState.value.newUsername,
        password: String = _uiState.value.newPassword,
    ) {
        _uiState.update {
            it.copy(
                newKind = kind,
                newName = name,
                newServerOrUrl = serverOrUrl,
                newUsername = username,
                newPassword = password,
                errorMessage = null,
            )
        }
    }

    fun addSource() {
        val current = _uiState.value
        if (current.newServerOrUrl.isBlank()) {
            _uiState.update { it.copy(errorMessage = "Adresse serveur ou URL requise.") }
            return
        }
        viewModelScope.launch {
            _uiState.update { it.copy(isSyncing = true, errorMessage = null) }
            runCatching {
                if (current.newKind == SourceKind.XTREAM) {
                    syncSourceUseCase.addAndSyncXtream(
                        name = current.newName.ifBlank { "Xtream IPTV" },
                        server = current.newServerOrUrl,
                        username = current.newUsername,
                        password = current.newPassword,
                    )
                } else {
                    syncSourceUseCase.addAndSyncM3u(
                        name = current.newName.ifBlank { "Playlist M3U" },
                        url = current.newServerOrUrl,
                    )
                }
            }.onSuccess { (_, report) ->
                qrPairingServer.stop()
                _uiState.update {
                    it.copy(
                        isSyncing = false,
                        showAddForm = false,
                        newName = "",
                        newServerOrUrl = "",
                        newUsername = "",
                        newPassword = "",
                        statusMessage = "${report.totalItems} contenus synchronisés en ${report.durationMs} ms.",
                    )
                }
            }.onFailure { err ->
                _uiState.update {
                    it.copy(isSyncing = false, errorMessage = err.message ?: "Erreur lors de l'ajout.")
                }
            }
        }
    }

    fun refreshSource(source: SourceSummary) {
        viewModelScope.launch {
            _uiState.update { it.copy(isSyncing = true, errorMessage = null, statusMessage = null) }
            runCatching {
                val report = syncSourceUseCase.refreshExistingSource(source)
                sourcesRepository.syncSourceEpg(source.id, null)
                report
            }.onSuccess { report ->
                _uiState.update {
                    it.copy(
                        isSyncing = false,
                        statusMessage = "« ${source.name} » mis à jour (${report.totalItems} éléments).",
                    )
                }
            }.onFailure { err ->
                _uiState.update {
                    it.copy(isSyncing = false, errorMessage = err.message ?: "Échec de synchronisation.")
                }
            }
        }
    }

    fun deleteSource(sourceId: Long) {
        viewModelScope.launch {
            sourcesRepository.deleteSource(sourceId)
        }
    }

    private fun startQrPairing() {
        val url = qrPairingServer.startPairingEndpoint(viewModelScope) { payload ->
            _uiState.update { it.copy(isSyncing = true) }
            runCatching {
                when (payload) {
                    is PairedSourcePayload.M3u -> syncSourceUseCase.addAndSyncM3u(payload.name, payload.url)
                    is PairedSourcePayload.Xtream -> syncSourceUseCase.addAndSyncXtream(
                        payload.name,
                        payload.server,
                        payload.username,
                        payload.password,
                    )
                    is PairedSourcePayload.ShareJson -> sourcesRepository.importShareJson(payload.json)
                }
            }.onSuccess {
                _uiState.update {
                    it.copy(isSyncing = false, showAddForm = false, statusMessage = "Source reçue depuis le téléphone !")
                }
            }.onFailure { err ->
                _uiState.update { it.copy(isSyncing = false, errorMessage = err.message) }
            }
        }
        if (url != null) {
            _uiState.update {
                it.copy(pairingUrl = url, qrMatrix = qrPairingServer.encodeQrMatrix(url, 200))
            }
        }
    }

    override fun onCleared() {
        qrPairingServer.stop()
        super.onCleared()
    }
}

