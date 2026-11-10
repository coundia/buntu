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

    /**
     * `source_key` of the account an item belongs to (PRD-41 identity, computed in Rust): the key of the
     * "one stream per account" rule (`release_stream`). `null` when the item or its source is unknown.
     */
    suspend fun sourceKeyForItem(itemId: Long): String?

    /** Content key, account key, kind and resume position of a playable item; `null` for a series or unknown id. */
    suspend fun remoteItem(itemId: Long): com.pcoundia.buntu.core.domain.model.RemoteItemDescriptor?

    suspend fun importHouseholdDelta(deltaJson: String): Boolean
    suspend fun exportHouseholdDelta(sinceTs: Long): String
}

