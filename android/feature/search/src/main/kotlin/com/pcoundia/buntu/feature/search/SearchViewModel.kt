package com.pcoundia.buntu.feature.search

import androidx.compose.runtime.Immutable
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.pcoundia.buntu.core.domain.model.SearchHitItem
import com.pcoundia.buntu.core.domain.model.SearchScopeKind
import com.pcoundia.buntu.core.domain.usecase.SearchCatalogUseCase
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.persistentListOf
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.util.TimeZone
import javax.inject.Inject

@Immutable
data class SearchUiState(
    val query: String = "",
    val scope: SearchScopeKind = SearchScopeKind.ALL,
    val isSearching: Boolean = false,
    val hits: ImmutableList<SearchHitItem> = persistentListOf(),
    val assistantReply: String = "",
    val resolvedBy: String = "local",
    val missingTitles: ImmutableList<String> = persistentListOf(),
    val errorMessage: String? = null,
)

/**
 * PRD-33 & PRD-37 § 5.2, § 6 (37.5):
 * Unified local FTS5 + prompt search with optional AI smart search & Android TV voice dictation.
 */
@OptIn(FlowPreview::class)
@HiltViewModel
class SearchViewModel @Inject constructor(
    private val searchCatalogUseCase: SearchCatalogUseCase,
) : ViewModel() {

    private val _uiState = MutableStateFlow(SearchUiState())
    val uiState: StateFlow<SearchUiState> = _uiState.asStateFlow()

    private var smartSearchJob: Job? = null

    init {
        viewModelScope.launch {
            _uiState
                .map { it.query.trim() to it.scope }
                .distinctUntilChanged()
                .debounce(150L)
                .collectLatest { (trimmed, scope) ->
                    if (trimmed.isEmpty()) {
                        _uiState.update {
                            it.copy(
                                isSearching = false,
                                hits = persistentListOf(),
                                assistantReply = "",
                                missingTitles = persistentListOf(),
                                errorMessage = null,
                            )
                        }
                    } else {
                        runInstantSearch(trimmed, scope)
                    }
                }
        }
    }

    fun updateQuery(query: String) {
        _uiState.update { it.copy(query = query, errorMessage = null) }
    }

    fun selectScope(scope: SearchScopeKind) {
        _uiState.update { it.copy(scope = scope) }
    }

    fun applyVoiceTranscript(transcript: String) {
        val cleaned = transcript.trim()
        if (cleaned.isEmpty()) return
        _uiState.update { it.copy(query = cleaned, errorMessage = null) }
        submitSmartSearch()
    }

    private suspend fun runInstantSearch(prompt: String, scope: SearchScopeKind) {
        _uiState.update { it.copy(isSearching = true) }
        val offsetMins = TimeZone.getDefault().getOffset(System.currentTimeMillis()) / 60_000
        runCatching {
            searchCatalogUseCase.searchInstant(
                prompt = prompt,
                scope = scope,
                locale = "fr",
                utcOffsetMinutes = offsetMins,
            )
        }.onSuccess { outcome ->
            _uiState.update {
                it.copy(
                    isSearching = false,
                    hits = outcome.hits,
                    assistantReply = outcome.assistantReply,
                    resolvedBy = outcome.resolvedBy,
                    missingTitles = outcome.missingTitles,
                )
            }
        }.onFailure { err ->
            _uiState.update {
                it.copy(isSearching = false, errorMessage = err.message ?: "Recherche indisponible.")
            }
        }
    }

    fun submitSmartSearch() {
        val snap = _uiState.value
        val prompt = snap.query.trim()
        if (prompt.isEmpty()) return
        smartSearchJob?.cancel()
        smartSearchJob = viewModelScope.launch {
            _uiState.update { it.copy(isSearching = true, errorMessage = null) }
            val offsetMins = TimeZone.getDefault().getOffset(System.currentTimeMillis()) / 60_000
            runCatching {
                searchCatalogUseCase.searchSmart(
                    prompt = prompt,
                    scope = snap.scope,
                    locale = "fr",
                    utcOffsetMinutes = offsetMins,
                )
            }.onSuccess { outcome ->
                _uiState.update {
                    it.copy(
                        isSearching = false,
                        hits = outcome.hits,
                        assistantReply = outcome.assistantReply,
                        resolvedBy = outcome.resolvedBy,
                        missingTitles = outcome.missingTitles,
                    )
                }
            }.onFailure { err ->
                _uiState.update {
                    it.copy(isSearching = false, errorMessage = err.message ?: "Erreur recherche IA.")
                }
            }
        }
    }
}

