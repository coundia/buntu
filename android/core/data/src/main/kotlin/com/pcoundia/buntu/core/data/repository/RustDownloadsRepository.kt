package com.pcoundia.buntu.core.data.repository

import com.pcoundia.buntu.core.data.mapper.EngineMappers.toDomain
import com.pcoundia.buntu.core.domain.model.ConnectionBudget
import com.pcoundia.buntu.core.domain.model.DownloadItem
import com.pcoundia.buntu.core.domain.repository.DownloadsRepository
import com.pcoundia.buntu.core.domain.repository.SettingsRepository
import com.pcoundia.buntu.core.domain.repository.SourcesRepository
import com.pcoundia.buntu.core.engine.EngineProvider
import com.pcoundia.buntu.core.engine.ffi.NewDownloadRequest
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
import java.util.concurrent.atomic.AtomicBoolean
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class RustDownloadsRepository @Inject constructor(
    private val engineProvider: EngineProvider,
    private val sourcesRepository: SourcesRepository,
    private val settingsRepository: SettingsRepository,
) : DownloadsRepository {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val _downloadsFlow = MutableStateFlow<ImmutableList<DownloadItem>>(persistentListOf())
    override val downloadsFlow: Flow<ImmutableList<DownloadItem>> = _downloadsFlow.asStateFlow()

    private val pausedByPlayback = AtomicBoolean(false)

    init {
        scope.launch {
            runCatching { refreshDownloads() }
        }
    }

    override suspend fun refreshDownloads(): ImmutableList<DownloadItem> =
        withContext(Dispatchers.IO) {
            val engine = engineProvider.awaitEngine()
            val items = engine.listDownloads(null).map { it.toDomain() }.toImmutableList()
            _downloadsFlow.value = items
            items
        }

    override suspend fun enqueueDownload(itemId: Long): Long =
        withContext(Dispatchers.IO) {
            val engine = engineProvider.awaitEngine()
            val item = engine.getItemById(itemId)
                ?: throw IllegalArgumentException("Média introuvable (id=$itemId)")

            // Clamp concurrent segments & active files to source connection budget (PRD-37 § 4.2 & § 12)
            val sources = sourcesRepository.refreshSourcesList()
            val prefs = settingsRepository.currentPreferences()
            val budget = ConnectionBudget.forHost(item.host, sources, prefs.assumedMaxConnections)
            val settings = engine.getSettings()
            val (segments, maxFiles) = budget.clampDownloads(
                requestedSegments = settings.segmentsPerFile.toInt(),
                requestedFiles = settings.maxActiveFiles.toInt(),
            )
            if (settings.segmentsPerFile.toInt() != segments || settings.maxActiveFiles.toInt() != maxFiles) {
                settings.segmentsPerFile = segments.toUInt()
                settings.maxActiveFiles = maxFiles.toUInt()
                runCatching { engine.updateSettings(settings) }
            }

            val ext = item.containerExt?.trim('.')?.takeIf(String::isNotBlank) ?: "mkv"
            val safeBase = item.nameClean.ifBlank { item.name }
                .replace(Regex("[^\\p{L}\\p{N}._ -]"), "_")
                .trim()
                .ifBlank { "media_$itemId" }

            val taskId = engine.enqueueDownload(
                NewDownloadRequest(
                    url = item.streamUrl,
                    fileName = "$safeBase.$ext",
                    saveDir = engineProvider.downloadsDirPath,
                    userAgent = item.userAgent,
                    referer = item.referer,
                    headersJson = item.headersJson,
                    autoStart = true,
                )
            )
            refreshDownloads()
            taskId
        }

    override suspend fun pauseDownload(taskId: Long) = withContext(Dispatchers.IO) {
        engineProvider.awaitEngine().pauseDownload(taskId)
        refreshDownloads()
        Unit
    }

    override suspend fun resumeDownload(taskId: Long) = withContext(Dispatchers.IO) {
        engineProvider.awaitEngine().startDownload(taskId)
        refreshDownloads()
        Unit
    }

    override suspend fun removeDownload(taskId: Long, deleteFiles: Boolean) =
        withContext(Dispatchers.IO) {
            engineProvider.awaitEngine().removeDownload(taskId, deleteFiles)
            refreshDownloads()
            Unit
        }

    override suspend fun pauseAllForPlayback() = withContext(Dispatchers.IO) {
        val engine = engineProvider.awaitEngine()
        val hasActive = engine.listDownloads(null).any {
            it.state == "downloading" || it.state == "queued" || it.state == "probing"
        }
        if (hasActive) {
            pausedByPlayback.set(true)
            engine.pauseAllDownloads()
            refreshDownloads()
        }
    }

    override suspend fun resumeAfterPlayback() = withContext(Dispatchers.IO) {
        if (pausedByPlayback.compareAndSet(true, false)) {
            engineProvider.awaitEngine().startAllDownloads()
            refreshDownloads()
        }
    }
}
