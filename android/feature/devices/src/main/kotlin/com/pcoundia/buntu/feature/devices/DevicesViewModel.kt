package com.pcoundia.buntu.feature.devices

import android.content.Context
import com.pcoundia.buntu.core.domain.repository.TvDataSender
import com.pcoundia.buntu.core.domain.repository.TvDataSendResult
import kotlinx.coroutines.CancellationException
import com.pcoundia.buntu.core.domain.repository.HouseholdInviteCodec
import com.pcoundia.buntu.core.platform.device.DeviceCapabilities
import com.pcoundia.buntu.core.platform.phone.PhoneQrScanResult
import com.pcoundia.buntu.core.platform.phone.PhoneQrScanner
import com.pcoundia.buntu.core.platform.tv.QrCodeEncoder
import com.pcoundia.buntu.core.platform.tv.QrMatrix
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.pcoundia.buntu.core.domain.model.DiscoveredPeer
import com.pcoundia.buntu.core.domain.model.SyncLogEntry
import com.pcoundia.buntu.core.domain.repository.HouseholdRepository
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import javax.inject.Inject

data class DevicesUiState(
    val isJoined: Boolean = false,
    val householdId: String? = null,
    val deviceId: String = "",
    val deviceName: String = "",
    val deviceType: String = "mobile",
    val syncStatus: String = "Prêt",
    val peers: List<DiscoveredPeer> = emptyList(),
    val syncLog: List<SyncLogEntry> = emptyList(),
    val errorMessage: String? = null,
    val infoMessage: String? = null,
    /** Android TV has no camera: it shows the household QR code, the phone scans it. */
    val isTv: Boolean = false,
    /** QR code to add a device (`buntu://household?key=…`); `null` when hidden. Holds the key: never logged. */
    val inviteQr: QrMatrix? = null,
    val isScanning: Boolean = false,
)

@HiltViewModel
class DevicesViewModel @Inject constructor(
    private val householdRepo: HouseholdRepository,
    private val inviteCodec: HouseholdInviteCodec,
    private val qrScanner: PhoneQrScanner,
    private val tvDataSender: TvDataSender,
    deviceCapabilities: DeviceCapabilities,
) : ViewModel() {

    private val isTv = deviceCapabilities.isTelevision
    private val _errorMessage = MutableStateFlow<String?>(null)
    private val _infoMessage = MutableStateFlow<String?>(null)
    private val _inviteQr = MutableStateFlow<QrMatrix?>(null)
    private val _isScanning = MutableStateFlow(false)

    private data class HouseholdSnapshot(
        val isJoined: Boolean,
        val householdId: String?,
        val status: String,
        val peers: List<DiscoveredPeer>,
        val log: List<SyncLogEntry>,
    )

    private val householdState = combine(
        householdRepo.isJoined,
        householdRepo.householdId,
        householdRepo.syncStatus,
        householdRepo.activePeers,
        householdRepo.syncLog,
    ) { isJoined, hId, status, peers, log ->
        HouseholdSnapshot(isJoined, hId, status, peers, log)
    }

    val uiState: StateFlow<DevicesUiState> = combine(
        householdState,
        _errorMessage,
        _infoMessage,
        _inviteQr,
        _isScanning,
    ) { snap, error, info, inviteQr, scanning ->
        DevicesUiState(
            isJoined = snap.isJoined,
            householdId = snap.householdId,
            deviceId = householdRepo.deviceId,
            deviceName = householdRepo.deviceName,
            deviceType = householdRepo.deviceType,
            syncStatus = snap.status,
            peers = snap.peers,
            syncLog = snap.log,
            errorMessage = error,
            infoMessage = info,
            isTv = isTv,
            inviteQr = inviteQr,
            isScanning = scanning,
        )
    }.stateIn(
        scope = viewModelScope,
        started = SharingStarted.WhileSubscribed(5000),
        initialValue = DevicesUiState(
            deviceId = householdRepo.deviceId,
            deviceName = householdRepo.deviceName,
            deviceType = householdRepo.deviceType,
            isTv = isTv,
        ),
    )

    fun createHousehold() {
        viewModelScope.launch {
            try {
                _errorMessage.value = null
                householdRepo.createHousehold()
                _infoMessage.value = "Foyer créé avec succès !"
            } catch (e: Exception) {
                _errorMessage.value = "Échec création du foyer: ${e.message}"
            }
        }
    }

    /** "Rejoindre avec la clé…": the 64-character key, or the `buntu://household?key=…` link, pasted. */
    fun joinHousehold(keyOrLink: String) {
        viewModelScope.launch { joinWith(keyOrLink, fromScan = false) }
    }

    /** "Scanner un QR code": the code shown by another device of the household (Appareils, "Afficher le QR code"). */
    fun scanToJoin(activityContext: Context) {
        if (_isScanning.value) return
        _isScanning.value = true
        _errorMessage.value = null
        viewModelScope.launch {
            try {
                when (val result = qrScanner.scanQrCode(activityContext)) {
                    is PhoneQrScanResult.Scanned -> joinWith(result.rawValue, fromScan = true)
                    PhoneQrScanResult.Cancelled -> Unit
                    is PhoneQrScanResult.Unavailable -> _errorMessage.value =
                        "Scanner indisponible sur cet appareil (${result.message}). Utilisez « Rejoindre avec la clé… »."
                }
            } finally {
                _isScanning.value = false
            }
        }
    }

    /** Scans the TV's ephemeral QR, joins it to the phone household, then sends data. */
    fun scanAndSend(activityContext: Context) {
        if (_isScanning.value) return
        _isScanning.value = true
        _errorMessage.value = null
        _infoMessage.value = null
        viewModelScope.launch {
            try {
                when (val result = qrScanner.scanQrCode(activityContext)) {
                    is PhoneQrScanResult.Scanned -> sendScannedTv(result.rawValue)
                    PhoneQrScanResult.Cancelled -> Unit
                    is PhoneQrScanResult.Unavailable -> _errorMessage.value = "Scanner indisponible. Vérifiez les services Google et réessayez."
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                _errorMessage.value = "Impossible de scanner ou d’envoyer les données. Réessayez."
            } finally {
                _isScanning.value = false
            }
        }
    }

    internal suspend fun sendScannedTv(link: String) {
        _infoMessage.value = "En attente de confirmation sur la TV…"
        _errorMessage.value = null
        when (val result = tvDataSender.send(link)) {
            is TvDataSendResult.Sent -> _infoMessage.value = "Données envoyées à ${result.tvName}."
            TvDataSendResult.Refused -> {
                _infoMessage.value = null
                _errorMessage.value = "Ajout refusé sur la TV. Aucune donnée envoyée."
            }
            is TvDataSendResult.Failed -> {
                _infoMessage.value = null
                _errorMessage.value = result.message
            }
        }
    }

    private suspend fun joinWith(text: String, fromScan: Boolean) {
        try {
            _errorMessage.value = null
            // The format of the code is decided in Rust (`cnd_domain::sync::invite`).
            val key = inviteCodec.keyFromScanned(text)
            if (key == null) {
                _errorMessage.value = if (fromScan) {
                    "Ce QR code n'est pas celui d'un foyer Buntu. Sur l'autre appareil : Appareils, puis « Afficher le QR code »."
                } else {
                    "Clé invalide : collez les 64 caractères affichés sur l'autre appareil."
                }
                return
            }
            householdRepo.joinHousehold(key)
            _infoMessage.value = "Foyer rejoint avec succès !"
        } catch (e: Exception) {
            _errorMessage.value = "Échec pour rejoindre le foyer: ${e.message}"
        }
    }

    /** "Afficher le QR code": shown only on request, never stored. */
    fun showInviteQr() {
        viewModelScope.launch {
            _errorMessage.value = null
            val key = householdRepo.currentHouseholdKeyHex()
            val link = key?.let { inviteCodec.inviteLink(it) }
            if (link == null) {
                _errorMessage.value = "Impossible de créer le QR code : aucun foyer sur cet appareil."
                return@launch
            }
            _inviteQr.value = withContext(Dispatchers.Default) { QrCodeEncoder.encode(link) }
        }
    }

    fun hideInviteQr() {
        _inviteQr.value = null
    }

    fun leaveHousehold() {
        viewModelScope.launch {
            try {
                householdRepo.leaveHousehold()
                _infoMessage.value = "Vous avez quitté le foyer."
            } catch (e: Exception) {
                _errorMessage.value = "Erreur: ${e.message}"
            }
        }
    }

    /** "Envoyer mes données": additive, never deletes an account on the other devices. */
    fun sendNow() {
        viewModelScope.launch {
            try {
                _errorMessage.value = null
                householdRepo.sendNow()
            } catch (e: Exception) {
                _errorMessage.value = "Erreur d'envoi: ${e.message}"
            }
        }
    }

    /** "Recevoir les données": asks the other devices; their accounts are added, never duplicated. */
    fun receiveNow() {
        viewModelScope.launch {
            try {
                _errorMessage.value = null
                householdRepo.receiveNow()
            } catch (e: Exception) {
                _errorMessage.value = "Erreur de réception: ${e.message}"
            }
        }
    }

    suspend fun getHouseholdKeyHex(): String? {
        return householdRepo.currentHouseholdKeyHex()
    }

    fun clearMessages() {
        _errorMessage.value = null
        _infoMessage.value = null
    }
}
