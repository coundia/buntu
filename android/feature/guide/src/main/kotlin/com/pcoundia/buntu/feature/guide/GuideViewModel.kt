package com.pcoundia.buntu.feature.guide

import androidx.compose.runtime.Immutable
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.pcoundia.buntu.core.domain.model.ChannelGuideRow
import com.pcoundia.buntu.core.domain.repository.CatalogRepository
import com.pcoundia.buntu.core.domain.repository.EpgRepository
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.persistentListOf
import kotlinx.collections.immutable.toImmutableList
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject

@Immutable
data class GuideUiState(
    val isLoading: Boolean = true,
    val categories: ImmutableList<String> = persistentListOf(),
    val selectedCategory: String? = null,
    val windowStartEpochSecs: Long = currentHalfHourEpochSecs(),
    val rows: ImmutableList<ChannelGuideRow> = persistentListOf(),
    val errorMessage: String? = null,
)

private fun currentHalfHourEpochSecs(): Long {
    val now = System.currentTimeMillis() / 1_000L
    return now - (now % 1_800L)
}

/**
 * PRD-37 § 6 (37.2) & § 5.2:
 * Lazy 2D EPG programme guide for Phone & Android TV with live zapping and catch-up replay.
 */
@HiltViewModel
class GuideViewModel @Inject constructor(
    private val epgRepository: EpgRepository,
    private val catalogRepository: CatalogRepository,
) : ViewModel() {

    private val _uiState = MutableStateFlow(GuideUiState())
    val uiState: StateFlow<GuideUiState> = _uiState.asStateFlow()

    init {
        viewModelScope.launch {
            runCatching { catalogRepository.getGroups("live") }
                .onSuccess { facets ->
                    _uiState.update { state ->
                        state.copy(categories = facets.map { it.name }.toImmutableList())
                    }
                }
        }
        reloadGrid()
    }

    fun selectCategory(category: String?) {
        _uiState.update { it.copy(selectedCategory = category) }
        reloadGrid()
    }

    fun shiftWindowHours(deltaHours: Int) {
        _uiState.update {
            it.copy(windowStartEpochSecs = it.windowStartEpochSecs + deltaHours * 3_600L)
        }
        reloadGrid()
    }

    fun jumpToNow() {
        _uiState.update { it.copy(windowStartEpochSecs = currentHalfHourEpochSecs()) }
        reloadGrid()
    }

    fun reloadGrid() {
        val snap = _uiState.value
        val from = snap.windowStartEpochSecs
        val to = from + 4 * 3_600L // 4-hour viewport window
        viewModelScope.launch {
            _uiState.update { it.copy(isLoading = true, errorMessage = null) }
            runCatching {
                epgRepository.loadGuideGrid(
                    groupName = snap.selectedCategory,
                    fromEpochSecs = from,
                    toEpochSecs = to,
                    limitChannels = 80,
                )
            }.onSuccess { rows ->
                _uiState.update { it.copy(isLoading = false, rows = rows) }
            }.onFailure { err ->
                _uiState.update {
                    it.copy(isLoading = false, errorMessage = err.message ?: "Guide EPG indisponible.")
                }
            }
        }
    }
}

