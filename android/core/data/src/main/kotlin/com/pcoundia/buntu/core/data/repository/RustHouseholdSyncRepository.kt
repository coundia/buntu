package com.pcoundia.buntu.core.data.repository

import com.pcoundia.buntu.core.domain.repository.DomainHouseholdCredentials
import com.pcoundia.buntu.core.domain.repository.DomainHouseholdSealedEnvelope
import com.pcoundia.buntu.core.domain.repository.HouseholdSyncRepository
import com.pcoundia.buntu.core.engine.ffi.HouseholdSealedEnvelope
import com.pcoundia.buntu.core.engine.ffi.syncComputeContentKey
import com.pcoundia.buntu.core.engine.ffi.syncComputeSourceKey
import com.pcoundia.buntu.core.engine.ffi.syncCreateHousehold
import com.pcoundia.buntu.core.engine.ffi.syncDeriveHouseholdId
import com.pcoundia.buntu.core.engine.ffi.syncOpenEnvelope
import com.pcoundia.buntu.core.engine.ffi.syncSealEnvelope
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class RustHouseholdSyncRepository @Inject constructor() : HouseholdSyncRepository {

    override fun createHousehold(entropy: ByteArray): DomainHouseholdCredentials {
        val creds = syncCreateHousehold(entropy)
        return DomainHouseholdCredentials(
            householdId = creds.householdId,
            householdKeyHex = creds.householdKeyHex,
        )
    }

    override fun deriveHouseholdId(householdKeyHex: String): String {
        return syncDeriveHouseholdId(householdKeyHex)
    }

    override fun sealEnvelope(
        householdKeyHex: String,
        senderDeviceId: String,
        sequence: ULong,
        nonceBytes: ByteArray,
        messageJson: String,
    ): DomainHouseholdSealedEnvelope {
        val env = syncSealEnvelope(
            householdKeyHex = householdKeyHex,
            senderDeviceId = senderDeviceId,
            sequence = sequence,
            nonceBytes = nonceBytes,
            messageJson = messageJson,
        )
        return DomainHouseholdSealedEnvelope(
            householdId = env.householdId,
            senderDeviceId = env.senderDeviceId,
            sequence = env.sequence,
            nonceHex = env.nonceHex,
            ciphertextHex = env.ciphertextHex,
        )
    }

    override fun openEnvelope(
        householdKeyHex: String,
        envelope: DomainHouseholdSealedEnvelope,
        lastSeenSequence: ULong,
    ): String {
        val ffiEnv = HouseholdSealedEnvelope(
            householdId = envelope.householdId,
            senderDeviceId = envelope.senderDeviceId,
            sequence = envelope.sequence,
            nonceHex = envelope.nonceHex,
            ciphertextHex = envelope.ciphertextHex,
        )
        return syncOpenEnvelope(
            householdKeyHex = householdKeyHex,
            envelope = ffiEnv,
            lastSeenSequence = lastSeenSequence,
        )
    }

    override fun computeSourceKey(sourceType: String, serverOrUrl: String, username: String?): String {
        return syncComputeSourceKey(sourceType, serverOrUrl, username)
    }

    override fun computeContentKey(sourceKey: String, itemKind: String, providerId: String): String {
        return syncComputeContentKey(sourceKey, itemKind, providerId)
    }
}

