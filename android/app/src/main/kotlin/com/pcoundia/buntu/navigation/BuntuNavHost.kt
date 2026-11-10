package com.pcoundia.buntu.navigation

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.navigation.NavHostController
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.navArgument
import com.pcoundia.buntu.feature.details.DetailsRoute
import com.pcoundia.buntu.feature.devices.DevicesRoute
import com.pcoundia.buntu.feature.downloads.DownloadsRoute
import com.pcoundia.buntu.feature.guide.GuideRoute
import com.pcoundia.buntu.feature.live.LiveRoute
import com.pcoundia.buntu.feature.movies.MoviesRoute
import com.pcoundia.buntu.feature.onboarding.OnboardingRoute
import com.pcoundia.buntu.feature.player.PlayerRoute
import com.pcoundia.buntu.feature.profiles.ProfilesRoute
import com.pcoundia.buntu.feature.recommendations.RecommendationsRoute
import com.pcoundia.buntu.feature.search.SearchRoute
import com.pcoundia.buntu.feature.series.SeriesRoute
import com.pcoundia.buntu.feature.settings.SettingsRoute
import com.pcoundia.buntu.feature.sources.SourcesRoute

/**
 * PRD-37 § 2.1 & § 5.2:
 * Single navigation graph shared by both `MobileShell` and `TvShell`.
 * Feature modules stay 100% decoupled from one another because `:app` wires all callbacks.
 */
@Composable
fun BuntuNavHost(
    navController: NavHostController,
    startDestination: String,
    modifier: Modifier = Modifier,
) {
    NavHost(
        navController = navController,
        startDestination = startDestination,
        modifier = modifier,
    ) {
        composable(BuntuRoutes.ONBOARDING) {
            OnboardingRoute(
                onFinished = {
                    navController.navigate(BuntuRoutes.LIVE) {
                        popUpTo(BuntuRoutes.ONBOARDING) { inclusive = true }
                    }
                },
            )
        }

        composable(BuntuRoutes.LIVE) {
            LiveRoute(
                onOpenFullscreenPlayer = { channelId ->
                    navController.navigate(BuntuRoutes.player(itemId = channelId))
                },
                onOpenSources = {
                    navController.navigate(BuntuRoutes.SOURCES)
                },
            )
        }

        composable(BuntuRoutes.GUIDE) {
            GuideRoute(
                onOpenLiveChannel = { channelId ->
                    navController.navigate(BuntuRoutes.player(itemId = channelId))
                },
                onOpenCatchupReplay = { channelId, startEpoch, endEpoch ->
                    navController.navigate(
                        BuntuRoutes.player(
                            itemId = channelId,
                            catchupStartEpoch = startEpoch,
                            catchupEndEpoch = endEpoch,
                        )
                    )
                },
            )
        }

        composable(BuntuRoutes.MOVIES) {
            MoviesRoute(
                onOpenMovieDetail = { movieId ->
                    navController.navigate(BuntuRoutes.details(movieId, isSeries = false))
                },
                onOpenSources = {
                    navController.navigate(BuntuRoutes.SOURCES)
                },
            )
        }

        composable(BuntuRoutes.SERIES) {
            SeriesRoute(
                onOpenSeriesDetail = { seriesId ->
                    navController.navigate(BuntuRoutes.details(seriesId, isSeries = true))
                },
                onOpenSources = {
                    navController.navigate(BuntuRoutes.SOURCES)
                },
            )
        }

        composable(BuntuRoutes.RECOMMENDATIONS) {
            RecommendationsRoute(
                onOpenLiveChannel = { channelId ->
                    navController.navigate(BuntuRoutes.player(itemId = channelId))
                },
                onOpenMovieDetail = { movieId ->
                    navController.navigate(BuntuRoutes.details(movieId, isSeries = false))
                },
                onOpenSeriesDetail = { seriesId ->
                    navController.navigate(BuntuRoutes.details(seriesId, isSeries = true))
                },
            )
        }

        composable(BuntuRoutes.SEARCH) {
            SearchRoute(
                onOpenLiveChannel = { channelId ->
                    navController.navigate(BuntuRoutes.player(itemId = channelId))
                },
                onOpenMovieDetail = { movieId ->
                    navController.navigate(BuntuRoutes.details(movieId, isSeries = false))
                },
                onOpenSeriesDetail = { seriesId ->
                    navController.navigate(BuntuRoutes.details(seriesId, isSeries = true))
                },
                onOpenReplay = { channelId, startEpoch, endEpoch ->
                    navController.navigate(
                        BuntuRoutes.player(
                            itemId = channelId,
                            catchupStartEpoch = startEpoch,
                            catchupEndEpoch = endEpoch,
                        )
                    )
                },
            )
        }

        composable(BuntuRoutes.DOWNLOADS) {
            DownloadsRoute(
                onPlayDownloadedItem = { itemId ->
                    navController.navigate(BuntuRoutes.player(itemId = itemId))
                },
            )
        }

        composable(
            route = BuntuRoutes.SOURCES_PATTERN,
            arguments = listOf(
                navArgument("pairLink") {
                    type = NavType.StringType
                    nullable = true
                    defaultValue = null
                },
            ),
        ) {
            SourcesRoute()
        }

        composable(BuntuRoutes.PROFILES) {
            ProfilesRoute()
        }

        composable(BuntuRoutes.SETTINGS) {
            SettingsRoute(
                onOpenSources = { navController.navigate(BuntuRoutes.SOURCES) },
                onOpenProfiles = { navController.navigate(BuntuRoutes.PROFILES) },
                onOpenDevices = { navController.navigate(BuntuRoutes.DEVICES) },
            )
        }

        composable(BuntuRoutes.DEVICES) {
            DevicesRoute(
                onBack = { navController.popBackStack() },
            )
        }

        composable(
            route = BuntuRoutes.DETAILS_PATTERN,
            arguments = listOf(
                navArgument("mediaId") { type = NavType.LongType },
                navArgument("isSeries") {
                    type = NavType.BoolType
                    defaultValue = false
                },
            ),
        ) {
            DetailsRoute(
                onPlayMedia = { itemId, startPosMs ->
                    // Opens fullscreen player immediately in front!
                    navController.navigate(
                        BuntuRoutes.player(itemId = itemId, startPositionMs = startPosMs)
                    )
                },
                onBack = { navController.popBackStack() },
            )
        }

        composable(
            route = BuntuRoutes.PLAYER_PATTERN,
            arguments = listOf(
                navArgument("itemId") { type = NavType.LongType },
                navArgument("startPositionMs") {
                    type = NavType.LongType
                    defaultValue = 0L
                },
                navArgument("catchupStartEpoch") {
                    type = NavType.LongType
                    defaultValue = 0L
                },
                navArgument("catchupEndEpoch") {
                    type = NavType.LongType
                    defaultValue = 0L
                },
            ),
        ) {
            PlayerRoute(
                onBack = { navController.popBackStack() },
                onNavigateToDownloads = {
                    navController.navigate(BuntuRoutes.DOWNLOADS) {
                        popUpTo(BuntuRoutes.PLAYER_PATTERN) { inclusive = true }
                    }
                },
            )
        }
    }
}

