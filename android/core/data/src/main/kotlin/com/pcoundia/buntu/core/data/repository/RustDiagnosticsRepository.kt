package com.pcoundia.buntu.core.data.repository

import com.pcoundia.buntu.core.data.mapper.EngineMappers.toDomain
import com.pcoundia.buntu.core.data.mapper.EngineMappers.toEngineConfig
import com.pcoundia.buntu.core.domain.model.AiProviderTestResult
import com.pcoundia.buntu.core.domain.model.AiSettingsConfig
import com.pcoundia.buntu.core.domain.model.EngineDbStats
import com.pcoundia.buntu.core.domain.model.EngineRuntimeConfig
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

    override suspend fun testAiProvider(
        aiConfig: AiSettingsConfig,
        apiKey: String?,
    ): AiProviderTestResult = withContext(Dispatchers.IO) {
        runCatching {
            val status = engineProvider.awaitEngine().aiTestProvider(aiConfig.toEngineConfig(apiKey))
            AiProviderTestResult(
                ok = status.ok,
                latencyMs = status.latencyMs.toLong(),
                model = status.model,
                message = status.message,
            )
        }.getOrElse { err ->
            AiProviderTestResult(
                ok = false,
                latencyMs = 0L,
                model = aiConfig.model.ifBlank { aiConfig.provider.defaultModel },
                message = err.message ?: "Impossible de contacter le fournisseur IA.",
            )
        }
    }

    override suspend fun getDbStats(): EngineDbStats = withContext(Dispatchers.IO) {
        val stats = engineProvider.awaitEngine().getStats()
        EngineDbStats(
            totalSources = stats.totalSources.toInt(),
            totalLiveChannels = stats.totalLiveChannels.toInt(),
            totalMovies = stats.totalMovies.toInt(),
            totalSeries = stats.totalSeries.toInt(),
            totalEpisodes = stats.totalEpisodes.toInt(),
            totalFavorites = stats.totalFavorites.toInt(),
            totalBroken = stats.totalBroken.toInt(),
            totalDownloads = stats.totalDownloads.toInt(),
            dbSizeBytes = stats.dbSizeBytes.toLong(),
        )
    }

    override suspend fun getRuntimeConfig(): EngineRuntimeConfig = withContext(Dispatchers.IO) {
        val s = engineProvider.awaitEngine().getSettings()
        EngineRuntimeConfig(
            segmentsPerFile = s.segmentsPerFile.toInt().coerceIn(1, 16),
            partSizeMb = (s.partSizeBytes / (1024uL * 1024uL)).toInt().coerceIn(1, 256),
            maxActiveFiles = s.maxActiveFiles.toInt().coerceIn(1, 8),
            defaultUserAgent = s.defaultUserAgent,
            defaultReferer = s.defaultReferer.orEmpty(),
            showNetworkConsole = s.showNetworkConsole,
        )
    }

    override suspend fun updateRuntimeConfig(
        config: EngineRuntimeConfig,
        omdbKeyRef: String?,
    ) = withContext(Dispatchers.IO) {
        val engine = engineProvider.awaitEngine()
        val base = engine.getSettings()
        val updated = base.copy(
            segmentsPerFile = config.segmentsPerFile.coerceIn(1, 16).toUInt(),
            partSizeBytes = config.partSizeMb.coerceIn(1, 256).toULong() * 1024uL * 1024uL,
            maxActiveFiles = config.maxActiveFiles.coerceIn(1, 8).toUInt(),
            defaultUserAgent = config.defaultUserAgent.trim().ifEmpty { base.defaultUserAgent },
            defaultReferer = config.defaultReferer.trim().takeIf { it.isNotEmpty() },
            omdbApiKeyRef = omdbKeyRef?.trim()?.takeIf { it.isNotEmpty() },
            showNetworkConsole = config.showNetworkConsole,
        )
        engine.updateSettings(updated)
    }

    override suspend fun resetDismissedRecommendations() = withContext(Dispatchers.IO) {
        engineProvider.awaitEngine().resetDismissedRecommendations()
    }
}


