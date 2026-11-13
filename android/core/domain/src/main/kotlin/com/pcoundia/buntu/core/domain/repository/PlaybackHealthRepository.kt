package com.pcoundia.buntu.core.domain.repository

import kotlinx.coroutines.flow.StateFlow

/** Persists live playback observations and updates already displayed channel rows. */
interface PlaybackHealthRepository {
    val brokenChannels: StateFlow<Map<String, Boolean>>
    suspend fun setLiveBroken(stableHash: String, broken: Boolean)
}
