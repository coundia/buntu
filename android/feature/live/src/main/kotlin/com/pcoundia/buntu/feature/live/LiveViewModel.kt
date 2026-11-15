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
import com.pcoundia.buntu.core.domain.model.CatalogSort
import com.pcoundia.buntu.core.domain.model.ChannelItem
import com.pcoundia.buntu.core.domain.model.RecoDomainKind
import com.pcoundia.buntu.core.domain.model.RecoShelfGroup
import com.pcoundia.buntu.core.domain.model.formatPlaybackErrorMessage
import com.pcoundia.buntu.core.domain.repository.CatalogRepository
import com.pcoundia.buntu.core.domain.repository.PlaybackHealthRepository
import com.pcoundia.buntu.core.domain.repository.SettingsRepository
import com.pcoundia.buntu.core.domain.usecase.LoadShelvesUseCase
import com.pcoundia.buntu.core.domain.usecase.ZapToChannelUseCase
import com.pcoundia.buntu.core.player.PlayerEngineState
import com.pcoundia.buntu.core.player.VideoEngine
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.persistentListOf
import kotlinx.collections.immutable.toImmutableList
import kotlinx.coroutines.CancellationException
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

private const val RECENT_LIMIT = 10
private const val FAVORITES_LIMIT = 20

@Immutable
data class LiveUiState(
    val categories: ImmutableList<String> = persistentListOf(),
    val selectedCategory: String? = null,
    val favoritesOnly: Boolean = false,
    val searchQuery: String = "",
    val sort: CatalogSort = CatalogSort.DEFAULT,
    val activeChannelId: Long? = null,
    val activeChannelTitle: String? = null,
    val activeChannelNow: String? = null,
    val isInlinePlayerVisible: Boolean = false,
    val numericBuffer: String = "",
    val liveShelves: ImmutableList<RecoShelfGroup> = persistentListOf(),
    /** Most recently watched channels, shown first on the phone screen. */
    val recentChannels: ImmutableList<ChannelItem> = persistentListOf(),
    /** Favorite channels (capped), shown right after the recents. */
    val favoriteChannels: ImmutableList<ChannelItem> = persistentListOf(),
    val brokenChannels: Map<String, Boolean> = emptyMap(),
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
    private val playbackHealth: PlaybackHealthRepository,
) : ViewModel() {

    // « Lire sur un autre appareil » from the context menu of a channel (PRD-44 § 2.2).
    val remoteDevices: StateFlow<List<DiscoveredPeer>> = playOnAnotherDevice.devices
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())
    val remoteStatus: StateFlow<String?> = playOnAnotherDevice.status

    fun openRemoteMenu() = playOnAnotherDevice.reset()

    /** Favorite of the item behind a card menu (an episode reads its series, as in the player). */
    suspend fun isItemFavorite(itemId: Long): Boolean? =
        runCatching { catalogRepository.isFavoriteForPlayback(itemId) }
            .onFailure { if (it is CancellationException) throw it }
            .getOrNull()

    /** Flips the favorite of the item behind a card menu; returns the new state, or `null` on failure. */
    suspend fun toggleItemFavorite(itemId: Long): Boolean? =
        runCatching { catalogRepository.toggleFavoriteForPlayback(itemId) }
            .onFailure { if (it is CancellationException) throw it }
            .getOrNull()
            ?.also { refreshQuickLists() }

    fun playOnDevice(deviceId: String, itemId: Long, onSent: () -> Unit) {
        viewModelScope.launch {
            runCatching { playOnAnotherDevice(deviceId, itemId) }
                .onSuccess { sent -> if (sent) onSent() }
                .onFailure { err ->
                    if (err is CancellationException) throw err
                    localState.update {
                        it.copy(errorMessage = formatPlaybackErrorMessage("Lecture sur l'autre appareil impossible", err))
                    }
                }
        }
    }

    private val localState = MutableStateFlow(LiveUiState())

    val playerState: StateFlow<PlayerEngineState> = videoEngine.state

    val pagedChannels: Flow<PagingData<ChannelItem>> = localState
        .combine(settingsRepository.preferencesFlow) { state, _ ->
            CatalogQuery(
                searchQuery = state.searchQuery,
                groupName = state.selectedCategory,
                favoritesOnly = state.favoritesOnly,
                sort = state.sort,
            )
        }
        .distinctUntilChanged()
        .flatMapLatest { query -> catalogRepository.pagedLiveChannels(query) }
        .cachedIn(viewModelScope)

    val uiState: StateFlow<LiveUiState> = combine(
        localState,
        videoEngine.state,
        playbackHealth.brokenChannels,
    ) { state, engineState, brokenMap ->
        state.copy(
            activeChannelTitle = engineState.activeStream?.title ?: state.activeChannelTitle,
            brokenChannels = brokenMap,
            errorMessage = engineState.diagnosis?.userMessage ?: state.errorMessage,
        )
    }.stateIn(
        scope = viewModelScope,
        started = SharingStarted.WhileSubscribed(5_000L),
        initialValue = LiveUiState(),
    )

    init {
        refreshCategoriesAndShelves()
        refreshQuickLists()
    }

    /** Reloads the « Récents » and « Favoris » sections (cheap, capped lists; never the whole catalog). */
    fun refreshQuickLists() {
        viewModelScope.launch {
            val recents = runCatching { catalogRepository.listRecentChannels(RECENT_LIMIT) }
                .onFailure { if (it is CancellationException) throw it }
                .getOrNull()
            val favorites = runCatching { catalogRepository.listFavoriteChannels() }
                .onFailure { if (it is CancellationException) throw it }
                .getOrNull()
            localState.update { state ->
                state.copy(
                    recentChannels = recents?.toImmutableList() ?: state.recentChannels,
                    favoriteChannels = favorites?.take(FAVORITES_LIMIT)?.toImmutableList() ?: state.favoriteChannels,
                )
            }
        }
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

    fun selectCategory(category: String?) {
        localState.update { it.copy(selectedCategory = category, errorMessage = null) }
    }

    fun toggleFavoritesOnly() {
        localState.update { it.copy(favoritesOnly = !it.favoritesOnly) }
    }

    fun selectSort(sort: CatalogSort) {
        localState.update { it.copy(sort = sort) }
    }

    fun updateSearchQuery(query: String) {
        localState.update { it.copy(searchQuery = query) }
    }

    private fun surfaceZapFailure(
        fallback: String,
        err: Throwable? = null,
        channelId: Long? = null,
        channelTitle: String? = null,
        channelNow: String? = null,
    ) {
        val message = if (err != null) formatPlaybackErrorMessage(fallback, err) else fallback
        localState.update { state ->
            state.copy(
                activeChannelId = channelId ?: state.activeChannelId,
                activeChannelTitle = channelTitle ?: state.activeChannelTitle,
                activeChannelNow = channelNow ?: state.activeChannelNow,
                isInlinePlayerVisible = true,
                errorMessage = message,
            )
        }
    }

    fun playChannelInline(channel: ChannelItem) {
        viewModelScope.launch {
            val stream = runCatching { zapToChannelUseCase.byId(channel.id) }
                .getOrElse { err ->
                    if (err is CancellationException) throw err
                    surfaceZapFailure(
                        fallback = AppLanguageState.translate("live.open_channel_error"),
                        err = err,
                        channelId = channel.id,
                        channelTitle = channel.name,
                        channelNow = channel.nowTitle,
                    )
                    return@launch
                }
            if (stream != null) {
                localState.update {
                    it.copy(
                        activeChannelId = channel.id,
                        activeChannelTitle = channel.name,
                        activeChannelNow = channel.nowTitle,
                        isInlinePlayerVisible = true,
                        errorMessage = null,
                    )
                }
                videoEngine.zap(stream)
                refreshQuickLists()
            } else {
                surfaceZapFailure(
                    fallback = AppLanguageState.translate("live.open_channel_error"),
                    channelId = channel.id,
                    channelTitle = channel.name,
                    channelNow = channel.nowTitle,
                )
            }
        }
    }

    fun zapByChannelId(channelId: Long) {
        viewModelScope.launch {
            val stream = runCatching { zapToChannelUseCase.byId(channelId) }
                .getOrElse { err ->
                    if (err is CancellationException) throw err
                    surfaceZapFailure(
                        fallback = AppLanguageState.translate("live.open_channel_error"),
                        err = err,
                        channelId = channelId,
                    )
                    return@launch
                }
            if (stream == null) {
                surfaceZapFailure(
                    fallback = AppLanguageState.translate("live.open_channel_error"),
                    channelId = channelId,
                )
                return@launch
            }
            val channel = runCatching { catalogRepository.getChannelById(channelId) }.getOrNull()
            localState.update {
                it.copy(
                    activeChannelId = channelId,
                    activeChannelTitle = channel?.name ?: stream.title,
                    activeChannelNow = channel?.nowTitle,
                    isInlinePlayerVisible = true,
                    errorMessage = null,
                )
            }
            videoEngine.zap(stream)
        }
    }

    fun retryActiveChannel() {
        val channelId = localState.value.activeChannelId ?: videoEngine.state.value.activeStream?.itemId ?: return
        zapByChannelId(channelId)
    }

    fun zapAdjacent(delta: Int) {
        val currentId = localState.value.activeChannelId
            ?: videoEngine.state.value.activeStream?.itemId
            ?: return
        viewModelScope.launch {
            val stream = runCatching {
                zapToChannelUseCase.adjacent(
                    currentChannelId = currentId,
                    delta = delta,
                    groupName = localState.value.selectedCategory,
                )
            }.getOrElse { err ->
                if (err is CancellationException) throw err
                surfaceZapFailure(
                    fallback = AppLanguageState.translate("live.open_channel_error"),
                    err = err,
                )
                return@launch
            } ?: return@launch
            localState.update {
                it.copy(
                    activeChannelId = stream.itemId,
                    activeChannelTitle = stream.title,
                    isInlinePlayerVisible = true,
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
            val stream = runCatching { zapToChannelUseCase.byNumber(number) }
                .getOrElse { err ->
                    if (err is CancellationException) throw err
                    surfaceZapFailure(
                        fallback = AppLanguageState.translate("live.open_channel_error"),
                        err = err,
                    )
                    return@launch
                }
            if (stream != null) {
                localState.update {
                    it.copy(
                        activeChannelId = stream.itemId,
                        activeChannelTitle = stream.title,
                        isInlinePlayerVisible = true,
                        errorMessage = null,
                    )
                }
                videoEngine.zap(stream)
            } else {
                localState.update {
                    it.copy(errorMessage = "Chaîne $number introuvable")
                }
            }
        }
    }

    fun closeInlinePlayer() {
        videoEngine.stop()
        localState.update {
            it.copy(
                isInlinePlayerVisible = false,
                activeChannelId = null,
                activeChannelTitle = null,
                activeChannelNow = null,
                errorMessage = null,
            )
        }
    }

    fun toggleFavorite(channel: ChannelItem) {
        viewModelScope.launch {
            runCatching { catalogRepository.toggleFavorite(channel.stableHash, "live") }
                .onFailure { err ->
                    if (err is CancellationException) throw err
                    localState.update {
                        it.copy(errorMessage = formatPlaybackErrorMessage("Impossible de modifier les favoris", err))
                    }
                }
        }
    }
}

