package com.pcoundia.buntu.core.data.repository

import com.pcoundia.buntu.core.data.mapper.EngineMappers.toDomain
import com.pcoundia.buntu.core.domain.model.NetworkLogItem
import com.pcoundia.buntu.core.domain.repository.EngineDiagnosticsRepository
import com.pcoundia.buntu.core.engine.EngineProvider
import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.toImmutableList
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class RustDiagnosticsRepository @Inject constructor(
    private val engineProvider: EngineProvider,
) : EngineDiagnosticsRepository {

    override suspend fun engineVersion(): String = withContext(Dispatchers.IO) {
        engineProvider.awaitEngine().version()
    }

    override suspend fun pollNetworkLogs(
        afterSeqId: Long,
        limit: Int,
    ): ImmutableList<NetworkLogItem> = withContext(Dispatchers.IO) {
        engineProvider.awaitEngine()
            .getLogsSince(afterSeqId.coerceAtLeast(0L).toULong(), limit.coerceIn(1, 500).toUInt())
            .map { it.toDomain() }
            .toImmutableList()
    }

    override suspend fun clearLogs() = withContext(Dispatchers.IO) {
        engineProvider.awaitEngine().clearLogs()
    }
}

