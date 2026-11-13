package com.pcoundia.buntu.feature.search

import androidx.compose.runtime.Immutable
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.pcoundia.buntu.core.domain.model.SearchHitItem
import com.pcoundia.buntu.core.domain.model.SearchScopeKind
import com.pcoundia.buntu.core.domain.usecase.SearchCatalogUseCase
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.persistentListOf
import kotlinx.coroutines.CancellationException
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

enum class SearchMode {
    LOCAL,
    AI,
}

@Immutable
data class SearchUiState(
    val query: String = "",
    val scope: SearchScopeKind = SearchScopeKind.ALL,
    val searchMode: SearchMode = SearchMode.LOCAL,
    val aiAvailable: Boolean = false,
    val aiProviderLabel: String = "",
    val aiBlockerMessage: String? = null,
    val isSearching: Boolean = false,
    val hits: ImmutableList<SearchHitItem> = persistentListOf(),
    val assistantReply: String = "",
    val resolvedBy: String = "local",
    val missingTitles: ImmutableList<String> = persistentListOf(),
    val errorMessage: String? = null,
)

/**
 * PRD-33 & PRD-37 § 5.2, § 6 (37.5):
 * Modal popup search with explicit user choice between Local FTS5 search and AI Assistant,
 * pre-scoped from TV / Movies / Series and supporting Android TV voice dictation.
 */
@OptIn(FlowPreview::class)
@HiltViewModel
class SearchViewModel @Inject constructor(
    private val searchCatalogUseCase: SearchCatalogUseCase,
    savedStateHandle: SavedStateHandle,
) : ViewModel() {

    private val initialScope: SearchScopeKind = savedStateHandle.get<String>("scope")
        ?.let { runCatching { SearchScopeKind.valueOf(it) }.getOrNull() }
        ?: SearchScopeKind.ALL

    private val _uiState = MutableStateFlow(SearchUiState(scope = initialScope))
    val uiState: StateFlow<SearchUiState> = _uiState.asStateFlow()

    private var smartSearchJob: Job? = null

    init {
        viewModelScope.launch {
            val status = runCatching { searchCatalogUseCase.getAiSearchStatus() }.getOrNull()
            if (status != null) {
                _uiState.update {
                    it.copy(
                        aiAvailable = status.isAvailable,
                        aiProviderLabel = status.providerLabel,
                        aiBlockerMessage = status.blockerMessage,
                        searchMode = if (status.isAvailable && status.autoSearch) {
                            SearchMode.AI
                        } else {
                            it.searchMode
                        },
                    )
                }
            }
        }
        viewModelScope.launch {
            _uiState
                .map { it.query.trim() to it.scope }
                .distinctUntilChanged()
                .debounce(150L)
                .collectLatest { (trimmed, scope) ->
                    if (trimmed.isEmpty()) {
                        smartSearchJob?.cancel()
                        _uiState.update {
                            it.copy(
                                isSearching = false,
                                hits = persistentListOf(),
                                assistantReply = "",
                                resolvedBy = "local",
                                missingTitles = persistentListOf(),
                                errorMessage = null,
                            )
                        }
                    } else {
                        runInstantSearch(trimmed, scope)
                        if (_uiState.value.searchMode == SearchMode.AI && _uiState.value.aiAvailable) {
                            submitSmartSearch()
                        }
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

    fun selectSearchMode(mode: SearchMode) {
        _uiState.update { it.copy(searchMode = mode, errorMessage = null) }
        val snap = _uiState.value
        val prompt = snap.query.trim()
        if (prompt.isEmpty()) {
            if (mode == SearchMode.LOCAL) {
                smartSearchJob?.cancel()
                _uiState.update {
                    it.copy(assistantReply = "", resolvedBy = "local", missingTitles = persistentListOf())
                }
            }
            return
        }
        when (mode) {
            SearchMode.AI -> submitSmartSearch()
            SearchMode.LOCAL -> {
                smartSearchJob?.cancel()
                smartSearchJob = viewModelScope.launch {
                    runInstantSearch(prompt, snap.scope)
                }
            }
        }
    }

    fun submitSearch() {
        val snap = _uiState.value
        val prompt = snap.query.trim()
        if (prompt.isEmpty()) return
        when (snap.searchMode) {
            SearchMode.AI -> submitSmartSearch()
            SearchMode.LOCAL -> {
                smartSearchJob?.cancel()
                smartSearchJob = viewModelScope.launch {
                    runInstantSearch(prompt, snap.scope)
                }
            }
        }
    }

    fun applyVoiceTranscript(transcript: String) {
        val cleaned = transcript.trim()
        if (cleaned.isEmpty()) return
        _uiState.update { it.copy(query = cleaned, errorMessage = null) }
        submitSearch()
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
            if (err is CancellationException) throw err
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
                if (err is CancellationException) throw err
                _uiState.update {
                    it.copy(isSearching = false, errorMessage = err.message ?: "Erreur recherche IA.")
                }
            }
        }
    }
}

