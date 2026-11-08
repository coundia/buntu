package com.pcoundia.buntu.core.domain.repository

data class DomainHouseholdCredentials(
    val householdId: String,
    val householdKeyHex: String,
)

data class DomainHouseholdSealedEnvelope(
    val householdId: String,
    val senderDeviceId: String,
    val sequence: ULong,
    val nonceHex: String,
    val ciphertextHex: String,
)

/**
 * PRD-41 § 5 & § 6: Serverless household synchronization and encryption primitives.
 * Implemented once in Rust (`cnd-domain::sync`) and exposed via [HouseholdSyncRepository].
 */
interface HouseholdSyncRepository {
    fun createHousehold(entropy: ByteArray): DomainHouseholdCredentials
    fun deriveHouseholdId(householdKeyHex: String): String
    fun sealEnvelope(
        householdKeyHex: String,
        senderDeviceId: String,
        sequence: ULong,
        nonceBytes: ByteArray,
        messageJson: String,
    ): DomainHouseholdSealedEnvelope
    fun openEnvelope(
        householdKeyHex: String,
        envelope: DomainHouseholdSealedEnvelope,
        lastSeenSequence: ULong,
    ): String
    fun computeSourceKey(sourceType: String, serverOrUrl: String, username: String?): String
    fun computeContentKey(sourceKey: String, itemKind: String, providerId: String): String
}

