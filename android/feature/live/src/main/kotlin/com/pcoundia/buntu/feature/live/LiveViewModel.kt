package com.pcoundia.buntu.feature.live

import com.pcoundia.buntu.core.designsystem.i18n.AppLanguageState
import com.pcoundia.buntu.core.domain.model.DiscoveredPeer
import com.pcoundia.buntu.core.domain.usecase.PlayOnAnotherDeviceUseCase
import androidx.compose.runtime.Immutable
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.paging.PagingData
import androidx.paging.cachedIn
import com.pcoundia.buntu.core.domain.model.CatalogQuery
import com.pcoundia.buntu.core.domain.model.ChannelItem
import com.pcoundia.buntu.core.domain.model.RecoDomainKind
import com.pcoundia.buntu.core.domain.model.RecoShelfGroup
import com.pcoundia.buntu.core.domain.repository.CatalogRepository
import com.pcoundia.buntu.core.domain.repository.SettingsRepository
import com.pcoundia.buntu.core.domain.usecase.LoadShelvesUseCase
import com.pcoundia.buntu.core.domain.usecase.ZapToChannelUseCase
import com.pcoundia.buntu.core.player.PlayerEngineState
import com.pcoundia.buntu.core.player.VideoEngine
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.persistentListOf
import kotlinx.collections.immutable.toImmutableList
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject

@Immutable
data class LiveUiState(
    val categories: ImmutableList<String> = persistentListOf(),
    val selectedCategory: String? = null,
    val favoritesOnly: Boolean = false,
    val searchQuery: String = "",
    val activeChannelId: Long? = null,
    val activeChannelTitle: String? = null,
    val activeChannelNow: String? = null,
    val numericBuffer: String = "",
    val liveShelves: ImmutableList<RecoShelfGroup> = persistentListOf(),
    val errorMessage: String? = null,
)

/**
 * PRD-37 § 6 (37.2) & § 5.2:
 * Shared Phone + Android TV ViewModel for Live TV:
 * - Paging 3 channel list + category filter + favorites toggle
 * - Instant zapping via `ZapToChannelUseCase` + singleton `VideoEngine`
 * - D-Pad Up/Down adjacent zapping + numeric keypad entry on TV remotes
 * - Live TV recommendation shelves displayed directly below the inline player
 */
@OptIn(ExperimentalCoroutinesApi::class)
@HiltViewModel
class LiveViewModel @Inject constructor(
    private val catalogRepository: CatalogRepository,
    private val settingsRepository: SettingsRepository,
    private val zapToChannelUseCase: ZapToChannelUseCase,
    private val loadShelvesUseCase: LoadShelvesUseCase,
    val videoEngine: VideoEngine,
    private val playOnAnotherDevice: PlayOnAnotherDeviceUseCase,
) : ViewModel() {

    // « Lire sur un autre appareil » from the context menu of a channel (PRD-44 § 2.2).
    val remoteDevices: StateFlow<List<DiscoveredPeer>> = playOnAnotherDevice.devices
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())
    val remoteStatus: StateFlow<String?> = playOnAnotherDevice.status

    fun openRemoteMenu() = playOnAnotherDevice.reset()

    fun playOnDevice(deviceId: String, itemId: Long, onSent: () -> Unit) {
        viewModelScope.launch { if (playOnAnotherDevice(deviceId, itemId)) onSent() }
    }

    private val localState = MutableStateFlow(LiveUiState())

    val playerState: StateFlow<PlayerEngineState> = videoEngine.state

    val pagedChannels: Flow<PagingData<ChannelItem>> = localState
        .combine(settingsRepository.preferencesFlow) { state, _ ->
            CatalogQuery(
                searchQuery = state.searchQuery,
                groupName = state.selectedCategory,
                favoritesOnly = state.favoritesOnly,
            )
        }
        .distinctUntilChanged()
        .flatMapLatest { query -> catalogRepository.pagedLiveChannels(query) }
        .cachedIn(viewModelScope)

    val uiState: StateFlow<LiveUiState> = combine(
        localState,
        videoEngine.state,
    ) { state, engineState ->
        state.copy(
            activeChannelTitle = engineState.activeStream?.title ?: state.activeChannelTitle,
            errorMessage = engineState.diagnosis?.userMessage ?: state.errorMessage,
        )
    }.stateIn(
        scope = viewModelScope,
        started = SharingStarted.WhileSubscribed(5_000L),
        initialValue = LiveUiState(),
    )

    init {
        refreshCategoriesAndShelves()
        restoreLastWatchedChannelIfIdle()
    }

    fun refreshCategoriesAndShelves() {
        viewModelScope.launch {
            runCatching {
                catalogRepository.getGroups(kind = "live")
            }.onSuccess { facets ->
                localState.update { state ->
                    state.copy(categories = facets.map { it.name }.toImmutableList())
                }
            }
        }
        viewModelScope.launch {
            runCatching {
                loadShelvesUseCase(kind = RecoDomainKind.LIVE_TV).collect { shelves ->
                    localState.update { it.copy(liveShelves = shelves) }
                }
            }
        }
    }

    private fun restoreLastWatchedChannelIfIdle() {
        viewModelScope.launch {
            if (videoEngine.state.value.activeStream != null) return@launch
            val lastId = settingsRepository.currentPreferences().lastChannelId ?: return@launch
            val channel = catalogRepository.getChannelById(lastId) ?: return@launch
            localState.update {
                it.copy(
                    activeChannelId = channel.id,
                    activeChannelTitle = channel.name,
                    activeChannelNow = channel.nowTitle,
                )
            }
        }
    }

    fun selectCategory(category: String?) {
        localState.update { it.copy(selectedCategory = category, errorMessage = null) }
    }

    fun toggleFavoritesOnly() {
        localState.update { it.copy(favoritesOnly = !it.favoritesOnly) }
    }

    fun updateSearchQuery(query: String) {
        localState.update { it.copy(searchQuery = query) }
    }

    fun playChannelInline(channel: ChannelItem) {
        viewModelScope.launch {
            val stream = zapToChannelUseCase.byId(channel.id)
            if (stream != null) {
                localState.update {
                    it.copy(
                        activeChannelId = channel.id,
                        activeChannelTitle = channel.name,
                        activeChannelNow = channel.nowTitle,
                        errorMessage = null,
                    )
                }
                videoEngine.zap(stream)
            } else {
                localState.update { it.copy(errorMessage = AppLanguageState.translate("live.open_channel_error")) }
            }
        }
    }

    fun zapByChannelId(channelId: Long) {
        viewModelScope.launch {
            val stream = zapToChannelUseCase.byId(channelId) ?: return@launch
            val channel = catalogRepository.getChannelById(channelId)
            localState.update {
                it.copy(
                    activeChannelId = channelId,
                    activeChannelTitle = channel?.name ?: stream.title,
                    activeChannelNow = channel?.nowTitle,
                    errorMessage = null,
                )
            }
            videoEngine.zap(stream)
        }
    }

    fun zapAdjacent(delta: Int) {
        val currentId = localState.value.activeChannelId
            ?: videoEngine.state.value.activeStream?.itemId
            ?: return
        viewModelScope.launch {
            val stream = zapToChannelUseCase.adjacent(
                currentChannelId = currentId,
                delta = delta,
                groupName = localState.value.selectedCategory,
            ) ?: return@launch
            localState.update {
                it.copy(
                    activeChannelId = stream.itemId,
                    activeChannelTitle = stream.title,
                    errorMessage = null,
                )
            }
            videoEngine.zap(stream)
        }
    }

    fun appendChannelDigit(digit: Char) {
        if (!digit.isDigit()) return
        val next = (localState.value.numericBuffer + digit).takeLast(4)
        localState.update { it.copy(numericBuffer = next) }
    }

    fun confirmNumericZap() {
        val number = localState.value.numericBuffer.toIntOrNull() ?: return
        localState.update { it.copy(numericBuffer = "") }
        viewModelScope.launch {
            val stream = zapToChannelUseCase.byNumber(number)
            if (stream != null) {
                localState.update {
                    it.copy(
                        activeChannelId = stream.itemId,
                        activeChannelTitle = stream.title,
                        errorMessage = null,
                    )
                }
                videoEngine.zap(stream)
            }
        }
    }

    fun toggleFavorite(channel: ChannelItem) {
        viewModelScope.launch {
            catalogRepository.toggleFavorite(channel.stableHash, "live")
        }
    }
}

