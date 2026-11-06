package com.pcoundia.buntu.feature.recommendations

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.pcoundia.buntu.core.designsystem.BuntuEmptyState
import com.pcoundia.buntu.core.designsystem.BuntuMediaShelf
import com.pcoundia.buntu.core.designsystem.BuntuPalette
import com.pcoundia.buntu.core.designsystem.BuntuShelfCardData
import com.pcoundia.buntu.core.designsystem.LocalBuntuMetrics
import com.pcoundia.buntu.core.domain.model.RecoDomainKind
import kotlinx.collections.immutable.toImmutableList

@Composable
fun RecommendationsRoute(
    onOpenLiveChannel: (Long) -> Unit,
    onOpenMovieDetail: (Long) -> Unit,
    onOpenSeriesDetail: (Long) -> Unit,
    viewModel: RecommendationsViewModel = hiltViewModel(),
) {
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val metrics = LocalBuntuMetrics.current

    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .background(BuntuPalette.Midnight),
        contentPadding = PaddingValues(vertical = metrics.verticalScreenPadding),
        verticalArrangement = Arrangement.spacedBy(metrics.spacingL),
    ) {
        item(key = "reco_header", contentType = "header") {
            Column(
                modifier = Modifier.padding(horizontal = metrics.horizontalScreenPadding),
                verticalArrangement = Arrangement.spacedBy(metrics.spacingM),
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text(
                        text = "Pour vous",
                        style = MaterialTheme.typography.headlineSmall,
                        fontWeight = FontWeight.Bold,
                        color = BuntuPalette.PureWhite,
                    )
                    OutlinedButton(onClick = viewModel::resetCurrentDomainTaste) {
                        Text("Réinitialiser mes goûts", color = BuntuPalette.MutedSilver)
                    }
                }

                Row(horizontalArrangement = Arrangement.spacedBy(metrics.spacingS)) {
                    DomainTabChip("Films", RecoDomainKind.MOVIES, state.selectedDomain, viewModel::selectDomain)
                    DomainTabChip("Séries", RecoDomainKind.SERIES, state.selectedDomain, viewModel::selectDomain)
                    DomainTabChip("TV en direct", RecoDomainKind.LIVE_TV, state.selectedDomain, viewModel::selectDomain)
                }
            }
        }

        if (!state.isLoading && state.shelves.isEmpty()) {
            item(key = "reco_empty", contentType = "empty_state") {
                BuntuEmptyState(
                    title = "Suggestions en préparation",
                    subtitle = "Regardez quelques contenus ou ajoutez des favoris pour personnaliser vos étagères.",
                )
            }
        } else {
            items(
                items = state.shelves,
                key = { "${state.selectedDomain}_${it.id}" },
                contentType = { "reco_shelf" },
            ) { shelf ->
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
                        val card = shelf.cards.firstOrNull { it.stableHash == clicked.key } ?: return@BuntuMediaShelf
                        when (shelf.kind) {
                            RecoDomainKind.MOVIES -> card.itemId?.let(onOpenMovieDetail)
                            RecoDomainKind.SERIES -> (card.seriesId ?: card.itemId)?.let(onOpenSeriesDetail)
                            RecoDomainKind.LIVE_TV -> card.itemId?.let(onOpenLiveChannel)
                        }
                    },
                )
            }
        }
    }
}

@Composable
private fun DomainTabChip(
    label: String,
    domain: RecoDomainKind,
    selected: RecoDomainKind,
    onSelect: (RecoDomainKind) -> Unit,
) {
    FilterChip(
        selected = domain == selected,
        onClick = { onSelect(domain) },
        label = { Text(label) },
        colors = FilterChipDefaults.filterChipColors(
            selectedContainerColor = BuntuPalette.TerangaGold,
            selectedLabelColor = BuntuPalette.Midnight,
        ),
    )
}

