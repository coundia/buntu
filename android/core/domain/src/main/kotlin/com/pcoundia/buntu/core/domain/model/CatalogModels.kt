package com.pcoundia.buntu.core.domain.model

import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.ImmutableMap
import kotlinx.collections.immutable.persistentListOf
import kotlinx.collections.immutable.persistentMapOf

enum class SourceKind {
    XTREAM,
    M3U,
}

data class SourceSummary(
    val id: Long,
    val uuid: String,
    val name: String,
    val kind: SourceKind,
    val serverOrUrl: String,
    val username: String?,
    val passwordRef: String?,
    val epgUrl: String?,
    val maxConnections: Int?,
    val activeConnections: Int?,
    val expDateEpochSecs: Long?,
    val accountStatus: String?,
    val lastSyncEpochSecs: Long?,
) {
    val isSingleConnection: Boolean
        get() = (maxConnections ?: 1) <= 1
}

data class SyncReport(
    val totalItems: Int,
    val liveCount: Int,
    val movieCount: Int,
    val seriesCount: Int,
    val episodeCount: Int,
    val durationMs: Long,
)

data class CategoryFacet(
    val name: String,
    val count: Int,
    val isAdult: Boolean = false,
)

enum class CatalogSort {
    DEFAULT,
    NAME_ASC,
    RECENTLY_ADDED,
    YEAR_DESC,
    RATING_DESC,
}

data class CatalogQuery(
    val searchQuery: String = "",
    val groupName: String? = null,
    val host: String? = null,
    val sourceId: Long? = null,
    val favoritesOnly: Boolean = false,
    val sort: CatalogSort = CatalogSort.DEFAULT,
)

data class ChannelItem(
    val id: Long,
    val sourceId: Long,
    val stableHash: String,
    val name: String,
    val channelNumber: Int?,
    val groupTitle: String?,
    val logoUrl: String?,
    val tvgId: String?,
    val streamUrl: String,
    val containerExtension: String?,
    val host: String,
    val userAgent: String?,
    val referer: String?,
    val headers: ImmutableMap<String, String> = persistentMapOf(),
    val catchupDays: Int?,
    val isFavorite: Boolean,
    val isBroken: Boolean,
    val nowTitle: String? = null,
    val nowProgress: Float = 0f,
    val nextTitle: String? = null,
)

data class MovieItem(
    val id: Long,
    val sourceId: Long,
    val stableHash: String,
    val title: String,
    val year: Int?,
    val rating: Double?,
    val posterUrl: String?,
    val groupTitle: String?,
    val streamUrl: String,
    val containerExtension: String?,
    val host: String,
    val userAgent: String?,
    val referer: String?,
    val headers: ImmutableMap<String, String> = persistentMapOf(),
    val isFavorite: Boolean,
    val watchPositionMs: Long = 0L,
    val watchDurationMs: Long = 0L,
) {
    val resumeFraction: Float
        get() = if (watchDurationMs > 0L) {
            (watchPositionMs.toFloat() / watchDurationMs.toFloat()).coerceIn(0f, 1f)
        } else {
            0f
        }

    val hasResumePoint: Boolean
        get() = watchPositionMs >= 30_000L && resumeFraction < 0.94f
}

data class SeriesItem(
    val id: Long,
    val sourceId: Long,
    val stableHash: String,
    val title: String,
    val year: Int?,
    val rating: Double?,
    val posterUrl: String?,
    val backdropUrl: String?,
    val plot: String?,
    val genre: String?,
    val groupTitle: String?,
    val seasonCount: Int,
    val episodeCount: Int,
    val isFavorite: Boolean,
)

data class SeasonInfo(
    val seasonNumber: Int,
    val episodeCount: Int,
)

data class EpisodeItem(
    val id: Long,
    val seriesId: Long,
    val sourceId: Long,
    val stableHash: String,
    val title: String,
    val seasonNumber: Int,
    val episodeNumber: Int,
    val posterUrl: String?,
    val streamUrl: String,
    val containerExtension: String?,
    val host: String,
    val userAgent: String?,
    val referer: String?,
    val headers: ImmutableMap<String, String> = persistentMapOf(),
    val watchPositionMs: Long = 0L,
    val watchDurationMs: Long = 0L,
) {
    val code: String
        get() = "S%02dE%02d".format(seasonNumber, episodeNumber)
}

data class MediaDetail(
    val id: Long,
    val isSeries: Boolean,
    val stableHash: String,
    val title: String,
    val year: Int?,
    val rating: String?,
    val runtimeMinutes: Int?,
    val genre: String?,
    val plot: String?,
    val cast: String?,
    val director: String?,
    val posterUrl: String?,
    val backdropUrl: String?,
    val containerExtension: String?,
    val isFavorite: Boolean,
    val movieItem: MovieItem? = null,
    val seriesItem: SeriesItem? = null,
    val seasons: ImmutableList<SeasonInfo> = persistentListOf(),
    val episodes: ImmutableList<EpisodeItem> = persistentListOf(),
    val nextEpisode: EpisodeItem? = null,
    val otherVersions: ImmutableList<MovieItem> = persistentListOf(),
)

