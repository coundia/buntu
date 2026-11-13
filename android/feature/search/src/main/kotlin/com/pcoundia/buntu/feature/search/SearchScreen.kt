package com.pcoundia.buntu.feature.search

import android.app.Activity
import android.content.Intent
import android.speech.RecognizerIntent
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.CircularProgressIndicator
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.pcoundia.buntu.core.designsystem.BuntuEmptyState
import com.pcoundia.buntu.core.designsystem.BuntuErrorBanner
import com.pcoundia.buntu.core.designsystem.BuntuPalette
import com.pcoundia.buntu.core.designsystem.BuntuPosterCard
import com.pcoundia.buntu.core.designsystem.BuntuPrimaryActionButton
import com.pcoundia.buntu.core.designsystem.LocalBuntuMetrics
import com.pcoundia.buntu.core.domain.model.SearchHitItem
import com.pcoundia.buntu.core.domain.model.SearchHitKind
import com.pcoundia.buntu.core.domain.model.SearchScopeKind

@Composable
fun SearchRoute(
    onOpenLiveChannel: (Long) -> Unit,
    onOpenMovieDetail: (Long) -> Unit,
    onOpenSeriesDetail: (Long) -> Unit,
    onOpenReplay: (channelId: Long, startEpochSecs: Long, endEpochSecs: Long) -> Unit,
    onDismiss: () -> Unit = {},
    onOpenSettings: () -> Unit = {},
    viewModel: SearchViewModel = hiltViewModel(),
) {
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val metrics = LocalBuntuMetrics.current

    val voiceLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.StartActivityForResult(),
    ) { result ->
        if (result.resultCode == Activity.RESULT_OK) {
            val matches = result.data?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)
            val first = matches?.firstOrNull()
            if (!first.isNullOrBlank()) {
                viewModel.applyVoiceTranscript(first)
            }
        }
    }

    val launchVoice = {
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(
                RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                RecognizerIntent.LANGUAGE_MODEL_FREE_FORM,
            )
            putExtra(RecognizerIntent.EXTRA_PROMPT, "Dictez votre recherche Buntu")
        }
        runCatching { voiceLauncher.launch(intent) }
        Unit
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black.copy(alpha = 0.65f))
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                onClick = onDismiss,
            ),
        contentAlignment = Alignment.Center,
    ) {
        Surface(
            color = BuntuPalette.Slate,
            shape = RoundedCornerShape(20.dp),
            border = BorderStroke(1.dp, BuntuPalette.SlateElevated),
            modifier = Modifier
                .fillMaxWidth(0.95f)
                .widthIn(max = 860.dp)
                .fillMaxHeight(0.88f)
                .clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null,
                    onClick = {},
                ),
        ) {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(horizontal = metrics.horizontalScreenPadding, vertical = metrics.spacingM),
                verticalArrangement = Arrangement.spacedBy(metrics.spacingM),
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text(
                        text = "Rechercher",
                        style = MaterialTheme.typography.headlineSmall,
                        fontWeight = FontWeight.Bold,
                        color = BuntuPalette.PureWhite,
                    )
                    IconButton(onClick = onDismiss) {
                        Icon(
                            imageVector = Icons.Default.Close,
                            contentDescription = "Fermer",
                            tint = BuntuPalette.PureWhite,
                        )
                    }
                }

                // Explicit mode choice inside the popup: Local FTS5 vs AI Assistant
                Row(
                    horizontalArrangement = Arrangement.spacedBy(metrics.spacingS),
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .horizontalScroll(rememberScrollState()),
                ) {
                    SearchModeChip(
                        label = "🔍 Recherche locale",
                        selected = state.searchMode == SearchMode.LOCAL,
                        onClick = { viewModel.selectSearchMode(SearchMode.LOCAL) },
                    )
                    val aiLabel = if (state.aiAvailable && state.aiProviderLabel.isNotBlank()) {
                        "✨ IA · ${state.aiProviderLabel}"
                    } else {
                        "✨ Assistant IA"
                    }
                    SearchModeChip(
                        label = aiLabel,
                        selected = state.searchMode == SearchMode.AI,
                        onClick = { viewModel.selectSearchMode(SearchMode.AI) },
                    )
                }

                if (state.searchMode == SearchMode.AI && !state.aiBlockerMessage.isNullOrBlank()) {
                    Surface(
                        color = BuntuPalette.SlateElevated,
                        shape = RoundedCornerShape(12.dp),
                        border = BorderStroke(1.dp, BuntuPalette.TerangaGold.copy(alpha = 0.5f)),
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(metrics.spacingS),
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 12.dp, vertical = 10.dp),
                        ) {
                            Text(
                                text = state.aiBlockerMessage ?: "",
                                style = MaterialTheme.typography.bodySmall,
                                color = BuntuPalette.PureWhite,
                                modifier = Modifier.weight(1f),
                            )
                            OutlinedButton(onClick = onOpenSettings) {
                                Text("Configurer l'IA", color = BuntuPalette.TerangaGold)
                            }
                        }
                    }
                }

                BoxWithConstraints(modifier = Modifier.fillMaxWidth()) {
                    val compact = maxWidth < 600.dp
                    val actionLabel = if (state.searchMode == SearchMode.AI) "Demander à l'IA" else "Rechercher"
                    val placeholderText = when (state.searchMode) {
                        SearchMode.AI -> if (compact) "Ex. : thriller coréen, match ce soir…" else "Ex. : film d'action avec Tom Cruise, match ce soir…"
                        SearchMode.LOCAL -> if (compact) "Titre, chaîne, programme…" else "Tapez un titre, une chaîne ou un programme…"
                    }
                    val field = @Composable { fieldModifier: Modifier ->
                        OutlinedTextField(
                            value = state.query,
                            onValueChange = viewModel::updateQuery,
                            placeholder = {
                                Text(
                                    text = placeholderText,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            },
                            leadingIcon = { Icon(Icons.Default.Search, contentDescription = null) },
                            trailingIcon = {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    if (state.query.isNotEmpty()) {
                                        IconButton(onClick = { viewModel.updateQuery("") }) {
                                            Icon(Icons.Default.Close, contentDescription = "Effacer")
                                        }
                                    }
                                    IconButton(onClick = launchVoice) {
                                        Icon(Icons.Default.Mic, contentDescription = "Recherche vocale")
                                    }
                                }
                            },
                            singleLine = true,
                            keyboardOptions = KeyboardOptions(
                                capitalization = KeyboardCapitalization.None,
                                autoCorrectEnabled = false,
                                imeAction = ImeAction.Search,
                            ),
                            keyboardActions = KeyboardActions(onSearch = { viewModel.submitSearch() }),
                            modifier = fieldModifier,
                        )
                    }
                    if (compact) {
                        Column(verticalArrangement = Arrangement.spacedBy(metrics.spacingS)) {
                            field(Modifier.fillMaxWidth())
                            BuntuPrimaryActionButton(
                                label = actionLabel,
                                onClick = viewModel::submitSearch,
                                modifier = Modifier.fillMaxWidth(),
                            )
                        }
                    } else {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(metrics.spacingS),
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            field(Modifier.weight(1f))
                            BuntuPrimaryActionButton(
                                label = actionLabel,
                                onClick = viewModel::submitSearch,
                            )
                        }
                    }
                }

                // Scope filters scroll sideways instead of overflowing on a narrow screen.
                Row(
                    horizontalArrangement = Arrangement.spacedBy(metrics.spacingS),
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .horizontalScroll(rememberScrollState()),
                ) {
                    ScopeChip("Tout", SearchScopeKind.ALL, state.scope, viewModel::selectScope)
                    ScopeChip("Direct", SearchScopeKind.LIVE, state.scope, viewModel::selectScope)
                    ScopeChip("Films", SearchScopeKind.MOVIES, state.scope, viewModel::selectScope)
                    ScopeChip("Séries", SearchScopeKind.SERIES, state.scope, viewModel::selectScope)
                    if (state.isSearching) {
                        Spacer(modifier = Modifier.size(4.dp))
                        CircularProgressIndicator(
                            color = BuntuPalette.TerangaGold,
                            modifier = Modifier.size(22.dp),
                        )
                    }
                }

                LazyVerticalGrid(
                    columns = GridCells.Adaptive(minSize = metrics.posterGridMinCell),
                    modifier = Modifier
                        .fillMaxWidth()
                        .weight(1f),
                    contentPadding = PaddingValues(bottom = metrics.spacingM),
                    horizontalArrangement = Arrangement.spacedBy(metrics.spacingM),
                    verticalArrangement = Arrangement.spacedBy(metrics.spacingM),
                ) {
                    state.errorMessage?.let { err ->
                        item(key = "search_err", span = { GridItemSpan(maxLineSpan) }, contentType = "banner") {
                            BuntuErrorBanner(message = err)
                        }
                    }

                    if (state.assistantReply.isNotBlank()) {
                        item(key = "ai_reply", span = { GridItemSpan(maxLineSpan) }, contentType = "ai_card") {
                            Surface(
                                color = BuntuPalette.SlateElevated,
                                shape = RoundedCornerShape(12.dp),
                                modifier = Modifier.fillMaxWidth(),
                            ) {
                                Column(modifier = Modifier.padding(metrics.spacingM)) {
                                    Text(
                                        text = state.assistantReply,
                                        style = MaterialTheme.typography.bodyMedium,
                                        color = BuntuPalette.PureWhite,
                                    )
                                    if (state.missingTitles.isNotEmpty()) {
                                        Text(
                                            text = "Absents de vos sources : ${state.missingTitles.joinToString(", ")}",
                                            style = MaterialTheme.typography.labelSmall,
                                            color = BuntuPalette.MutedSilver,
                                        )
                                    }
                                }
                            }
                        }
                    }

                    if (state.query.isBlank() && state.hits.isEmpty()) {
                        item(key = "search_idle", span = { GridItemSpan(maxLineSpan) }, contentType = "empty_state") {
                            BuntuEmptyState(
                                title = "Que voulez-vous regarder ?",
                                subtitle = if (state.searchMode == SearchMode.AI) {
                                    "Décrivez votre envie en langage naturel pour lancer la recherche avec l'assistant IA."
                                } else {
                                    "Tapez un titre, une chaîne ou un programme EPG pour chercher instantanément dans vos sources."
                                },
                            )
                        }
                    } else if (!state.isSearching && state.hits.isEmpty()) {
                        item(key = "search_none", span = { GridItemSpan(maxLineSpan) }, contentType = "empty_state") {
                            BuntuEmptyState(
                                title = "Aucun résultat dans vos sources",
                                subtitle = "Essayez un autre mot-clé, changez de mode ou élargissez le filtre à « Tout ».",
                            )
                        }
                    } else {
                        items(
                            count = state.hits.size,
                            key = { idx -> "${state.hits[idx].kind}_${state.hits[idx].id}_$idx" },
                            contentType = { "search_hit_card" },
                        ) { idx ->
                            val hit = state.hits[idx]
                            BuntuPosterCard(
                                title = hit.title,
                                posterUrl = hit.posterUrl,
                                subtitle = hit.subtitle ?: hit.reason,
                                badge = hitBadge(hit.kind),
                                onClick = {
                                    dispatchHitClick(
                                        hit = hit,
                                        onOpenLiveChannel = onOpenLiveChannel,
                                        onOpenMovieDetail = onOpenMovieDetail,
                                        onOpenSeriesDetail = onOpenSeriesDetail,
                                        onOpenReplay = onOpenReplay,
                                    )
                                },
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun SearchModeChip(
    label: String,
    selected: Boolean,
    onClick: () -> Unit,
) {
    FilterChip(
        selected = selected,
        onClick = onClick,
        label = { Text(label) },
        colors = FilterChipDefaults.filterChipColors(
            selectedContainerColor = BuntuPalette.TerangaGold,
            selectedLabelColor = BuntuPalette.Midnight,
        ),
    )
}

@Composable
private fun ScopeChip(
    label: String,
    scope: SearchScopeKind,
    selected: SearchScopeKind,
    onSelect: (SearchScopeKind) -> Unit,
) {
    FilterChip(
        selected = scope == selected,
        onClick = { onSelect(scope) },
        label = { Text(label) },
        colors = FilterChipDefaults.filterChipColors(
            selectedContainerColor = BuntuPalette.TerangaGold,
            selectedLabelColor = BuntuPalette.Midnight,
        ),
    )
}

private fun hitBadge(kind: SearchHitKind): String = when (kind) {
    SearchHitKind.LIVE -> "DIRECT"
    SearchHitKind.PROGRAMME -> "EPG"
    SearchHitKind.REPLAY -> "REPLAY"
    SearchHitKind.MOVIE -> "FILM"
    SearchHitKind.SERIES -> "SÉRIE"
}

private fun dispatchHitClick(
    hit: SearchHitItem,
    onOpenLiveChannel: (Long) -> Unit,
    onOpenMovieDetail: (Long) -> Unit,
    onOpenSeriesDetail: (Long) -> Unit,
    onOpenReplay: (Long, Long, Long) -> Unit,
) {
    when (hit.kind) {
        SearchHitKind.LIVE, SearchHitKind.PROGRAMME -> onOpenLiveChannel(hit.id)
        SearchHitKind.REPLAY -> {
            val s = hit.startEpochSecs
            val e = hit.endEpochSecs
            if (s != null && e != null && e > s) {
                onOpenReplay(hit.id, s, e)
            } else {
                onOpenLiveChannel(hit.id)
            }
        }
        SearchHitKind.MOVIE -> onOpenMovieDetail(hit.id)
        SearchHitKind.SERIES -> onOpenSeriesDetail(hit.seriesId ?: hit.id)
    }
}
