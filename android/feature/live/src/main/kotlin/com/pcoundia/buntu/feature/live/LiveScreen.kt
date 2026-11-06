package com.pcoundia.buntu.feature.live

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
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
import com.pcoundia.buntu.core.designsystem.LocalBuntuMetrics
import com.pcoundia.buntu.core.domain.model.ChannelItem
import com.pcoundia.buntu.core.domain.model.RecoShelfGroup
import com.pcoundia.buntu.core.player.BuntuVideoSurface
import com.pcoundia.buntu.core.player.PlayerEngineState
import com.pcoundia.buntu.core.player.VideoEngine
import kotlinx.collections.immutable.toImmutableList

@Composable
fun LiveRoute(
    onOpenFullscreenPlayer: (Long) -> Unit,
    onOpenSources: () -> Unit,
    viewModel: LiveViewModel = hiltViewModel(),
) {
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val playerState by viewModel.playerState.collectAsStateWithLifecycle()
    val pagedChannels = viewModel.pagedChannels.collectAsLazyPagingItems()
    val metrics = LocalBuntuMetrics.current

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
                onOpenSources = onOpenSources,
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
                onChannelClick = { channel ->
                    viewModel.playChannelInline(channel)
                },
                onZapCardId = viewModel::zapByChannelId,
                onOpenFullscreen = {
                    val targetId = state.activeChannelId ?: playerState.activeStream?.itemId
                    if (targetId != null) onOpenFullscreenPlayer(targetId)
                },
                onOpenSources = onOpenSources,
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
                    text = "Chaîne ${state.numericBuffer} ⏎",
                    style = MaterialTheme.typography.headlineMedium,
                    color = BuntuPalette.TerangaGold,
                    fontWeight = FontWeight.Bold,
                    modifier = Modifier.padding(horizontal = 20.dp, vertical = 12.dp),
                )
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
    onChannelClick: (ChannelItem) -> Unit,
    onZapCardId: (Long) -> Unit,
    onOpenFullscreen: () -> Unit,
    onOpenSources: () -> Unit,
) {
    val metrics = LocalBuntuMetrics.current

    Column(modifier = Modifier.fillMaxSize()) {
        // Inline live player at top of phone view
        if (playerState.activeStream != null || state.activeChannelId != null) {
            InlineLivePlayerCard(
                title = state.activeChannelTitle ?: "TV en direct",
                subtitle = state.activeChannelNow,
                playerState = playerState,
                videoEngine = videoEngine,
                onOpenFullscreen = onOpenFullscreen,
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
            // Live TV recommendations immediately below the player when watching a channel
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

            item(key = "filters", contentType = "live_filters") {
                LiveFilterToolbar(
                    categories = state.categories,
                    selectedCategory = state.selectedCategory,
                    favoritesOnly = state.favoritesOnly,
                    searchQuery = state.searchQuery,
                    onSelectCategory = onSelectCategory,
                    onToggleFavorites = onToggleFavorites,
                    onUpdateSearch = onUpdateSearch,
                )
            }

            state.errorMessage?.let { err ->
                item(key = "live_error", contentType = "error_banner") {
                    Box(modifier = Modifier.padding(horizontal = metrics.horizontalScreenPadding)) {
                        BuntuErrorBanner(message = err)
                    }
                }
            }

            if (pagedChannels.itemCount == 0) {
                item(key = "empty_live", contentType = "empty_state") {
                    BuntuEmptyState(
                        title = "Aucune chaîne disponible",
                        subtitle = "Synchronisez votre source IPTV ou modifiez vos filtres.",
                        actionLabel = "Gérer les sources",
                        onAction = onOpenSources,
                    )
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
    onChannelClick: (ChannelItem) -> Unit,
    onZapCardId: (Long) -> Unit,
    onOpenFullscreen: () -> Unit,
    onOpenSources: () -> Unit,
) {
    val metrics = LocalBuntuMetrics.current

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
        Column(
            modifier = Modifier
                .weight(0.45f)
                .fillMaxHeight(),
            verticalArrangement = Arrangement.spacedBy(metrics.spacingS),
        ) {
            LiveFilterToolbar(
                categories = state.categories,
                selectedCategory = state.selectedCategory,
                favoritesOnly = state.favoritesOnly,
                searchQuery = state.searchQuery,
                onSelectCategory = onSelectCategory,
                onToggleFavorites = onToggleFavorites,
                onUpdateSearch = onUpdateSearch,
                compactPadding = true,
            )

            if (pagedChannels.itemCount == 0) {
                BuntuEmptyState(
                    title = "Aucune chaîne",
                    subtitle = "Ajoutez ou synchronisez une source IPTV.",
                    actionLabel = "Sources IPTV",
                    onAction = onOpenSources,
                )
            } else {
                LazyColumn(
                    modifier = Modifier.fillMaxSize(),
                    verticalArrangement = Arrangement.spacedBy(metrics.spacingS),
                ) {
                    items(
                        count = pagedChannels.itemCount,
                        key = { index -> pagedChannels.peek(index)?.id ?: (-1L - index) },
                        contentType = { "channel_row" },
                    ) { index ->
                        val channel = pagedChannels[index] ?: return@items
                        ChannelRowWithStatusBadge(
                            channel = channel,
                            isSelected = channel.id == state.activeChannelId,
                            onClick = { onChannelClick(channel) },
                        )
                    }
                }
            }
        }

        // Right column: inline player + Live TV recommendations directly below it
        LazyColumn(
            modifier = Modifier
                .weight(0.55f)
                .fillMaxHeight(),
            verticalArrangement = Arrangement.spacedBy(metrics.spacingM),
        ) {
            item(key = "tv_inline_player", contentType = "inline_player") {
                InlineLivePlayerCard(
                    title = state.activeChannelTitle ?: "Sélectionnez une chaîne",
                    subtitle = state.activeChannelNow,
                    playerState = playerState,
                    videoEngine = videoEngine,
                    onOpenFullscreen = onOpenFullscreen,
                    modifier = Modifier.fillMaxWidth(),
                )
            }

            state.errorMessage?.let { err ->
                item(key = "tv_live_error", contentType = "error_banner") {
                    BuntuErrorBanner(message = err)
                }
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
    onOpenFullscreen: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val metrics = LocalBuntuMetrics.current
    Surface(
        color = BuntuPalette.Slate,
        shape = RoundedCornerShape(16.dp),
        modifier = modifier,
    ) {
        Column {
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
                Spacer(modifier = Modifier.width(metrics.spacingS))
                if (playerState.activeStream != null) {
                    OutlinedButton(onClick = { videoEngine.togglePlayPause() }) {
                        Text(
                            text = if (playerState.isPlaying) "Pause" else "Lecture",
                            color = BuntuPalette.PureWhite,
                        )
                    }
                    Spacer(modifier = Modifier.width(metrics.spacingS))
                    BuntuPrimaryActionButton(
                        label = "Plein écran",
                        onClick = onOpenFullscreen,
                    )
                }
            }
        }
    }
}

@Composable
private fun LiveFilterToolbar(
    categories: kotlinx.collections.immutable.ImmutableList<String>,
    selectedCategory: String?,
    favoritesOnly: Boolean,
    searchQuery: String,
    onSelectCategory: (String?) -> Unit,
    onToggleFavorites: () -> Unit,
    onUpdateSearch: (String) -> Unit,
    compactPadding: Boolean = false,
) {
    val metrics = LocalBuntuMetrics.current
    val horizontalPad = if (compactPadding) 0.dp else metrics.horizontalScreenPadding

    Column(verticalArrangement = Arrangement.spacedBy(metrics.spacingS)) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(metrics.spacingS),
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = horizontalPad),
        ) {
            OutlinedTextField(
                value = searchQuery,
                onValueChange = onUpdateSearch,
                placeholder = { Text("Filtrer les chaînes…") },
                singleLine = true,
                modifier = Modifier.weight(1f),
            )
            FilterChip(
                selected = favoritesOnly,
                onClick = onToggleFavorites,
                label = { Text("★ Favoris") },
                colors = FilterChipDefaults.filterChipColors(
                    selectedContainerColor = BuntuPalette.TerangaGold,
                    selectedLabelColor = BuntuPalette.Midnight,
                ),
            )
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
    onClick: () -> Unit,
) {
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
        )
        // Concise outage badge (never verbose!)
        if (channel.isBroken) {
            Surface(
                color = BuntuPalette.DangerRed.copy(alpha = 0.9f),
                shape = RoundedCornerShape(6.dp),
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .padding(6.dp),
            ) {
                Text(
                    text = "HS",
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
    val shelfCards = remember(shelf.cards) {
        shelf.cards.map { card ->
            BuntuShelfCardData(
                key = card.stableHash,
                title = card.title,
                subtitle = card.subtitle ?: card.reasonLabel,
                badge = "DIRECT",
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
    )
}

