package com.pcoundia.buntu.navigation

import android.net.Uri
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.Explore
import androidx.compose.material.icons.filled.LiveTv
import androidx.compose.material.icons.filled.Movie
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Tv
import androidx.compose.material.icons.filled.ViewTimeline
import androidx.compose.ui.graphics.vector.ImageVector

enum class TopLevelDestination(
    val route: String,
    val label: String,
    val icon: ImageVector,
    val showOnPhoneBottomBar: Boolean,
    val showOnTvRail: Boolean,
) {
    LIVE(
        route = BuntuRoutes.LIVE,
        label = "Direct",
        icon = Icons.Default.LiveTv,
        showOnPhoneBottomBar = true,
        showOnTvRail = true,
    ),
    GUIDE(
        route = BuntuRoutes.GUIDE,
        label = "Guide",
        icon = Icons.Default.ViewTimeline,
        showOnPhoneBottomBar = false,
        showOnTvRail = true,
    ),
    MOVIES(
        route = BuntuRoutes.MOVIES,
        label = "Films",
        icon = Icons.Default.Movie,
        showOnPhoneBottomBar = true,
        showOnTvRail = true,
    ),
    SERIES(
        route = BuntuRoutes.SERIES,
        label = "Séries",
        icon = Icons.Default.Tv,
        showOnPhoneBottomBar = true,
        showOnTvRail = true,
    ),
    FOR_YOU(
        route = BuntuRoutes.RECOMMENDATIONS,
        label = "Pour vous",
        icon = Icons.Default.Explore,
        showOnPhoneBottomBar = false,
        showOnTvRail = true,
    ),
    SEARCH(
        route = BuntuRoutes.SEARCH,
        label = "Recherche",
        icon = Icons.Default.Search,
        showOnPhoneBottomBar = true,
        showOnTvRail = true,
    ),
    DOWNLOADS(
        route = BuntuRoutes.DOWNLOADS,
        label = "Hors-ligne",
        icon = Icons.Default.Download,
        showOnPhoneBottomBar = false,
        showOnTvRail = false,
    ),
    PROFILES(
        route = BuntuRoutes.PROFILES,
        label = "Profils",
        icon = Icons.Default.Person,
        showOnPhoneBottomBar = false,
        showOnTvRail = true,
    ),
    SETTINGS(
        route = BuntuRoutes.SETTINGS,
        label = "Plus",
        icon = Icons.Default.Settings,
        showOnPhoneBottomBar = true,
        showOnTvRail = true,
    ),
}

object BuntuRoutes {
    const val ONBOARDING = "onboarding"
    const val LIVE = "live"
    const val GUIDE = "guide"
    const val MOVIES = "movies"
    const val SERIES = "series"
    const val RECOMMENDATIONS = "recommendations"
    const val SEARCH = "search"
    const val DOWNLOADS = "downloads"
    const val SOURCES = "sources"
    const val SOURCES_PATTERN = "sources?pairLink={pairLink}"
    const val PROFILES = "profiles"
    const val SETTINGS = "settings"

    const val DETAILS_PATTERN = "details/{mediaId}?isSeries={isSeries}"
    const val PLAYER_PATTERN =
        "player/{itemId}?startPositionMs={startPositionMs}&catchupStartEpoch={catchupStartEpoch}&catchupEndEpoch={catchupEndEpoch}"

    fun sources(pairLink: String? = null): String =
        if (pairLink.isNullOrBlank()) SOURCES else "sources?pairLink=${Uri.encode(pairLink)}"

    fun details(mediaId: Long, isSeries: Boolean): String =
        "details/$mediaId?isSeries=$isSeries"

    fun player(
        itemId: Long,
        startPositionMs: Long = 0L,
        catchupStartEpoch: Long = 0L,
        catchupEndEpoch: Long = 0L,
    ): String =
        "player/$itemId?startPositionMs=$startPositionMs&catchupStartEpoch=$catchupStartEpoch&catchupEndEpoch=$catchupEndEpoch"
}

