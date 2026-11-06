package com.pcoundia.buntu.feature.downloads

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.pcoundia.buntu.core.designsystem.BuntuEmptyState
import com.pcoundia.buntu.core.designsystem.BuntuPalette
import com.pcoundia.buntu.core.designsystem.BuntuPrimaryActionButton
import com.pcoundia.buntu.core.designsystem.LocalBuntuMetrics
import com.pcoundia.buntu.core.domain.model.DownloadItem

@Composable
fun DownloadsRoute(
    onPlayDownloadedItem: (Long) -> Unit,
    viewModel: DownloadsViewModel = hiltViewModel(),
) {
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val metrics = LocalBuntuMetrics.current

    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .background(BuntuPalette.Midnight),
        contentPadding = PaddingValues(
            horizontal = metrics.horizontalScreenPadding,
            vertical = metrics.verticalScreenPadding,
        ),
        verticalArrangement = Arrangement.spacedBy(metrics.spacingM),
    ) {
        item(key = "dl_header", contentType = "header") {
            Column {
                Text(
                    text = "Téléchargements hors-ligne",
                    style = MaterialTheme.typography.headlineSmall,
                    fontWeight = FontWeight.Bold,
                    color = BuntuPalette.PureWhite,
                )
                Text(
                    text = "Les téléchargements se poursuivent en arrière-plan même lorsque l'écran s'éteint.",
                    style = MaterialTheme.typography.bodySmall,
                    color = BuntuPalette.MutedSilver,
                )
            }
        }

        if (state.tasks.isEmpty()) {
            item(key = "dl_empty", contentType = "empty_state") {
                BuntuEmptyState(
                    title = "Aucun téléchargement",
                    subtitle = "Ouvrez un film ou un épisode et touchez « Hors-ligne » pour le regarder sans réseau.",
                )
            }
        } else {
            items(
                items = state.tasks,
                key = { it.id },
                contentType = { "download_row" },
            ) { item ->
                DownloadTaskCard(
                    item = item,
                    onPlay = { item.itemId?.let(onPlayDownloadedItem) },
                    onPause = { viewModel.pause(item.id) },
                    onResume = { viewModel.resume(item.id) },
                    onRemove = { viewModel.remove(item.id) },
                )
            }
        }
    }
}

@Composable
private fun DownloadTaskCard(
    item: DownloadItem,
    onPlay: () -> Unit,
    onPause: () -> Unit,
    onResume: () -> Unit,
    onRemove: () -> Unit,
) {
    val metrics = LocalBuntuMetrics.current
    val downloadedMb = item.downloadedBytes / (1024.0 * 1024.0)
    val totalMb = item.totalBytes?.let { it / (1024.0 * 1024.0) }
    val speedMbps = (item.speedBytesPerSec * 8.0) / 1_000_000.0

    Surface(
        color = BuntuPalette.Slate,
        shape = RoundedCornerShape(12.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(
            modifier = Modifier.padding(metrics.spacingM),
            verticalArrangement = Arrangement.spacedBy(metrics.spacingS),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = item.title,
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.SemiBold,
                        color = BuntuPalette.PureWhite,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    val meta = buildString {
                        append(item.state)
                        append(" · %.1f Mo".format(downloadedMb))
                        if (totalMb != null) append(" / %.1f Mo".format(totalMb))
                        if (speedMbps > 0.05) append(" · %.1f Mb/s".format(speedMbps))
                    }
                    Text(
                        text = meta,
                        style = MaterialTheme.typography.bodySmall,
                        color = BuntuPalette.MutedSilver,
                    )
                }

                Row(horizontalArrangement = Arrangement.spacedBy(metrics.spacingXS)) {
                    when (item.state) {
                        "completed" -> {
                            if (item.itemId != null) {
                                BuntuPrimaryActionButton(label = "Lire", onClick = onPlay)
                            }
                        }
                        "downloading", "queued", "probing" -> {
                            OutlinedButton(onClick = onPause) {
                                Text("Pause", color = BuntuPalette.PureWhite)
                            }
                        }
                        else -> {
                            OutlinedButton(onClick = onResume) {
                                Text("Reprendre", color = BuntuPalette.TerangaGold)
                            }
                        }
                    }
                    OutlinedButton(onClick = onRemove) {
                        Text("Supprimer", color = BuntuPalette.DangerRed)
                    }
                }
            }

            if (item.state != "completed") {
                Spacer(modifier = Modifier.height(2.dp))
                LinearProgressIndicator(
                    progress = { item.progressFraction },
                    color = BuntuPalette.TerangaGold,
                    trackColor = BuntuPalette.Midnight,
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(4.dp),
                )
            }

            item.errorMessage?.takeIf { it.isNotBlank() }?.let { err ->
                Text(
                    text = err,
                    style = MaterialTheme.typography.bodySmall,
                    color = BuntuPalette.DangerRed,
                )
            }
        }
    }
}

