package com.pcoundia.buntu.core.domain.usecase

import com.pcoundia.buntu.core.domain.model.SourceKind
import com.pcoundia.buntu.core.domain.model.SourceSummary
import com.pcoundia.buntu.core.domain.model.SyncReport
import com.pcoundia.buntu.core.domain.repository.SecretStore
import com.pcoundia.buntu.core.domain.repository.SourcesRepository
import java.util.UUID
import javax.inject.Inject

/**
 * Single responsibility: synchronize an M3U or Xtream source + its XMLTV EPG,
 * resolving Xtream credentials strictly from `SecretStore` (Android Keystore).
 */
class SyncSourceUseCase @Inject constructor(
    private val sourcesRepository: SourcesRepository,
    private val secretStore: SecretStore,
) {
    suspend operator fun invoke(source: SourceSummary, includeEpg: Boolean = true): SyncReport {
        val password = source.passwordRef?.let { secretStore.getSecret(it) }
        val report = when (source.kind) {
            SourceKind.M3U -> sourcesRepository.syncM3uSource(source.id)
            SourceKind.XTREAM -> sourcesRepository.syncXtreamSource(
                sourceId = source.id,
                password = password.orEmpty(),
            )
        }
        if (includeEpg) {
            runCatching { sourcesRepository.syncSourceEpg(source.id, password) }
        }
        sourcesRepository.refreshSourcesList()
        return report
    }

    suspend fun refreshExistingSource(source: SourceSummary): SyncReport =
        invoke(source, includeEpg = true)

    suspend fun addAndSyncM3u(name: String, url: String): Pair<Long, SyncReport> {
        val sourceId = sourcesRepository.addM3uSource(name = name, url = url)
        val report = sourcesRepository.syncM3uSource(sourceId)
        runCatching { sourcesRepository.syncSourceEpg(sourceId, null) }
        sourcesRepository.refreshSourcesList()
        return sourceId to report
    }

    suspend fun addAndSyncXtream(
        name: String,
        server: String,
        username: String,
        password: String,
    ): Pair<Long, SyncReport> {
        val passwordAlias = "xtream_pwd_${UUID.randomUUID()}"
        secretStore.putSecret(passwordAlias, password)
        val sourceId = sourcesRepository.addXtreamSource(
            name = name,
            server = server,
            username = username,
            passwordRef = passwordAlias,
        )
        val report = sourcesRepository.syncXtreamSource(sourceId = sourceId, password = password)
        runCatching { sourcesRepository.syncSourceEpg(sourceId, password) }
        sourcesRepository.refreshSourcesList()
        return sourceId to report
    }

    suspend fun syncAllStaleEpg(maxAgeSeconds: Long = 12 * 3600L) {
        val nowSecs = System.currentTimeMillis() / 1_000L
        val sources = sourcesRepository.refreshSourcesList()
        for (source in sources) {
            val lastSync = source.lastSyncEpochSecs ?: 0L
            if (nowSecs - lastSync >= maxAgeSeconds) {
                val password = source.passwordRef?.let { secretStore.getSecret(it) }
                runCatching { sourcesRepository.syncSourceEpg(source.id, password) }
            }
        }
    }
}

