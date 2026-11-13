package com.pcoundia.buntu.feature.series

import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.pcoundia.buntu.core.designsystem.BuntuDeviceChoice
import com.pcoundia.buntu.core.designsystem.BuntuDevicePickerDialog
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.paging.compose.collectAsLazyPagingItems
import com.pcoundia.buntu.core.designsystem.BuntuCategoryChips
import com.pcoundia.buntu.core.designsystem.BuntuEmptyState
import com.pcoundia.buntu.core.designsystem.BuntuMediaShelf
import com.pcoundia.buntu.core.designsystem.BuntuPalette
import com.pcoundia.buntu.core.designsystem.BuntuPosterCard
import com.pcoundia.buntu.core.designsystem.BuntuShelfCardData
import com.pcoundia.buntu.core.designsystem.LocalBuntuMetrics
import kotlinx.collections.immutable.toImmutableList

@Composable
fun SeriesRoute(
    onOpenSeriesDetail: (Long) -> Unit,
    onOpenSources: () -> Unit,
    onOpenSearch: () -> Unit = {},
    viewModel: SeriesViewModel = hiltViewModel(),
) {
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val pagedSeries = viewModel.pagedSeries.collectAsLazyPagingItems()
    val metrics = LocalBuntuMetrics.current
    val remoteDevices by viewModel.remoteDevices.collectAsStateWithLifecycle()
    val remoteStatus by viewModel.remoteStatus.collectAsStateWithLifecycle()
    var remoteTarget by remember { mutableStateOf<Pair<Long, String>?>(null) }
    val openRemoteMenu: (Long, String) -> Unit = { itemId, title ->
        viewModel.openRemoteMenu()
        remoteTarget = itemId to title
    }

    LazyVerticalGrid(
        columns = GridCells.Adaptive(minSize = metrics.posterGridMinCell),
        modifier = Modifier
            .fillMaxSize()
            .background(BuntuPalette.Midnight),
        contentPadding = PaddingValues(
            horizontal = metrics.horizontalScreenPadding,
            vertical = metrics.verticalScreenPadding,
        ),
        horizontalArrangement = Arrangement.spacedBy(metrics.spacingM),
        verticalArrangement = Arrangement.spacedBy(metrics.spacingM),
    ) {
        item(
            key = "series_header",
            span = { GridItemSpan(maxLineSpan) },
            contentType = "header",
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(metrics.spacingS)) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text(
                        text = "Séries",
                        style = MaterialTheme.typography.headlineSmall,
                        fontWeight = FontWeight.Bold,
                        color = BuntuPalette.PureWhite,
                    )
                    Spacer(modifier = Modifier.width(metrics.spacingS))
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(metrics.spacingS),
                        modifier = Modifier.horizontalScroll(rememberScrollState()),
                    ) {
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
                            label = { Text("Rechercher") },
                        )
                        FilterChip(
                            selected = state.favoritesOnly,
                            onClick = viewModel::toggleFavoritesOnly,
                            label = { Text("★ Favoris") },
                            colors = FilterChipDefaults.filterChipColors(
                                selectedContainerColor = BuntuPalette.TerangaGold,
                                selectedLabelColor = BuntuPalette.Midnight,
                            ),
                        )
                    }
                }
                BuntuCategoryChips(
                    categories = state.categories,
                    selectedCategory = state.selectedCategory,
                    onSelectCategory = viewModel::selectCategory,
                )
            }
        }

        if (state.selectedCategory == null && !state.favoritesOnly) {
            items(
                count = state.shelves.size,
                key = { idx -> "series_shelf_${state.shelves[idx].id}" },
                span = { GridItemSpan(maxLineSpan) },
                contentType = { "series_shelf" },
            ) { idx ->
                val shelf = state.shelves[idx]
                val cards = remember(shelf.cards) {
                    shelf.cards.map { c ->
                        BuntuShelfCardData(
                            key = c.stableHash,
                            title = c.title,
                            subtitle = c.subtitle ?: c.reasonLabel,
                            posterUrl = c.posterUrl,
                        )
                    }.toImmutableList()
                }
                BuntuMediaShelf(
                    title = shelf.title,
                    subtitle = shelf.refinedByAi.takeIf { it.isNotBlank() && it != "local" },
                    cards = cards,
                    onCardClick = { clicked ->
                        val seriesId = shelf.cards.firstOrNull { it.stableHash == clicked.key }?.let {
                            it.seriesId ?: it.itemId
                        }
                        if (seriesId != null) onOpenSeriesDetail(seriesId)
                    },
                    // Only an episode card (e.g. « À suivre ») can be sent; a series card has no menu.
                    onCardLongClick = { clicked ->
                        val card = shelf.cards.firstOrNull { it.stableHash == clicked.key }
                        val episodeId = card?.itemId?.takeIf { card.seriesId != null && it != card.seriesId }
                        if (episodeId != null) openRemoteMenu(episodeId, clicked.title)
                    },
                )
            }
        }

        if (pagedSeries.itemCount == 0) {
            item(
                key = "series_empty",
                span = { GridItemSpan(maxLineSpan) },
                contentType = "empty_state",
            ) {
                BuntuEmptyState(
                    title = "Aucune série trouvée",
                    subtitle = "Synchronisez votre source IPTV ou changez de catégorie.",
                    actionLabel = "Gérer les sources",
                    onAction = onOpenSources,
                )
            }
        } else {
            items(
                count = pagedSeries.itemCount,
                key = { index -> pagedSeries.peek(index)?.id ?: (-1L - index) },
                contentType = { "series_poster_card" },
            ) { index ->
                val series = pagedSeries[index] ?: return@items
                val subtitle = buildString {
                    series.year?.let { append(it).append(" · ") }
                    append("${series.seasonCount} saison(s)")
                }
                BuntuPosterCard(
                    title = series.title,
                    posterUrl = series.posterUrl,
                    subtitle = subtitle,
                    badge = series.rating?.takeIf { it > 0.0 }?.let { "★ %.1f".format(it) },
                    onClick = { onOpenSeriesDetail(series.id) },
                )
            }
        }
    }

    remoteTarget?.let { (itemId, title) ->
        BuntuDevicePickerDialog(
            itemTitle = title,
            devices = remember(remoteDevices) {
                remoteDevices.map { BuntuDeviceChoice(it.id, it.name, it.deviceType) }.toImmutableList()
            },
            status = remoteStatus,
            onPick = { device -> viewModel.playOnDevice(device.id, itemId) { remoteTarget = null } },
            onDismiss = { remoteTarget = null },
        )
    }
}

