package com.pcoundia.buntu.feature.series

import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.pcoundia.buntu.core.designsystem.BuntuDeviceChoice
import com.pcoundia.buntu.core.designsystem.BuntuItemMenu
import com.pcoundia.buntu.core.designsystem.BuntuItemMenuHost
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
import androidx.paging.LoadState
import androidx.paging.compose.collectAsLazyPagingItems
import com.pcoundia.buntu.core.designsystem.BuntuCategoryChips
import com.pcoundia.buntu.core.designsystem.BuntuEmptyState
import com.pcoundia.buntu.core.designsystem.BuntuErrorBanner
import com.pcoundia.buntu.core.designsystem.BuntuLoadingState
import com.pcoundia.buntu.core.designsystem.BuntuMediaShelf
import com.pcoundia.buntu.core.designsystem.BuntuPalette
import com.pcoundia.buntu.core.designsystem.BuntuPosterCard
import com.pcoundia.buntu.core.designsystem.BuntuShelfCardData
import com.pcoundia.buntu.core.designsystem.BuntuSortChip
import com.pcoundia.buntu.core.domain.model.CatalogSort
import com.pcoundia.buntu.core.designsystem.LocalBuntuMetrics
import com.pcoundia.buntu.core.designsystem.i18n.rememberAppLanguage
import com.pcoundia.buntu.core.designsystem.i18n.t
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
                        text = t("series.title"),
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
                            label = { Text(t("series.search")) },
                        )
                        FilterChip(
                            selected = state.favoritesOnly,
                            onClick = viewModel::toggleFavoritesOnly,
                            label = { Text(t("series.favorites")) },
                            colors = FilterChipDefaults.filterChipColors(
                                selectedContainerColor = BuntuPalette.TerangaGold,
                                selectedLabelColor = BuntuPalette.Midnight,
                            ),
                        )
                        BuntuSortChip(
                            selected = state.sort,
                            options = listOf(
                                CatalogSort.DEFAULT to t("common.sort_recently_added"),
                                CatalogSort.OLDEST_ADDED to t("common.sort_oldest_added"),
                                CatalogSort.NAME_ASC to t("common.sort_name_asc"),
                                CatalogSort.NAME_DESC to t("common.sort_name_desc"),
                                CatalogSort.RATING_DESC to t("movies.sort_rating"),
                                CatalogSort.RATING_ASC to t("movies.sort_rating_asc"),
                            ),
                            onSelection = viewModel::selectSort,
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

        val refreshState = pagedSeries.loadState.refresh
        if (pagedSeries.itemCount == 0) {
            when (refreshState) {
                is LoadState.Loading -> {
                    item(
                        key = "series_loading",
                        span = { GridItemSpan(maxLineSpan) },
                        contentType = "loading_state",
                    ) {
                        BuntuLoadingState(label = t("common.loading"))
                    }
                }
                is LoadState.Error -> {
                    item(
                        key = "series_error",
                        span = { GridItemSpan(maxLineSpan) },
                        contentType = "error_state",
                    ) {
                        BuntuErrorBanner(
                            message = refreshState.error.localizedMessage ?: t("series.empty_subtitle"),
                            actionLabel = t("common.retry"),
                            onAction = { pagedSeries.retry() },
                        )
                    }
                }
                is LoadState.NotLoading -> {
                    item(
                        key = "series_empty",
                        span = { GridItemSpan(maxLineSpan) },
                        contentType = "empty_state",
                    ) {
                        BuntuEmptyState(
                            title = t("series.empty_title"),
                            subtitle = t("series.empty_subtitle"),
                            actionLabel = t("series.manage_sources"),
                            onAction = onOpenSources,
                        )
                    }
                }
            }
        } else {
            items(
                count = pagedSeries.itemCount,
                key = { index -> pagedSeries.peek(index)?.id ?: (-1L - index) },
                contentType = { "series_poster_card" },
            ) { index ->
                val series = pagedSeries[index] ?: return@items
                val seasonLabel = if (series.seasonCount == 1) {
                    t("series.season_one", series.seasonCount)
                } else {
                    t("series.season_many", series.seasonCount)
                }
                val subtitle = buildString {
                    series.year?.let { append(it).append(" · ") }
                    append(seasonLabel)
                }
                BuntuPosterCard(
                    title = series.title,
                    posterUrl = series.posterUrl,
                    subtitle = subtitle,
                    badge = series.rating?.takeIf { it > 0.0 }?.let { "★ %.1f".format(it) },
                    onClick = { onOpenSeriesDetail(series.id) },
                    // A series is not playable by itself: its menu only offers the favorite.
                    onLongClick = {
                        itemMenu = BuntuItemMenu(
                            title = series.title,
                            isFavorite = { viewModel.isSeriesFavorite(series) },
                            toggleFavorite = { viewModel.toggleSeriesFavorite(series) },
                        )
                    },
                )
            }
        }
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
}

