package com.pcoundia.buntu.feature.details

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PhoneAndroid
import androidx.compose.material.icons.filled.Tv
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import coil3.compose.AsyncImage
import com.pcoundia.buntu.core.designsystem.BuntuErrorBanner
import com.pcoundia.buntu.core.designsystem.BuntuPalette
import com.pcoundia.buntu.core.designsystem.BuntuPrimaryActionButton
import com.pcoundia.buntu.core.designsystem.LocalBuntuMetrics
import com.pcoundia.buntu.core.domain.model.EpisodeItem
import com.pcoundia.buntu.core.domain.model.MediaDetail

@Composable
fun DetailsRoute(
    onPlayMedia: (itemId: Long, startPositionMs: Long) -> Unit,
    onBack: () -> Unit,
    viewModel: DetailsViewModel = hiltViewModel(),
) {
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val peers by viewModel.availablePeers.collectAsStateWithLifecycle()
    val handoffStatus by viewModel.handoffStatus.collectAsStateWithLifecycle()
    var showRemoteDialog by remember { mutableStateOf(false) }
    val metrics = LocalBuntuMetrics.current
    val primaryFocusRequester = remember { FocusRequester() }

    LaunchedEffect(state.detail?.id, state.isTv) {
        if (state.isTv && state.detail != null) {
            runCatching { primaryFocusRequester.requestFocus() }
        }
    }

    if (state.isLoading) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(BuntuPalette.Midnight),
            contentAlignment = Alignment.Center,
        ) {
            CircularProgressIndicator(color = BuntuPalette.TerangaGold)
        }
        return
    }

    val detail = state.detail
    if (detail == null) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .background(BuntuPalette.Midnight)
                .padding(metrics.horizontalScreenPadding),
            verticalArrangement = Arrangement.Center,
        ) {
            BuntuErrorBanner(
                message = state.errorMessage ?: "Contenu introuvable.",
                actionLabel = "Retour",
                onAction = onBack,
            )
        }
        return
    }

    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .background(BuntuPalette.Midnight),
        contentPadding = PaddingValues(
            horizontal = metrics.horizontalScreenPadding,
            vertical = metrics.verticalScreenPadding,
        ),
        verticalArrangement = Arrangement.spacedBy(metrics.spacingL),
    ) {
        item(key = "hero", contentType = "details_hero") {
            DetailsHeroSection(
                detail = detail,
                primaryEpisode = state.primaryEpisode,
                isTv = state.isTv,
                hasOnlinePeers = peers.any { it.state != "offline" },
                primaryFocusRequester = primaryFocusRequester,
                onPlayPrimary = {
                    if (detail.isSeries) {
                        val ep = state.primaryEpisode ?: detail.episodes.firstOrNull()
                        if (ep != null) {
                            val startMs = if (ep.watchPositionMs >= 30_000L) ep.watchPositionMs else 0L
                            onPlayMedia(ep.id, startMs)
                        }
                    } else {
                        val movie = detail.movieItem
                        if (movie != null) {
                            val startMs = if (movie.hasResumePoint) movie.watchPositionMs else 0L
                            onPlayMedia(movie.id, startMs)
                        } else {
                            onPlayMedia(detail.id, 0L)
                        }
                    }
                },
                onPlayFromBeginning = {
                    val targetId = if (detail.isSeries) {
                        (state.primaryEpisode ?: detail.episodes.firstOrNull())?.id
                    } else {
                        detail.movieItem?.id ?: detail.id
                    }
                    if (targetId != null) onPlayMedia(targetId, 0L)
                },
                onToggleFavorite = viewModel::toggleFavorite,
                onDownload = {
                    val dlId = if (detail.isSeries) state.primaryEpisode?.id else (detail.movieItem?.id ?: detail.id)
                    if (dlId != null) viewModel.enqueueDownload(dlId)
                },
                onOpenRemoteDialog = { showRemoteDialog = true },
                onBack = onBack,
            )
        }

        state.statusBanner?.let { msg ->
            item(key = "status_banner", contentType = "banner") {
                Surface(color = BuntuPalette.SlateElevated, shape = RoundedCornerShape(10.dp)) {
                    Text(
                        text = msg,
                        color = BuntuPalette.LeerCyan,
                        modifier = Modifier.padding(metrics.spacingM),
                    )
                }
            }
        }

        state.errorMessage?.let { err ->
            item(key = "err_banner", contentType = "banner") {
                BuntuErrorBanner(message = err)
            }
        }

        if (!detail.isSeries && detail.otherVersions.isNotEmpty()) {
            item(key = "other_versions", contentType = "versions") {
                Column(verticalArrangement = Arrangement.spacedBy(metrics.spacingS)) {
                    Text(
                        text = "Autres versions disponibles",
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.Bold,
                        color = BuntuPalette.PureWhite,
                    )
                    LazyRow(horizontalArrangement = Arrangement.spacedBy(metrics.spacingS)) {
                        items(
                            items = detail.otherVersions,
                            key = { it.id },
                            contentType = { "version_chip" },
                        ) { alt ->
                            OutlinedButton(onClick = { onPlayMedia(alt.id, 0L) }) {
                                Text(
                                    text = "${alt.title} (${alt.containerExtension?.uppercase() ?: "VOD"})",
                                    color = BuntuPalette.PureWhite,
                                )
                            }
                        }
                    }
                }
            }
        }

        if (detail.isSeries && detail.seasons.isNotEmpty()) {
            item(key = "season_selector", contentType = "seasons") {
                LazyRow(horizontalArrangement = Arrangement.spacedBy(metrics.spacingS)) {
                    items(
                        items = detail.seasons,
                        key = { it.seasonNumber },
                        contentType = { "season_chip" },
                    ) { season ->
                        FilterChip(
                            selected = state.selectedSeason == season.seasonNumber,
                            onClick = { viewModel.selectSeason(season.seasonNumber) },
                            label = { Text("Saison ${season.seasonNumber} (${season.episodeCount})") },
                            colors = FilterChipDefaults.filterChipColors(
                                selectedContainerColor = BuntuPalette.TerangaGold,
                                selectedLabelColor = BuntuPalette.Midnight,
                            ),
                        )
                    }
                }
            }
        }

        if (detail.isSeries) {
            items(
                items = detail.episodes,
                key = { it.id },
                contentType = { "episode_row" },
            ) { episode ->
                EpisodeRowCard(
                    episode = episode,
                    isTv = state.isTv,
                    onPlay = {
                        val startMs = if (episode.watchPositionMs >= 30_000L) episode.watchPositionMs else 0L
                        onPlayMedia(episode.id, startMs)
                    },
                    onDownload = { viewModel.enqueueDownload(episode.id) },
                )
            }
        }
    }

    if (showRemoteDialog) {
        val onlinePeers = peers.filter { it.state != "offline" }
        AlertDialog(
            onDismissRequest = { showRemoteDialog = false },
            title = { Text("Lire sur un autre appareil") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    handoffStatus?.let { status ->
                        Text(status, color = BuntuPalette.LeerCyan, style = MaterialTheme.typography.bodyMedium)
                        Spacer(modifier = Modifier.height(4.dp))
                    }
                    if (onlinePeers.isEmpty()) {
                        Text("Aucun appareil disponible.", style = MaterialTheme.typography.bodySmall)
                    } else {
                        onlinePeers.forEach { peer ->
                            Surface(
                                color = BuntuPalette.SlateElevated,
                                shape = RoundedCornerShape(8.dp),
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable {
                                        viewModel.playOnPeer(peer.id) {
                                            showRemoteDialog = false
                                        }
                                    },
                            ) {
                                Row(
                                    modifier = Modifier.padding(12.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                ) {
                                    Icon(
                                        imageVector = if (peer.deviceType == "tv") Icons.Default.Tv else Icons.Default.PhoneAndroid,
                                        contentDescription = null,
                                        tint = BuntuPalette.PureWhite,
                                    )
                                    Spacer(modifier = Modifier.width(10.dp))
                                    Text(peer.name, color = BuntuPalette.PureWhite, style = MaterialTheme.typography.bodyMedium)
                                }
                            }
                        }
                    }
                }
            },
            confirmButton = {},
            dismissButton = {
                TextButton(onClick = { showRemoteDialog = false }) {
                    Text("Fermer")
                }
            },
        )
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun DetailsHeroSection(
    detail: MediaDetail,
    primaryEpisode: EpisodeItem?,
    isTv: Boolean,
    hasOnlinePeers: Boolean,
    primaryFocusRequester: FocusRequester,
    onPlayPrimary: () -> Unit,
    onPlayFromBeginning: () -> Unit,
    onToggleFavorite: () -> Unit,
    onDownload: () -> Unit,
    onOpenRemoteDialog: () -> Unit,
    onBack: () -> Unit,
) {
    val metrics = LocalBuntuMetrics.current
    var plotExpanded by remember(detail.id) { mutableStateOf(false) }
    val primaryLabel = when {
        detail.isSeries && primaryEpisode != null -> {
            if (primaryEpisode.watchPositionMs >= 30_000L) {
                "▶ Reprendre ${primaryEpisode.code}"
            } else {
                "▶ Regarder ${primaryEpisode.code}"
            }
        }
        detail.movieItem?.hasResumePoint == true -> "▶ Reprendre le film"
        else -> "▶ Regarder maintenant"
    }

    val metaParts = buildList {
        detail.year?.let { add(it.toString()) }
        detail.runtimeMinutes?.let { add("$it min") }
        detail.rating?.takeIf { it.isNotBlank() }?.let { add("★ $it") }
        detail.containerExtension?.uppercase()?.let { add(it) }
        detail.genre?.takeIf { it.isNotBlank() }?.let { add(it) }
    }

    val actionButtons = @Composable {
        FlowRow(
            horizontalArrangement = Arrangement.spacedBy(metrics.spacingS),
            verticalArrangement = Arrangement.spacedBy(metrics.spacingS),
            modifier = Modifier.fillMaxWidth(),
        ) {
            BuntuPrimaryActionButton(
                label = primaryLabel,
                onClick = onPlayPrimary,
                modifier = Modifier.focusRequester(primaryFocusRequester),
            )

            if (detail.movieItem?.hasResumePoint == true) {
                OutlinedButton(onClick = onPlayFromBeginning) {
                    Text("Depuis le début", color = BuntuPalette.PureWhite)
                }
            }

            OutlinedButton(onClick = onToggleFavorite) {
                Text(
                    text = if (detail.isFavorite) "★ Favori" else "☆ Favori",
                    color = BuntuPalette.TerangaGold,
                )
            }

            if (hasOnlinePeers) {
                OutlinedButton(onClick = onOpenRemoteDialog) {
                    Text("Lire sur…", color = BuntuPalette.PureWhite)
                }
            }

            if (!isTv) {
                OutlinedButton(onClick = onDownload) {
                    Text("⬇ Hors-ligne", color = BuntuPalette.PureWhite)
                }
            }
        }
    }

    val plotAndCredits = @Composable {
        val plotText = detail.plot
        if (!plotText.isNullOrBlank()) {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(
                    text = plotText,
                    style = MaterialTheme.typography.bodyMedium,
                    color = BuntuPalette.MutedSilver,
                    maxLines = if (plotExpanded) Int.MAX_VALUE else 4,
                    overflow = TextOverflow.Ellipsis,
                )
                if (plotText.length > 180) {
                    Text(
                        text = if (plotExpanded) "Voir moins" else "Voir plus",
                        style = MaterialTheme.typography.labelMedium,
                        color = BuntuPalette.LeerCyan,
                        fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.clickable { plotExpanded = !plotExpanded },
                    )
                }
            }
        }
        detail.director?.takeIf { it.isNotBlank() }?.let { director ->
            Text(
                text = "Réalisation : $director",
                style = MaterialTheme.typography.bodySmall,
                color = BuntuPalette.PureWhite.copy(alpha = 0.8f),
            )
        }
        detail.cast?.takeIf { it.isNotBlank() }?.let { cast ->
            Text(
                text = "Avec : $cast",
                style = MaterialTheme.typography.bodySmall,
                color = BuntuPalette.MutedSilver,
                maxLines = if (plotExpanded) Int.MAX_VALUE else 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }

    Column(verticalArrangement = Arrangement.spacedBy(metrics.spacingM)) {
        OutlinedButton(onClick = onBack) {
            Text("← Retour", color = BuntuPalette.PureWhite)
        }

        BoxWithConstraints(modifier = Modifier.fillMaxWidth()) {
            val isCompact = maxWidth < 600.dp
            if (isCompact) {
                Column(
                    verticalArrangement = Arrangement.spacedBy(metrics.spacingM),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(metrics.spacingM),
                        verticalAlignment = Alignment.Top,
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        if (!detail.posterUrl.isNullOrBlank()) {
                            AsyncImage(
                                model = detail.posterUrl,
                                contentDescription = detail.title,
                                contentScale = ContentScale.Crop,
                                modifier = Modifier
                                    .width(116.dp)
                                    .aspectRatio(2f / 3f)
                                    .clip(RoundedCornerShape(12.dp))
                                    .background(BuntuPalette.Slate),
                            )
                        }
                        Column(
                            modifier = Modifier.weight(1f),
                            verticalArrangement = Arrangement.spacedBy(metrics.spacingXS),
                        ) {
                            Text(
                                text = detail.title,
                                style = MaterialTheme.typography.headlineSmall,
                                fontWeight = FontWeight.Bold,
                                color = BuntuPalette.PureWhite,
                            )
                            if (metaParts.isNotEmpty()) {
                                Text(
                                    text = metaParts.joinToString(" · "),
                                    style = MaterialTheme.typography.bodySmall,
                                    color = BuntuPalette.LeerCyan,
                                )
                            }
                        }
                    }
                    plotAndCredits()
                    actionButtons()
                }
            } else {
                Row(
                    horizontalArrangement = Arrangement.spacedBy(metrics.spacingL),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    if (!detail.posterUrl.isNullOrBlank()) {
                        AsyncImage(
                            model = detail.posterUrl,
                            contentDescription = detail.title,
                            contentScale = ContentScale.Crop,
                            modifier = Modifier
                                .width(metrics.posterCardWidth)
                                .height(metrics.posterCardHeight)
                                .clip(RoundedCornerShape(14.dp))
                                .background(BuntuPalette.Slate),
                        )
                    }

                    Column(
                        modifier = Modifier.weight(1f),
                        verticalArrangement = Arrangement.spacedBy(metrics.spacingS),
                    ) {
                        Text(
                            text = detail.title,
                            style = MaterialTheme.typography.headlineMedium,
                            fontWeight = FontWeight.Bold,
                            color = BuntuPalette.PureWhite,
                        )
                        if (metaParts.isNotEmpty()) {
                            Text(
                                text = metaParts.joinToString(" · "),
                                style = MaterialTheme.typography.bodyMedium,
                                color = BuntuPalette.LeerCyan,
                            )
                        }
                        plotAndCredits()
                        Spacer(modifier = Modifier.height(metrics.spacingXS))
                        actionButtons()
                    }
                }
            }
        }
    }
}

@Composable
private fun EpisodeRowCard(
    episode: EpisodeItem,
    isTv: Boolean,
    onPlay: () -> Unit,
    onDownload: () -> Unit,
) {
    val metrics = LocalBuntuMetrics.current
    Surface(
        color = BuntuPalette.Slate,
        shape = RoundedCornerShape(12.dp),
        modifier = Modifier
            .fillMaxWidth()
            .focusable()
            .clickable(onClick = onPlay),
    ) {
        BoxWithConstraints(modifier = Modifier.padding(metrics.spacingM)) {
            val isNarrow = maxWidth < 400.dp
            val episodeMeta = @Composable { modifier: Modifier ->
                Column(modifier = modifier) {
                    Text(
                        text = "${episode.code} · ${episode.title}",
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.SemiBold,
                        color = BuntuPalette.PureWhite,
                        maxLines = if (isNarrow) 2 else 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    if (episode.watchPositionMs >= 30_000L) {
                        val mins = episode.watchPositionMs / 60_000L
                        Text(
                            text = "Reprise à ${mins} min",
                            style = MaterialTheme.typography.bodySmall,
                            color = BuntuPalette.TerangaGold,
                        )
                    }
                }
            }
            val episodeActions = @Composable {
                Row(horizontalArrangement = Arrangement.spacedBy(metrics.spacingS)) {
                    BuntuPrimaryActionButton(
                        label = "Lecture",
                        onClick = onPlay,
                    )
                    if (!isTv) {
                        OutlinedButton(onClick = onDownload) {
                            Text("⬇", color = BuntuPalette.PureWhite)
                        }
                    }
                }
            }
            if (isNarrow) {
                Column(
                    verticalArrangement = Arrangement.spacedBy(metrics.spacingS),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    episodeMeta(Modifier.fillMaxWidth())
                    episodeActions()
                }
            } else {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    episodeMeta(Modifier.weight(1f))
                    Spacer(modifier = Modifier.width(metrics.spacingS))
                    episodeActions()
                }
            }
        }
    }
}

