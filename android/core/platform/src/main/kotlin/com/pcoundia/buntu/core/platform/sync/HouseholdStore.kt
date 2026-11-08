package com.pcoundia.buntu.core.platform.sync

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import com.pcoundia.buntu.core.domain.repository.DomainHouseholdCredentials
import com.pcoundia.buntu.core.domain.repository.HouseholdSyncRepository
import com.pcoundia.buntu.core.domain.repository.SecretStore
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.security.SecureRandom
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Manages household credentials, persistent device identity, and monotonic sequence barriers (PRD-41 § 5 & § 6).
 * Secrets are securely stored in the hardware-backed Android KeyStore via [SecretStore].
 */
@Singleton
class HouseholdStore @Inject constructor(
    @ApplicationContext private val context: Context,
    private val secretStore: SecretStore,
    private val syncRepo: HouseholdSyncRepository,
) {
    companion object {
        private const val PREFS_NAME = "buntu_sync_prefs"
        private const val PREF_DEVICE_ID = "sync_device_id"
        private const val PREF_SEQUENCE = "sync_sequence"
        private const val SECRET_KEY_ALIAS = "household_key_v1"
    }

    private val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    private val mutex = Mutex()
    private val lastSeenSequenceByDevice = ConcurrentHashMap<String, ULong>()

    val deviceId: String
    val deviceName: String
    val deviceType: String

    private val _isJoined = MutableStateFlow(false)
    val isJoined: StateFlow<Boolean> = _isJoined.asStateFlow()

    private val _householdId = MutableStateFlow<String?>(null)
    val householdId: StateFlow<String?> = _householdId.asStateFlow()

    private var currentSequence: ULong

    init {
        val existingId = prefs.getString(PREF_DEVICE_ID, null)
        deviceId = if (!existingId.isNullOrEmpty()) {
            existingId
        } else {
            val newId = "android_" + UUID.randomUUID().toString().lowercase().replace("-", "")
            prefs.edit().putString(PREF_DEVICE_ID, newId).apply()
            newId
        }

        deviceName = Build.MODEL ?: "Android Device"

        val isTv = context.packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK)
        deviceType = if (isTv) "tv" else "mobile"

        val savedSeq = prefs.getLong(PREF_SEQUENCE, 0L)
        currentSequence = if (savedSeq > 0) savedSeq.toULong() else System.currentTimeMillis().toULong()
    }

    suspend fun loadFromStore(): Boolean = mutex.withLock {
        val keyHex = secretStore.getSecret(SECRET_KEY_ALIAS)
        if (keyHex != null && keyHex.length == 64) {
            try {
                val derived = syncRepo.deriveHouseholdId(keyHex)
                _householdId.value = derived
                _isJoined.value = true
                return@withLock true
            } catch (_: Exception) {
                _householdId.value = null
                _isJoined.value = false
            }
        } else {
            _householdId.value = null
            _isJoined.value = false
        }
        false
    }

    suspend fun createHousehold(): DomainHouseholdCredentials = mutex.withLock {
        val entropy = ByteArray(32)
        SecureRandom().nextBytes(entropy)

        val creds = syncRepo.createHousehold(entropy)
        secretStore.putSecret(SECRET_KEY_ALIAS, creds.householdKeyHex)

        _householdId.value = creds.householdId
        _isJoined.value = true
        lastSeenSequenceByDevice.clear()
        creds
    }

    suspend fun joinHousehold(keyHex: String): String = mutex.withLock {
        val trimmed = keyHex.trim().lowercase()
        require(trimmed.length == 64) { "Clé de foyer invalide (64 caractères attendus)" }

        val derivedId = syncRepo.deriveHouseholdId(trimmed)
        secretStore.putSecret(SECRET_KEY_ALIAS, trimmed)

        _householdId.value = derivedId
        _isJoined.value = true
        lastSeenSequenceByDevice.clear()
        derivedId
    }

    suspend fun leaveHousehold() = mutex.withLock {
        secretStore.deleteSecret(SECRET_KEY_ALIAS)
        _householdId.value = null
        _isJoined.value = false
        lastSeenSequenceByDevice.clear()
    }

    suspend fun currentHouseholdKeyHex(): String? = mutex.withLock {
        if (!_isJoined.value) return@withLock null
        secretStore.getSecret(SECRET_KEY_ALIAS)
    }

    suspend fun nextSequence(): ULong = mutex.withLock {
        currentSequence++
        prefs.edit().putLong(PREF_SEQUENCE, currentSequence.toLong()).apply()
        currentSequence
    }

    fun verifyAndAdvanceSequence(senderDeviceId: String, sequence: ULong): Boolean {
        val lastSeen = lastSeenSequenceByDevice[senderDeviceId] ?: 0uL
        if (sequence <= lastSeen) {
            return false // Replay
        }
        lastSeenSequenceByDevice[senderDeviceId] = sequence
        return true
    }

    fun lastSeenSequence(senderDeviceId: String): ULong {
        return lastSeenSequenceByDevice[senderDeviceId] ?: 0uL
    }
}
