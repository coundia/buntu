package com.pcoundia.buntu.feature.details

import android.content.Context
import androidx.compose.runtime.Immutable
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.pcoundia.buntu.core.domain.model.EpisodeItem
import com.pcoundia.buntu.core.domain.model.MediaDetail
import com.pcoundia.buntu.core.domain.repository.CatalogRepository
import com.pcoundia.buntu.core.domain.repository.DownloadsRepository
import com.pcoundia.buntu.core.domain.repository.SecretStore
import com.pcoundia.buntu.core.domain.repository.SettingsRepository
import com.pcoundia.buntu.core.domain.repository.SourcesRepository
import com.pcoundia.buntu.core.domain.usecase.NextEpisodeUseCase
import com.pcoundia.buntu.core.platform.device.DeviceCapabilities
import com.pcoundia.buntu.core.platform.work.DownloadForegroundWorker
import dagger.hilt.android.lifecycle.HiltViewModel
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject

@Immutable
data class DetailsUiState(
    val isLoading: Boolean = true,
    val detail: MediaDetail? = null,
    val selectedSeason: Int? = null,
    val primaryEpisode: EpisodeItem? = null,
    val isTv: Boolean = false,
    val statusBanner: String? = null,
    val errorMessage: String? = null,
)

/**
 * PRD-37 § 5.4 & § 6 (37.3):
 * Single shared ViewModel for Movie & Series detail sheet:
 * - Immediate primary action ("Regarder" / "Reprendre" / "Épisode suivant")
 * - Season switcher + episode list
 * - Alternate stream versions picker
 * - Offline download enqueue on Phone (`DownloadForegroundWorker` screen-off safe)
 */
@HiltViewModel
class DetailsViewModel @Inject constructor(
    savedStateHandle: SavedStateHandle,
    @ApplicationContext private val appContext: Context,
    private val catalogRepository: CatalogRepository,
    private val sourcesRepository: SourcesRepository,
    private val downloadsRepository: DownloadsRepository,
    private val settingsRepository: SettingsRepository,
    private val secretStore: SecretStore,
    private val nextEpisodeUseCase: NextEpisodeUseCase,
    deviceCapabilities: DeviceCapabilities,
) : ViewModel() {

    private val mediaId: Long = savedStateHandle.get<Long>("mediaId")
        ?: savedStateHandle.get<String>("mediaId")?.toLongOrNull()
        ?: 0L
    private val isSeriesArg: Boolean = savedStateHandle.get<Boolean>("isSeries")
        ?: (savedStateHandle.get<String>("isSeries")?.toBooleanStrictOrNull() ?: false)

    private val _uiState = MutableStateFlow(DetailsUiState(isTv = deviceCapabilities.isTelevision))
    val uiState: StateFlow<DetailsUiState> = _uiState.asStateFlow()

    init {
        loadDetails(selectedSeason = null)
    }

    fun loadDetails(selectedSeason: Int? = _uiState.value.selectedSeason) {
        if (mediaId <= 0L) {
            _uiState.update { it.copy(isLoading = false, errorMessage = "Contenu introuvable.") }
            return
        }
        viewModelScope.launch {
            _uiState.update { it.copy(isLoading = true, errorMessage = null) }
            val detailResult = runCatching {
                if (isSeriesArg) {
                    val sources = sourcesRepository.refreshSourcesList()
                    val firstPasswordRef = sources.firstOrNull { it.passwordRef != null }?.passwordRef
                    val password = firstPasswordRef?.let { secretStore.getSecret(it) }
                    catalogRepository.getSeriesDetail(
                        seriesId = mediaId,
                        selectedSeason = selectedSeason,
                        xtreamPassword = password,
                    )
                } else {
                    catalogRepository.getMovieDetail(itemId = mediaId)
                }
            }
            detailResult.onSuccess { detail ->
                if (detail == null) {
                    _uiState.update { it.copy(isLoading = false, errorMessage = "Fiche média indisponible.") }
                } else {
                    val primaryEp = if (detail.isSeries) nextEpisodeUseCase(detail) else null
                    val season = selectedSeason ?: detail.seasons.firstOrNull()?.seasonNumber
                    _uiState.update {
                        it.copy(
                            isLoading = false,
                            detail = detail,
                            selectedSeason = season,
                            primaryEpisode = primaryEp,
                        )
                    }
                }
            }.onFailure { err ->
                _uiState.update {
                    it.copy(isLoading = false, errorMessage = err.message ?: "Erreur lors du chargement.")
                }
            }
        }
    }

    fun selectSeason(seasonNumber: Int) {
        if (seasonNumber == _uiState.value.selectedSeason) return
        loadDetails(selectedSeason = seasonNumber)
    }

    fun toggleFavorite() {
        val detail = _uiState.value.detail ?: return
        viewModelScope.launch {
            val kind = if (detail.isSeries) "series" else "vod"
            val nextFav = runCatching { catalogRepository.toggleFavorite(detail.stableHash, kind) }
                .getOrDefault(!detail.isFavorite)
            _uiState.update { state ->
                state.copy(detail = state.detail?.copy(isFavorite = nextFav))
            }
        }
    }

    fun enqueueDownload(targetItemId: Long) {
        viewModelScope.launch {
            runCatching {
                downloadsRepository.enqueueDownload(targetItemId)
                val prefs = settingsRepository.currentPreferences()
                DownloadForegroundWorker.enqueue(appContext, allowCellular = prefs.downloadOverCellular)
            }.onSuccess {
                _uiState.update {
                    it.copy(statusBanner = "Téléchargement lancé (continue même écran éteint).")
                }
            }.onFailure { err ->
                _uiState.update {
                    it.copy(errorMessage = err.message ?: "Impossible de démarrer le téléchargement.")
                }
            }
        }
    }
}

