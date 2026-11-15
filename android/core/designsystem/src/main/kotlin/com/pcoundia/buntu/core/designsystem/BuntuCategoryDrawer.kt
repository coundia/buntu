package com.pcoundia.buntu.core.designsystem

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.slideInHorizontally
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.pcoundia.buntu.core.designsystem.i18n.t
import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.toImmutableList

/** Phone layout: the category chips are replaced by a drawer opened from the left (see [BuntuCategoryChips]). */
@Composable
internal fun BuntuCategoryDrawerEntry(
    categories: ImmutableList<String>,
    selectedCategory: String?,
    onSelectCategory: (String?) -> Unit,
    allLabel: String,
    horizontalPadding: Dp,
    modifier: Modifier = Modifier,
) {
    val metrics = LocalBuntuMetrics.current
    var isOpen by remember { mutableStateOf(false) }

    Row(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = horizontalPadding),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        FilterChip(
            selected = selectedCategory != null,
            onClick = { isOpen = true },
            leadingIcon = {
                Icon(
                    imageVector = Icons.Default.Menu,
                    contentDescription = null,
                    modifier = Modifier.size(FilterChipDefaults.IconSize),
                )
            },
            label = {
                Text(
                    text = selectedCategory ?: "${t("categories.title")} · $allLabel",
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            },
            modifier = Modifier
                .weight(1f, fill = false)
                .defaultMinSize(minHeight = metrics.minTouchTarget),
            colors = FilterChipDefaults.filterChipColors(
                selectedContainerColor = BuntuPalette.TerangaGold,
                selectedLabelColor = BuntuPalette.Midnight,
                selectedLeadingIconColor = BuntuPalette.Midnight,
            ),
        )
    }

    if (isOpen) {
        BuntuCategoryDrawer(
            categories = categories,
            selectedCategory = selectedCategory,
            allLabel = allLabel,
            onSelectCategory = { category ->
                onSelectCategory(category)
                isOpen = false
            },
            onDismiss = { isOpen = false },
        )
    }
}

/**
 * Left drawer listing every category, with a search field. Drawn in a dialog so it works from any
 * place in a list (no need to wrap the whole screen in a `ModalNavigationDrawer`).
 */
@Composable
fun BuntuCategoryDrawer(
    categories: ImmutableList<String>,
    selectedCategory: String?,
    allLabel: String,
    onSelectCategory: (String?) -> Unit,
    onDismiss: () -> Unit,
) {
    var query by remember { mutableStateOf("") }
    val filtered = remember(categories, query) { filterCategories(categories, query).toImmutableList() }
    var visible by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { visible = true }

    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(Color.Black.copy(alpha = 0.5f))
                .clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null,
                    onClick = onDismiss,
                ),
        ) {
            AnimatedVisibility(
                visible = visible,
                enter = slideInHorizontally { fullWidth -> -fullWidth },
                modifier = Modifier.align(Alignment.CenterStart),
            ) {
                Column(
                    modifier = Modifier
                        .fillMaxHeight()
                        .fillMaxWidth(0.86f)
                        .widthIn(max = 360.dp)
                        .clip(RoundedCornerShape(topEnd = 20.dp, bottomEnd = 20.dp))
                        .background(BuntuPalette.Slate)
                        // Swallows taps so that touching the panel does not dismiss it.
                        .clickable(
                            interactionSource = remember { MutableInteractionSource() },
                            indication = null,
                            onClick = {},
                        )
                        .statusBarsPadding()
                        .navigationBarsPadding()
                        .padding(vertical = 12.dp),
                ) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(start = 20.dp, end = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween,
                    ) {
                        Text(
                            text = t("categories.title"),
                            style = MaterialTheme.typography.titleLarge,
                            fontWeight = FontWeight.Bold,
                            color = BuntuPalette.PureWhite,
                        )
                        IconButton(onClick = onDismiss) {
                            Icon(
                                imageVector = Icons.Default.Close,
                                contentDescription = t("common.close"),
                                tint = BuntuPalette.PureWhite,
                            )
                        }
                    }

                    OutlinedTextField(
                        value = query,
                        onValueChange = { query = it },
                        placeholder = {
                            Text(
                                text = t("categories.search_placeholder"),
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        },
                        leadingIcon = { Icon(Icons.Default.Search, contentDescription = null) },
                        trailingIcon = {
                            if (query.isNotEmpty()) {
                                IconButton(onClick = { query = "" }) {
                                    Icon(Icons.Default.Close, contentDescription = t("common.close"))
                                }
                            }
                        },
                        singleLine = true,
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 16.dp, vertical = 8.dp),
                    )

                    LazyColumn(
                        modifier = Modifier.fillMaxWidth(),
                        contentPadding = PaddingValues(horizontal = 12.dp, vertical = 4.dp),
                        verticalArrangement = Arrangement.spacedBy(4.dp),
                    ) {
                        if (query.isBlank()) {
                            item(key = "__all__", contentType = "category_row") {
                                CategoryRow(
                                    label = allLabel,
                                    selected = selectedCategory == null,
                                    onClick = { onSelectCategory(null) },
                                )
                            }
                        }
                        if (filtered.isEmpty()) {
                            item(key = "__no_match__", contentType = "category_empty_hint") {
                                Text(
                                    text = t("categories.no_match"),
                                    color = BuntuPalette.MutedSilver,
                                    style = MaterialTheme.typography.bodyMedium,
                                    modifier = Modifier.padding(16.dp),
                                )
                            }
                        } else {
                            items(items = filtered, key = { it }, contentType = { "category_row" }) { category ->
                                CategoryRow(
                                    label = category,
                                    selected = selectedCategory == category,
                                    onClick = { onSelectCategory(category) },
                                )
                            }
                        }
                    }
                    Spacer(modifier = Modifier.size(8.dp))
                }
            }
        }
    }
}

@Composable
private fun CategoryRow(label: String, selected: Boolean, onClick: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .defaultMinSize(minHeight = 48.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(if (selected) BuntuPalette.TerangaGold.copy(alpha = 0.16f) else Color.Transparent)
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 10.dp),
    ) {
        Text(
            text = label,
            style = MaterialTheme.typography.bodyLarge,
            fontWeight = if (selected) FontWeight.Bold else FontWeight.Medium,
            color = if (selected) BuntuPalette.TerangaGold else BuntuPalette.PureWhite,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        if (selected) {
            Icon(
                imageVector = Icons.Default.Check,
                contentDescription = null,
                tint = BuntuPalette.TerangaGold,
            )
        }
    }
}
