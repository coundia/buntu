package com.pcoundia.buntu.core.designsystem

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider

private val BuntuDarkColorScheme = darkColorScheme(
    primary = BuntuPalette.TerangaGold,
    onPrimary = BuntuPalette.Midnight,
    secondary = BuntuPalette.LeerCyan,
    onSecondary = BuntuPalette.Midnight,
    background = BuntuPalette.Midnight,
    onBackground = BuntuPalette.PureWhite,
    surface = BuntuPalette.Slate,
    onSurface = BuntuPalette.PureWhite,
    surfaceVariant = BuntuPalette.SlateElevated,
    onSurfaceVariant = BuntuPalette.MutedSilver,
    error = BuntuPalette.DangerRed,
    onError = BuntuPalette.Midnight,
)

@Composable
fun BuntuTheme(
    metrics: BuntuMetrics = BuntuMetrics(),
    content: @Composable () -> Unit,
) {
    CompositionLocalProvider(LocalBuntuMetrics provides metrics) {
        MaterialTheme(
            colorScheme = BuntuDarkColorScheme,
            typography = Typography(),
            content = content,
        )
    }
}

