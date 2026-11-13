package com.pcoundia.buntu.core.data.repository

import com.pcoundia.buntu.core.domain.repository.PlaybackHealthRepository
import com.pcoundia.buntu.core.engine.EngineProvider
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class RustPlaybackHealthRepository @Inject constructor(private val engineProvider: EngineProvider) : PlaybackHealthRepository {
    private val statuses = MutableStateFlow<Map<String, Boolean>>(emptyMap())
    override val brokenChannels = statuses.asStateFlow()
    private val writes = Mutex()
    override suspend fun setLiveBroken(stableHash: String, broken: Boolean) = withContext(Dispatchers.IO) {
        writes.withLock {
            engineProvider.awaitEngine().setBroken(stableHash, "live", broken)
            statuses.value = statuses.value + (stableHash to broken)
        }
    }
}
