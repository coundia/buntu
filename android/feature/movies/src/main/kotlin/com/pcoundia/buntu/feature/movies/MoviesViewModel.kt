package com.pcoundia.buntu.feature.movies

import com.pcoundia.buntu.core.domain.model.DiscoveredPeer
import com.pcoundia.buntu.core.domain.usecase.PlayOnAnotherDeviceUseCase
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.stateIn
import androidx.compose.runtime.Immutable
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.paging.PagingData
import androidx.paging.cachedIn
import com.pcoundia.buntu.core.domain.model.CatalogQuery
import com.pcoundia.buntu.core.domain.model.CatalogSort
import com.pcoundia.buntu.core.domain.model.MovieItem
import com.pcoundia.buntu.core.domain.model.RecoDomainKind
import com.pcoundia.buntu.core.domain.model.RecoShelfGroup
import com.pcoundia.buntu.core.domain.repository.CatalogRepository
import com.pcoundia.buntu.core.domain.usecase.LoadShelvesUseCase
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.persistentListOf
import kotlinx.collections.immutable.toImmutableList
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject

@Immutable
data class MoviesUiState(
    val categories: ImmutableList<String> = persistentListOf(),
    val selectedCategory: String? = null,
    val sort: CatalogSort = CatalogSort.DEFAULT,
    val favoritesOnly: Boolean = false,
    val shelves: ImmutableList<RecoShelfGroup> = persistentListOf(),
)

/**
 * PRD-37 § 6 (37.3) & PRD-34:
 * VOD Movies catalog: `RecoDomainKind.MOVIES`-only shelves + virtualized Paging 3 poster grid.
 */
@OptIn(ExperimentalCoroutinesApi::class)
@HiltViewModel
class MoviesViewModel @Inject constructor(
    private val catalogRepository: CatalogRepository,
    private val loadShelvesUseCase: LoadShelvesUseCase,
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

    private val _uiState = MutableStateFlow(MoviesUiState())
    val uiState: StateFlow<MoviesUiState> = _uiState.asStateFlow()

    val pagedMovies: Flow<PagingData<MovieItem>> = _uiState
        .map { state ->
            CatalogQuery(
                groupName = state.selectedCategory,
                favoritesOnly = state.favoritesOnly,
                sort = state.sort,
            )
        }
        .distinctUntilChanged()
        .flatMapLatest { query -> catalogRepository.pagedMovies(query) }
        .cachedIn(viewModelScope)

    init {
        viewModelScope.launch {
            runCatching { catalogRepository.getGroups(kind = "vod") }
                .onSuccess { facets ->
                    _uiState.update { state ->
                        state.copy(categories = facets.map { it.name }.toImmutableList())
                    }
                }
        }
        viewModelScope.launch {
            runCatching {
                loadShelvesUseCase(kind = RecoDomainKind.MOVIES).collect { shelves ->
                    _uiState.update { it.copy(shelves = shelves) }
                }
            }
        }
    }

    fun selectCategory(category: String?) {
        _uiState.update { it.copy(selectedCategory = category) }
    }

    fun selectSort(sort: CatalogSort) {
        _uiState.update { it.copy(sort = sort) }
    }

    fun toggleFavoritesOnly() {
        _uiState.update { it.copy(favoritesOnly = !it.favoritesOnly) }
    }
}

