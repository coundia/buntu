package com.pcoundia.buntu.core.data.mapper

import com.pcoundia.buntu.core.domain.model.AiProviderType
import com.pcoundia.buntu.core.domain.model.AiSettingsConfig
import com.pcoundia.buntu.core.domain.model.CatalogSort
import com.pcoundia.buntu.core.domain.model.CategoryFacet
import com.pcoundia.buntu.core.domain.model.ChannelItem
import com.pcoundia.buntu.core.domain.model.DownloadItem
import com.pcoundia.buntu.core.domain.model.EpisodeItem
import com.pcoundia.buntu.core.domain.model.EpgSlot
import com.pcoundia.buntu.core.domain.model.MovieItem
import com.pcoundia.buntu.core.domain.model.NetworkLogItem
import com.pcoundia.buntu.core.domain.model.ProfileSummary
import com.pcoundia.buntu.core.domain.model.RecoCardItem
import com.pcoundia.buntu.core.domain.model.RecoDomainKind
import com.pcoundia.buntu.core.domain.model.RecoShelfGroup
import com.pcoundia.buntu.core.domain.model.SearchHitItem
import com.pcoundia.buntu.core.domain.model.SearchHitKind
import com.pcoundia.buntu.core.domain.model.SearchOutcome
import com.pcoundia.buntu.core.domain.model.SearchScopeKind
import com.pcoundia.buntu.core.domain.model.SeasonInfo
import com.pcoundia.buntu.core.domain.model.SeriesItem
import com.pcoundia.buntu.core.domain.model.SourceKind
import com.pcoundia.buntu.core.domain.model.SourceSummary
import com.pcoundia.buntu.core.domain.model.StreamKind
import com.pcoundia.buntu.core.domain.model.SyncReport
import com.pcoundia.buntu.core.domain.model.UpNextContext
import com.pcoundia.buntu.core.domain.model.UpNextItem
import com.pcoundia.buntu.core.domain.model.UpNextReason
import com.pcoundia.buntu.core.engine.ffi.AiProviderConfig
import com.pcoundia.buntu.core.engine.ffi.AiProviderKind
import com.pcoundia.buntu.core.engine.ffi.ChannelNowNext
import com.pcoundia.buntu.core.engine.ffi.DownloadTaskRecord
import com.pcoundia.buntu.core.engine.ffi.EpgProgramRecord
import com.pcoundia.buntu.core.engine.ffi.FacetCount
import com.pcoundia.buntu.core.engine.ffi.IptvItemRecord
import com.pcoundia.buntu.core.engine.ffi.IptvSourceRecord
import com.pcoundia.buntu.core.engine.ffi.NetworkLogEntry
import com.pcoundia.buntu.core.engine.ffi.ProfileRecord
import com.pcoundia.buntu.core.engine.ffi.RecoCard
import com.pcoundia.buntu.core.engine.ffi.RecoKind
import com.pcoundia.buntu.core.engine.ffi.RecoShelf
import com.pcoundia.buntu.core.engine.ffi.Recommendation
import com.pcoundia.buntu.core.engine.ffi.RecommendationContext
import com.pcoundia.buntu.core.engine.ffi.RecommendationReasonKind
import com.pcoundia.buntu.core.engine.ffi.SearchHit
import com.pcoundia.buntu.core.engine.ffi.SearchKind
import com.pcoundia.buntu.core.engine.ffi.SearchResponse
import com.pcoundia.buntu.core.engine.ffi.SeasonSummary
import com.pcoundia.buntu.core.engine.ffi.SeriesRecord
import com.pcoundia.buntu.core.engine.ffi.SortField
import com.pcoundia.buntu.core.engine.ffi.SyncSummary
import kotlinx.collections.immutable.ImmutableMap
import kotlinx.collections.immutable.persistentMapOf
import kotlinx.collections.immutable.toImmutableList
import kotlinx.collections.immutable.toImmutableMap
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * PRD-37 § 5.1:
 * Converts mutable UniFFI JNA records into `@Immutable` / immutable Kotlin domain models
 * on background threads so no UniFFI record ever reaches a Composable.
 */
object EngineMappers {

    private val json = Json { ignoreUnknownKeys = true }

    fun parseHeadersJson(rawJson: String?): ImmutableMap<String, String> {
        val text = rawJson?.trim()?.takeIf { it.startsWith("{") } ?: return persistentMapOf()
        return runCatching {
            val obj = json.parseToJsonElement(text).jsonObject
            obj.entries.associate { (k, v) -> k to v.jsonPrimitive.content }.toImmutableMap()
        }.getOrDefault(persistentMapOf())
    }

    fun IptvSourceRecord.toDomain(): SourceSummary = SourceSummary(
        id = id,
        uuid = uuid,
        name = name,
        kind = if (sourceType.equals("xtream", ignoreCase = true)) SourceKind.XTREAM else SourceKind.M3U,
        serverOrUrl = server?.takeIf { it.isNotBlank() } ?: url.orEmpty(),
        username = username,
        passwordRef = passwordRef,
        epgUrl = epgUrl,
        maxConnections = maxConnections?.toInt(),
        activeConnections = activeCons?.toInt(),
        expDateEpochSecs = expDate,
        accountStatus = accountStatus,
        lastSyncEpochSecs = updatedAt.takeIf { it > 0L },
    )

    fun SyncSummary.toDomain(): SyncReport = SyncReport(
        totalItems = totalItems.toInt(),
        liveCount = liveCount.toInt(),
        movieCount = movieCount.toInt(),
        seriesCount = seriesCount.toInt(),
        episodeCount = episodeCount.toInt(),
        durationMs = durationMs.toLong(),
    )

    fun FacetCount.toDomain(isAdult: Boolean = false): CategoryFacet = CategoryFacet(
        name = value,
        count = count.toInt(),
        isAdult = isAdult,
    )

    fun CatalogSort.toEngineSort(): Pair<SortField, Boolean> = when (this) {
        CatalogSort.DEFAULT -> SortField.CHANNEL_NUMBER to true
        CatalogSort.NAME_ASC -> SortField.NAME to true
        CatalogSort.RECENTLY_ADDED -> SortField.RECENTLY_ADDED to false
        CatalogSort.YEAR_DESC -> SortField.RECENTLY_ADDED to false
        CatalogSort.RATING_DESC -> SortField.RATING to false
    }

    fun IptvItemRecord.toChannelDomain(nowNext: ChannelNowNext? = null): ChannelItem = ChannelItem(
        id = id,
        sourceId = sourceId,
        stableHash = stableHash,
        name = nameClean.ifBlank { name },
        channelNumber = chno?.toInt(),
        groupTitle = groupTitle,
        logoUrl = logoUrl,
        tvgId = tvgId,
        streamUrl = streamUrl,
        containerExtension = containerExt,
        host = host,
        userAgent = userAgent,
        referer = referer,
        headers = parseHeadersJson(headersJson),
        catchupDays = catchupDays?.toInt(),
        isFavorite = isFavorite,
        isBroken = isBroken,
        nowTitle = nowNext?.now?.title,
        nowProgress = (nowNext?.now?.progressRatio ?: 0.0).toFloat().coerceIn(0f, 1f),
        nextTitle = nowNext?.next?.title,
    )

    /** Engine item kind (`live`, `movie`, `episode`) to the player's stream kind. */
    fun streamKindOf(engineKind: String): StreamKind = when (engineKind) {
        "live" -> StreamKind.LIVE
        "episode" -> StreamKind.VOD_EPISODE
        else -> StreamKind.VOD_MOVIE
    }

    /** PRD-27: a recommendation chosen by `cnd-core`, ready for the "À suivre" row or the end card. */
    fun Recommendation.toUpNextDomain(): UpNextItem {
        val kind = streamKindOf(item.kind)
        val subtitle = when (kind) {
            StreamKind.VOD_EPISODE -> {
                val season = item.seasonNum?.toInt()
                val episode = item.episodeNum?.toInt()
                if (season != null && episode != null) "S%02dE%02d".format(season, episode) else item.groupTitle
            }
            StreamKind.LIVE -> item.groupTitle
            else -> item.year?.toString() ?: item.groupTitle
        }
        return UpNextItem(
            itemId = item.id,
            stableHash = item.stableHash,
            kind = kind,
            title = item.nameClean.ifBlank { item.name },
            subtitle = subtitle,
            posterUrl = item.logoUrl,
            reason = when (reasonKind) {
                RecommendationReasonKind.SAGA_NEXT -> UpNextReason.SAGA_NEXT
                RecommendationReasonKind.SAGA_MEMBER -> UpNextReason.SAGA_MEMBER
                RecommendationReasonKind.NEXT_EPISODE -> UpNextReason.NEXT_EPISODE
                RecommendationReasonKind.SAME_DIRECTOR -> UpNextReason.SAME_DIRECTOR
                RecommendationReasonKind.SAME_ACTOR -> UpNextReason.SAME_ACTOR
                RecommendationReasonKind.SIMILAR_GENRE -> UpNextReason.SIMILAR_GENRE
                RecommendationReasonKind.RESUME -> UpNextReason.RESUME
                RecommendationReasonKind.LIVE_NOW -> UpNextReason.LIVE_NOW
            },
            reasonText = reasonText,
            alreadyWatched = alreadyWatched,
            resumePositionMs = item.resumePositionMs,
            durationMs = item.durationMs,
        )
    }

    fun UpNextContext.toEngineContext(): RecommendationContext = when (this) {
        UpNextContext.PLAYING -> RecommendationContext.PLAYING
        UpNextContext.ENDING -> RecommendationContext.ENDING
        UpNextContext.LIVE -> RecommendationContext.LIVE
    }

    fun IptvItemRecord.toMovieDomain(): MovieItem = MovieItem(
        id = id,
        sourceId = sourceId,
        stableHash = stableHash,
        title = nameClean.ifBlank { name },
        year = year?.toInt(),
        rating = imdbRating,
        posterUrl = logoUrl,
        groupTitle = groupTitle,
        streamUrl = streamUrl,
        containerExtension = containerExt,
        host = host,
        userAgent = userAgent,
        referer = referer,
        headers = parseHeadersJson(headersJson),
        isFavorite = isFavorite,
        watchPositionMs = resumePositionMs,
        watchDurationMs = durationMs,
    )

    fun IptvItemRecord.toEpisodeDomain(fallbackSeriesId: Long = 0L): EpisodeItem = EpisodeItem(
        id = id,
        seriesId = seriesId ?: fallbackSeriesId,
        sourceId = sourceId,
        stableHash = stableHash,
        title = nameClean.ifBlank { name },
        seasonNumber = seasonNum?.toInt() ?: 1,
        episodeNumber = episodeNum?.toInt() ?: 1,
        posterUrl = logoUrl,
        streamUrl = streamUrl,
        containerExtension = containerExt,
        host = host,
        userAgent = userAgent,
        referer = referer,
        headers = parseHeadersJson(headersJson),
        watchPositionMs = resumePositionMs,
        watchDurationMs = durationMs,
    )

    fun SeriesRecord.toDomain(): SeriesItem = SeriesItem(
        id = id,
        sourceId = sourceId,
        stableHash = stableHash,
        title = title,
        year = null,
        rating = imdbRating,
        posterUrl = posterUrl,
        backdropUrl = backdropUrl,
        plot = plot,
        genre = groupTitle,
        groupTitle = groupTitle,
        seasonCount = seasonCount.toInt(),
        episodeCount = episodeCount.toInt(),
        isFavorite = isFavorite,
    )

    fun SeasonSummary.toDomain(): SeasonInfo = SeasonInfo(
        seasonNumber = seasonNum.toInt(),
        episodeCount = episodeCount.toInt(),
    )

    fun EpgProgramRecord.toDomain(catchupAvailable: Boolean): EpgSlot = EpgSlot(
        id = id,
        channelTvgId = channelTvgId,
        title = title,
        description = description ?: subtitle,
        category = category,
        startEpochSecs = startTs,
        endEpochSecs = endTs,
        isCatchupAvailable = catchupAvailable,
    )

    fun SearchScopeKind.toEngineKinds(): List<SearchKind> = when (this) {
        SearchScopeKind.ALL -> emptyList()
        SearchScopeKind.LIVE -> listOf(SearchKind.LIVE, SearchKind.PROGRAM)
        SearchScopeKind.MOVIES -> listOf(SearchKind.MOVIE)
        SearchScopeKind.SERIES -> listOf(SearchKind.SERIES)
    }

    fun SearchHit.toDomain(nowEpochSecs: Long): SearchHitItem? {
        val hitKind = when (kind) {
            SearchKind.LIVE -> SearchHitKind.LIVE
            SearchKind.PROGRAM -> {
                val endTs = program?.endTs ?: 0L
                if (endTs in 1..nowEpochSecs) SearchHitKind.REPLAY else SearchHitKind.PROGRAMME
            }
            SearchKind.MOVIE -> SearchHitKind.MOVIE
            SearchKind.SERIES -> SearchHitKind.SERIES
        }
        val targetId = series?.id ?: item?.id ?: return null
        val hash = series?.stableHash ?: item?.stableHash ?: ""
        val hitTitle = when (kind) {
            SearchKind.PROGRAM -> program?.title ?: item?.nameClean ?: item?.name.orEmpty()
            SearchKind.SERIES -> series?.title.orEmpty()
            else -> item?.nameClean?.ifBlank { item?.name.orEmpty() } ?: item?.name.orEmpty()
        }
        val hitSubtitle = when (kind) {
            SearchKind.PROGRAM -> item?.nameClean ?: item?.name
            SearchKind.SERIES -> series?.groupTitle
            else -> item?.groupTitle
        }
        val poster = series?.posterUrl ?: item?.logoUrl
        return SearchHitItem(
            id = targetId,
            seriesId = series?.id,
            stableHash = hash,
            kind = hitKind,
            title = hitTitle,
            subtitle = hitSubtitle,
            posterUrl = poster,
            reason = reason,
            startEpochSecs = program?.startTs,
            endEpochSecs = program?.endTs,
        )
    }

    fun SearchResponse.toDomain(query: String, nowEpochSecs: Long): SearchOutcome = SearchOutcome(
        query = query,
        hits = hits.mapNotNull { it.toDomain(nowEpochSecs) }.toImmutableList(),
        missingTitles = missingTitles.toImmutableList(),
        assistantReply = reply,
        resolvedBy = resolvedBy,
        latencyMs = latencyMs.toLong(),
        fallbackReason = fallbackReason,
    )

    fun RecoDomainKind.toEngineKind(): RecoKind = when (this) {
        RecoDomainKind.MOVIES -> RecoKind.MOVIES
        RecoDomainKind.SERIES -> RecoKind.SERIES
        RecoDomainKind.LIVE_TV -> RecoKind.LIVE
    }

    fun RecoKind.toDomain(): RecoDomainKind = when (this) {
        RecoKind.MOVIES -> RecoDomainKind.MOVIES
        RecoKind.SERIES -> RecoDomainKind.SERIES
        RecoKind.LIVE -> RecoDomainKind.LIVE_TV
    }

    fun RecoCard.toDomain(domainKind: RecoDomainKind): RecoCardItem? {
        val targetItem = nextEpisode ?: item
        val targetSeries = series
        val hash = targetSeries?.stableHash ?: targetItem?.stableHash ?: return null
        val displayTitle = when {
            program != null && targetItem != null -> program!!.title
            targetSeries != null -> targetSeries.title
            targetItem != null -> targetItem.nameClean.ifBlank { targetItem.name }
            else -> return null
        }
        val subtitle = when {
            program != null && targetItem != null -> targetItem.nameClean.ifBlank { targetItem.name }
            nextEpisode != null -> "S%02dE%02d".format(
                nextEpisode!!.seasonNum?.toInt() ?: 1,
                nextEpisode!!.episodeNum?.toInt() ?: 1,
            )
            targetSeries != null -> targetSeries.groupTitle
            else -> targetItem?.groupTitle
        }
        val poster = targetSeries?.posterUrl ?: targetItem?.logoUrl
        return RecoCardItem(
            itemId = targetItem?.id,
            seriesId = targetSeries?.id,
            stableHash = hash,
            kind = domainKind,
            title = displayTitle,
            subtitle = subtitle,
            posterUrl = poster,
            reasonLabel = reasonText,
            startEpochSecs = program?.startTs,
            endEpochSecs = program?.endTs,
        )
    }

    fun RecoShelf.toDomain(): RecoShelfGroup {
        val domainKind = kind.toDomain()
        return RecoShelfGroup(
            id = id,
            title = title,
            kind = domainKind,
            refinedByAi = refinedBy.orEmpty(),
            cards = items.mapNotNull { it.toDomain(domainKind) }.toImmutableList(),
        )
    }

    fun DownloadTaskRecord.toDomain(): DownloadItem = DownloadItem(
        id = id,
        itemId = null,
        title = fileName,
        state = state,
        downloadedBytes = downloadedBytes.toLong(),
        totalBytes = totalBytes.toLong().takeIf { it > 0L },
        speedBytesPerSec = speedBps,
        etaSeconds = etaSeconds.toLong().takeIf { it > 0L },
        targetPath = savePath,
        errorMessage = null,
    )

    fun ProfileRecord.toDomain(activeId: Long): ProfileSummary = ProfileSummary(
        id = id,
        name = name,
        avatar = avatar,
        isKids = isKids,
        isActive = id == activeId,
    )

    fun NetworkLogEntry.toDomain(): NetworkLogItem = NetworkLogItem(
        seqId = seqId.toLong(),
        timestampMs = timestampMs,
        level = level.name,
        category = category,
        redactedUrl = urlRedacted,
        statusCode = statusCode?.toInt(),
        durationMs = durationMs?.toLong(),
        message = message,
    )

    fun AiSettingsConfig.toEngineConfig(apiKey: String?): AiProviderConfig {
        val kind = when (provider) {
            AiProviderType.NONE -> AiProviderKind.LOCAL_ONLY
            AiProviderType.GEMINI -> AiProviderKind.GEMINI
            AiProviderType.OPENAI_COMPATIBLE -> AiProviderKind.OPEN_AI_COMPATIBLE
            AiProviderType.CLAUDE -> AiProviderKind.ANTHROPIC
        }
        return AiProviderConfig(
            kind = kind,
            model = model.trim(),
            baseUrl = endpointUrl.trim().takeIf { it.isNotEmpty() },
            apiKey = apiKey?.takeIf { it.isNotBlank() },
            timeoutMs = 12_000u,
        )
    }
}

