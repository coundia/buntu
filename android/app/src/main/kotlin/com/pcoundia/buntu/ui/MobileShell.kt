package com.pcoundia.buntu.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.NavigationDrawerItem
import androidx.compose.material3.NavigationDrawerItemDefaults
import androidx.compose.material3.NavigationRail
import androidx.compose.material3.NavigationRailItem
import androidx.compose.material3.NavigationRailItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.NavHostController
import androidx.navigation.compose.currentBackStackEntryAsState
import com.pcoundia.buntu.core.designsystem.BuntuBrandMark
import com.pcoundia.buntu.core.designsystem.BuntuPalette
import com.pcoundia.buntu.core.designsystem.BuntuWindowWidth
import com.pcoundia.buntu.core.designsystem.i18n.t
import com.pcoundia.buntu.navigation.BuntuNavHost
import com.pcoundia.buntu.navigation.BuntuRoutes
import com.pcoundia.buntu.navigation.TopLevelDestination

/**
 * PRD-37 § 5.2:
 * Adaptive Phone / Tablet / Foldable shell:
 * - `COMPACT` (< 600dp): Bottom NavigationBar + compact top bar (Search + Explore shortcuts sheet)
 * - `MEDIUM` (600–840dp): Scrollable side `NavigationRail`
 * - `EXPANDED` (> 840dp): Scrollable permanent side navigation column
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MobileShell(
    navController: NavHostController,
    startDestination: String,
    windowWidth: BuntuWindowWidth,
) {
    val backStackEntry by navController.currentBackStackEntryAsState()
    val currentRoute = backStackEntry?.destination?.route.orEmpty()
    val isFullscreenRoute = currentRoute.startsWith("player/") || currentRoute == BuntuRoutes.ONBOARDING

    val navigateTopLevel: (String) -> Unit = { route ->
        navController.navigate(route) {
            popUpTo(navController.graph.findStartDestination().id) {
                saveState = true
            }
            launchSingleTop = true
            restoreState = true
        }
    }

    val bottomItems = remember { TopLevelDestination.entries.filter { it.showOnPhoneBottomBar } }
    val secondaryItems = remember {
        listOf(
            TopLevelDestination.GUIDE,
            TopLevelDestination.FOR_YOU,
            TopLevelDestination.DOWNLOADS,
            TopLevelDestination.SOURCES,
            TopLevelDestination.PROFILES,
            TopLevelDestination.DEVICES,
            TopLevelDestination.REMOTE_COMMAND,
        )
    }
    val activeSecondary = secondaryItems.firstOrNull { it.matches(currentRoute) }
    var showExploreSheet by remember { mutableStateOf(false) }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(BuntuPalette.Midnight)
            .then(if (isFullscreenRoute) Modifier else Modifier.systemBarsPadding()),
    ) {
        Row(modifier = Modifier.fillMaxSize()) {
            if (!isFullscreenRoute && windowWidth == BuntuWindowWidth.MEDIUM) {
                NavigationRail(
                    containerColor = BuntuPalette.Slate,
                    modifier = Modifier
                        .fillMaxHeight()
                        .verticalScroll(rememberScrollState()),
                ) {
                    TopLevelDestination.entries.forEach { dest ->
                        val destLabel = t(dest.labelKey)
                        NavigationRailItem(
                            selected = dest.matches(currentRoute),
                            onClick = { navigateTopLevel(dest.route) },
                            icon = { Icon(dest.icon, contentDescription = destLabel) },
                            label = { Text(destLabel) },
                            colors = NavigationRailItemDefaults.colors(
                                selectedIconColor = BuntuPalette.Midnight,
                                selectedTextColor = BuntuPalette.TerangaGold,
                                indicatorColor = BuntuPalette.TerangaGold,
                                unselectedIconColor = BuntuPalette.MutedSilver,
                                unselectedTextColor = BuntuPalette.MutedSilver,
                            ),
                        )
                    }
                }
            } else if (!isFullscreenRoute && windowWidth == BuntuWindowWidth.EXPANDED) {
                Column(
                    modifier = Modifier
                        .width(220.dp)
                        .fillMaxHeight()
                        .verticalScroll(rememberScrollState())
                        .background(BuntuPalette.Slate)
                        .padding(12.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    BuntuBrandMark(
                        modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
                    )
                    TopLevelDestination.entries.forEach { dest ->
                        val destLabel = t(dest.labelKey)
                        NavigationDrawerItem(
                            selected = dest.matches(currentRoute),
                            onClick = { navigateTopLevel(dest.route) },
                            icon = { Icon(dest.icon, contentDescription = destLabel) },
                            label = { Text(destLabel) },
                            colors = NavigationDrawerItemDefaults.colors(
                                selectedContainerColor = BuntuPalette.TerangaGold,
                                selectedIconColor = BuntuPalette.Midnight,
                                selectedTextColor = BuntuPalette.Midnight,
                                unselectedIconColor = BuntuPalette.MutedSilver,
                                unselectedTextColor = BuntuPalette.PureWhite,
                            ),
                        )
                    }
                }
            }

            Column(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxHeight(),
            ) {
                if (!isFullscreenRoute && windowWidth == BuntuWindowWidth.COMPACT) {
                    Surface(
                        color = BuntuPalette.Slate,
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 12.dp, vertical = 4.dp),
                        ) {
                            BuntuBrandMark(logoSize = 26.dp)
                            if (activeSecondary != null) {
                                Spacer(modifier = Modifier.width(8.dp))
                                Surface(
                                    color = BuntuPalette.TerangaGold.copy(alpha = 0.16f),
                                    shape = RoundedCornerShape(50),
                                ) {
                                    Text(
                                        text = t(activeSecondary.labelKey),
                                        style = MaterialTheme.typography.labelMedium,
                                        color = BuntuPalette.TerangaGold,
                                        fontWeight = FontWeight.SemiBold,
                                        modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp),
                                    )
                                }
                            }
                            Spacer(modifier = Modifier.weight(1f))
                            IconButton(
                                onClick = {
                                    navController.navigate(BuntuRoutes.search()) {
                                        launchSingleTop = true
                                    }
                                },
                            ) {
                                Icon(
                                    imageVector = Icons.Default.Search,
                                    contentDescription = t("common.search"),
                                    tint = BuntuPalette.PureWhite,
                                )
                            }
                            IconButton(onClick = { showExploreSheet = true }) {
                                Icon(
                                    imageVector = Icons.Default.GridView,
                                    contentDescription = t("nav.more_menu"),
                                    tint = if (activeSecondary != null) BuntuPalette.TerangaGold else BuntuPalette.PureWhite,
                                )
                            }
                        }
                    }
                }

                // Single BuntuNavHost kept mounted across fullscreen routes and width changes so
                // Paging 3 flows on screens like LiveScreen are never re-collected twice.
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxWidth(),
                ) {
                    BuntuNavHost(
                        navController = navController,
                        startDestination = startDestination,
                        modifier = Modifier.fillMaxSize(),
                    )
                }

                if (!isFullscreenRoute && windowWidth == BuntuWindowWidth.COMPACT) {
                    NavigationBar(containerColor = BuntuPalette.Slate) {
                        bottomItems.forEach { dest ->
                            val destLabel = t(dest.labelKey)
                            NavigationBarItem(
                                selected = dest.matches(currentRoute),
                                onClick = { navigateTopLevel(dest.route) },
                                icon = { Icon(dest.icon, contentDescription = destLabel) },
                                label = { Text(destLabel) },
                                colors = NavigationBarItemDefaults.colors(
                                    selectedIconColor = BuntuPalette.Midnight,
                                    selectedTextColor = BuntuPalette.TerangaGold,
                                    indicatorColor = BuntuPalette.TerangaGold,
                                    unselectedIconColor = BuntuPalette.MutedSilver,
                                    unselectedTextColor = BuntuPalette.MutedSilver,
                                ),
                            )
                        }
                    }
                }
            }
        }

        if (!isFullscreenRoute && windowWidth == BuntuWindowWidth.COMPACT && showExploreSheet) {
            ModalBottomSheet(
                onDismissRequest = { showExploreSheet = false },
                containerColor = BuntuPalette.Slate,
                contentColor = BuntuPalette.PureWhite,
            ) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 8.dp)
                        .navigationBarsPadding(),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Text(
                        text = t("nav.shortcuts_title"),
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.Bold,
                        color = BuntuPalette.PureWhite,
                        modifier = Modifier.padding(horizontal = 4.dp, vertical = 4.dp),
                    )
                    secondaryItems.forEach { dest ->
                        val selected = dest.matches(currentRoute)
                        val label = t(dest.labelKey)
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(12.dp))
                                .background(
                                    if (selected) BuntuPalette.TerangaGold.copy(alpha = 0.16f)
                                    else BuntuPalette.SlateElevated,
                                )
                                .clickable {
                                    showExploreSheet = false
                                    navigateTopLevel(dest.route)
                                }
                                .padding(horizontal = 14.dp, vertical = 12.dp),
                        ) {
                            Icon(
                                imageVector = dest.icon,
                                contentDescription = null,
                                tint = if (selected) BuntuPalette.TerangaGold else BuntuPalette.PureWhite,
                            )
                            Spacer(modifier = Modifier.width(12.dp))
                            Text(
                                text = label,
                                style = MaterialTheme.typography.bodyLarge,
                                fontWeight = if (selected) FontWeight.Bold else FontWeight.Medium,
                                color = if (selected) BuntuPalette.TerangaGold else BuntuPalette.PureWhite,
                            )
                        }
                    }
                    Spacer(modifier = Modifier.height(8.dp))
                }
            }
        }
    }
}

