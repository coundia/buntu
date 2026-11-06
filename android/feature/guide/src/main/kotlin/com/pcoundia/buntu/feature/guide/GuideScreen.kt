package com.pcoundia.buntu.feature.guide

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.focusable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.pcoundia.buntu.core.designsystem.BuntuCategoryChips
import com.pcoundia.buntu.core.designsystem.BuntuEmptyState
import com.pcoundia.buntu.core.designsystem.BuntuErrorBanner
import com.pcoundia.buntu.core.designsystem.BuntuPalette
import com.pcoundia.buntu.core.designsystem.BuntuPrimaryActionButton
import com.pcoundia.buntu.core.designsystem.LocalBuntuMetrics
import com.pcoundia.buntu.core.domain.model.ChannelGuideRow
import com.pcoundia.buntu.core.domain.model.EpgSlot
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

@Composable
fun GuideRoute(
    onOpenLiveChannel: (Long) -> Unit,
    onOpenCatchupReplay: (channelId: Long, startEpochSecs: Long, endEpochSecs: Long) -> Unit,
    viewModel: GuideViewModel = hiltViewModel(),
) {
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val metrics = LocalBuntuMetrics.current
    val horizontalScroll = rememberScrollState()
    val nowEpoch = remember(state.windowStartEpochSecs) { System.currentTimeMillis() / 1_000L }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(BuntuPalette.Midnight)
            .padding(vertical = metrics.verticalScreenPadding),
        verticalArrangement = Arrangement.spacedBy(metrics.spacingM),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = metrics.horizontalScreenPadding),
        ) {
            Text(
                text = "Guide TV (EPG)",
                style = MaterialTheme.typography.headlineSmall,
                fontWeight = FontWeight.Bold,
                color = BuntuPalette.PureWhite,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(metrics.spacingS)) {
                OutlinedButton(onClick = { viewModel.shiftWindowHours(-2) }) {
                    Text("−2 h", color = BuntuPalette.PureWhite)
                }
                BuntuPrimaryActionButton(
                    label = "Maintenant",
                    onClick = viewModel::jumpToNow,
                )
                OutlinedButton(onClick = { viewModel.shiftWindowHours(+2) }) {
                    Text("+2 h", color = BuntuPalette.PureWhite)
                }
            }
        }

        BuntuCategoryChips(
            categories = state.categories,
            selectedCategory = state.selectedCategory,
            onSelectCategory = viewModel::selectCategory,
        )

        state.errorMessage?.let { err ->
            Box(modifier = Modifier.padding(horizontal = metrics.horizontalScreenPadding)) {
                BuntuErrorBanner(message = err)
            }
        }

        if (state.isLoading) {
            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = BuntuPalette.TerangaGold)
            }
        } else if (state.rows.isEmpty()) {
            BuntuEmptyState(
                title = "Aucun programme EPG",
                subtitle = "Synchronisez le guide EPG de votre source IPTV pour afficher la grille horaire.",
            )
        } else {
            LazyColumn(
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(horizontal = metrics.horizontalScreenPadding),
                verticalArrangement = Arrangement.spacedBy(metrics.spacingS),
            ) {
                items(
                    items = state.rows,
                    key = { it.channel.id },
                    contentType = { "epg_channel_row" },
                ) { row ->
                    GuideChannelTimelineRow(
                        row = row,
                        windowStartEpoch = state.windowStartEpochSecs,
                        nowEpoch = nowEpoch,
                        sharedScrollState = horizontalScroll,
                        onOpenLive = { onOpenLiveChannel(row.channel.id) },
                        onSlotClick = { slot ->
                            if (slot.endEpochSecs <= nowEpoch && slot.isCatchupAvailable) {
                                onOpenCatchupReplay(row.channel.id, slot.startEpochSecs, slot.endEpochSecs)
                            } else {
                                onOpenLiveChannel(row.channel.id)
                            }
                        },
                    )
                }
            }
        }
    }
}

@Composable
private fun GuideChannelTimelineRow(
    row: ChannelGuideRow,
    windowStartEpoch: Long,
    nowEpoch: Long,
    sharedScrollState: androidx.compose.foundation.ScrollState,
    onOpenLive: () -> Unit,
    onSlotClick: (EpgSlot) -> Unit,
) {
    val metrics = LocalBuntuMetrics.current
    val timeFmt = remember { SimpleDateFormat("HH:mm", Locale.FRANCE) }

    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .height(68.dp),
    ) {
        // Pinned channel header column
        Box(
            contentAlignment = Alignment.CenterStart,
            modifier = Modifier
                .width(160.dp)
                .height(64.dp)
                .clip(RoundedCornerShape(10.dp))
                .background(BuntuPalette.Slate)
                .focusable()
                .clickable(onClick = onOpenLive)
                .padding(horizontal = metrics.spacingM),
        ) {
            Text(
                text = row.channel.name,
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.SemiBold,
                color = BuntuPalette.PureWhite,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }

        Spacer(modifier = Modifier.width(metrics.spacingS))

        // Synchronized horizontal programme slots
        Row(
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            modifier = Modifier
                .weight(1f)
                .horizontalScroll(sharedScrollState),
        ) {
            if (row.programs.isEmpty()) {
                EpgProgramCell(
                    title = row.channel.nowTitle ?: "Programme non renseigné",
                    subtitle = "Direct",
                    widthDp = 320,
                    isLive = true,
                    isCatchup = false,
                    onClick = onOpenLive,
                )
            } else {
                row.programs.forEach { slot ->
                    val durationMins = ((slot.endEpochSecs - maxOf(slot.startEpochSecs, windowStartEpoch)) / 60L)
                        .coerceIn(20L, 240L)
                    val widthDp = (durationMins * 4L).toInt().coerceAtLeast(110)
                    val startLabel = timeFmt.format(Date(slot.startEpochSecs * 1_000L))
                    val endLabel = timeFmt.format(Date(slot.endEpochSecs * 1_000L))
                    val isLive = slot.isLiveAt(nowEpoch)
                    val isReplay = slot.endEpochSecs <= nowEpoch && slot.isCatchupAvailable

                    EpgProgramCell(
                        title = slot.title,
                        subtitle = "$startLabel–$endLabel" + if (isReplay) " · ↺ Replay" else "",
                        widthDp = widthDp,
                        isLive = isLive,
                        isCatchup = isReplay,
                        onClick = { onSlotClick(slot) },
                    )
                }
            }
        }
    }
}

@Composable
private fun EpgProgramCell(
    title: String,
    subtitle: String,
    widthDp: Int,
    isLive: Boolean,
    isCatchup: Boolean,
    onClick: () -> Unit,
) {
    var isFocused by remember { mutableStateOf(false) }
    val shape = RoundedCornerShape(10.dp)
    val borderColor = when {
        isFocused -> BuntuPalette.TerangaGold
        isLive -> BuntuPalette.LeerCyan
        else -> BuntuPalette.SlateElevated
    }

    Column(
        verticalArrangement = Arrangement.Center,
        modifier = Modifier
            .width(widthDp.dp)
            .height(64.dp)
            .onFocusChanged { isFocused = it.isFocused }
            .focusable()
            .clip(shape)
            .background(if (isLive || isFocused) BuntuPalette.SlateElevated else BuntuPalette.Slate)
            .border(BorderStroke(if (isFocused) 2.dp else 1.dp, borderColor), shape)
            .clickable(onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 6.dp),
    ) {
        Text(
            text = title,
            style = MaterialTheme.typography.bodyMedium,
            fontWeight = if (isLive || isFocused) FontWeight.Bold else FontWeight.Normal,
            color = if (isFocused) BuntuPalette.TerangaGold else BuntuPalette.PureWhite,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Text(
            text = subtitle,
            style = MaterialTheme.typography.labelSmall,
            color = if (isCatchup) BuntuPalette.TerangaGold else BuntuPalette.MutedSilver,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

