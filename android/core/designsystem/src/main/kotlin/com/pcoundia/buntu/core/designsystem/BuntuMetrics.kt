package com.pcoundia.buntu.core.designsystem

import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

enum class BuntuWindowWidth {
    COMPACT,
    MEDIUM,
    EXPANDED,
}

/**
 * PRD-30 & PRD-37 § 5.2 / § 5.3:
 * Design tokens computed once per configuration change (never per item during composition).
 */
@Immutable
data class BuntuMetrics(
    val scale: Float = 1.0f,
    val windowWidth: BuntuWindowWidth = BuntuWindowWidth.COMPACT,
    val isTv: Boolean = false,
    val isLowRamDevice: Boolean = false,
) {
    private val clampedScale: Float = scale.coerceIn(0.85f, 1.35f)
    private fun scaled(baseDp: Int): Dp = (baseDp * clampedScale).dp

    val spacingXS: Dp = scaled(4)
    val spacingS: Dp = scaled(8)
    val spacingM: Dp = scaled(12)
    val spacingL: Dp = scaled(16)
    val spacingXL: Dp = scaled(24)

    // PRD-37 § 5.3: Android TV safe overscan margins (48dp sides, 27dp top/bottom)
    val horizontalScreenPadding: Dp = if (isTv) 48.dp else when (windowWidth) {
        BuntuWindowWidth.COMPACT -> 16.dp
        BuntuWindowWidth.MEDIUM -> 24.dp
        BuntuWindowWidth.EXPANDED -> 32.dp
    }
    val verticalScreenPadding: Dp = if (isTv) 27.dp else 12.dp

    // PRD-37 § 5.4: Minimum 48dp touch target
    val minTouchTarget: Dp = if (isTv) 56.dp else 48.dp

    // Poster & Channel card tokens (2:3 posters)
    val posterCardWidth: Dp = if (isTv) scaled(164) else scaled(142)
    val posterCardHeight: Dp = (posterCardWidth.value * 1.5f).dp
    val posterGridMinCell: Dp = if (isTv) scaled(172) else when (windowWidth) {
        BuntuWindowWidth.COMPACT -> scaled(128)
        BuntuWindowWidth.MEDIUM -> scaled(148)
        BuntuWindowWidth.EXPANDED -> scaled(164)
    }
    val channelCardMinWidth: Dp = if (isTv) scaled(280) else scaled(240)
    val channelCardHeight: Dp = if (isTv) scaled(100) else scaled(88)
    val categorySidebarWidth: Dp = scaled(220)

    // Low-RAM devices skip expensive scale/blur animations (PRD-37 § 5.3)
    val enableFocusScaleAnimation: Boolean = !isLowRamDevice
}

val LocalBuntuMetrics = staticCompositionLocalOf { BuntuMetrics() }
