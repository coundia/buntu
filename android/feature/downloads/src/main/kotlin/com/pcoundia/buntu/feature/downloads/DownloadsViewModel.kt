package com.pcoundia.buntu.feature.downloads

import android.content.Context
import androidx.compose.runtime.Immutable
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.pcoundia.buntu.core.domain.model.DownloadItem
import com.pcoundia.buntu.core.domain.repository.DownloadsRepository
import com.pcoundia.buntu.core.domain.repository.SettingsRepository
import com.pcoundia.buntu.core.platform.work.DownloadForegroundWorker
import dagger.hilt.android.lifecycle.HiltViewModel
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.persistentListOf
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import javax.inject.Inject

@Immutable
data class DownloadsUiState(
    val tasks: ImmutableList<DownloadItem> = persistentListOf(),
)

/**
 * PRD-36 & PRD-37 § 6 (37.6):
 * Offline VOD downloads screen on Phone/Tablet. Ensures `DownloadForegroundWorker` (`dataSync`)
 * keeps transfers alive when the screen turns off or device enters Doze.
 */
@HiltViewModel
class DownloadsViewModel @Inject constructor(
    @ApplicationContext private val appContext: Context,
    private val downloadsRepository: DownloadsRepository,
    private val settingsRepository: SettingsRepository,
) : ViewModel() {

    val uiState: StateFlow<DownloadsUiState> = downloadsRepository.downloadsFlow
        .map { DownloadsUiState(tasks = it) }
        .stateIn(
            scope = viewModelScope,
            started = SharingStarted.WhileSubscribed(5_000L),
            initialValue = DownloadsUiState(),
        )

    init {
        viewModelScope.launch {
            while (isActive) {
                val items = runCatching { downloadsRepository.refreshDownloads() }
                    .getOrDefault(persistentListOf())
                val hasActive = items.any {
                    it.state == "downloading" || it.state == "queued" || it.state == "probing"
                }
                if (hasActive) {
                    val prefs = settingsRepository.currentPreferences()
                    DownloadForegroundWorker.enqueue(appContext, allowCellular = prefs.downloadOverCellular)
                    delay(1_500L)
                } else {
                    delay(4_000L)
                }
            }
        }
    }

    fun pause(taskId: Long) {
        viewModelScope.launch { downloadsRepository.pauseDownload(taskId) }
    }

    fun resume(taskId: Long) {
        viewModelScope.launch {
            downloadsRepository.resumeDownload(taskId)
            val prefs = settingsRepository.currentPreferences()
            DownloadForegroundWorker.enqueue(appContext, allowCellular = prefs.downloadOverCellular)
        }
    }

    fun remove(taskId: Long) {
        viewModelScope.launch { downloadsRepository.removeDownload(taskId, deleteFiles = true) }
    }
}

