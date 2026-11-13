package com.pcoundia.buntu.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.LiveTv
import androidx.compose.material.icons.filled.Movie
import androidx.compose.material.icons.filled.Tv
import com.pcoundia.buntu.core.designsystem.BuntuBrandMark
import com.pcoundia.buntu.core.designsystem.BuntuPalette
import com.pcoundia.buntu.core.designsystem.LocalBuntuMetrics
import kotlinx.coroutines.delay
import java.time.LocalTime

/**
 * Home of the TV app (same as the Samsung TV): three big sections, then Sources, Appareils, Réglages and Quitter.
 * Nothing is loaded here (no catalogue, thumbnails or counters): it opens instantly. D-pad: arrows to choose, OK to open.
 */
@Composable
fun TvHomeScreen(
    onOpen: (route: String) -> Unit,
    onExit: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val metrics = LocalBuntuMetrics.current
    val firstFocus = remember { FocusRequester() }
    val time by produceState(initialValue = currentClock()) {
        while (true) {
            value = currentClock()
            delay(1_000L)
        }
    }
    LaunchedEffect(Unit) { runCatching { firstFocus.requestFocus() } }

    Column(
        modifier = modifier
            .fillMaxSize()
            .background(Brush.verticalGradient(listOf(Color(0xFF0F1626), BuntuPalette.Midnight)))
            .padding(
                start = metrics.horizontalScreenPadding,
                end = metrics.horizontalScreenPadding,
                top = metrics.verticalScreenPadding,
                bottom = 24.dp,
            ),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
            BuntuBrandMark(logoSize = 44.dp, textStyle = MaterialTheme.typography.titleLarge)
            Spacer(modifier = Modifier.weight(1f))
            Text(
                text = TvHomeModel.TAGLINE,
                style = MaterialTheme.typography.titleSmall,
                color = BuntuPalette.PureWhite.copy(alpha = 0.6f),
            )
            Spacer(modifier = Modifier.width(24.dp))
            Text(
                text = time,
                style = MaterialTheme.typography.headlineMedium,
                fontWeight = FontWeight.Bold,
                color = BuntuPalette.PureWhite,
            )
        }

        Spacer(modifier = Modifier.height(24.dp))
        Text(
            text = TvHomeModel.WELCOME,
            style = MaterialTheme.typography.labelLarge,
            color = BuntuPalette.TerangaGold,
        )
        Text(
            text = TvHomeModel.HEADLINE,
            style = MaterialTheme.typography.displaySmall,
            fontWeight = FontWeight.Bold,
            color = BuntuPalette.PureWhite,
        )
        Spacer(modifier = Modifier.height(20.dp))

        Row(
            horizontalArrangement = Arrangement.spacedBy(20.dp),
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth(),
        ) {
            TvHomeModel.Section.entries.forEachIndexed { index, section ->
                SectionCard(
                    section = section,
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxSize()
                        .then(if (index == 0) Modifier.focusRequester(firstFocus) else Modifier),
                    onClick = { onOpen(section.route) },
                )
            }
        }

        Spacer(modifier = Modifier.height(16.dp))
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
            TvHomeModel.Shortcut.entries.forEach { shortcut ->
                ShortcutButton(
                    title = shortcut.title,
                    onClick = { shortcut.route?.let(onOpen) ?: onExit() },
                )
                Spacer(modifier = Modifier.width(12.dp))
            }
            Spacer(modifier = Modifier.weight(1f))
            Text(
                text = "← →  Choisir      OK  Ouvrir",
                style = MaterialTheme.typography.bodyMedium,
                color = BuntuPalette.PureWhite.copy(alpha = 0.6f),
            )
        }
    }
}

private fun currentClock(): String = LocalTime.now().let { TvHomeModel.clock(it.hour, it.minute) }

@Composable
private fun SectionCard(
    section: TvHomeModel.Section,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var focused by remember { mutableStateOf(false) }
    val (top, bottom, icon) = sectionLook(section)
    val shape = RoundedCornerShape(24.dp)
    Box(
        modifier = modifier
            .onFocusChanged { focused = it.isFocused }
            .focusable()
            .clip(shape)
            .background(Brush.linearGradient(listOf(top, bottom)))
            .border(
                BorderStroke(
                    width = if (focused) 4.dp else 1.dp,
                    color = if (focused) BuntuPalette.TerangaGold else BuntuPalette.SlateElevated,
                ),
                shape,
            )
            .clickable(onClick = onClick)
            .padding(28.dp),
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = BuntuPalette.PureWhite.copy(alpha = 0.9f),
            modifier = Modifier
                .align(Alignment.TopStart)
                .width(56.dp)
                .height(56.dp),
        )
        Column(modifier = Modifier.align(Alignment.BottomStart)) {
            Text(section.subtitle, style = MaterialTheme.typography.bodyLarge, color = BuntuPalette.PureWhite.copy(alpha = 0.7f))
            Text(section.title, style = MaterialTheme.typography.displayMedium, fontWeight = FontWeight.Bold, color = BuntuPalette.PureWhite)
            Spacer(modifier = Modifier.height(6.dp))
            Text(section.detail, style = MaterialTheme.typography.titleMedium, color = BuntuPalette.PureWhite.copy(alpha = 0.8f))
            Spacer(modifier = Modifier.height(14.dp))
            Text("Explorer →", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, color = BuntuPalette.TerangaGold)
        }
    }
}

private fun sectionLook(section: TvHomeModel.Section): Triple<Color, Color, ImageVector> = when (section) {
    TvHomeModel.Section.LIVE -> Triple(Color(0xFF1B3550), Color(0xFF0F2036), Icons.Default.LiveTv)
    TvHomeModel.Section.MOVIES -> Triple(Color(0xFF4A3520), Color(0xFF2A1D12), Icons.Default.Movie)
    TvHomeModel.Section.SERIES -> Triple(Color(0xFF38305A), Color(0xFF1F1A36), Icons.Default.Tv)
}

@Composable
private fun ShortcutButton(title: String, onClick: () -> Unit) {
    var focused by remember { mutableStateOf(false) }
    val shape = RoundedCornerShape(50)
    Text(
        text = title,
        style = MaterialTheme.typography.titleMedium,
        fontWeight = FontWeight.Medium,
        color = if (focused) BuntuPalette.Midnight else BuntuPalette.PureWhite,
        modifier = Modifier
            .onFocusChanged { focused = it.isFocused }
            .focusable()
            .clip(shape)
            .background(if (focused) BuntuPalette.TerangaGold else Color.Transparent)
            .clickable(onClick = onClick)
            .padding(horizontal = 22.dp, vertical = 10.dp),
    )
}
