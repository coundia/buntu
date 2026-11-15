package com.pcoundia.buntu.feature.live

import androidx.compose.runtime.CompositionLocalProvider
import kotlinx.coroutines.launch
import com.pcoundia.buntu.core.player.VideoAspectMode
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.FilledIconButton
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.automirrored.filled.VolumeOff
import androidx.compose.material.icons.filled.StarBorder
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.Fullscreen
import androidx.compose.material.icons.filled.Cast
import androidx.compose.material.icons.filled.AspectRatio
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.pcoundia.buntu.core.designsystem.BuntuDeviceChoice
import com.pcoundia.buntu.core.designsystem.BuntuItemMenu
import com.pcoundia.buntu.core.designsystem.BuntuItemMenuHost
import com.pcoundia.buntu.core.designsystem.BuntuLoadingState
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.paging.LoadState
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.paging.compose.LazyPagingItems
import androidx.paging.compose.collectAsLazyPagingItems
import com.pcoundia.buntu.core.designsystem.BuntuCategoryChips
import com.pcoundia.buntu.core.designsystem.BuntuChannelCard
import com.pcoundia.buntu.core.designsystem.BuntuEmptyState
import com.pcoundia.buntu.core.designsystem.BuntuErrorBanner
import com.pcoundia.buntu.core.designsystem.BuntuMediaShelf
import com.pcoundia.buntu.core.designsystem.BuntuPalette
import com.pcoundia.buntu.core.designsystem.BuntuPrimaryActionButton
import com.pcoundia.buntu.core.designsystem.BuntuShelfCardData
import com.pcoundia.buntu.core.designsystem.BuntuSortChip
import com.pcoundia.buntu.core.designsystem.LocalBuntuMetrics
import com.pcoundia.buntu.core.designsystem.i18n.rememberAppLanguage
import com.pcoundia.buntu.core.designsystem.i18n.t
import com.pcoundia.buntu.core.domain.model.CatalogSort
import com.pcoundia.buntu.core.domain.model.ChannelItem
import com.pcoundia.buntu.core.domain.model.RecoShelfGroup
import com.pcoundia.buntu.core.player.BuntuVideoSurface
import com.pcoundia.buntu.core.player.PlayerEngineState
import com.pcoundia.buntu.core.player.VideoEngine
import kotlinx.collections.immutable.toImmutableList

/** Opens the « Lire sur un autre appareil » menu for a channel (item id, name); provided by [LiveRoute]. */
private val LocalOpenRemoteMenu = staticCompositionLocalOf<((Long, String) -> Unit)?> { null }

/** What the buttons of the inline player do besides play / pause / fullscreen; provided by [LiveRoute]. */
@Immutable
private class InlinePlayerActions(
    val isFavorite: Boolean,
    val onToggleFavorite: () -> Unit,
    val onPrevious: () -> Unit,
    val onNext: () -> Unit,
    val onPlayElsewhere: () -> Unit,
)

private val LocalInlinePlayerActions = staticCompositionLocalOf<InlinePlayerActions?> { null }

@Composable
fun LiveRoute(
    onOpenFullscreenPlayer: (Long) -> Unit,
    onOpenSources: () -> Unit,
    onOpenSearch: () -> Unit = {},
    viewModel: LiveViewModel = hiltViewModel(),
) {
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val playerState by viewModel.playerState.collectAsStateWithLifecycle()
    val pagedChannels = viewModel.pagedChannels.collectAsLazyPagingItems()
    val metrics = LocalBuntuMetrics.current
    @Suppress("UNUSED_VARIABLE")
    val currentLanguage = rememberAppLanguage()
    val remoteDevices by viewModel.remoteDevices.collectAsStateWithLifecycle()
    val remoteStatus by viewModel.remoteStatus.collectAsStateWithLifecycle()
    var itemMenu by remember { mutableStateOf<BuntuItemMenu?>(null) }
    val openRemoteMenu: (Long, String) -> Unit = { itemId, title ->
        itemMenu = BuntuItemMenu(
            title = title,
            itemId = itemId,
            isFavorite = { viewModel.isItemFavorite(itemId) },
            toggleFavorite = { viewModel.toggleItemFavorite(itemId) },
        )
    }

    BuntuItemMenuHost(
        menu = itemMenu,
        devices = remember(remoteDevices) {
            remoteDevices.map { BuntuDeviceChoice(it.id, it.name, it.deviceType) }.toImmutableList()
        },
        status = remoteStatus,
        onOpenDevices = viewModel::openRemoteMenu,
        onPlayOnDevice = viewModel::playOnDevice,
        onDismiss = { itemMenu = null },
    )

    // Favorite state of the channel being played (the player buttons need it).
    val activeChannelId = state.activeChannelId ?: playerState.activeStream?.itemId
    var activeFavorite by remember { mutableStateOf(false) }
    LaunchedEffect(activeChannelId) {
        activeFavorite = activeChannelId?.let { viewModel.isItemFavorite(it) } == true
    }
    val scope = rememberCoroutineScope()
    val inlineActions = InlinePlayerActions(
        isFavorite = activeFavorite,
        onToggleFavorite = {
            val id = activeChannelId
            if (id != null) scope.launch { viewModel.toggleItemFavorite(id)?.let { activeFavorite = it } }
        },
        onPrevious = { viewModel.zapAdjacent(-1) },
        onNext = { viewModel.zapAdjacent(+1) },
        onPlayElsewhere = {
            val id = activeChannelId
            if (id != null) {
                itemMenu = BuntuItemMenu(
                    title = state.activeChannelTitle ?: playerState.activeStream?.title.orEmpty(),
                    itemId = id,
                    startOnDevices = true,
                )
            }
        },
    )

    CompositionLocalProvider(
        LocalOpenRemoteMenu provides openRemoteMenu,
        LocalInlinePlayerActions provides inlineActions,
    ) {
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(BuntuPalette.Midnight)
            .onPreviewKeyEvent { event ->
                if (event.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                when (event.key) {
                    Key.ChannelUp -> {
                        viewModel.zapAdjacent(-1)
                        true
                    }
                    Key.ChannelDown -> {
                        viewModel.zapAdjacent(+1)
                        true
                    }
                    Key.Zero, Key.NumPad0 -> { viewModel.appendChannelDigit('0'); true }
                    Key.One, Key.NumPad1 -> { viewModel.appendChannelDigit('1'); true }
                    Key.Two, Key.NumPad2 -> { viewModel.appendChannelDigit('2'); true }
                    Key.Three, Key.NumPad3 -> { viewModel.appendChannelDigit('3'); true }
                    Key.Four, Key.NumPad4 -> { viewModel.appendChannelDigit('4'); true }
                    Key.Five, Key.NumPad5 -> { viewModel.appendChannelDigit('5'); true }
                    Key.Six, Key.NumPad6 -> { viewModel.appendChannelDigit('6'); true }
                    Key.Seven, Key.NumPad7 -> { viewModel.appendChannelDigit('7'); true }
                    Key.Eight, Key.NumPad8 -> { viewModel.appendChannelDigit('8'); true }
                    Key.Nine, Key.NumPad9 -> { viewModel.appendChannelDigit('9'); true }
                    Key.Enter, Key.NumPadEnter -> {
                        if (state.numericBuffer.isNotEmpty()) {
                            viewModel.confirmNumericZap()
                            true
                        } else {
                            false
                        }
                    }
                    else -> false
                }
            },
    ) {
        if (metrics.isTv || metrics.posterGridMinCell >= 140.dp) {
            ExpandedOrTvLiveLayout(
                state = state,
                playerState = playerState,
                pagedChannels = pagedChannels,
                videoEngine = viewModel.videoEngine,
                onSelectCategory = viewModel::selectCategory,
                onToggleFavorites = viewModel::toggleFavoritesOnly,
                onUpdateSearch = viewModel::updateSearchQuery,
                onSelectSort = viewModel::selectSort,
                onChannelClick = { channel ->
                    if (metrics.isTv && state.activeChannelId == channel.id) {
                        onOpenFullscreenPlayer(channel.id)
                    } else {
                        viewModel.playChannelInline(channel)
                    }
                },
                onZapCardId = viewModel::zapByChannelId,
                onOpenFullscreen = {
                    val targetId = state.activeChannelId ?: playerState.activeStream?.itemId
                    if (targetId != null) onOpenFullscreenPlayer(targetId)
                },
                onClosePlayer = viewModel::closeInlinePlayer,
                onRetryPlayer = viewModel::retryActiveChannel,
                onOpenSources = onOpenSources,
                onOpenSearch = onOpenSearch,
            )
        } else {
            CompactLiveLayout(
                state = state,
                playerState = playerState,
                pagedChannels = pagedChannels,
                videoEngine = viewModel.videoEngine,
                onSelectCategory = viewModel::selectCategory,
                onToggleFavorites = viewModel::toggleFavoritesOnly,
                onUpdateSearch = viewModel::updateSearchQuery,
                onSelectSort = viewModel::selectSort,
                onChannelClick = { channel ->
                    viewModel.playChannelInline(channel)
                },
                onZapCardId = viewModel::zapByChannelId,
                onOpenFullscreen = {
                    val targetId = state.activeChannelId ?: playerState.activeStream?.itemId
                    if (targetId != null) onOpenFullscreenPlayer(targetId)
                },
                onClosePlayer = viewModel::closeInlinePlayer,
                onRetryPlayer = viewModel::retryActiveChannel,
                onOpenSources = onOpenSources,
                onOpenSearch = onOpenSearch,
            )
        }

        if (state.numericBuffer.isNotEmpty()) {
            Surface(
                color = BuntuPalette.Midnight.copy(alpha = 0.92f),
                shape = RoundedCornerShape(12.dp),
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .padding(metrics.spacingXL),
            ) {
                Text(
                    text = t("live.numeric_zap", state.numericBuffer),
                    style = MaterialTheme.typography.headlineMedium,
                    color = BuntuPalette.TerangaGold,
                    fontWeight = FontWeight.Bold,
                    modifier = Modifier.padding(horizontal = 20.dp, vertical = 12.dp),
                )
            }
        }
    }
    }
}

@Composable
private fun CompactLiveLayout(
    state: LiveUiState,
    playerState: PlayerEngineState,
    pagedChannels: LazyPagingItems<ChannelItem>,
    videoEngine: VideoEngine,
    onSelectCategory: (String?) -> Unit,
    onToggleFavorites: () -> Unit,
    onUpdateSearch: (String) -> Unit,
    onSelectSort: (CatalogSort) -> Unit,
    onChannelClick: (ChannelItem) -> Unit,
    onZapCardId: (Long) -> Unit,
    onOpenFullscreen: () -> Unit,
    onClosePlayer: () -> Unit,
    onRetryPlayer: () -> Unit,
    onOpenSources: () -> Unit,
    onOpenSearch: () -> Unit,
) {
    val metrics = LocalBuntuMetrics.current
    val inlineErrorMessage = playerState.diagnosis?.userMessage ?: state.errorMessage
    val showInlinePlayer = state.isInlinePlayerVisible &&
        (playerState.activeStream != null || inlineErrorMessage != null)

    Column(modifier = Modifier.fillMaxSize()) {
        // Search, favorites and categories first and always visible (outside the scrolling list).
        LiveSearchBar(
            searchQuery = state.searchQuery,
            onUpdateSearch = onUpdateSearch,
            onOpenSearch = onOpenSearch,
        )
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(metrics.spacingS),
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = metrics.horizontalScreenPadding),
        ) {
            FavoritesFilterChip(favoritesOnly = state.favoritesOnly, onToggle = onToggleFavorites)
            LiveSortChip(sort = state.sort, onSelectSort = onSelectSort)
            BuntuCategoryChips(
                categories = state.categories,
                selectedCategory = state.selectedCategory,
                onSelectCategory = onSelectCategory,
                modifier = Modifier.weight(1f),
                phoneHorizontalPadding = 0.dp,
            )
        }
        // Inline live player is hidden until the user explicitly clicks a channel / media
        if (showInlinePlayer) {
            InlineLivePlayerCard(
                title = state.activeChannelTitle ?: t("live.inline_default_title"),
                subtitle = state.activeChannelNow,
                playerState = playerState,
                videoEngine = videoEngine,
                errorMessage = inlineErrorMessage,
                onRetry = if (state.activeChannelId != null || playerState.activeStream != null) onRetryPlayer else null,
                onOpenFullscreen = onOpenFullscreen,
                onClosePlayer = onClosePlayer,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(
                        horizontal = metrics.horizontalScreenPadding,
                        vertical = metrics.spacingS,
                    ),
            )
        }

        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(bottom = metrics.verticalScreenPadding),
            verticalArrangement = Arrangement.spacedBy(metrics.spacingS),
        ) {
            // Order: recents, favorites, suggestions, then every channel. The quick sections only show on the
            // unfiltered list (a search, a category or the favorites filter already narrows the list).
            val isUnfiltered = state.searchQuery.isBlank() && state.selectedCategory == null && !state.favoritesOnly
            if (isUnfiltered && state.recentChannels.isNotEmpty()) {
                item(key = "recent_header", contentType = "section_header") {
                    LiveSectionHeader(t("live.recent_title"))
                }
                items(
                    count = state.recentChannels.size,
                    key = { idx -> "recent_${state.recentChannels[idx].id}" },
                    contentType = { "channel_row" },
                ) { idx ->
                    val channel = state.recentChannels[idx]
                    Box(modifier = Modifier.padding(horizontal = metrics.horizontalScreenPadding)) {
                        ChannelRowWithStatusBadge(
                            channel = channel,
                            isSelected = channel.id == state.activeChannelId,
                            isBrokenOverride = state.brokenChannels[channel.stableHash],
                            onClick = { onChannelClick(channel) },
                        )
                    }
                }
            }
            if (isUnfiltered && state.favoriteChannels.isNotEmpty()) {
                item(key = "favorites_header", contentType = "section_header") {
                    LiveSectionHeader(t("live.favorites_title"))
                }
                items(
                    count = state.favoriteChannels.size,
                    key = { idx -> "favorite_${state.favoriteChannels[idx].id}" },
                    contentType = { "channel_row" },
                ) { idx ->
                    val channel = state.favoriteChannels[idx]
                    Box(modifier = Modifier.padding(horizontal = metrics.horizontalScreenPadding)) {
                        ChannelRowWithStatusBadge(
                            channel = channel,
                            isSelected = channel.id == state.activeChannelId,
                            isBrokenOverride = state.brokenChannels[channel.stableHash],
                            onClick = { onChannelClick(channel) },
                        )
                    }
                }
            }

            // Live TV recommendations
            if (state.liveShelves.isNotEmpty()) {
                items(
                    count = state.liveShelves.size,
                    key = { idx -> "live_reco_${state.liveShelves[idx].id}" },
                    contentType = { "live_reco_shelf" },
                ) { idx ->
                    LiveRecoShelfSection(
                        shelf = state.liveShelves[idx],
                        onSelectChannelId = onZapCardId,
                    )
                }
            }

            if (isUnfiltered && (state.recentChannels.isNotEmpty() || state.favoriteChannels.isNotEmpty())) {
                item(key = "all_header", contentType = "section_header") {
                    LiveSectionHeader(t("live.all_channels_title"))
                }
            }

            if (!showInlinePlayer) {
                inlineErrorMessage?.let { err ->
                    item(key = "live_error", contentType = "error_banner") {
                        Box(modifier = Modifier.padding(horizontal = metrics.horizontalScreenPadding)) {
                            BuntuErrorBanner(
                                message = err,
                                actionLabel = if (state.activeChannelId != null) t("common.retry") else null,
                                onAction = if (state.activeChannelId != null) onRetryPlayer else null,
                            )
                        }
                    }
                }
            }

            val refreshState = pagedChannels.loadState.refresh
            if (pagedChannels.itemCount == 0) {
                when (refreshState) {
                    is LoadState.Loading -> {
                        item(key = "loading_live", contentType = "loading_state") {
                            BuntuLoadingState(label = t("common.loading"))
                        }
                    }
                    is LoadState.Error -> {
                        item(key = "error_live", contentType = "error_state") {
                            Box(modifier = Modifier.padding(horizontal = metrics.horizontalScreenPadding)) {
                                BuntuErrorBanner(
                                    message = refreshState.error.localizedMessage ?: t("live.empty_subtitle"),
                                    actionLabel = t("common.retry"),
                                    onAction = { pagedChannels.retry() },
                                )
                            }
                        }
                    }
                    is LoadState.NotLoading -> {
                        item(key = "empty_live", contentType = "empty_state") {
                            BuntuEmptyState(
                                title = t("live.empty_title"),
                                subtitle = t("live.empty_subtitle"),
                                actionLabel = t("live.manage_sources"),
                                onAction = onOpenSources,
                            )
                        }
                    }
                }
            } else {
                items(
                    count = pagedChannels.itemCount,
                    key = { index -> pagedChannels.peek(index)?.id ?: (-1L - index) },
                    contentType = { "channel_row" },
                ) { index ->
                    val channel = pagedChannels[index] ?: return@items
                    Box(modifier = Modifier.padding(horizontal = metrics.horizontalScreenPadding)) {
                        ChannelRowWithStatusBadge(
                            channel = channel,
                            isSelected = channel.id == state.activeChannelId,
                            isBrokenOverride = state.brokenChannels[channel.stableHash],
                            onClick = { onChannelClick(channel) },
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun ExpandedOrTvLiveLayout(
    state: LiveUiState,
    playerState: PlayerEngineState,
    pagedChannels: LazyPagingItems<ChannelItem>,
    videoEngine: VideoEngine,
    onSelectCategory: (String?) -> Unit,
    onToggleFavorites: () -> Unit,
    onUpdateSearch: (String) -> Unit,
    onSelectSort: (CatalogSort) -> Unit,
    onChannelClick: (ChannelItem) -> Unit,
    onZapCardId: (Long) -> Unit,
    onOpenFullscreen: () -> Unit,
    onClosePlayer: () -> Unit,
    onRetryPlayer: () -> Unit,
    onOpenSources: () -> Unit,
    onOpenSearch: () -> Unit,
) {
    val metrics = LocalBuntuMetrics.current
    val inlineErrorMessage = playerState.diagnosis?.userMessage ?: state.errorMessage
    val showInlinePlayer = state.isInlinePlayerVisible &&
        (playerState.activeStream != null || inlineErrorMessage != null)

    val channelColumnContent: @Composable (includeShelves: Boolean, modifier: Modifier) -> Unit =
        { includeShelves, colModifier ->
            Column(
                modifier = colModifier,
                verticalArrangement = Arrangement.spacedBy(metrics.spacingS),
            ) {
                LiveFilterToolbar(
                    categories = state.categories,
                    selectedCategory = state.selectedCategory,
                    favoritesOnly = state.favoritesOnly,
                    searchQuery = state.searchQuery,
                    sort = state.sort,
                    onSelectCategory = onSelectCategory,
                    onToggleFavorites = onToggleFavorites,
                    onUpdateSearch = onUpdateSearch,
                    onSelectSort = onSelectSort,
                    onOpenSearch = onOpenSearch,
                    compactPadding = true,
                )

                LazyColumn(
                    modifier = Modifier.fillMaxSize(),
                    verticalArrangement = Arrangement.spacedBy(metrics.spacingS),
                ) {
                    if (includeShelves) {
                        inlineErrorMessage?.let { err ->
                            item(key = "tv_full_error", contentType = "error_banner") {
                                BuntuErrorBanner(
                                    message = err,
                                    actionLabel = if (state.activeChannelId != null) t("common.retry") else null,
                                    onAction = if (state.activeChannelId != null) onRetryPlayer else null,
                                )
                            }
                        }
                        if (state.liveShelves.isNotEmpty()) {
                            items(
                                count = state.liveShelves.size,
                                key = { idx -> "tv_full_reco_${state.liveShelves[idx].id}" },
                                contentType = { "live_reco_shelf" },
                            ) { idx ->
                                LiveRecoShelfSection(
                                    shelf = state.liveShelves[idx],
                                    onSelectChannelId = onZapCardId,
                                )
                            }
                        }
                    }

                    val refreshState = pagedChannels.loadState.refresh
                    if (pagedChannels.itemCount == 0) {
                        when (refreshState) {
                            is LoadState.Loading -> {
                                item(key = "tv_loading_live", contentType = "loading_state") {
                                    BuntuLoadingState(label = t("common.loading"))
                                }
                            }
                            is LoadState.Error -> {
                                item(key = "tv_error_live", contentType = "error_state") {
                                    BuntuErrorBanner(
                                        message = refreshState.error.localizedMessage ?: t("live.tv_empty_subtitle"),
                                        actionLabel = t("common.retry"),
                                        onAction = { pagedChannels.retry() },
                                    )
                                }
                            }
                            is LoadState.NotLoading -> {
                                item(key = "tv_empty_live", contentType = "empty_state") {
                                    BuntuEmptyState(
                                        title = t("live.tv_empty_title"),
                                        subtitle = t("live.tv_empty_subtitle"),
                                        actionLabel = t("live.tv_sources_action"),
                                        onAction = onOpenSources,
                                    )
                                }
                            }
                        }
                    } else {
                        items(
                            count = pagedChannels.itemCount,
                            key = { index -> pagedChannels.peek(index)?.id ?: (-1L - index) },
                            contentType = { "channel_row" },
                        ) { index ->
                            val channel = pagedChannels[index] ?: return@items
                            ChannelRowWithStatusBadge(
                                channel = channel,
                                isSelected = channel.id == state.activeChannelId,
                                isBrokenOverride = state.brokenChannels[channel.stableHash],
                                onClick = { onChannelClick(channel) },
                            )
                        }
                    }
                }
            }
        }

    if (!showInlinePlayer) {
        channelColumnContent(
            true,
            Modifier
                .fillMaxSize()
                .padding(
                    horizontal = metrics.horizontalScreenPadding,
                    vertical = metrics.verticalScreenPadding,
                ),
        )
        return
    }

    Row(
        modifier = Modifier
            .fillMaxSize()
            .padding(
                horizontal = metrics.horizontalScreenPadding,
                vertical = metrics.verticalScreenPadding,
            ),
        horizontalArrangement = Arrangement.spacedBy(metrics.spacingL),
    ) {
        // Left column: filter + virtualized channel list
        channelColumnContent(
            false,
            Modifier
                .weight(0.45f)
                .fillMaxHeight(),
        )

        // Right column: inline player + Live TV recommendations directly below it
        LazyColumn(
            modifier = Modifier
                .weight(0.55f)
                .fillMaxHeight(),
            verticalArrangement = Arrangement.spacedBy(metrics.spacingM),
        ) {
            item(key = "tv_inline_player", contentType = "inline_player") {
                InlineLivePlayerCard(
                    title = state.activeChannelTitle ?: t("live.select_channel"),
                    subtitle = state.activeChannelNow,
                    playerState = playerState,
                    videoEngine = videoEngine,
                    errorMessage = inlineErrorMessage,
                    onRetry = if (state.activeChannelId != null || playerState.activeStream != null) onRetryPlayer else null,
                    onOpenFullscreen = onOpenFullscreen,
                    onClosePlayer = onClosePlayer,
                    modifier = Modifier.fillMaxWidth(),
                )
            }

            items(
                count = state.liveShelves.size,
                key = { idx -> "tv_live_reco_${state.liveShelves[idx].id}" },
                contentType = { "live_reco_shelf" },
            ) { idx ->
                LiveRecoShelfSection(
                    shelf = state.liveShelves[idx],
                    onSelectChannelId = onZapCardId,
                )
            }
        }
    }
}

@Composable
private fun InlineLivePlayerCard(
    title: String,
    subtitle: String?,
    playerState: PlayerEngineState,
    videoEngine: VideoEngine,
    errorMessage: String? = null,
    onRetry: (() -> Unit)? = null,
    onOpenFullscreen: () -> Unit,
    onClosePlayer: () -> Unit = {},
    modifier: Modifier = Modifier,
) {
    val metrics = LocalBuntuMetrics.current
    val controlsVisible = playerState.activeStream != null && errorMessage == null
    Surface(
        color = BuntuPalette.Slate,
        shape = RoundedCornerShape(16.dp),
        modifier = modifier,
    ) {
        Column {
            if (errorMessage != null) {
                Box(
                    contentAlignment = Alignment.Center,
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(topStart = 16.dp, topEnd = 16.dp))
                        .background(BuntuPalette.Midnight)
                        .padding(metrics.spacingM),
                ) {
                    BuntuErrorBanner(
                        message = errorMessage,
                        actionLabel = if (onRetry != null) t("common.retry") else null,
                        onAction = onRetry,
                        secondaryActionLabel = t("live.close_player"),
                        onSecondaryAction = onClosePlayer,
                    )
                }
            } else {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .aspectRatio(16f / 9f)
                        .clip(RoundedCornerShape(topStart = 16.dp, topEnd = 16.dp))
                        .background(BuntuPalette.Midnight),
                    contentAlignment = Alignment.Center,
                ) {
                    if (playerState.activeStream != null) {
                        BuntuVideoSurface(
                            videoEngine = videoEngine,
                            modifier = Modifier.fillMaxSize(),
                        )
                    } else {
                        Text(
                            text = title,
                            style = MaterialTheme.typography.titleMedium,
                            color = BuntuPalette.MutedSilver,
                        )
                    }
                }
            }
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(metrics.spacingM),
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = title,
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.Bold,
                        color = BuntuPalette.PureWhite,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    if (!subtitle.isNullOrBlank()) {
                        Text(
                            text = subtitle,
                            style = MaterialTheme.typography.bodySmall,
                            color = BuntuPalette.LeerCyan,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
                if (controlsVisible) {
                    PlayerIconButton(
                        icon = Icons.Filled.AspectRatio,
                        description = t("live.aspect"),
                        onClick = {
                            val modes = VideoAspectMode.entries
                            videoEngine.setAspectMode(modes[(playerState.aspectMode.ordinal + 1) % modes.size])
                        },
                    )
                    PlayerIconButton(
                        icon = Icons.Default.Close,
                        description = t("live.close_player"),
                        onClick = onClosePlayer,
                    )
                }
            }
            if (controlsVisible) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceEvenly,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(start = metrics.spacingS, end = metrics.spacingS, bottom = metrics.spacingM),
                ) {
                    val actions = LocalInlinePlayerActions.current
                    if (actions != null) {
                        PlayerIconButton(
                            icon = Icons.Filled.SkipPrevious,
                            description = t("live.previous_channel"),
                            onClick = actions.onPrevious,
                        )
                    }
                    FilledIconButton(
                        onClick = { videoEngine.togglePlayPause() },
                        colors = IconButtonDefaults.filledIconButtonColors(
                            containerColor = BuntuPalette.TerangaGold,
                            contentColor = BuntuPalette.Midnight,
                        ),
                        modifier = Modifier.size(52.dp),
                    ) {
                        Icon(
                            imageVector = if (playerState.isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow,
                            contentDescription = if (playerState.isPlaying) t("live.pause") else t("live.play"),
                            modifier = Modifier.size(30.dp),
                        )
                    }
                    if (actions != null) {
                        PlayerIconButton(
                            icon = Icons.Filled.SkipNext,
                            description = t("live.next_channel"),
                            onClick = actions.onNext,
                        )
                    }
                    PlayerIconButton(
                        icon = if (playerState.isMuted) Icons.AutoMirrored.Filled.VolumeOff else Icons.AutoMirrored.Filled.VolumeUp,
                        description = if (playerState.isMuted) t("live.unmute") else t("live.mute"),
                        onClick = { videoEngine.setMuted(!playerState.isMuted) },
                    )
                    if (actions != null) {
                        PlayerIconButton(
                            icon = if (actions.isFavorite) Icons.Filled.Star else Icons.Filled.StarBorder,
                            description = t(if (actions.isFavorite) "item_menu.favorite_remove" else "item_menu.favorite_add"),
                            tint = if (actions.isFavorite) BuntuPalette.TerangaGold else BuntuPalette.PureWhite,
                            onClick = actions.onToggleFavorite,
                        )
                        PlayerIconButton(
                            icon = Icons.Filled.Cast,
                            description = t("item_menu.play_elsewhere"),
                            onClick = actions.onPlayElsewhere,
                        )
                    }
                    PlayerIconButton(
                        icon = Icons.Filled.Fullscreen,
                        description = t("live.fullscreen"),
                        onClick = onOpenFullscreen,
                    )
                }
            }
        }
    }
}

@Composable
private fun PlayerIconButton(
    icon: ImageVector,
    description: String,
    onClick: () -> Unit,
    tint: Color = BuntuPalette.PureWhite,
) {
    IconButton(onClick = onClick) {
        Icon(imageVector = icon, contentDescription = description, tint = tint)
    }
}

@Composable
private fun LiveSectionHeader(title: String) {
    val metrics = LocalBuntuMetrics.current
    Text(
        text = title,
        style = MaterialTheme.typography.titleMedium,
        fontWeight = FontWeight.Bold,
        color = BuntuPalette.PureWhite,
        modifier = Modifier.padding(
            start = metrics.horizontalScreenPadding,
            end = metrics.horizontalScreenPadding,
            top = metrics.spacingS,
        ),
    )
}

@Composable
private fun FavoritesFilterChip(favoritesOnly: Boolean, onToggle: () -> Unit) {
    FilterChip(
        selected = favoritesOnly,
        onClick = onToggle,
        label = { Text(t("live.favorites")) },
        colors = FilterChipDefaults.filterChipColors(
            selectedContainerColor = BuntuPalette.TerangaGold,
            selectedLabelColor = BuntuPalette.Midnight,
        ),
    )
}

/**
 * Search form pinned at the top of the Live screen on phone: a field that filters the channel list as
 * the user types, and a gold call-to-action that opens the full search.
 */
@Composable
private fun LiveSearchBar(
    searchQuery: String,
    onUpdateSearch: (String) -> Unit,
    onOpenSearch: () -> Unit,
) {
    val metrics = LocalBuntuMetrics.current
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(metrics.spacingS),
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = metrics.horizontalScreenPadding, vertical = metrics.spacingS),
    ) {
        OutlinedTextField(
            value = searchQuery,
            onValueChange = onUpdateSearch,
            placeholder = {
                Text(
                    text = t("live.filter_placeholder"),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            },
            leadingIcon = { Icon(imageVector = Icons.Default.Search, contentDescription = null) },
            trailingIcon = {
                if (searchQuery.isNotEmpty()) {
                    IconButton(onClick = { onUpdateSearch("") }) {
                        Icon(imageVector = Icons.Default.Close, contentDescription = t("common.close"))
                    }
                }
            },
            singleLine = true,
            modifier = Modifier.weight(1f),
        )
        Button(
            onClick = onOpenSearch,
            colors = ButtonDefaults.buttonColors(
                containerColor = BuntuPalette.TerangaGold,
                contentColor = BuntuPalette.Midnight,
            ),
            modifier = Modifier.defaultMinSize(minHeight = metrics.minTouchTarget),
        ) {
            Text(text = t("live.search"), fontWeight = FontWeight.Bold, maxLines = 1)
        }
    }
}

@Composable
private fun LiveSortChip(sort: CatalogSort, onSelectSort: (CatalogSort) -> Unit) {
    BuntuSortChip(
        selected = sort,
        options = listOf(
            CatalogSort.DEFAULT to t("live.sort_number"),
            CatalogSort.NUMBER_DESC to t("live.sort_number_desc"),
            CatalogSort.NAME_ASC to t("common.sort_name_asc"),
            CatalogSort.NAME_DESC to t("common.sort_name_desc"),
            CatalogSort.RECENTLY_ADDED to t("common.sort_recently_added"),
            CatalogSort.OLDEST_ADDED to t("common.sort_oldest_added"),
        ),
        onSelection = onSelectSort,
    )
}

@Composable
private fun LiveFilterToolbar(
    categories: kotlinx.collections.immutable.ImmutableList<String>,
    selectedCategory: String?,
    favoritesOnly: Boolean,
    searchQuery: String,
    sort: CatalogSort,
    onSelectCategory: (String?) -> Unit,
    onToggleFavorites: () -> Unit,
    onUpdateSearch: (String) -> Unit,
    onSelectSort: (CatalogSort) -> Unit,
    onOpenSearch: () -> Unit,
    compactPadding: Boolean = false,
) {
    val metrics = LocalBuntuMetrics.current
    val horizontalPad = if (compactPadding) 0.dp else metrics.horizontalScreenPadding

    Column(verticalArrangement = Arrangement.spacedBy(metrics.spacingS)) {
        BoxWithConstraints(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = horizontalPad),
        ) {
            val isWide = maxWidth >= 520.dp
            val filterField = @Composable { fieldModifier: Modifier ->
                OutlinedTextField(
                    value = searchQuery,
                    onValueChange = onUpdateSearch,
                    placeholder = {
                        Text(
                            text = t("live.filter_placeholder"),
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    },
                    singleLine = true,
                    modifier = fieldModifier,
                )
            }
            val actionChips = @Composable {
                Row(horizontalArrangement = Arrangement.spacedBy(metrics.spacingS)) {
                    FilterChip(
                        selected = false,
                        onClick = onOpenSearch,
                        leadingIcon = {
                            Icon(
                                imageVector = Icons.Default.Search,
                                contentDescription = null,
                                modifier = Modifier.size(FilterChipDefaults.IconSize),
                            )
                        },
                        label = { Text(t("live.search")) },
                    )
                    FavoritesFilterChip(favoritesOnly = favoritesOnly, onToggle = onToggleFavorites)
                    LiveSortChip(sort = sort, onSelectSort = onSelectSort)
                }
            }
            if (isWide) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(metrics.spacingS),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    filterField(Modifier.weight(1f))
                    actionChips()
                }
            } else {
                Column(
                    verticalArrangement = Arrangement.spacedBy(metrics.spacingS),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    filterField(Modifier.fillMaxWidth())
                    actionChips()
                }
            }
        }
        BuntuCategoryChips(
            categories = categories,
            selectedCategory = selectedCategory,
            onSelectCategory = onSelectCategory,
        )
    }
}

@Composable
private fun ChannelRowWithStatusBadge(
    channel: ChannelItem,
    isSelected: Boolean,
    isBrokenOverride: Boolean? = null,
    onClick: () -> Unit,
) {
    val openRemoteMenu = LocalOpenRemoteMenu.current
    val isBroken = isBrokenOverride ?: channel.isBroken
    Box(modifier = Modifier.fillMaxWidth()) {
        BuntuChannelCard(
            name = channel.name,
            logoUrl = channel.logoUrl,
            channelNumber = channel.channelNumber,
            nowTitle = channel.nowTitle,
            nextTitle = channel.nextTitle,
            nowProgress = channel.nowProgress,
            isFavorite = channel.isFavorite,
            isSelected = isSelected,
            onClick = onClick,
            onLongClick = openRemoteMenu?.let { open -> { open(channel.id, channel.name) } },
        )
        // Concise outage badge (never verbose!)
        if (isBroken) {
            Surface(
                color = BuntuPalette.DangerRed.copy(alpha = 0.9f),
                shape = RoundedCornerShape(6.dp),
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .padding(6.dp),
            ) {
                Text(
                    text = t("live.outage_badge"),
                    style = MaterialTheme.typography.labelSmall,
                    fontWeight = FontWeight.Bold,
                    color = BuntuPalette.PureWhite,
                    modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp),
                )
            }
        }
    }
}

@Composable
private fun LiveRecoShelfSection(
    shelf: RecoShelfGroup,
    onSelectChannelId: (Long) -> Unit,
) {
    val openRemoteMenu = LocalOpenRemoteMenu.current
    val liveBadge = t("live.badge")
    val shelfCards = remember(shelf.cards, liveBadge) {
        shelf.cards.map { card ->
            BuntuShelfCardData(
                key = card.stableHash,
                title = card.title,
                subtitle = card.subtitle ?: card.reasonLabel,
                badge = liveBadge,
                posterUrl = card.posterUrl,
            )
        }.toImmutableList()
    }
    BuntuMediaShelf(
        title = shelf.title,
        subtitle = shelf.refinedByAi.takeIf { it.isNotBlank() && it != "local" },
        cards = shelfCards,
        onCardClick = { clicked ->
            val match = shelf.cards.firstOrNull { it.stableHash == clicked.key }
            match?.itemId?.let(onSelectChannelId)
        },
        onCardLongClick = openRemoteMenu?.let { open ->
            { clicked: BuntuShelfCardData ->
                shelf.cards.firstOrNull { it.stableHash == clicked.key }?.itemId?.let { open(it, clicked.title) }
            }
        },
    )
}

