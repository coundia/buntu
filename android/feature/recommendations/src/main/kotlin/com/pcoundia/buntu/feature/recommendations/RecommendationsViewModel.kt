package com.pcoundia.buntu.feature.recommendations

import androidx.compose.runtime.Immutable
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.pcoundia.buntu.core.domain.model.RecoDomainKind
import com.pcoundia.buntu.core.domain.model.RecoShelfGroup
import com.pcoundia.buntu.core.domain.repository.RecommendationsRepository
import com.pcoundia.buntu.core.domain.usecase.LoadShelvesUseCase
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.persistentListOf
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject

@Immutable
data class RecommendationsUiState(
    val selectedDomain: RecoDomainKind = RecoDomainKind.MOVIES,
    val isLoading: Boolean = true,
    val shelves: ImmutableList<RecoShelfGroup> = persistentListOf(),
)

/**
 * PRD-34 & PRD-37 § 6 (37.4), § 12:
 * Domain-separated "Pour vous" shelves (`MOVIES`, `SERIES`, `LIVE_TV` never mixed),
 * with local instant scoring + optional AI refinement + taste reset.
 */
@HiltViewModel
class RecommendationsViewModel @Inject constructor(
    private val loadShelvesUseCase: LoadShelvesUseCase,
    private val recommendationsRepository: RecommendationsRepository,
) : ViewModel() {

    private val _uiState = MutableStateFlow(RecommendationsUiState())
    val uiState: StateFlow<RecommendationsUiState> = _uiState.asStateFlow()

    private var loadJob: Job? = null

    init {
        selectDomain(RecoDomainKind.MOVIES)
    }

    fun selectDomain(domain: RecoDomainKind) {
        _uiState.update { it.copy(selectedDomain = domain, isLoading = true) }
        loadJob?.cancel()
        loadJob = viewModelScope.launch {
            runCatching {
                loadShelvesUseCase(kind = domain).collect { groups ->
                    _uiState.update { it.copy(isLoading = false, shelves = groups) }
                }
            }.onFailure {
                _uiState.update { it.copy(isLoading = false) }
            }
        }
    }

    fun resetCurrentDomainTaste() {
        val domain = _uiState.value.selectedDomain
        viewModelScope.launch {
            recommendationsRepository.resetTaste(domain)
            selectDomain(domain)
        }
    }
}

