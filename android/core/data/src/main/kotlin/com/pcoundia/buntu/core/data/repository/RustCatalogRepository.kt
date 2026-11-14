package com.pcoundia.buntu.core.data.repository

import androidx.paging.Pager
import androidx.paging.PagingConfig
import androidx.paging.map
import kotlinx.coroutines.flow.combine
import com.pcoundia.buntu.core.domain.repository.PlaybackHealthRepository
import androidx.paging.PagingData
import com.pcoundia.buntu.core.data.mapper.EngineMappers.parseHeadersJson
import com.pcoundia.buntu.core.data.mapper.EngineMappers.toChannelDomain
import com.pcoundia.buntu.core.data.mapper.EngineMappers.toDomain
import com.pcoundia.buntu.core.data.mapper.EngineMappers.toEpisodeDomain
import com.pcoundia.buntu.core.data.mapper.EngineMappers.toMovieDomain
import com.pcoundia.buntu.core.data.paging.LiveChannelsPagingSource
import com.pcoundia.buntu.core.data.paging.MoviesPagingSource
import com.pcoundia.buntu.core.data.paging.SeriesPagingSource
import com.pcoundia.buntu.core.domain.model.CatalogQuery
import com.pcoundia.buntu.core.domain.model.CategoryFacet
import com.pcoundia.buntu.core.domain.model.ChannelItem
import com.pcoundia.buntu.core.domain.model.ConnectionBudget
import com.pcoundia.buntu.core.domain.model.EpisodeItem
import com.pcoundia.buntu.core.domain.model.MediaDetail
import com.pcoundia.buntu.core.domain.model.MovieItem
import com.pcoundia.buntu.core.domain.model.PlayableStream
import com.pcoundia.buntu.core.domain.model.SeriesItem
import com.pcoundia.buntu.core.domain.model.StreamKind
import com.pcoundia.buntu.core.domain.repository.CatalogRepository
import com.pcoundia.buntu.core.domain.repository.SettingsRepository
import com.pcoundia.buntu.core.domain.repository.SourcesRepository
import com.pcoundia.buntu.core.engine.EngineProvider
import com.pcoundia.buntu.core.engine.ffi.CatalogFilter
import com.pcoundia.buntu.core.engine.ffi.IptvItemRecord
import com.pcoundia.buntu.core.engine.ffi.SortField
import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.persistentListOf
import kotlinx.collections.immutable.toImmutableList
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.withContext
import java.util.concurrent.ConcurrentHashMap
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class RustCatalogRepository @Inject constructor(
    private val engineProvider: EngineProvider,
    private val sourcesRepository: SourcesRepository,
    private val settingsRepository: SettingsRepository,
    private val playbackHealth: PlaybackHealthRepository,
) : CatalogRepository {

    companion object {
        // PRD-37 § 5.1: Paging 3 with 2-page prefetch distance, zero per-item FFI calls
        const val PAGE_SIZE = 60
        const val PREFETCH_DISTANCE = 120
        private const val FACET_CACHE_TTL_MS = 15_000L
    }

    private data class CachedFacets(
        val timestampMs: Long,
        val facets: ImmutableList<CategoryFacet>,
    )

    private val facetsCache = ConcurrentHashMap<String, CachedFacets>()

    private fun defaultPagingConfig(): PagingConfig = PagingConfig(
        pageSize = PAGE_SIZE,
        prefetchDistance = PREFETCH_DISTANCE,
        initialLoadSize = PAGE_SIZE * 2,
        enablePlaceholders = false,
        maxSize = PAGE_SIZE * 8,
    )

    override fun pagedLiveChannels(query: CatalogQuery): Flow<PagingData<ChannelItem>> =
        Pager(config = defaultPagingConfig()) {
            LiveChannelsPagingSource(engineProvider, query)
        }.flow.combine(playbackHealth.brokenChannels) { pages, statuses ->
            pages.map { channel -> statuses[channel.stableHash]?.let { channel.copy(isBroken = it) } ?: channel }
        }

    override fun pagedMovies(query: CatalogQuery): Flow<PagingData<MovieItem>> =
        Pager(config = defaultPagingConfig()) {
            MoviesPagingSource(engineProvider, query)
        }.flow

    override fun pagedSeries(query: CatalogQuery): Flow<PagingData<SeriesItem>> =
        Pager(config = defaultPagingConfig()) {
            SeriesPagingSource(engineProvider, query)
        }.flow

    override suspend fun getGroups(kind: String, sourceId: Long?): ImmutableList<CategoryFacet> =
        withContext(Dispatchers.IO) {
            val cacheKey = "$kind:${sourceId ?: "all"}"
            val now = System.currentTimeMillis()
            facetsCache[cacheKey]?.takeIf { now - it.timestampMs < FACET_CACHE_TTL_MS }?.let {
                return@withContext it.facets
            }
            val engine = engineProvider.awaitEngine()
            val facets = engine.getGroups(kind, sourceId)
                .map { facet ->
                    facet.toDomain(isAdult = engine.isAdultCategory(facet.value))
                }
                .toImmutableList()
            facetsCache[cacheKey] = CachedFacets(now, facets)
            facets
        }

    override suspend fun getChannelById(itemId: Long): ChannelItem? =
        withContext(Dispatchers.IO) {
            val engine = engineProvider.awaitEngine()
            val row = engine.getItemById(itemId)?.takeIf { it.kind == "live" } ?: return@withContext null
            val nowNext = row.tvgId?.takeIf(String::isNotBlank)?.let { tvg ->
                engine.getEpgNowNext(listOf(tvg)).firstOrNull()
            }
            row.toChannelDomain(nowNext)
        }

    override suspend fun getAdjacentChannel(
        currentItemId: Long,
        delta: Int,
        groupName: String?,
    ): ChannelItem? = withContext(Dispatchers.IO) {
        val engine = engineProvider.awaitEngine()
        val window = engine.queryCatalog(
            CatalogFilter(
                kind = "live",
                sourceId = null,
                query = "",
                groupTitle = groupName,
                host = null,
                favoritesOnly = false,
                includeBroken = false,
                includeHidden = false,
                sortBy = SortField.CHANNEL_NUMBER,
                sortAsc = true,
                limit = 500u,
                offset = 0u,
            )
        )
        if (window.isEmpty()) return@withContext null
        val currentIdx = window.indexOfFirst { it.id == currentItemId }
        val nextIdx = if (currentIdx < 0) {
            0
        } else {
            val mod = (currentIdx + delta) % window.size
            if (mod < 0) mod + window.size else mod
        }
        val target = window[nextIdx]
        val nowNext = target.tvgId?.takeIf(String::isNotBlank)?.let { tvg ->
            engine.getEpgNowNext(listOf(tvg)).firstOrNull()
        }
        target.toChannelDomain(nowNext)
    }

    override suspend fun getChannelByNumber(number: Int): ChannelItem? =
        withContext(Dispatchers.IO) {
            if (number <= 0) return@withContext null
            val engine = engineProvider.awaitEngine()
            val candidates = engine.queryCatalog(
                CatalogFilter(
                    kind = "live",
                    sourceId = null,
                    query = "",
                    groupTitle = null,
                    host = null,
                    favoritesOnly = false,
                    includeBroken = false,
                    includeHidden = false,
                    sortBy = SortField.CHANNEL_NUMBER,
                    sortAsc = true,
                    limit = 500u,
                    offset = 0u,
                )
            )
            val match = candidates.firstOrNull { it.chno?.toInt() == number }
                ?: candidates.getOrNull(number - 1)
                ?: return@withContext null
            val nowNext = match.tvgId?.takeIf(String::isNotBlank)?.let { tvg ->
                engine.getEpgNowNext(listOf(tvg)).firstOrNull()
            }
            match.toChannelDomain(nowNext)
        }

    override suspend fun listFavoriteChannels(): ImmutableList<ChannelItem> =
        withContext(Dispatchers.IO) {
            val engine = engineProvider.awaitEngine()
            val rows = engine.listFavoriteItems("live")
            val tvgIds = rows.mapNotNull { it.tvgId?.takeIf(String::isNotBlank) }.distinct()
            val nowNextMap = if (tvgIds.isNotEmpty()) {
                engine.getEpgNowNext(tvgIds).associateBy { it.channelTvgId }
            } else {
                emptyMap()
            }
            rows.map { row -> row.toChannelDomain(row.tvgId?.let(nowNextMap::get)) }.toImmutableList()
        }

    override suspend fun listRecentChannels(limit: Int): ImmutableList<ChannelItem> =
        withContext(Dispatchers.IO) {
            val engine = engineProvider.awaitEngine()
            val rows = engine.listRecentItems("live", limit.coerceIn(1, 100).toUInt())
            rows.mapChannelsWithEpg(engine)
        }

    override suspend fun findChannelMirrors(itemId: Long): ImmutableList<ChannelItem> =
        withContext(Dispatchers.IO) {
            val engine = engineProvider.awaitEngine()
            val rows = runCatching { engine.findMirrors(itemId) }.getOrDefault(emptyList())
            if (rows.isEmpty()) return@withContext persistentListOf()
            rows.mapChannelsWithEpg(engine)
        }

    override suspend fun listChannelsInGroup(
        groupName: String?,
        limit: Int,
    ): ImmutableList<ChannelItem> = withContext(Dispatchers.IO) {
        val engine = engineProvider.awaitEngine()
        val rows = engine.queryCatalog(
            CatalogFilter(
                kind = "live",
                sourceId = null,
                query = "",
                groupTitle = groupName,
                host = null,
                favoritesOnly = false,
                includeBroken = false,
                includeHidden = false,
                sortBy = SortField.CHANNEL_NUMBER,
                sortAsc = true,
                limit = limit.coerceIn(1, 500).toUInt(),
                offset = 0u,
            )
        )
        rows.mapChannelsWithEpg(engine)
    }

    private fun List<IptvItemRecord>.mapChannelsWithEpg(
        engine: com.pcoundia.buntu.core.engine.ffi.CndEngine,
    ): ImmutableList<ChannelItem> {
        val tvgIds = mapNotNull { it.tvgId?.takeIf(String::isNotBlank) }.distinct()
        val nowNextMap = if (tvgIds.isNotEmpty()) {
            engine.getEpgNowNext(tvgIds).associateBy { it.channelTvgId }
        } else {
            emptyMap()
        }
        return map { row -> row.toChannelDomain(row.tvgId?.let(nowNextMap::get)) }.toImmutableList()
    }

    override suspend fun getMovieDetail(itemId: Long, metadataApiKey: String?): MediaDetail? =
        withContext(Dispatchers.IO) {
            val engine = engineProvider.awaitEngine()
            val item = engine.getItemById(itemId) ?: return@withContext null
            val meta = metadataApiKey?.takeIf(String::isNotBlank)?.let { key ->
                runCatching { engine.fetchItemMetadata(itemId, key, false) }.getOrNull()
            }
            val otherVersions = runCatching { engine.otherVersions(itemId) }
                .getOrDefault(emptyList())
                .map { it.toMovieDomain() }
                .toImmutableList()

            val runtimeMinutes = meta?.runtime
                ?.filter(Char::isDigit)
                ?.toIntOrNull()
                ?: item.durationMs.takeIf { it > 0L }?.let { (it / 60_000L).toInt() }

            MediaDetail(
                id = item.id,
                isSeries = false,
                stableHash = item.stableHash,
                title = meta?.title?.takeIf(String::isNotBlank) ?: item.nameClean.ifBlank { item.name },
                year = meta?.year?.take(4)?.toIntOrNull() ?: item.year?.toInt(),
                rating = meta?.imdbRating?.toString() ?: item.imdbRating?.toString(),
                runtimeMinutes = runtimeMinutes,
                genre = meta?.genres ?: item.groupTitle,
                plot = meta?.plot ?: item.plot,
                cast = meta?.actors,
                director = meta?.director,
                posterUrl = meta?.posterUrl ?: item.logoUrl,
                backdropUrl = meta?.posterUrl ?: item.logoUrl,
                containerExtension = item.containerExt,
                isFavorite = item.isFavorite,
                movieItem = item.toMovieDomain(),
                otherVersions = otherVersions,
            )
        }

    override suspend fun getSeriesDetail(
        seriesId: Long,
        selectedSeason: Int?,
        xtreamPassword: String?,
        metadataApiKey: String?,
    ): MediaDetail? = withContext(Dispatchers.IO) {
        val engine = engineProvider.awaitEngine()
        if (!xtreamPassword.isNullOrBlank()) {
            runCatching { engine.ensureXtreamSeriesEpisodes(seriesId, xtreamPassword) }
        }
        val series = engine.getSeriesById(seriesId) ?: return@withContext null
        val seasons = engine.getSeriesSeasons(seriesId).map { it.toDomain() }.toImmutableList()
        val targetSeason = selectedSeason ?: seasons.firstOrNull()?.seasonNumber
        val episodes = engine.getSeriesEpisodes(seriesId, targetSeason?.toUInt())
            .map { it.toEpisodeDomain(fallbackSeriesId = seriesId) }
            .toImmutableList()

        val allEpisodes = if (targetSeason != null && seasons.size > 1) {
            engine.getSeriesEpisodes(seriesId, null).map { it.toEpisodeDomain(fallbackSeriesId = seriesId) }
        } else {
            episodes
        }
        val nextEpisode = allEpisodes.firstOrNull { ep ->
            ep.watchDurationMs <= 0L || (ep.watchPositionMs.toFloat() / ep.watchDurationMs.toFloat()) < 0.92f
        } ?: allEpisodes.firstOrNull()

        val meta = metadataApiKey?.takeIf(String::isNotBlank)?.let { key ->
            runCatching { engine.fetchSeriesMetadata(seriesId, key, false) }.getOrNull()
        }

        MediaDetail(
            id = series.id,
            isSeries = true,
            stableHash = series.stableHash,
            title = series.title,
            year = meta?.year?.take(4)?.toIntOrNull(),
            rating = meta?.imdbRating?.toString() ?: series.imdbRating?.toString(),
            runtimeMinutes = null,
            genre = meta?.genres ?: series.groupTitle,
            plot = meta?.plot ?: series.plot,
            cast = meta?.actors,
            director = meta?.director,
            posterUrl = meta?.posterUrl ?: series.posterUrl,
            backdropUrl = series.backdropUrl ?: series.posterUrl,
            containerExtension = episodes.firstOrNull()?.containerExtension,
            isFavorite = series.isFavorite,
            seriesItem = series.toDomain(),
            seasons = seasons,
            episodes = episodes,
            nextEpisode = nextEpisode,
        )
    }

    override suspend fun getEpisodeById(episodeId: Long): EpisodeItem? =
        withContext(Dispatchers.IO) {
            val engine = engineProvider.awaitEngine()
            engine.getItemById(episodeId)?.toEpisodeDomain()
        }

    override suspend fun toggleFavorite(stableHash: String, kind: String): Boolean =
        withContext(Dispatchers.IO) {
            facetsCache.clear()
            engineProvider.awaitEngine().toggleFavorite(stableHash, kind)
        }

    override suspend fun isFavoriteForPlayback(itemId: Long): Boolean =
        withContext(Dispatchers.IO) {
            val engine = engineProvider.awaitEngine()
            val item = engine.getItemById(itemId) ?: return@withContext false
            val seriesId = item.seriesId
            if (item.kind == "episode" && seriesId != null) {
                engine.getSeriesById(seriesId)?.isFavorite ?: false
            } else {
                item.isFavorite
            }
        }

    override suspend fun toggleFavoriteForPlayback(itemId: Long): Boolean =
        withContext(Dispatchers.IO) {
            facetsCache.clear()
            val engine = engineProvider.awaitEngine()
            val item = engine.getItemById(itemId) ?: return@withContext false
            val seriesId = item.seriesId
            val series = if (item.kind == "episode" && seriesId != null) engine.getSeriesById(seriesId) else null
            if (series != null) {
                // Same as Apple `AppState.toggleFavorite(for:)`: the series carries the favorite, the episode follows.
                val newState = engine.toggleFavorite(series.stableHash, "series")
                runCatching { engine.toggleFavorite(item.stableHash, "episode") }
                newState
            } else {
                engine.toggleFavorite(item.stableHash, item.kind)
            }
        }

    override suspend fun recordWatchProgress(
        stableHash: String,
        positionMs: Long,
        durationMs: Long,
    ) = withContext(Dispatchers.IO) {
        engineProvider.awaitEngine().recordWatchProgress(stableHash, positionMs, durationMs)
    }

    override suspend fun resolvePlayableStream(
        itemId: Long,
        startPositionMs: Long,
    ): PlayableStream? = withContext(Dispatchers.IO) {
        val engine = engineProvider.awaitEngine()
        val item = engine.getItemById(itemId) ?: return@withContext null
        val sources = sourcesRepository.refreshSourcesList()
        val prefs = settingsRepository.currentPreferences()
        val budget = ConnectionBudget.forHost(
            host = item.host,
            sources = sources,
            assumedLimit = prefs.assumedMaxConnections,
        )
        val headersMap = parseHeadersJson(item.headersJson)

        val kind = when (item.kind) {
            "live" -> StreamKind.LIVE
            "episode" -> StreamKind.VOD_EPISODE
            else -> StreamKind.VOD_MOVIE
        }

        // PRD-37 § 4.2: VOD movies & episodes ALWAYS go through the Rust single-connection relay
        // (`127.0.0.1`), closing any previous upstream connection before opening a new one on seek/retry!
        val playbackUrl = if (kind == StreamKind.VOD_MOVIE || kind == StreamKind.VOD_EPISODE) {
            engine.singleConnectionUrl(
                url = item.streamUrl,
                userAgent = item.userAgent,
                referer = item.referer,
                headers = HashMap(headersMap),
            )
        } else {
            item.streamUrl
        }

        val effectiveStartMs = if (startPositionMs > 0L) {
            startPositionMs
        } else if (kind != StreamKind.LIVE && !item.isCompleted && item.resumePositionMs >= 30_000L) {
            item.resumePositionMs
        } else {
            0L
        }

        PlayableStream(
            itemId = item.id,
            stableHash = item.stableHash,
            title = item.nameClean.ifBlank { item.name },
            subtitle = item.groupTitle,
            posterUrl = item.logoUrl,
            originalUrl = item.streamUrl,
            playbackUrl = playbackUrl,
            kind = kind,
            host = item.host,
            containerExtension = item.containerExt,
            userAgent = item.userAgent,
            referer = item.referer,
            headers = headersMap,
            startPositionMs = effectiveStartMs,
            expectedFileSizeBytes = null,
            expectedDurationMs = item.durationMs.takeIf { it > 0L },
            maxConnectionsForSource = budget.limit,
        )
    }
}

