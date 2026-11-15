package com.pcoundia.buntu.core.designsystem

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Sort
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import coil3.request.ImageRequest
import coil3.request.crossfade
import coil3.size.Size
import com.pcoundia.buntu.core.designsystem.i18n.t
import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.toImmutableList

@Immutable
data class BuntuShelfCardData(
    val key: String,
    val title: String,
    val subtitle: String? = null,
    val badge: String? = null,
    val posterUrl: String? = null,
    val progressFraction: Float = 0f,
)

/**
 * PRD-37 § 5.1, § 5.3, § 5.4:
 * - Decodes image at exact card pixel dimensions via Coil 3 `Size(widthPx, heightPx)`.
 * - Reserves fixed space so layout never jumps while loading.
 * - Visible focus border + optional 1.05x scale on Android TV (skipped on low-RAM devices).
 * - Minimum 48dp touch target & TalkBack semantics.
 */
@Composable
fun BuntuPosterCard(
    title: String,
    posterUrl: String?,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    subtitle: String? = null,
    badge: String? = null,
    progressFraction: Float = 0f,
    /** Context menu (long press, Menu key on TV); `null` = none. */
    onLongClick: (() -> Unit)? = null,
) {
    val metrics = LocalBuntuMetrics.current
    val density = LocalDensity.current
    val context = LocalContext.current
    var isFocused by remember { mutableStateOf(false) }

    val scale by animateFloatAsState(
        targetValue = if (isFocused && metrics.enableFocusScaleAnimation) 1.05f else 1.0f,
        label = "posterFocusScale",
    )
    val widthPx = with(density) { metrics.posterCardWidth.roundToPx().coerceAtLeast(64) }
    val heightPx = with(density) { metrics.posterCardHeight.roundToPx().coerceAtLeast(96) }

    val imageRequest = remember(posterUrl, widthPx, heightPx) {
        posterUrl?.takeIf { it.isNotBlank() }?.let { url ->
            ImageRequest.Builder(context)
                .data(url)
                .size(Size(widthPx, heightPx))
                .crossfade(!metrics.isLowRamDevice)
                .build()
        }
    }

    val shape = RoundedCornerShape(12.dp)
    val borderMod = if (isFocused) {
        Modifier.border(BorderStroke(2.5.dp, BuntuPalette.TerangaGold), shape)
    } else {
        Modifier.border(BorderStroke(1.dp, BuntuPalette.SlateElevated), shape)
    }

    Column(
        modifier = modifier
            .width(metrics.posterCardWidth)
            .graphicsLayer {
                scaleX = scale
                scaleY = scale
            }
            .semantics {
                contentDescription = buildString {
                    append(title)
                    if (!subtitle.isNullOrBlank()) {
                        append(", ")
                        append(subtitle)
                    }
                    if (!badge.isNullOrBlank()) {
                        append(", ")
                        append(badge)
                    }
                }
            }
            .onFocusChanged { isFocused = it.isFocused }
            .focusable()
            .clip(shape)
            .buntuCardClickable(onClick = onClick, onLongClick = onLongClick),
    ) {
        Box(
            modifier = Modifier
                .width(metrics.posterCardWidth)
                .height(metrics.posterCardHeight)
                .clip(shape)
                .background(BuntuPalette.Slate)
                .then(borderMod),
        ) {
            if (imageRequest != null) {
                AsyncImage(
                    model = imageRequest,
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxSize(),
                )
            } else {
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(metrics.spacingM),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        text = title.take(2).uppercase(),
                        style = MaterialTheme.typography.headlineSmall,
                        fontWeight = FontWeight.Bold,
                        color = BuntuPalette.MutedSilver,
                    )
                }
            }

            if (!badge.isNullOrBlank()) {
                Surface(
                    color = BuntuPalette.Midnight.copy(alpha = 0.86f),
                    shape = RoundedCornerShape(6.dp),
                    modifier = Modifier
                        .align(Alignment.TopStart)
                        .padding(metrics.spacingS),
                ) {
                    Text(
                        text = badge,
                        style = MaterialTheme.typography.labelSmall,
                        color = BuntuPalette.TerangaGold,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp),
                    )
                }
            }

            if (progressFraction > 0.01f) {
                LinearProgressIndicator(
                    progress = { progressFraction.coerceIn(0f, 1f) },
                    color = BuntuPalette.TerangaGold,
                    trackColor = BuntuPalette.Midnight.copy(alpha = 0.7f),
                    modifier = Modifier
                        .align(Alignment.BottomCenter)
                        .fillMaxWidth()
                        .height(4.dp),
                )
            }
        }

        Spacer(modifier = Modifier.height(metrics.spacingXS))
        Text(
            text = title,
            style = MaterialTheme.typography.bodyMedium,
            fontWeight = if (isFocused) FontWeight.Bold else FontWeight.Medium,
            color = if (isFocused) BuntuPalette.TerangaGold else BuntuPalette.PureWhite,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        if (!subtitle.isNullOrBlank()) {
            Text(
                text = subtitle,
                style = MaterialTheme.typography.bodySmall,
                color = BuntuPalette.MutedSilver,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

@Composable
fun BuntuChannelCard(
    name: String,
    logoUrl: String?,
    channelNumber: Int?,
    nowTitle: String?,
    nextTitle: String?,
    nowProgress: Float,
    isFavorite: Boolean,
    isSelected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    /** Context menu (long press, Menu key on TV); `null` = none. */
    onLongClick: (() -> Unit)? = null,
) {
    val metrics = LocalBuntuMetrics.current
    val density = LocalDensity.current
    val context = LocalContext.current
    var isFocused by remember { mutableStateOf(false) }

    val logoPx = with(density) { 52.dp.roundToPx() }
    val logoRequest = remember(logoUrl, logoPx) {
        logoUrl?.takeIf { it.isNotBlank() }?.let { url ->
            ImageRequest.Builder(context)
                .data(url)
                .size(Size(logoPx, logoPx))
                .crossfade(!metrics.isLowRamDevice)
                .build()
        }
    }

    val shape = RoundedCornerShape(12.dp)
    val highlighted = isFocused || isSelected
    val borderColor = when {
        isFocused -> BuntuPalette.TerangaGold
        isSelected -> BuntuPalette.LeerCyan
        else -> BuntuPalette.SlateElevated
    }

    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier
            .fillMaxWidth()
            .defaultMinSize(
                minWidth = metrics.channelCardMinWidth,
                minHeight = metrics.channelCardHeight,
            )
            .semantics {
                contentDescription = buildString {
                    if (channelNumber != null) append("Chaîne $channelNumber, ")
                    append(name)
                    if (!nowTitle.isNullOrBlank()) append(", En cours : $nowTitle")
                    if (!nextTitle.isNullOrBlank()) append(", Ensuite : $nextTitle")
                }
            }
            .onFocusChanged { isFocused = it.isFocused }
            .focusable()
            .clip(shape)
            .background(if (highlighted) BuntuPalette.SlateElevated else BuntuPalette.Slate)
            .border(BorderStroke(if (highlighted) 2.dp else 1.dp, borderColor), shape)
            .buntuCardClickable(onClick = onClick, onLongClick = onLongClick)
            .padding(metrics.spacingM),
    ) {
        Box(
            modifier = Modifier
                .size(52.dp)
                .clip(RoundedCornerShape(8.dp))
                .background(BuntuPalette.Midnight),
            contentAlignment = Alignment.Center,
        ) {
            if (logoRequest != null) {
                AsyncImage(
                    model = logoRequest,
                    contentDescription = null,
                    contentScale = ContentScale.Fit,
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(4.dp),
                )
            } else {
                Text(
                    text = channelNumber?.toString() ?: name.take(2).uppercase(),
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.Bold,
                    color = BuntuPalette.TerangaGold,
                )
            }
        }

        Spacer(modifier = Modifier.width(metrics.spacingM))

        Column(modifier = Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (channelNumber != null) {
                    Text(
                        text = "$channelNumber · ",
                        style = MaterialTheme.typography.labelLarge,
                        color = BuntuPalette.TerangaGold,
                        fontWeight = FontWeight.Bold,
                    )
                }
                Text(
                    text = name,
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                    color = BuntuPalette.PureWhite,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                if (isFavorite) {
                    Text(
                        text = "★",
                        color = BuntuPalette.TerangaGold,
                        style = MaterialTheme.typography.titleMedium,
                    )
                }
            }

            if (!nowTitle.isNullOrBlank()) {
                Text(
                    text = nowTitle,
                    style = MaterialTheme.typography.bodySmall,
                    color = BuntuPalette.LeerCyan,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                if (nowProgress > 0f) {
                    Spacer(modifier = Modifier.height(4.dp))
                    LinearProgressIndicator(
                        progress = { nowProgress.coerceIn(0f, 1f) },
                        color = BuntuPalette.LeerCyan,
                        trackColor = BuntuPalette.Midnight,
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(3.dp),
                    )
                }
            }
            if (!nextTitle.isNullOrBlank()) {
                Text(
                    text = "Ensuite : $nextTitle",
                    style = MaterialTheme.typography.labelSmall,
                    color = BuntuPalette.MutedSilver,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

@Composable
fun BuntuMediaShelf(
    title: String,
    cards: ImmutableList<BuntuShelfCardData>,
    onCardClick: (BuntuShelfCardData) -> Unit,
    modifier: Modifier = Modifier,
    subtitle: String? = null,
    /** Context menu of a card; `null` = none. */
    onCardLongClick: ((BuntuShelfCardData) -> Unit)? = null,
) {
    if (cards.isEmpty()) return
    val metrics = LocalBuntuMetrics.current

    Column(modifier = modifier.fillMaxWidth()) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.padding(horizontal = metrics.horizontalScreenPadding),
        ) {
            Text(
                text = title,
                style = MaterialTheme.typography.titleLarge,
                fontWeight = FontWeight.Bold,
                color = BuntuPalette.PureWhite,
            )
            if (!subtitle.isNullOrBlank()) {
                Spacer(modifier = Modifier.width(metrics.spacingS))
                Text(
                    text = subtitle,
                    style = MaterialTheme.typography.labelMedium,
                    color = BuntuPalette.LeerCyan,
                )
            }
        }
        Spacer(modifier = Modifier.height(metrics.spacingS))
        LazyRow(
            contentPadding = PaddingValues(horizontal = metrics.horizontalScreenPadding),
            horizontalArrangement = Arrangement.spacedBy(metrics.spacingM),
        ) {
            items(
                items = cards,
                key = { it.key },
                contentType = { "shelf_poster_card" },
            ) { card ->
                BuntuPosterCard(
                    title = card.title,
                    posterUrl = card.posterUrl,
                    subtitle = card.subtitle,
                    badge = card.badge,
                    progressFraction = card.progressFraction,
                    onClick = { onCardClick(card) },
                    onLongClick = onCardLongClick?.let { handler -> { handler(card) } },
                )
            }
        }
    }
}

/** Filters category names case-insensitively by [query]. */
fun filterCategories(categories: List<String>, query: String): List<String> {
    val trimmed = query.trim()
    if (trimmed.isEmpty()) return categories
    return categories.filter { it.contains(trimmed, ignoreCase = true) }
}

@Composable
fun <T> BuntuSortChip(
    selected: T,
    options: List<Pair<T, String>>,
    onSelection: (T) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        FilterChip(
            selected = expanded,
            onClick = { expanded = true },
            leadingIcon = {
                Icon(Icons.Default.Sort, contentDescription = null, modifier = Modifier.size(FilterChipDefaults.IconSize))
            },
            label = { Text(t("common.sort")) },
        )
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            options.forEach { (value, label) ->
                DropdownMenuItem(
                    text = { Text(label) },
                    onClick = {
                        expanded = false
                        onSelection(value)
                    },
                    trailingIcon = if (value == selected) {
                        { Icon(Icons.Default.Check, contentDescription = t("common.sort_selected")) }
                    } else null,
                )
            }
        }
    }
}

@Composable
fun BuntuCategoryChips(
    categories: ImmutableList<String>,
    selectedCategory: String?,
    onSelectCategory: (String?) -> Unit,
    modifier: Modifier = Modifier,
    allLabel: String = t("categories.all"),
    /** Side padding of the phone button; `null` = the screen padding. Pass `0.dp` when embedded in a row. */
    phoneHorizontalPadding: Dp? = null,
) {
    val metrics = LocalBuntuMetrics.current
    // Phone: one button that opens a left drawer instead of a long row of chips. Tablets and TV keep the chips.
    if (!metrics.isTv && metrics.windowWidth == BuntuWindowWidth.COMPACT) {
        if (categories.isNotEmpty()) {
            BuntuCategoryDrawerEntry(
                categories = categories,
                selectedCategory = selectedCategory,
                onSelectCategory = onSelectCategory,
                allLabel = allLabel,
                horizontalPadding = phoneHorizontalPadding ?: metrics.horizontalScreenPadding,
                modifier = modifier,
            )
        }
        return
    }
    var isSearchOpen by remember { mutableStateOf(false) }
    var categoryQuery by remember { mutableStateOf("") }
    val filteredCategories = remember(categories, categoryQuery) {
        filterCategories(categories, categoryQuery).toImmutableList()
    }

    Column(
        modifier = modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(metrics.spacingXS),
    ) {
        if (isSearchOpen) {
            OutlinedTextField(
                value = categoryQuery,
                onValueChange = { categoryQuery = it },
                placeholder = {
                    Text(
                        text = t("categories.search_placeholder"),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                },
                leadingIcon = {
                    Icon(
                        imageVector = Icons.Default.Search,
                        contentDescription = null,
                    )
                },
                trailingIcon = {
                    IconButton(
                        onClick = {
                            if (categoryQuery.isNotEmpty()) {
                                categoryQuery = ""
                            } else {
                                isSearchOpen = false
                            }
                        },
                    ) {
                        Icon(
                            imageVector = Icons.Default.Close,
                            contentDescription = t("common.close"),
                        )
                    }
                },
                singleLine = true,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = metrics.horizontalScreenPadding),
            )
        }

        LazyRow(
            modifier = Modifier.fillMaxWidth(),
            contentPadding = PaddingValues(horizontal = metrics.horizontalScreenPadding),
            horizontalArrangement = Arrangement.spacedBy(metrics.spacingS),
        ) {
            if (categories.isNotEmpty()) {
                item(key = "__search_cat__", contentType = "category_search_chip") {
                    FilterChip(
                        selected = isSearchOpen || categoryQuery.isNotBlank(),
                        onClick = {
                            if (isSearchOpen) {
                                isSearchOpen = false
                                categoryQuery = ""
                            } else {
                                isSearchOpen = true
                            }
                        },
                        leadingIcon = {
                            Icon(
                                imageVector = Icons.Default.Search,
                                contentDescription = null,
                                modifier = Modifier.size(FilterChipDefaults.IconSize),
                            )
                        },
                        label = {
                            Text(
                                text = categoryQuery.takeIf { it.isNotBlank() } ?: t("categories.search_chip"),
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        },
                        modifier = Modifier.defaultMinSize(minHeight = metrics.minTouchTarget),
                        colors = FilterChipDefaults.filterChipColors(
                            selectedContainerColor = BuntuPalette.TerangaGold,
                            selectedLabelColor = BuntuPalette.Midnight,
                            selectedLeadingIconColor = BuntuPalette.Midnight,
                        ),
                    )
                }
            }
            item(key = "__all__", contentType = "category_chip") {
                FilterChip(
                    selected = selectedCategory == null,
                    onClick = { onSelectCategory(null) },
                    label = { Text(allLabel) },
                    modifier = Modifier.defaultMinSize(minHeight = metrics.minTouchTarget),
                    colors = FilterChipDefaults.filterChipColors(
                        selectedContainerColor = BuntuPalette.TerangaGold,
                        selectedLabelColor = BuntuPalette.Midnight,
                    ),
                )
            }
            if (filteredCategories.isEmpty() && categoryQuery.isNotBlank()) {
                item(key = "__no_cat_match__", contentType = "category_empty_hint") {
                    Text(
                        text = t("categories.no_match"),
                        color = BuntuPalette.MutedSilver,
                        style = MaterialTheme.typography.bodySmall,
                        modifier = Modifier.padding(vertical = 12.dp, horizontal = metrics.spacingS),
                    )
                }
            } else {
                items(
                    items = filteredCategories,
                    key = { it },
                    contentType = { "category_chip" },
                ) { category ->
                    FilterChip(
                        selected = selectedCategory == category,
                        onClick = { onSelectCategory(category) },
                        label = { Text(category, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                        modifier = Modifier.defaultMinSize(minHeight = metrics.minTouchTarget),
                        colors = FilterChipDefaults.filterChipColors(
                            selectedContainerColor = BuntuPalette.TerangaGold,
                            selectedLabelColor = BuntuPalette.Midnight,
                        ),
                    )
                }
            }
        }
    }
}

@Composable
fun BuntuErrorBanner(
    message: String,
    actionLabel: String? = null,
    onAction: (() -> Unit)? = null,
    modifier: Modifier = Modifier,
    secondaryActionLabel: String? = null,
    onSecondaryAction: (() -> Unit)? = null,
) {
    val metrics = LocalBuntuMetrics.current
    Surface(
        color = BuntuPalette.SlateElevated,
        border = BorderStroke(1.dp, BuntuPalette.DangerRed),
        shape = RoundedCornerShape(12.dp),
        modifier = modifier.fillMaxWidth(),
    ) {
        Column(modifier = Modifier.padding(metrics.spacingM)) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text(
                    text = message,
                    style = MaterialTheme.typography.bodyMedium,
                    color = BuntuPalette.PureWhite,
                    modifier = Modifier.weight(1f),
                )
                if (actionLabel != null && onAction != null) {
                    Spacer(modifier = Modifier.width(metrics.spacingM))
                    BuntuPrimaryActionButton(
                        label = actionLabel,
                        onClick = onAction,
                    )
                }
            }
            if (secondaryActionLabel != null && onSecondaryAction != null) {
                Spacer(modifier = Modifier.height(metrics.spacingS))
                Row(
                    horizontalArrangement = Arrangement.End,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    BuntuPrimaryActionButton(
                        label = secondaryActionLabel,
                        onClick = onSecondaryAction,
                        containerColor = BuntuPalette.Slate,
                    )
                }
            }
        }
    }
}

@Composable
fun BuntuEmptyState(
    title: String,
    subtitle: String,
    actionLabel: String? = null,
    onAction: (() -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    val metrics = LocalBuntuMetrics.current
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
        modifier = modifier
            .fillMaxWidth()
            .padding(metrics.spacingXL),
    ) {
        Text(
            text = title,
            style = MaterialTheme.typography.headlineSmall,
            fontWeight = FontWeight.Bold,
            color = BuntuPalette.PureWhite,
        )
        Spacer(modifier = Modifier.height(metrics.spacingS))
        Text(
            text = subtitle,
            style = MaterialTheme.typography.bodyMedium,
            color = BuntuPalette.MutedSilver,
        )
        if (actionLabel != null && onAction != null) {
            Spacer(modifier = Modifier.height(metrics.spacingL))
            BuntuPrimaryActionButton(
                label = actionLabel,
                onClick = onAction,
            )
        }
    }
}

@Composable
fun BuntuLoadingState(
    label: String? = null,
    modifier: Modifier = Modifier,
) {
    val metrics = LocalBuntuMetrics.current
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
        modifier = modifier
            .fillMaxWidth()
            .padding(metrics.spacingXL),
    ) {
        androidx.compose.material3.CircularProgressIndicator(
            color = BuntuPalette.TerangaGold,
        )
        if (!label.isNullOrBlank()) {
            Spacer(modifier = Modifier.height(metrics.spacingM))
            Text(
                text = label,
                style = MaterialTheme.typography.bodyMedium,
                color = BuntuPalette.MutedSilver,
            )
        }
    }
}

@Composable
fun BuntuPrimaryActionButton(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    containerColor: Color = BuntuPalette.TerangaGold,
) {
    val metrics = LocalBuntuMetrics.current
    var isFocused by remember { mutableStateOf(false) }

    Button(
        onClick = onClick,
        enabled = enabled,
        colors = ButtonDefaults.buttonColors(
            containerColor = containerColor,
            contentColor = BuntuPalette.Midnight,
        ),
        border = if (isFocused) BorderStroke(2.dp, BuntuPalette.PureWhite) else null,
        modifier = modifier
            .defaultMinSize(minHeight = metrics.minTouchTarget)
            .onFocusChanged { isFocused = it.isFocused },
    ) {
        Text(
            text = label,
            fontWeight = FontWeight.Bold,
        )
    }
}

