package com.pcoundia.buntu.feature.search

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import android.app.Activity
import android.content.Intent
import android.speech.RecognizerIntent
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
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
            key = "search_bar",
            span = { GridItemSpan(maxLineSpan) },
            contentType = "search_header",
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(metrics.spacingM)) {
                Text(
                    text = "Recherche universelle & IA",
                    style = MaterialTheme.typography.headlineSmall,
                    fontWeight = FontWeight.Bold,
                    color = BuntuPalette.PureWhite,
                )

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
                // Phones in portrait (< 600 dp): the field takes the whole width and "Demander" goes below,
                // so neither the text nor the buttons are squeezed. Wider screens keep everything on one row.
                BoxWithConstraints(modifier = Modifier.fillMaxWidth()) {
                    val compact = maxWidth < 600.dp
                    val field = @Composable { fieldModifier: Modifier ->
                        OutlinedTextField(
                            value = state.query,
                            onValueChange = viewModel::updateQuery,
                            placeholder = {
                                Text(
                                    text = if (compact) "Chaîne, film, envie…" else "Ex. : match ce soir, thriller coréen, RTS 1…",
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            },
                            leadingIcon = { Icon(Icons.Default.Search, contentDescription = null) },
                            trailingIcon = {
                                IconButton(onClick = launchVoice) {
                                    Icon(Icons.Default.Mic, contentDescription = "Recherche vocale")
                                }
                            },
                            singleLine = true,
                            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                            keyboardActions = KeyboardActions(onSearch = { viewModel.submitSmartSearch() }),
                            modifier = fieldModifier,
                        )
                    }
                    if (compact) {
                        Column(verticalArrangement = Arrangement.spacedBy(metrics.spacingS)) {
                            field(Modifier.fillMaxWidth())
                            BuntuPrimaryActionButton(
                                label = "Demander",
                                onClick = viewModel::submitSmartSearch,
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
                                label = "Demander",
                                onClick = viewModel::submitSmartSearch,
                            )
                        }
                    }
                }

                // The filters scroll sideways instead of overflowing on a narrow screen.
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
                        CircularProgressIndicator(
                            color = BuntuPalette.TerangaGold,
                            modifier = Modifier.size(22.dp),
                        )
                    }
                }
            }
        }

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
                    subtitle = "Tapez un titre, une chaîne, un programme EPG ou une envie en langage naturel.",
                )
            }
        } else if (!state.isSearching && state.hits.isEmpty()) {
            item(key = "search_none", span = { GridItemSpan(maxLineSpan) }, contentType = "empty_state") {
                BuntuEmptyState(
                    title = "Aucun résultat dans vos sources",
                    subtitle = "Essayez un autre mot-clé ou élargissez le filtre à « Tout ».",
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
                    onClick = { dispatchHitClick(hit, onOpenLiveChannel, onOpenMovieDetail, onOpenSeriesDetail, onOpenReplay) },
                )
            }
        }
    }
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

