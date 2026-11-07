package com.pcoundia.buntu.feature.sources

import android.content.Context
import android.os.Build
import androidx.compose.runtime.Immutable
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.pcoundia.buntu.core.domain.model.SourceKind
import com.pcoundia.buntu.core.domain.model.SourceSummary
import com.pcoundia.buntu.core.domain.repository.PairingLink
import com.pcoundia.buntu.core.domain.repository.PairingRepository
import com.pcoundia.buntu.core.domain.repository.SourcesRepository
import com.pcoundia.buntu.core.domain.usecase.SyncSourceUseCase
import com.pcoundia.buntu.core.platform.device.DeviceCapabilities
import com.pcoundia.buntu.core.platform.phone.PairingFailure
import com.pcoundia.buntu.core.platform.phone.PairingSendResult
import com.pcoundia.buntu.core.platform.phone.PairingSender
import com.pcoundia.buntu.core.platform.phone.PhoneQrScanResult
import com.pcoundia.buntu.core.platform.phone.PhoneQrScanner
import com.pcoundia.buntu.core.platform.phone.userMessage
import com.pcoundia.buntu.core.platform.tv.IncomingPairingUi
import com.pcoundia.buntu.core.platform.tv.QrMatrix
import com.pcoundia.buntu.core.platform.tv.TvPairingCoordinator
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.ImmutableSet
import kotlinx.collections.immutable.persistentListOf
import kotlinx.collections.immutable.toImmutableSet
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject

@Immutable
sealed interface PairToTvUiState {
    data object Closed : PairToTvUiState

    data class Scanning(
        val manualLink: String = "",
        val error: String? = null,
        val isScannerRunning: Boolean = false,
    ) : PairToTvUiState

    data class Choosing(
        val link: PairingLink,
        val rawLink: String,
        val selectedIds: ImmutableSet<Long>,
        val includeCredentialsIds: ImmutableSet<Long>,
        val autoInitializedSelection: Boolean,
        val error: String? = null,
    ) : PairToTvUiState

    data class WaitingForTv(val tvName: String) : PairToTvUiState

    data class Done(val tvName: String, val addedCount: Int) : PairToTvUiState

    data class Refused(val tvName: String) : PairToTvUiState

    data class Failed(val tvName: String, val message: String) : PairToTvUiState
}

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
    val incomingPairing: IncomingPairingUi? = null,
    val pairToTv: PairToTvUiState = PairToTvUiState.Closed,
)

@HiltViewModel
class SourcesViewModel @Inject constructor(
    savedStateHandle: SavedStateHandle,
    private val sourcesRepository: SourcesRepository,
    private val syncSourceUseCase: SyncSourceUseCase,
    private val pairingRepository: PairingRepository,
    private val pairingSender: PairingSender,
    private val phoneQrScanner: PhoneQrScanner,
    private val pairing: TvPairingCoordinator,
    deviceCapabilities: DeviceCapabilities,
) : ViewModel() {

    private val _uiState = MutableStateFlow(SourcesUiState(isTv = deviceCapabilities.isTelevision))
    val uiState: StateFlow<SourcesUiState> = _uiState.asStateFlow()
    private var sendJob: Job? = null

    init {
        viewModelScope.launch {
            sourcesRepository.sourcesFlow.collect { list ->
                _uiState.update { current ->
                    val updatedPair = when (val pair = current.pairToTv) {
                        is PairToTvUiState.Choosing -> {
                            if (!pair.autoInitializedSelection && list.isNotEmpty()) {
                                pair.copy(
                                    selectedIds = list.map { it.id }.toImmutableSet(),
                                    includeCredentialsIds = list
                                        .filter { it.kind == SourceKind.XTREAM }
                                        .map { it.id }
                                        .toImmutableSet(),
                                    autoInitializedSelection = true,
                                )
                            } else {
                                pair
                            }
                        }
                        else -> pair
                    }
                    current.copy(sources = list, pairToTv = updatedPair)
                }
            }
        }
        viewModelScope.launch {
            sourcesRepository.refreshSourcesList()
        }
        if (deviceCapabilities.isTelevision) {
            viewModelScope.launch {
                pairing.state.collect { p ->
                    _uiState.update {
                        it.copy(
                            pairingUrl = p.session?.link,
                            qrMatrix = p.session?.qr,
                            incomingPairing = p.incoming,
                            isSyncing = if (p.incoming != null || p.isSyncing) p.isSyncing else it.isSyncing,
                            errorMessage = p.error ?: it.errorMessage,
                        )
                    }
                }
            }
        } else {
            val deepLink = savedStateHandle.get<String>("pairLink")
            if (!deepLink.isNullOrBlank()) {
                savedStateHandle["pairLink"] = null
                acceptScannedPairLink(deepLink)
            }
        }
    }

    fun toggleAddForm(show: Boolean) {
        _uiState.update { it.copy(showAddForm = show, errorMessage = null) }
        if (show && _uiState.value.isTv) {
            pairing.start(viewModelScope) {
                _uiState.update { it.copy(showAddForm = false, statusMessage = "Source reçue depuis le téléphone !") }
            }
        } else {
            pairing.stop()
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
                pairing.stop()
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

    fun confirmIncomingPairing() = pairing.confirm()

    fun refuseIncomingPairing() = pairing.refuse()

    // -------------------------------------------------------------------------
    // Phone -> TV QR Pairing (PRD-39 § 2.2, § 5.5)
    // -------------------------------------------------------------------------

    fun openPairToTv() {
        sendJob?.cancel()
        _uiState.update { it.copy(pairToTv = PairToTvUiState.Scanning()) }
    }

    fun closePairToTv() {
        sendJob?.cancel()
        _uiState.update { it.copy(pairToTv = PairToTvUiState.Closed) }
    }

    fun closePairAndOpenAddSource() {
        sendJob?.cancel()
        _uiState.update {
            it.copy(
                pairToTv = PairToTvUiState.Closed,
                showAddForm = true,
            )
        }
    }

    fun updateManualPairLink(value: String) {
        _uiState.update { current ->
            val scan = current.pairToTv as? PairToTvUiState.Scanning ?: return@update current
            current.copy(pairToTv = scan.copy(manualLink = value, error = null))
        }
    }

    fun submitManualPairLink() {
        val scan = _uiState.value.pairToTv as? PairToTvUiState.Scanning ?: return
        acceptScannedPairLink(scan.manualLink)
    }

    fun launchQrScanner(activityContext: Context) {
        val currentScan = _uiState.value.pairToTv as? PairToTvUiState.Scanning
            ?: PairToTvUiState.Scanning()
        if (currentScan.isScannerRunning) return
        _uiState.update { it.copy(pairToTv = currentScan.copy(isScannerRunning = true, error = null)) }
        viewModelScope.launch {
            when (val result = phoneQrScanner.scanQrCode(activityContext)) {
                is PhoneQrScanResult.Scanned -> acceptScannedPairLink(result.rawValue)
                PhoneQrScanResult.Cancelled -> {
                    _uiState.update { state ->
                        val scan = state.pairToTv as? PairToTvUiState.Scanning ?: return@update state
                        state.copy(pairToTv = scan.copy(isScannerRunning = false))
                    }
                }
                is PhoneQrScanResult.Unavailable -> {
                    _uiState.update { state ->
                        val scan = state.pairToTv as? PairToTvUiState.Scanning ?: PairToTvUiState.Scanning()
                        state.copy(pairToTv = scan.copy(isScannerRunning = false, error = result.message))
                    }
                }
            }
        }
    }

    fun acceptScannedPairLink(rawInput: String) {
        val trimmed = rawInput.trim()
        val normalized = if (trimmed.startsWith("http://", ignoreCase = true) && trimmed.contains("/pair#")) {
            "buntu://pair?" + trimmed.substringAfter('#')
        } else {
            trimmed
        }
        val nowSeconds = System.currentTimeMillis() / 1_000L
        val parsed = runCatching { pairingRepository.parseLink(normalized, nowSeconds) }.getOrElse {
            val msg = PairingFailure.InvalidLink.userMessage()
            _uiState.update { current ->
                val next = when (val p = current.pairToTv) {
                    is PairToTvUiState.Scanning -> p.copy(isScannerRunning = false, error = msg)
                    else -> PairToTvUiState.Failed(tvName = "TV", message = msg)
                }
                current.copy(pairToTv = next)
            }
            return
        }

        if (parsed.transport != "http" && parsed.transport != "msf") {
            _uiState.update {
                it.copy(
                    pairToTv = PairToTvUiState.Failed(
                        tvName = parsed.tvName.ifBlank { "TV" },
                        message = PairingFailure.UnsupportedTv.userMessage(),
                    )
                )
            }
            return
        }

        val currentSources = _uiState.value.sources
        _uiState.update {
            it.copy(
                pairToTv = PairToTvUiState.Choosing(
                    link = parsed,
                    rawLink = normalized,
                    selectedIds = currentSources.map { src -> src.id }.toImmutableSet(),
                    includeCredentialsIds = currentSources
                        .filter { src -> src.kind == SourceKind.XTREAM }
                        .map { src -> src.id }
                        .toImmutableSet(),
                    autoInitializedSelection = currentSources.isNotEmpty(),
                )
            )
        }
    }

    fun togglePairSourceSelection(sourceId: Long) {
        _uiState.update { current ->
            val choosing = current.pairToTv as? PairToTvUiState.Choosing ?: return@update current
            val next = if (sourceId in choosing.selectedIds) {
                choosing.selectedIds - sourceId
            } else {
                choosing.selectedIds + sourceId
            }
            current.copy(pairToTv = choosing.copy(selectedIds = next.toImmutableSet(), error = null))
        }
    }

    fun togglePairSourceCredentials(sourceId: Long) {
        _uiState.update { current ->
            val choosing = current.pairToTv as? PairToTvUiState.Choosing ?: return@update current
            val next = if (sourceId in choosing.includeCredentialsIds) {
                choosing.includeCredentialsIds - sourceId
            } else {
                choosing.includeCredentialsIds + sourceId
            }
            current.copy(pairToTv = choosing.copy(includeCredentialsIds = next.toImmutableSet()))
        }
    }

    fun sendPairedSourcesToTv() {
        val choosing = _uiState.value.pairToTv as? PairToTvUiState.Choosing ?: return
        if (choosing.selectedIds.isEmpty()) {
            _uiState.update {
                it.copy(pairToTv = choosing.copy(error = "Sélectionnez au moins un compte à envoyer."))
            }
            return
        }
        val tvName = choosing.link.tvName.ifBlank { "votre TV" }
        val phoneName = resolvePhoneDisplayName()
        sendJob?.cancel()
        sendJob = viewModelScope.launch {
            _uiState.update { it.copy(pairToTv = PairToTvUiState.WaitingForTv(tvName = tvName)) }
            val shareJson = runCatching {
                sourcesRepository.exportShareJson(
                    sourceIds = choosing.selectedIds,
                    includeCredentials = choosing.includeCredentialsIds,
                    senderName = phoneName,
                )
            }.getOrElse { err ->
                _uiState.update {
                    it.copy(
                        pairToTv = PairToTvUiState.Failed(
                            tvName = tvName,
                            message = err.localizedMessage ?: "Impossible de préparer les comptes à partager.",
                        )
                    )
                }
                return@launch
            }

            when (val outcome = pairingSender.send(choosing.rawLink, shareJson, phoneName)) {
                is PairingSendResult.Added -> {
                    _uiState.update {
                        it.copy(
                            pairToTv = PairToTvUiState.Done(tvName = tvName, addedCount = outcome.count),
                            statusMessage = "${outcome.count} compte(s) envoyé(s) sur $tvName.",
                        )
                    }
                }
                PairingSendResult.Refused -> {
                    _uiState.update {
                        it.copy(pairToTv = PairToTvUiState.Refused(tvName = tvName))
                    }
                }
                is PairingSendResult.Failed -> {
                    _uiState.update {
                        it.copy(
                            pairToTv = PairToTvUiState.Failed(
                                tvName = tvName,
                                message = outcome.reason.userMessage(),
                            )
                        )
                    }
                }
            }
        }
    }

    private fun resolvePhoneDisplayName(): String {
        val model = Build.MODEL?.trim().orEmpty()
        val manufacturer = Build.MANUFACTURER?.trim().orEmpty()
        return when {
            model.isEmpty() -> "Téléphone Android"
            manufacturer.isEmpty() || model.startsWith(manufacturer, ignoreCase = true) -> model
            else -> "${manufacturer.replaceFirstChar { it.uppercase() }} $model"
        }
    }

    override fun onCleared() {
        sendJob?.cancel()
        pairing.stop()
        super.onCleared()
    }
}
