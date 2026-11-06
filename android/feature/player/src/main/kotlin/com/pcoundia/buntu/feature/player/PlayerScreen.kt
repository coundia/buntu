package com.pcoundia.buntu.feature.player

import android.app.Activity
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.pcoundia.buntu.core.designsystem.BuntuErrorBanner
import com.pcoundia.buntu.core.designsystem.BuntuPalette
import com.pcoundia.buntu.core.designsystem.BuntuPrimaryActionButton
import com.pcoundia.buntu.core.designsystem.LocalBuntuMetrics
import com.pcoundia.buntu.core.domain.model.StreamKind
import com.pcoundia.buntu.core.platform.pip.PipHelper
import com.pcoundia.buntu.core.player.BuntuVideoSurface

@Composable
fun PlayerRoute(
    onBack: () -> Unit,
    onNavigateToDownloads: () -> Unit,
    viewModel: PlayerViewModel = hiltViewModel(),
) {
    val screenState by viewModel.screenState.collectAsStateWithLifecycle()
    val engineState by viewModel.engineState.collectAsStateWithLifecycle()
    val metrics = LocalBuntuMetrics.current
    val context = LocalContext.current
    val activity = context as? Activity

    DisposableEffect(activity, engineState.isPlaying, screenState.isTv) {
        if (activity != null) {
            PipHelper.updateAutoEnter(activity, screenState.isTv, engineState.isPlaying)
        }
        onDispose {
            if (activity != null) {
                PipHelper.updateAutoEnter(activity, screenState.isTv, false)
            }
        }
    }

    BackHandler {
        if (screenState.showTrackSheet) {
            viewModel.toggleTrackSheet(false)
        } else if (screenState.showVersionsSheet) {
            viewModel.toggleVersionsSheet(false)
        } else {
            viewModel.stopPlaybackAndCleanup()
            onBack()
        }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black)
            .onPreviewKeyEvent { event ->
                if (event.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                viewModel.showControls()
                val isLive = engineState.activeStream?.kind == StreamKind.LIVE
                when (event.key) {
                    Key.MediaPlayPause, Key.Spacebar -> {
                        viewModel.videoEngine.togglePlayPause()
                        true
                    }
                    Key.DirectionLeft, Key.MediaRewind -> {
                        if (!isLive) {
                            viewModel.videoEngine.seekBy(-10_000L)
                            true
                        } else false
                    }
                    Key.DirectionRight, Key.MediaFastForward -> {
                        if (!isLive) {
                            viewModel.videoEngine.seekBy(30_000L)
                            true
                        } else false
                    }
                    Key.DirectionUp, Key.ChannelUp -> {
                        if (isLive) {
                            viewModel.zapAdjacentLive(-1)
                            true
                        } else false
                    }
                    Key.DirectionDown, Key.ChannelDown -> {
                        if (isLive) {
                            viewModel.zapAdjacentLive(+1)
                            true
                        } else false
                    }
                    else -> false
                }
            }
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                onClick = viewModel::toggleControls,
            ),
    ) {
        BuntuVideoSurface(
            videoEngine = viewModel.videoEngine,
            modifier = Modifier.fillMaxSize(),
        )

        if (engineState.isBuffering) {
            CircularProgressIndicator(
                color = BuntuPalette.TerangaGold,
                modifier = Modifier
                    .size(48.dp)
                    .align(Alignment.Center),
            )
        }

        // Insufficient bandwidth warning banner (PRD-37 § 4.3 & § 5.4)
        engineState.bandwidthWarning?.let { bw ->
            Surface(
                color = BuntuPalette.SlateElevated.copy(alpha = 0.96f),
                shape = RoundedCornerShape(14.dp),
                modifier = Modifier
                    .align(Alignment.TopCenter)
                    .padding(
                        horizontal = metrics.horizontalScreenPadding,
                        vertical = metrics.verticalScreenPadding,
                    )
                    .fillMaxWidth(),
            ) {
                Column(
                    modifier = Modifier.padding(metrics.spacingM),
                    verticalArrangement = Arrangement.spacedBy(metrics.spacingS),
                ) {
                    Text(
                        text = "Débit insuffisant (%.1f Mb/s mesurés pour ~%.1f Mb/s requis)".format(
                            bw.measuredMbps,
                            bw.requiredMbps,
                        ),
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.Bold,
                        color = BuntuPalette.TerangaGold,
                    )
                    Row(horizontalArrangement = Arrangement.spacedBy(metrics.spacingS)) {
                        if (screenState.otherVersions.isNotEmpty()) {
                            BuntuPrimaryActionButton(
                                label = "Autre version",
                                onClick = { viewModel.toggleVersionsSheet(true) },
                            )
                        }
                        if (!screenState.isTv && engineState.activeStream?.kind != StreamKind.LIVE) {
                            OutlinedButton(
                                onClick = { viewModel.downloadInsteadAndExit(onNavigateToDownloads) },
                            ) {
                                Text("Télécharger puis regarder", color = BuntuPalette.PureWhite)
                            }
                        }
                        OutlinedButton(onClick = { viewModel.videoEngine.dismissBandwidthWarning() }) {
                            Text("Continuer", color = BuntuPalette.MutedSilver)
                        }
                    }
                }
            }
        }

        // Clear diagnosis error banner
        engineState.diagnosis?.let { diagnosis ->
            Box(
                modifier = Modifier
                    .align(Alignment.Center)
                    .padding(metrics.horizontalScreenPadding),
            ) {
                BuntuErrorBanner(
                    message = diagnosis.userMessage,
                    actionLabel = "Retour",
                    onAction = {
                        viewModel.stopPlaybackAndCleanup()
                        onBack()
                    },
                )
            }
        }

        // Top & Bottom OSD Controls
        if (screenState.controlsVisible) {
            Column(
                verticalArrangement = Arrangement.SpaceBetween,
                modifier = Modifier
                    .fillMaxSize()
                    .background(BuntuPalette.Midnight.copy(alpha = 0.48f))
                    .padding(
                        horizontal = metrics.horizontalScreenPadding,
                        vertical = metrics.verticalScreenPadding,
                    ),
            ) {
                // Top Bar
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        OutlinedButton(
                            onClick = {
                                viewModel.stopPlaybackAndCleanup()
                                onBack()
                            },
                        ) {
                            Text("← Retour", color = BuntuPalette.PureWhite)
                        }
                        Spacer(modifier = Modifier.width(metrics.spacingM))
                        Column {
                            Text(
                                text = engineState.activeStream?.title ?: "Lecture en cours",
                                style = MaterialTheme.typography.titleLarge,
                                fontWeight = FontWeight.Bold,
                                color = BuntuPalette.PureWhite,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                            engineState.activeStream?.subtitle?.let { sub ->
                                Text(
                                    text = sub,
                                    style = MaterialTheme.typography.bodySmall,
                                    color = BuntuPalette.LeerCyan,
                                )
                            }
                        }
                    }

                    Row(horizontalArrangement = Arrangement.spacedBy(metrics.spacingS)) {
                        if (engineState.audioTracks.isNotEmpty() || engineState.subtitleTracks.isNotEmpty()) {
                            OutlinedButton(onClick = { viewModel.toggleTrackSheet(true) }) {
                                Text("Audio / Sous-titres", color = BuntuPalette.PureWhite)
                            }
                        }
                        if (activity != null && PipHelper.isSupported(activity, screenState.isTv)) {
                            OutlinedButton(onClick = { PipHelper.enterPipNow(activity, screenState.isTv) }) {
                                Text("PiP", color = BuntuPalette.PureWhite)
                            }
                        }
                    }
                }

                // Bottom Transport Bar
                Column(verticalArrangement = Arrangement.spacedBy(metrics.spacingS)) {
                    val isLive = engineState.activeStream?.kind == StreamKind.LIVE
                    if (!isLive && engineState.durationMs > 0L) {
                        val sliderPos = (engineState.positionMs.toFloat() / engineState.durationMs.toFloat())
                            .coerceIn(0f, 1f)
                        Slider(
                            value = sliderPos,
                            onValueChange = { frac ->
                                val target = (frac * engineState.durationMs).toLong()
                                viewModel.videoEngine.seekTo(target)
                            },
                            colors = SliderDefaults.colors(
                                thumbColor = BuntuPalette.TerangaGold,
                                activeTrackColor = BuntuPalette.TerangaGold,
                            ),
                        )
                        Row(
                            horizontalArrangement = Arrangement.SpaceBetween,
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Text(
                                text = formatDurationMs(engineState.positionMs),
                                style = MaterialTheme.typography.labelMedium,
                                color = BuntuPalette.PureWhite,
                            )
                            Text(
                                text = formatDurationMs(engineState.durationMs),
                                style = MaterialTheme.typography.labelMedium,
                                color = BuntuPalette.MutedSilver,
                            )
                        }
                    } else if (isLive) {
                        LinearProgressIndicator(
                            progress = { 1f },
                            color = BuntuPalette.LeerCyan,
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(3.dp),
                        )
                    }

                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(metrics.spacingM),
                    ) {
                        BuntuPrimaryActionButton(
                            label = if (engineState.isPlaying) "⏸ Pause" else "▶ Lecture",
                            onClick = { viewModel.videoEngine.togglePlayPause() },
                        )
                        if (isLive) {
                            OutlinedButton(onClick = { viewModel.zapAdjacentLive(-1) }) {
                                Text("Chaîne −", color = BuntuPalette.PureWhite)
                            }
                            OutlinedButton(onClick = { viewModel.zapAdjacentLive(+1) }) {
                                Text("Chaîne +", color = BuntuPalette.PureWhite)
                            }
                        } else {
                            OutlinedButton(onClick = { viewModel.videoEngine.seekBy(-10_000L) }) {
                                Text("−10s", color = BuntuPalette.PureWhite)
                            }
                            OutlinedButton(onClick = { viewModel.videoEngine.seekBy(30_000L) }) {
                                Text("+30s", color = BuntuPalette.PureWhite)
                            }
                        }
                    }
                }
            }
        }

        // Audio / Subtitles Overlay Sheet
        if (screenState.showTrackSheet) {
            Surface(
                color = BuntuPalette.Slate.copy(alpha = 0.97f),
                shape = RoundedCornerShape(16.dp),
                modifier = Modifier
                    .align(Alignment.CenterEnd)
                    .padding(metrics.spacingXL)
                    .width(360.dp),
            ) {
                LazyColumn(
                    modifier = Modifier.padding(metrics.spacingL),
                    verticalArrangement = Arrangement.spacedBy(metrics.spacingS),
                ) {
                    item(key = "tracks_title") {
                        Row(
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Text(
                                text = "Pistes Audio & Sous-titres",
                                style = MaterialTheme.typography.titleMedium,
                                fontWeight = FontWeight.Bold,
                                color = BuntuPalette.PureWhite,
                            )
                            OutlinedButton(onClick = { viewModel.toggleTrackSheet(false) }) {
                                Text("Fermer", color = BuntuPalette.PureWhite)
                            }
                        }
                    }

                    if (engineState.audioTracks.isNotEmpty()) {
                        item(key = "audio_hdr") {
                            Text("Audio", color = BuntuPalette.TerangaGold, fontWeight = FontWeight.Bold)
                        }
                        items(
                            items = engineState.audioTracks,
                            key = { "aud_${it.id}" },
                        ) { track ->
                            FilterChip(
                                selected = track.isSelected,
                                onClick = {
                                    viewModel.videoEngine.selectAudioTrack(track.groupIndex, track.trackIndex)
                                },
                                label = { Text(track.label) },
                            )
                        }
                    }

                    item(key = "sub_hdr") {
                        Text("Sous-titres", color = BuntuPalette.TerangaGold, fontWeight = FontWeight.Bold)
                    }
                    item(key = "sub_off") {
                        FilterChip(
                            selected = engineState.subtitlesDisabled,
                            onClick = { viewModel.videoEngine.selectSubtitleTrack(null, null) },
                            label = { Text("Désactivés") },
                        )
                    }
                    items(
                        items = engineState.subtitleTracks,
                        key = { "sub_${it.id}" },
                    ) { track ->
                        FilterChip(
                            selected = track.isSelected && !engineState.subtitlesDisabled,
                            onClick = {
                                viewModel.videoEngine.selectSubtitleTrack(track.groupIndex, track.trackIndex)
                            },
                            label = { Text(track.label) },
                        )
                    }

                    item(key = "sub_offset") {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(metrics.spacingXS),
                        ) {
                            OutlinedButton(
                                onClick = {
                                    viewModel.videoEngine.setSubtitleOffsetMs(engineState.subtitleOffsetMs - 250L)
                                },
                            ) {
                                Text("−0.25s", color = BuntuPalette.PureWhite)
                            }
                            Text(
                                text = "${engineState.subtitleOffsetMs} ms",
                                color = BuntuPalette.MutedSilver,
                            )
                            OutlinedButton(
                                onClick = {
                                    viewModel.videoEngine.setSubtitleOffsetMs(engineState.subtitleOffsetMs + 250L)
                                },
                            ) {
                                Text("+0.25s", color = BuntuPalette.PureWhite)
                            }
                        }
                    }
                }
            }
        }

        // Alternate Versions Overlay Sheet
        if (screenState.showVersionsSheet && screenState.otherVersions.isNotEmpty()) {
            Surface(
                color = BuntuPalette.Slate.copy(alpha = 0.97f),
                shape = RoundedCornerShape(16.dp),
                modifier = Modifier
                    .align(Alignment.Center)
                    .padding(metrics.spacingXL)
                    .width(400.dp),
            ) {
                LazyColumn(
                    modifier = Modifier.padding(metrics.spacingL),
                    verticalArrangement = Arrangement.spacedBy(metrics.spacingS),
                ) {
                    item(key = "ver_hdr") {
                        Text(
                            text = "Choisir une autre version",
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.Bold,
                            color = BuntuPalette.PureWhite,
                        )
                    }
                    items(
                        items = screenState.otherVersions,
                        key = { it.id },
                    ) { ver ->
                        OutlinedButton(
                            onClick = { viewModel.switchVersion(ver) },
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Text(
                                text = "${ver.title} (${ver.containerExtension?.uppercase() ?: "VOD"})",
                                color = BuntuPalette.PureWhite,
                            )
                        }
                    }
                }
            }
        }
    }
}

private fun formatDurationMs(ms: Long): String {
    val totalSecs = (ms / 1_000L).coerceAtLeast(0L)
    val h = totalSecs / 3600L
    val m = (totalSecs % 3600L) / 60L
    val s = totalSecs % 60L
    return if (h > 0L) {
        "%d:%02d:%02d".format(h, m, s)
    } else {
        "%02d:%02d".format(m, s)
    }
}

