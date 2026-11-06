package com.pcoundia.buntu.core.engine

import com.pcoundia.buntu.core.engine.ffi.CndEngine
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class RustEngineProvider @Inject constructor(
    private val paths: EnginePaths,
) : EngineProvider {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val initMutex = Mutex()

    @Volatile
    private var instance: CndEngine? = null

    private val _isReady = MutableStateFlow(false)
    override val isReady: StateFlow<Boolean> = _isReady.asStateFlow()

    override val downloadsDirPath: String
        get() = paths.downloadsDir.absolutePath

    override val importsDirPath: String
        get() = paths.importsDir.absolutePath

    init {
        // Warm up the Rust SQLite WAL engine immediately in the background on app launch (PRD-37 § 2.2)
        scope.launch {
            runCatching { awaitEngine() }
        }
    }

    override suspend fun awaitEngine(): CndEngine {
        instance?.let { return it }
        return initMutex.withLock {
            instance?.let { return@withLock it }
            withContext(Dispatchers.IO) {
                val engine = CndEngine(paths.dbPath)
                val currentSettings = engine.getSettings()
                if (currentSettings.downloadDir.isNullOrBlank()) {
                    currentSettings.downloadDir = paths.downloadsDir.absolutePath
                    runCatching { engine.updateSettings(currentSettings) }
                }
                engine.setRecordingDirectory(paths.recordingsDir.absolutePath)
                instance = engine
                _isReady.value = true
                engine
            }
        }
    }
}

