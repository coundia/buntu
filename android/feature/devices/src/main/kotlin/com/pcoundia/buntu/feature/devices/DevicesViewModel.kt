package com.pcoundia.buntu.feature.devices

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
)

@HiltViewModel
class DevicesViewModel @Inject constructor(
    private val householdRepo: HouseholdRepository,
) : ViewModel() {

    private val _errorMessage = MutableStateFlow<String?>(null)
    private val _infoMessage = MutableStateFlow<String?>(null)

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
    ) { snap, error, info ->
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
        )
    }.stateIn(
        scope = viewModelScope,
        started = SharingStarted.WhileSubscribed(5000),
        initialValue = DevicesUiState(
            deviceId = householdRepo.deviceId,
            deviceName = householdRepo.deviceName,
            deviceType = householdRepo.deviceType,
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

    fun joinHousehold(keyHex: String) {
        viewModelScope.launch {
            try {
                _errorMessage.value = null
                val trimmed = keyHex.trim().lowercase()
                if (trimmed.length != 64) {
                    _errorMessage.value = "Clé invalide (64 caractères attendus)"
                    return@launch
                }
                householdRepo.joinHousehold(trimmed)
                _infoMessage.value = "Foyer rejoint avec succès !"
            } catch (e: Exception) {
                _errorMessage.value = "Échec pour rejoindre le foyer: ${e.message}"
            }
        }
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

    fun syncNow() {
        viewModelScope.launch {
            try {
                _errorMessage.value = null
                householdRepo.syncNow()
            } catch (e: Exception) {
                _errorMessage.value = "Erreur de synchronisation: ${e.message}"
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
