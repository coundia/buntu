package com.pcoundia.buntu.core.domain.repository

/**
 * Bridge interface allowing the platform sync layer to query local media resolution
 * and import/export sync deltas without depending on `:core:engine`.
 * Implemented in `:core:data` via [CndEngine].
 */
interface HouseholdSyncEngineBridge {
    suspend fun resolveItemByContentKey(
        contentKey: String,
        sourceKey: String?,
        providerRef: String?,
        itemKind: String?,
    ): Long?

    suspend fun importHouseholdDelta(deltaJson: String): Boolean
    suspend fun exportHouseholdDelta(sinceTs: Long): String
}

