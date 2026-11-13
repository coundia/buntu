package com.pcoundia.buntu.ui

import androidx.activity.compose.BackHandler
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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import android.os.SystemClock
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.nativeKeyCode
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.type
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.NavHostController
import androidx.navigation.compose.currentBackStackEntryAsState
import com.pcoundia.buntu.core.designsystem.BuntuBrandMark
import com.pcoundia.buntu.core.designsystem.BuntuPalette
import com.pcoundia.buntu.core.designsystem.LocalBuntuMetrics
import com.pcoundia.buntu.navigation.BuntuNavHost
import com.pcoundia.buntu.navigation.BuntuRoutes
import com.pcoundia.buntu.navigation.TopLevelDestination
import kotlinx.coroutines.delay

/**
 * PRD-37 § 5.2 & § 5.3:
 * 10-foot Android TV / Google TV shell:
 * - D-Pad focusable top navigation bar with clear gold focus ring
 * - Safe overscan padding (`48dp` sides, `27dp` top)
 * - Double-Back exit confirmation on root TV tabs so accidental Back press never drops to Launcher
 */
@Composable
fun TvShell(
    navController: NavHostController,
    startDestination: String,
    onExitApp: () -> Unit,
) {
    val metrics = LocalBuntuMetrics.current
    val backStackEntry by navController.currentBackStackEntryAsState()
    val currentRoute = backStackEntry?.destination?.route.orEmpty()
    val isFullscreenRoute = currentRoute.startsWith("player/") || currentRoute == BuntuRoutes.ONBOARDING
    // System sound effects of the remote's keys; not played over the full-screen player (it returns above).
    val view = LocalView.current
    val sounds = remember(view) { TvUiSounds(playEffect = { view.playSoundEffect(it) }, uptimeMillis = SystemClock::uptimeMillis) }
    val tvDestinations = remember { TopLevelDestination.entries.filter { it.showOnTvRail } }

    var confirmExitPending by remember { mutableStateOf(false) }

    LaunchedEffect(confirmExitPending) {
        if (confirmExitPending) {
            delay(2_500L)
            confirmExitPending = false
        }
    }

    val isHome = currentRoute == BuntuRoutes.HOME
    val isRootTab = isHome || tvDestinations.any { it.matches(currentRoute) }
    BackHandler(enabled = isRootTab) {
        when {
            // Back from a section returns to the home chooser; from the home, a second press quits.
            !isHome -> navController.navigate(BuntuRoutes.HOME) {
                popUpTo(BuntuRoutes.HOME)
                launchSingleTop = true
            }
            confirmExitPending -> onExitApp()
            else -> confirmExitPending = true
        }
    }

    if (isFullscreenRoute) {
        BuntuNavHost(
            navController = navController,
            startDestination = startDestination,
            modifier = Modifier.fillMaxSize(),
        )
        return
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(BuntuPalette.Midnight)
            .onPreviewKeyEvent { event ->
                if (event.type == KeyEventType.KeyDown) sounds.onKeyDown(event.key.nativeKeyCode)
                false // never consumes the key: only listens
            },
    ) {
        Column(modifier = Modifier.fillMaxSize()) {
            // 10-foot Top Navigation Bar (the home has its own header)
            if (!isHome) Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(
                        start = metrics.horizontalScreenPadding,
                        end = metrics.horizontalScreenPadding,
                        top = metrics.verticalScreenPadding,
                        bottom = 8.dp,
                    ),
            ) {
                BuntuBrandMark(
                    logoSize = 40.dp,
                    textStyle = MaterialTheme.typography.titleLarge,
                )
                Spacer(modifier = Modifier.width(metrics.spacingXL))

                LazyRow(horizontalArrangement = Arrangement.spacedBy(metrics.spacingS)) {
                    items(
                        items = tvDestinations,
                        key = { it.route },
                    ) { dest ->
                        TvNavPill(
                            destination = dest,
                            isSelected = dest.matches(currentRoute),
                            onClick = {
                                navController.navigate(dest.route) {
                                    popUpTo(navController.graph.findStartDestination().id) {
                                        saveState = true
                                    }
                                    launchSingleTop = true
                                    restoreState = true
                                }
                            },
                        )
                    }
                }
            }

            Box(modifier = Modifier.weight(1f)) {
                BuntuNavHost(
                    navController = navController,
                    startDestination = startDestination,
                    modifier = Modifier.fillMaxSize(),
                    onExitApp = onExitApp,
                )
            }
        }

        if (confirmExitPending) {
            Surface(
                color = BuntuPalette.SlateElevated,
                border = BorderStroke(2.dp, BuntuPalette.TerangaGold),
                shape = RoundedCornerShape(14.dp),
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .padding(bottom = 40.dp),
            ) {
                Text(
                    text = "Appuyez une seconde fois sur Retour pour quitter Buntu",
                    style = MaterialTheme.typography.titleMedium,
                    color = BuntuPalette.PureWhite,
                    modifier = Modifier.padding(horizontal = 24.dp, vertical = 12.dp),
                )
            }
        }
    }
}

@Composable
private fun TvNavPill(
    destination: TopLevelDestination,
    isSelected: Boolean,
    onClick: () -> Unit,
) {
    var isFocused by remember { mutableStateOf(false) }
    val shape = RoundedCornerShape(50)
    val bgColor = when {
        isFocused -> BuntuPalette.TerangaGold
        isSelected -> BuntuPalette.SlateElevated
        else -> BuntuPalette.Slate
    }
    val contentColor = when {
        isFocused -> BuntuPalette.Midnight
        isSelected -> BuntuPalette.TerangaGold
        else -> BuntuPalette.PureWhite
    }

    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .onFocusChanged { isFocused = it.isFocused }
            .focusable()
            .clip(shape)
            .background(bgColor)
            .border(
                BorderStroke(
                    width = if (isFocused || isSelected) 2.dp else 1.dp,
                    color = if (isFocused || isSelected) BuntuPalette.TerangaGold else BuntuPalette.SlateElevated,
                ),
                shape,
            )
            .clickable(onClick = onClick)
            .padding(horizontal = 18.dp, vertical = 10.dp),
    ) {
        Icon(
            imageVector = destination.icon,
            contentDescription = null,
            tint = contentColor,
        )
        Spacer(modifier = Modifier.width(8.dp))
        Text(
            text = destination.label,
            style = MaterialTheme.typography.titleSmall,
            fontWeight = FontWeight.Bold,
            color = contentColor,
        )
    }
}

