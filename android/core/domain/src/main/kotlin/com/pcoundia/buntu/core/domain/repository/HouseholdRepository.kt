package com.pcoundia.buntu.core.domain.repository

import com.pcoundia.buntu.core.domain.model.DiscoveredPeer
import com.pcoundia.buntu.core.domain.model.SyncLogEntry
import kotlinx.coroutines.flow.StateFlow

/**
 * Household device management, synchronization status, and pairing lifecycle (PRD-41, PRD-43, PRD-44).
 */
interface HouseholdRepository {
    val isJoined: StateFlow<Boolean>
    val householdId: StateFlow<String?>
    val deviceId: String
    val deviceName: String
    val deviceType: String
    val syncStatus: StateFlow<String>
    val activePeers: StateFlow<List<DiscoveredPeer>>
    val syncLog: StateFlow<List<SyncLogEntry>>

    suspend fun createHousehold(): DomainHouseholdCredentials
    suspend fun joinHousehold(keyHex: String): String
    suspend fun leaveHousehold()
    suspend fun syncNow()
    suspend fun currentHouseholdKeyHex(): String?
    fun startSyncService()
    fun stopSyncService()
}

