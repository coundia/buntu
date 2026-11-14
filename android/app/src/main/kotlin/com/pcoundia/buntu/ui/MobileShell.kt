package com.pcoundia.buntu.ui

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.NavigationDrawerItem
import androidx.compose.material3.NavigationDrawerItemDefaults
import androidx.compose.material3.NavigationRail
import androidx.compose.material3.NavigationRailItem
import androidx.compose.material3.NavigationRailItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.NavHostController
import androidx.navigation.compose.currentBackStackEntryAsState
import com.pcoundia.buntu.core.designsystem.BuntuBrandMark
import com.pcoundia.buntu.core.designsystem.BuntuPalette
import com.pcoundia.buntu.core.designsystem.BuntuWindowWidth
import com.pcoundia.buntu.navigation.BuntuNavHost
import com.pcoundia.buntu.navigation.BuntuRoutes
import com.pcoundia.buntu.navigation.TopLevelDestination

/**
 * PRD-37 § 5.2:
 * Adaptive Phone / Tablet / Foldable shell:
 * - `COMPACT` (< 600dp): Bottom NavigationBar + quick secondary chips ("Guide", "Pour vous", "Hors-ligne")
 * - `MEDIUM` (600–840dp): Side `NavigationRail`
 * - `EXPANDED` (> 840dp): Permanent side navigation column
 */
@Composable
fun MobileShell(
    navController: NavHostController,
    startDestination: String,
    windowWidth: BuntuWindowWidth,
) {
    val backStackEntry by navController.currentBackStackEntryAsState()
    val currentRoute = backStackEntry?.destination?.route.orEmpty()
    val isFullscreenRoute = currentRoute.startsWith("player/") || currentRoute == BuntuRoutes.ONBOARDING

    if (isFullscreenRoute) {
        BuntuNavHost(
            navController = navController,
            startDestination = startDestination,
            modifier = Modifier.fillMaxSize(),
        )
        return
    }

    val navigateTopLevel: (String) -> Unit = { route ->
        navController.navigate(route) {
            popUpTo(navController.graph.findStartDestination().id) {
                saveState = true
            }
            launchSingleTop = true
            restoreState = true
        }
    }

    when (windowWidth) {
        BuntuWindowWidth.COMPACT -> {
            val bottomItems = TopLevelDestination.entries.filter { it.showOnPhoneBottomBar }
            Scaffold(
                containerColor = BuntuPalette.Midnight,
                modifier = Modifier
                    .fillMaxSize()
                    .systemBarsPadding(),
                topBar = {
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        modifier = Modifier
                            .fillMaxWidth()
                            .background(BuntuPalette.Midnight)
                            .horizontalScroll(rememberScrollState())
                            .padding(horizontal = 16.dp, vertical = 6.dp),
                    ) {
                        listOf(
                            TopLevelDestination.GUIDE,
                            TopLevelDestination.FOR_YOU,
                            TopLevelDestination.DOWNLOADS,
                            TopLevelDestination.SOURCES,
                            TopLevelDestination.DEVICES,
                            TopLevelDestination.REMOTE_COMMAND,
                        ).forEach { secondary ->
                            FilterChip(
                                selected = secondary.matches(currentRoute),
                                onClick = { navigateTopLevel(secondary.route) },
                                label = { Text(secondary.label) },
                                colors = FilterChipDefaults.filterChipColors(
                                    selectedContainerColor = BuntuPalette.TerangaGold,
                                    selectedLabelColor = BuntuPalette.Midnight,
                                ),
                            )
                        }
                    }
                },
                bottomBar = {
                    NavigationBar(containerColor = BuntuPalette.Slate) {
                        bottomItems.forEach { dest ->
                            NavigationBarItem(
                                selected = dest.matches(currentRoute),
                                onClick = { navigateTopLevel(dest.route) },
                                icon = { Icon(dest.icon, contentDescription = dest.label) },
                                label = { Text(dest.label) },
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
                },
            ) { innerPadding ->
                BuntuNavHost(
                    navController = navController,
                    startDestination = startDestination,
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(innerPadding),
                )
            }
        }

        BuntuWindowWidth.MEDIUM -> {
            Row(
                modifier = Modifier
                    .fillMaxSize()
                    .background(BuntuPalette.Midnight)
                    .systemBarsPadding(),
            ) {
                NavigationRail(containerColor = BuntuPalette.Slate) {
                    TopLevelDestination.entries.forEach { dest ->
                        NavigationRailItem(
                            selected = dest.matches(currentRoute),
                            onClick = { navigateTopLevel(dest.route) },
                            icon = { Icon(dest.icon, contentDescription = dest.label) },
                            label = { Text(dest.label) },
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
                Box(modifier = Modifier.weight(1f)) {
                    BuntuNavHost(
                        navController = navController,
                        startDestination = startDestination,
                        modifier = Modifier.fillMaxSize(),
                    )
                }
            }
        }

        BuntuWindowWidth.EXPANDED -> {
            Row(
                modifier = Modifier
                    .fillMaxSize()
                    .background(BuntuPalette.Midnight)
                    .systemBarsPadding(),
            ) {
                Column(
                    modifier = Modifier
                        .width(220.dp)
                        .fillMaxHeight()
                        .background(BuntuPalette.Slate)
                        .padding(12.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    BuntuBrandMark(
                        modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
                    )
                    TopLevelDestination.entries.forEach { dest ->
                        NavigationDrawerItem(
                            selected = dest.matches(currentRoute),
                            onClick = { navigateTopLevel(dest.route) },
                            icon = { Icon(dest.icon, contentDescription = dest.label) },
                            label = { Text(dest.label) },
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
                Box(modifier = Modifier.weight(1f)) {
                    BuntuNavHost(
                        navController = navController,
                        startDestination = startDestination,
                        modifier = Modifier.fillMaxSize(),
                    )
                }
            }
        }
    }
}

