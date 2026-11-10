package com.pcoundia.buntu.feature.recommendations

import com.pcoundia.buntu.core.domain.model.DiscoveredPeer
import com.pcoundia.buntu.core.domain.usecase.PlayOnAnotherDeviceUseCase
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.stateIn
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
    private val playOnAnotherDevice: PlayOnAnotherDeviceUseCase,
) : ViewModel() {

    // « Lire sur un autre appareil » from the context menu of a card (PRD-44 § 2.2).
    val remoteDevices: StateFlow<List<DiscoveredPeer>> = playOnAnotherDevice.devices
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())
    val remoteStatus: StateFlow<String?> = playOnAnotherDevice.status

    fun openRemoteMenu() = playOnAnotherDevice.reset()

    fun playOnDevice(deviceId: String, itemId: Long, onSent: () -> Unit) {
        viewModelScope.launch { if (playOnAnotherDevice(deviceId, itemId)) onSent() }
    }

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

