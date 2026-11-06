package com.pcoundia.buntu.core.data.repository

import com.pcoundia.buntu.core.data.mapper.EngineMappers.toDomain
import com.pcoundia.buntu.core.domain.model.SourceSummary
import com.pcoundia.buntu.core.domain.model.SyncReport
import com.pcoundia.buntu.core.domain.repository.SecretStore
import com.pcoundia.buntu.core.domain.repository.SourcesRepository
import com.pcoundia.buntu.core.engine.EngineProvider
import com.pcoundia.buntu.core.engine.ffi.ShareDecision
import com.pcoundia.buntu.core.engine.ffi.ShareImportAction
import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.persistentListOf
import kotlinx.collections.immutable.toImmutableList
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class RustSourcesRepository @Inject constructor(
    private val engineProvider: EngineProvider,
    private val secretStore: SecretStore,
) : SourcesRepository {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val _sourcesFlow = MutableStateFlow<ImmutableList<SourceSummary>>(persistentListOf())
    override val sourcesFlow: Flow<ImmutableList<SourceSummary>> = _sourcesFlow.asStateFlow()

    init {
        scope.launch {
            runCatching { refreshSourcesList() }
        }
    }

    override suspend fun refreshSourcesList(): ImmutableList<SourceSummary> =
        withContext(Dispatchers.IO) {
            val engine = engineProvider.awaitEngine()
            val mapped = engine.listSources().map { it.toDomain() }.toImmutableList()
            _sourcesFlow.value = mapped
            mapped
        }

    override suspend fun addM3uSource(name: String, url: String): Long =
        withContext(Dispatchers.IO) {
            val engine = engineProvider.awaitEngine()
            val id = engine.addSource(
                name = name.trim(),
                sourceType = "m3u",
                url = url.trim(),
                server = null,
                username = null,
                passwordRef = null,
            )
            refreshSourcesList()
            id
        }

    override suspend fun addXtreamSource(
        name: String,
        server: String,
        username: String,
        passwordRef: String,
    ): Long = withContext(Dispatchers.IO) {
        val engine = engineProvider.awaitEngine()
        val id = engine.addSource(
            name = name.trim(),
            sourceType = "xtream",
            url = null,
            server = server.trim(),
            username = username.trim(),
            passwordRef = passwordRef,
        )
        refreshSourcesList()
        id
    }

    override suspend fun deleteSource(sourceId: Long) = withContext(Dispatchers.IO) {
        val existing = _sourcesFlow.value.firstOrNull { it.id == sourceId }
        val engine = engineProvider.awaitEngine()
        engine.deleteSource(sourceId)
        existing?.passwordRef?.let { secretStore.deleteSecret(it) }
        refreshSourcesList()
        Unit
    }

    override suspend fun syncM3uSource(sourceId: Long): SyncReport =
        withContext(Dispatchers.IO) {
            val engine = engineProvider.awaitEngine()
            val summary = engine.refreshSource(sourceId).toDomain()
            refreshSourcesList()
            summary
        }

    override suspend fun syncXtreamSource(sourceId: Long, password: String): SyncReport =
        withContext(Dispatchers.IO) {
            val engine = engineProvider.awaitEngine()
            val summary = engine.refreshXtreamSource(sourceId, password).toDomain()
            refreshSourcesList()
            summary
        }

    override suspend fun syncSourceEpg(sourceId: Long, password: String?): Int =
        withContext(Dispatchers.IO) {
            val engine = engineProvider.awaitEngine()
            engine.refreshSourceEpg(sourceId, password).toInt()
        }

    override suspend fun importShareJson(decryptedJson: String): Int =
        withContext(Dispatchers.IO) {
            val engine = engineProvider.awaitEngine()
            val preview = engine.previewShareDocument(decryptedJson)
            val decisions = preview.sources.map { src ->
                ShareDecision(
                    index = src.index,
                    action = if (src.duplicateOf != null) ShareImportAction.REPLACE else ShareImportAction.IMPORT,
                )
            }
            val result = engine.importShareDocument(
                json = decryptedJson,
                decisions = decisions,
                importsDir = engineProvider.importsDirPath,
            )
            // PRD-26 / PRD-37 § 7: Store any imported Xtream passwords in Android Keystore (`cnd.xtream.<uuid>`)
            for (imported in result.imported) {
                val pwd = imported.password?.takeIf { it.isNotEmpty() } ?: continue
                val alias = "cnd.xtream.${imported.uuid}"
                secretStore.putSecret(alias, pwd)
            }
            refreshSourcesList()
            result.imported.size
        }
}

