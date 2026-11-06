package com.pcoundia.buntu.core.data.repository

import com.pcoundia.buntu.core.data.mapper.EngineMappers.parseHeadersJson
import com.pcoundia.buntu.core.data.mapper.EngineMappers.toChannelDomain
import com.pcoundia.buntu.core.data.mapper.EngineMappers.toDomain
import com.pcoundia.buntu.core.domain.model.ChannelGuideRow
import com.pcoundia.buntu.core.domain.model.ConnectionBudget
import com.pcoundia.buntu.core.domain.model.EpgSlot
import com.pcoundia.buntu.core.domain.model.PlayableStream
import com.pcoundia.buntu.core.domain.model.StreamKind
import com.pcoundia.buntu.core.domain.repository.EpgRepository
import com.pcoundia.buntu.core.domain.repository.SettingsRepository
import com.pcoundia.buntu.core.domain.repository.SourcesRepository
import com.pcoundia.buntu.core.engine.EngineProvider
import com.pcoundia.buntu.core.engine.ffi.CatalogFilter
import com.pcoundia.buntu.core.engine.ffi.SortField
import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.persistentListOf
import kotlinx.collections.immutable.toImmutableList
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class RustEpgRepository @Inject constructor(
    private val engineProvider: EngineProvider,
    private val sourcesRepository: SourcesRepository,
    private val settingsRepository: SettingsRepository,
) : EpgRepository {

    override suspend fun loadGuideGrid(
        groupName: String?,
        fromEpochSecs: Long,
        toEpochSecs: Long,
        limitChannels: Int,
    ): ImmutableList<ChannelGuideRow> = withContext(Dispatchers.IO) {
        val engine = engineProvider.awaitEngine()
        val channels = engine.queryCatalog(
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
                limit = limitChannels.coerceIn(1, 200).toUInt(),
                offset = 0u,
            )
        )
        val tvgIds = channels.mapNotNull { it.tvgId?.takeIf(String::isNotBlank) }.distinct()
        val nowNextMap = if (tvgIds.isNotEmpty()) {
            engine.getEpgNowNext(tvgIds).associateBy { it.channelTvgId }
        } else {
            emptyMap()
        }

        val nowSecs = System.currentTimeMillis() / 1000L
        channels.map { ch ->
            val domainCh = ch.toChannelDomain(ch.tvgId?.let(nowNextMap::get))
            val programs = ch.tvgId?.takeIf(String::isNotBlank)?.let { tvg ->
                val hasCatchupMeta = (ch.catchupDays ?: 0u) > 0u || !ch.catchupType.isNullOrBlank()
                val catchupCutoff = nowSecs - ((ch.catchupDays?.toLong() ?: 0L) * 86_400L)
                engine.getChannelEpg(tvg, fromEpochSecs, toEpochSecs).map { prog ->
                    val canReplay = hasCatchupMeta && prog.endTs <= nowSecs && prog.startTs >= catchupCutoff
                    prog.toDomain(catchupAvailable = canReplay)
                }.toImmutableList()
            } ?: persistentListOf()

            ChannelGuideRow(
                channel = domainCh,
                programs = programs,
            )
        }.toImmutableList()
    }

    override suspend fun getChannelPrograms(
        tvgId: String,
        fromEpochSecs: Long,
        toEpochSecs: Long,
    ): ImmutableList<EpgSlot> = withContext(Dispatchers.IO) {
        if (tvgId.isBlank()) return@withContext persistentListOf()
        val engine = engineProvider.awaitEngine()
        engine.getChannelEpg(tvgId, fromEpochSecs, toEpochSecs)
            .map { it.toDomain(catchupAvailable = false) }
            .toImmutableList()
    }

    override suspend fun buildCatchupStream(
        channelItemId: Long,
        startEpochSecs: Long,
        endEpochSecs: Long,
    ): PlayableStream? = withContext(Dispatchers.IO) {
        val engine = engineProvider.awaitEngine()
        val item = engine.getItemById(channelItemId) ?: return@withContext null
        val catchupUrl = engine.buildCatchupUrl(channelItemId, startEpochSecs, endEpochSecs)
            ?: return@withContext null
        val sources = sourcesRepository.refreshSourcesList()
        val prefs = settingsRepository.currentPreferences()
        val budget = ConnectionBudget.forHost(item.host, sources, prefs.assumedMaxConnections)
        val headersMap = parseHeadersJson(item.headersJson)

        PlayableStream(
            itemId = item.id,
            stableHash = item.stableHash,
            title = item.nameClean.ifBlank { item.name },
            subtitle = "Replay TV",
            posterUrl = item.logoUrl,
            originalUrl = catchupUrl,
            playbackUrl = catchupUrl,
            kind = StreamKind.CATCHUP,
            host = item.host,
            containerExtension = item.containerExt,
            userAgent = item.userAgent,
            referer = item.referer,
            headers = headersMap,
            startPositionMs = 0L,
            maxConnectionsForSource = budget.limit,
        )
    }
}

