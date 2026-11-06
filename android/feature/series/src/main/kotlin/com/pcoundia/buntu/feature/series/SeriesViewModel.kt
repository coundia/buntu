package com.pcoundia.buntu.feature.series

import androidx.compose.runtime.Immutable
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.paging.PagingData
import androidx.paging.cachedIn
import com.pcoundia.buntu.core.domain.model.CatalogQuery
import com.pcoundia.buntu.core.domain.model.CatalogSort
import com.pcoundia.buntu.core.domain.model.RecoDomainKind
import com.pcoundia.buntu.core.domain.model.RecoShelfGroup
import com.pcoundia.buntu.core.domain.model.SeriesItem
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
data class SeriesUiState(
    val categories: ImmutableList<String> = persistentListOf(),
    val selectedCategory: String? = null,
    val sort: CatalogSort = CatalogSort.DEFAULT,
    val favoritesOnly: Boolean = false,
    val shelves: ImmutableList<RecoShelfGroup> = persistentListOf(),
)

@OptIn(ExperimentalCoroutinesApi::class)
@HiltViewModel
class SeriesViewModel @Inject constructor(
    private val catalogRepository: CatalogRepository,
    private val loadShelvesUseCase: LoadShelvesUseCase,
) : ViewModel() {

    private val _uiState = MutableStateFlow(SeriesUiState())
    val uiState: StateFlow<SeriesUiState> = _uiState.asStateFlow()

    val pagedSeries: Flow<PagingData<SeriesItem>> = _uiState
        .map { state ->
            CatalogQuery(
                groupName = state.selectedCategory,
                favoritesOnly = state.favoritesOnly,
                sort = state.sort,
            )
        }
        .distinctUntilChanged()
        .flatMapLatest { query -> catalogRepository.pagedSeries(query) }
        .cachedIn(viewModelScope)

    init {
        viewModelScope.launch {
            runCatching { catalogRepository.getGroups(kind = "series") }
                .onSuccess { facets ->
                    _uiState.update { state ->
                        state.copy(categories = facets.map { it.name }.toImmutableList())
                    }
                }
        }
        viewModelScope.launch {
            runCatching {
                loadShelvesUseCase(kind = RecoDomainKind.SERIES).collect { shelves ->
                    _uiState.update { it.copy(shelves = shelves) }
                }
            }
        }
    }

    fun selectCategory(category: String?) {
        _uiState.update { it.copy(selectedCategory = category) }
    }

    fun toggleFavoritesOnly() {
        _uiState.update { it.copy(favoritesOnly = !it.favoritesOnly) }
    }
}

