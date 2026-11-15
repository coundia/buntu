package com.pcoundia.buntu.feature.movies

import androidx.compose.runtime.mutableStateOf
import com.pcoundia.buntu.core.designsystem.BuntuWindowWidth
import com.pcoundia.buntu.core.designsystem.BuntuCategoryDrawer
import androidx.compose.ui.unit.dp
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.semantics.Role
import androidx.compose.material3.Surface
import androidx.compose.material3.OutlinedButton
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.filled.Close
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.clickable
import androidx.compose.foundation.BorderStroke
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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyGridScope
import androidx.compose.foundation.lazy.grid.LazyGridState
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
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
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
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
import com.pcoundia.buntu.core.designsystem.LocalBuntuMetrics
import com.pcoundia.buntu.core.designsystem.i18n.rememberAppLanguage
import com.pcoundia.buntu.core.designsystem.i18n.t
import com.pcoundia.buntu.core.domain.model.CatalogSort
import kotlinx.collections.immutable.toImmutableList

@Composable
fun MoviesRoute(
    onOpenMovieDetail: (Long) -> Unit,
    onOpenSources: () -> Unit,
    onOpenSearch: () -> Unit = {},
    viewModel: MoviesViewModel = hiltViewModel(),
) {
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val pagedMovies = viewModel.pagedMovies.collectAsLazyPagingItems()
    val metrics = LocalBuntuMetrics.current
    @Suppress("UNUSED_VARIABLE")
    val currentLanguage = rememberAppLanguage()
    val remoteDevices by viewModel.remoteDevices.collectAsStateWithLifecycle()
    val remoteStatus by viewModel.remoteStatus.collectAsStateWithLifecycle()
    var itemMenu by remember { mutableStateOf<BuntuItemMenu?>(null) }
    var showCategories by remember { mutableStateOf(false) }
    val isPhone = !metrics.isTv && metrics.windowWidth == BuntuWindowWidth.COMPACT
    val openRemoteMenu: (Long, String) -> Unit = { itemId, title ->
        itemMenu = BuntuItemMenu(
            title = title,
            itemId = itemId,
            isFavorite = { viewModel.isItemFavorite(itemId) },
            toggleFavorite = { viewModel.toggleItemFavorite(itemId) },
        )
    }

    val gridContent: LazyGridScope.() -> Unit = {
        item(
            key = "movies_header",
            span = { GridItemSpan(maxLineSpan) },
            contentType = "header",
        ) {
            if (isPhone) {
                MoviesPhoneHeader(
                    selectedCategory = state.selectedCategory,
                    favoritesOnly = state.favoritesOnly,
                    sort = state.sort,
                    onOpenCategories = { showCategories = true },
                    onClearCategory = { viewModel.selectCategory(null) },
                    onToggleFavorites = viewModel::toggleFavoritesOnly,
                    onSelectSort = viewModel::selectSort,
                    onOpenSearch = onOpenSearch,
                )
            } else Column(verticalArrangement = Arrangement.spacedBy(metrics.spacingS)) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text(
                        text = t("movies.title"),
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
                            label = { Text(t("movies.search")) },
                        )
                        FilterChip(
                            selected = state.favoritesOnly,
                            onClick = viewModel::toggleFavoritesOnly,
                            label = { Text(t("movies.favorites")) },
                            colors = FilterChipDefaults.filterChipColors(
                                selectedContainerColor = BuntuPalette.TerangaGold,
                                selectedLabelColor = BuntuPalette.Midnight,
                            ),
                        )
                        MoviesSortChip(sort = state.sort, onSelectSort = viewModel::selectSort)
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
                key = { idx -> "movie_shelf_${state.shelves[idx].id}" },
                span = { GridItemSpan(maxLineSpan) },
                contentType = { "movie_shelf" },
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
                        val itemId = shelf.cards.firstOrNull { it.stableHash == clicked.key }?.itemId
                        if (itemId != null) onOpenMovieDetail(itemId)
                    },
                    onCardLongClick = { clicked ->
                        shelf.cards.firstOrNull { it.stableHash == clicked.key }?.itemId
                            ?.let { openRemoteMenu(it, clicked.title) }
                    },
                )
            }
        }

        val refreshState = pagedMovies.loadState.refresh
        if (pagedMovies.itemCount == 0) {
            when (refreshState) {
                is LoadState.Loading -> {
                    item(
                        key = "movies_loading",
                        span = { GridItemSpan(maxLineSpan) },
                        contentType = "loading_state",
                    ) {
                        BuntuLoadingState(label = t("common.loading"))
                    }
                }
                is LoadState.Error -> {
                    item(
                        key = "movies_error",
                        span = { GridItemSpan(maxLineSpan) },
                        contentType = "error_state",
                    ) {
                        BuntuErrorBanner(
                            message = refreshState.error.localizedMessage ?: t("movies.empty_subtitle"),
                            actionLabel = t("common.retry"),
                            onAction = { pagedMovies.retry() },
                        )
                    }
                }
                is LoadState.NotLoading -> {
                    item(
                        key = "movies_empty",
                        span = { GridItemSpan(maxLineSpan) },
                        contentType = "empty_state",
                    ) {
                        BuntuEmptyState(
                            title = t("movies.empty_title"),
                            subtitle = t("movies.empty_subtitle"),
                            actionLabel = t("movies.manage_sources"),
                            onAction = onOpenSources,
                        )
                    }
                }
            }
        } else {
            items(
                count = pagedMovies.itemCount,
                key = { index -> pagedMovies.peek(index)?.id ?: (-1L - index) },
                contentType = { "movie_poster_card" },
            ) { index ->
                val movie = pagedMovies[index] ?: return@items
                BuntuPosterCard(
                    title = movie.title,
                    posterUrl = movie.posterUrl,
                    subtitle = movie.year?.toString() ?: movie.groupTitle,
                    badge = movie.rating?.takeIf { it > 0.0 }?.let { "★ %.1f".format(it) },
                    progressFraction = movie.resumeFraction,
                    onClick = { onOpenMovieDetail(movie.id) },
                    onLongClick = { openRemoteMenu(movie.id, movie.title) },
                )
            }
        }
    }

    val gridStateHolder = rememberSaveableStateHolder()
    val categoryKey = state.selectedCategory?.let { "category:$it" } ?: "all"
    val gridKey = "${state.sort.name}:${state.favoritesOnly}:$categoryKey"
    gridStateHolder.SaveableStateProvider(gridKey) {
        val savedGridState = rememberLazyGridState()
        // A loading or empty grid must not clamp the restored position before Paging displays its rows.
        val placeholderGridState = remember { LazyGridState() }
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
            state = if (pagedMovies.itemCount > 0) savedGridState else placeholderGridState,
            content = gridContent,
        )
    }

    if (showCategories) {
        BuntuCategoryDrawer(
            categories = state.categories,
            selectedCategory = state.selectedCategory,
            allLabel = t("categories.all"),
            onSelectCategory = { category ->
                viewModel.selectCategory(category)
                showCategories = false
            },
            onDismiss = { showCategories = false },
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
}

/**
 * Phone header of the movies: title with a visible « Catégories » button (opens the left drawer), a search
 * bar that opens the full search, then the quick filters. The chosen category appears as a chip that clears it.
 */
@Composable
private fun MoviesSortChip(sort: CatalogSort, onSelectSort: (CatalogSort) -> Unit) {
    BuntuSortChip(
        selected = sort,
        options = listOf(
            CatalogSort.DEFAULT to t("common.sort_recently_added"),
            CatalogSort.OLDEST_ADDED to t("common.sort_oldest_added"),
            CatalogSort.NAME_ASC to t("common.sort_name_asc"),
            CatalogSort.NAME_DESC to t("common.sort_name_desc"),
            CatalogSort.RATING_DESC to t("movies.sort_rating"),
            CatalogSort.RATING_ASC to t("movies.sort_rating_asc"),
        ),
        onSelection = onSelectSort,
    )
}

@Composable
private fun MoviesPhoneHeader(
    selectedCategory: String?,
    favoritesOnly: Boolean,
    sort: CatalogSort,
    onOpenCategories: () -> Unit,
    onClearCategory: () -> Unit,
    onToggleFavorites: () -> Unit,
    onSelectSort: (CatalogSort) -> Unit,
    onOpenSearch: () -> Unit,
) {
    val metrics = LocalBuntuMetrics.current
    Column(verticalArrangement = Arrangement.spacedBy(metrics.spacingM)) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text(
                text = t("movies.title"),
                style = MaterialTheme.typography.headlineSmall,
                fontWeight = FontWeight.Bold,
                color = BuntuPalette.PureWhite,
            )
            OutlinedButton(
                onClick = onOpenCategories,
                border = BorderStroke(1.dp, BuntuPalette.TerangaGold),
                modifier = Modifier.defaultMinSize(minHeight = metrics.minTouchTarget),
            ) {
                Icon(
                    imageVector = Icons.Default.Menu,
                    contentDescription = null,
                    tint = BuntuPalette.TerangaGold,
                    modifier = Modifier.size(18.dp),
                )
                Spacer(modifier = Modifier.width(8.dp))
                Text(t("categories.title"), color = BuntuPalette.TerangaGold, fontWeight = FontWeight.Bold)
            }
        }

        Surface(
            color = BuntuPalette.SlateElevated,
            shape = RoundedCornerShape(14.dp),
            modifier = Modifier
                .fillMaxWidth()
                .clickable(role = Role.Button, onClick = onOpenSearch),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .defaultMinSize(minHeight = 52.dp)
                    .padding(horizontal = 16.dp),
            ) {
                Icon(
                    imageVector = Icons.Default.Search,
                    contentDescription = null,
                    tint = BuntuPalette.MutedSilver,
                )
                Spacer(modifier = Modifier.width(12.dp))
                Text(
                    text = t("movies.search_hint"),
                    style = MaterialTheme.typography.bodyLarge,
                    color = BuntuPalette.MutedSilver,
                )
            }
        }

        Row(
            horizontalArrangement = Arrangement.spacedBy(metrics.spacingS),
            modifier = Modifier.horizontalScroll(rememberScrollState()),
        ) {
            FilterChip(
                selected = favoritesOnly,
                onClick = onToggleFavorites,
                label = { Text(t("movies.favorites")) },
                colors = FilterChipDefaults.filterChipColors(
                    selectedContainerColor = BuntuPalette.TerangaGold,
                    selectedLabelColor = BuntuPalette.Midnight,
                ),
            )
            MoviesSortChip(sort = sort, onSelectSort = onSelectSort)
            if (selectedCategory != null) {
                FilterChip(
                    selected = true,
                    onClick = onClearCategory,
                    label = { Text(selectedCategory, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                    trailingIcon = {
                        Icon(
                            imageVector = Icons.Default.Close,
                            contentDescription = t("common.close"),
                            modifier = Modifier.size(FilterChipDefaults.IconSize),
                        )
                    },
                    colors = FilterChipDefaults.filterChipColors(
                        selectedContainerColor = BuntuPalette.TerangaGold,
                        selectedLabelColor = BuntuPalette.Midnight,
                        selectedTrailingIconColor = BuntuPalette.Midnight,
                    ),
                )
            }
        }
    }
}
