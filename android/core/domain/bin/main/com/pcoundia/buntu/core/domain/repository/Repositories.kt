package com.pcoundia.buntu.core.domain.repository

import androidx.paging.PagingData
import com.pcoundia.buntu.core.domain.model.AiSettingsConfig
import com.pcoundia.buntu.core.domain.model.AppPreferences
import com.pcoundia.buntu.core.domain.model.CatalogQuery
import com.pcoundia.buntu.core.domain.model.CategoryFacet
import com.pcoundia.buntu.core.domain.model.ChannelGuideRow
import com.pcoundia.buntu.core.domain.model.ChannelItem
import com.pcoundia.buntu.core.domain.model.DownloadItem
import com.pcoundia.buntu.core.domain.model.EpisodeItem
import com.pcoundia.buntu.core.domain.model.EpgSlot
import com.pcoundia.buntu.core.domain.model.MediaDetail
import com.pcoundia.buntu.core.domain.model.MovieItem
import com.pcoundia.buntu.core.domain.model.NetworkLogItem
import com.pcoundia.buntu.core.domain.model.PlayableStream
import com.pcoundia.buntu.core.domain.model.ProfileSummary
import com.pcoundia.buntu.core.domain.model.RecoDomainKind
import com.pcoundia.buntu.core.domain.model.RecoShelfGroup
import com.pcoundia.buntu.core.domain.model.SearchOutcome
import com.pcoundia.buntu.core.domain.model.SearchScopeKind
import com.pcoundia.buntu.core.domain.model.SeriesItem
import com.pcoundia.buntu.core.domain.model.SourceSummary
import com.pcoundia.buntu.core.domain.model.SyncReport
import kotlinx.collections.immutable.ImmutableList
import kotlinx.coroutines.flow.Flow

interface SourcesRepository {
    val sourcesFlow: Flow<ImmutableList<SourceSummary>>
    suspend fun refreshSourcesList(): ImmutableList<SourceSummary>
    suspend fun addM3uSource(name: String, url: String): Long
    suspend fun addXtreamSource(
        name: String,
        server: String,
        username: String,
        passwordRef: String,
    ): Long
    suspend fun deleteSource(sourceId: Long)
    suspend fun syncM3uSource(sourceId: Long): SyncReport
    suspend fun syncXtreamSource(sourceId: Long, password: String): SyncReport
    suspend fun syncSourceEpg(sourceId: Long, password: String?): Int
    suspend fun importShareJson(decryptedJson: String): Int
    suspend fun exportShareJson(
        sourceIds: Set<Long>,
        includeCredentials: Set<Long>,
        senderName: String,
        validForSeconds: Int = 3600,
    ): String
}

interface CatalogRepository {
    fun pagedLiveChannels(query: CatalogQuery): Flow<PagingData<ChannelItem>>
    fun pagedMovies(query: CatalogQuery): Flow<PagingData<MovieItem>>
    fun pagedSeries(query: CatalogQuery): Flow<PagingData<SeriesItem>>

    suspend fun getGroups(kind: String, sourceId: Long? = null): ImmutableList<CategoryFacet>
    suspend fun getChannelById(itemId: Long): ChannelItem?
    suspend fun getAdjacentChannel(currentItemId: Long, delta: Int, groupName: String? = null): ChannelItem?
    suspend fun getChannelByNumber(number: Int): ChannelItem?
    suspend fun listFavoriteChannels(): ImmutableList<ChannelItem>
    suspend fun listRecentChannels(limit: Int = 20): ImmutableList<ChannelItem>

    suspend fun getMovieDetail(itemId: Long, metadataApiKey: String? = null): MediaDetail?
    suspend fun getSeriesDetail(
        seriesId: Long,
        selectedSeason: Int? = null,
        xtreamPassword: String? = null,
        metadataApiKey: String? = null,
    ): MediaDetail?
    suspend fun getEpisodeById(episodeId: Long): EpisodeItem?

    suspend fun toggleFavorite(stableHash: String, kind: String): Boolean
    suspend fun recordWatchProgress(stableHash: String, positionMs: Long, durationMs: Long)

    /**
     * Resolves a `PlayableStream`:
     * - For VOD movies/episodes: registers the URL with the Rust single-connection relay (`127.0.0.1`).
     * - For Live TV: keeps direct URL + headers, annotated with the source's connection budget.
     */
    suspend fun resolvePlayableStream(itemId: Long, startPositionMs: Long = 0L): PlayableStream?
}

interface EpgRepository {
    suspend fun loadGuideGrid(
        groupName: String?,
        fromEpochSecs: Long,
        toEpochSecs: Long,
        limitChannels: Int = 60,
    ): ImmutableList<ChannelGuideRow>

    suspend fun getChannelPrograms(
        tvgId: String,
        fromEpochSecs: Long,
        toEpochSecs: Long,
    ): ImmutableList<EpgSlot>

    suspend fun buildCatchupStream(
        channelItemId: Long,
        startEpochSecs: Long,
        endEpochSecs: Long,
    ): PlayableStream?
}

interface SearchRepository {
    suspend fun searchLocal(
        prompt: String,
        scope: SearchScopeKind,
        locale: String,
        utcOffsetMinutes: Int,
    ): SearchOutcome

    suspend fun searchWithAi(
        prompt: String,
        scope: SearchScopeKind,
        locale: String,
        utcOffsetMinutes: Int,
        aiConfig: AiSettingsConfig,
        apiKey: String,
    ): SearchOutcome
}

interface RecommendationsRepository {
    suspend fun loadLocalShelves(
        kind: RecoDomainKind,
        limitPerShelf: Int = 16,
        utcOffsetMinutes: Int = 0,
    ): ImmutableList<RecoShelfGroup>

    suspend fun refineShelvesWithAi(
        kind: RecoDomainKind,
        aiConfig: AiSettingsConfig,
        apiKey: String,
        limitPerShelf: Int = 16,
        locale: String = "fr",
        utcOffsetMinutes: Int = 0,
    ): ImmutableList<RecoShelfGroup>

    suspend fun markLessLikeThis(kind: RecoDomainKind, stableHash: String)
    suspend fun resetTaste(kind: RecoDomainKind)
}

interface DownloadsRepository {
    val downloadsFlow: Flow<ImmutableList<DownloadItem>>
    suspend fun refreshDownloads(): ImmutableList<DownloadItem>
    suspend fun enqueueDownload(itemId: Long): Long
    suspend fun pauseDownload(taskId: Long)
    suspend fun resumeDownload(taskId: Long)
    suspend fun removeDownload(taskId: Long, deleteFiles: Boolean)
    suspend fun pauseAllForPlayback()
    suspend fun resumeAfterPlayback()
}

interface ProfilesRepository {
    val profilesFlow: Flow<ImmutableList<ProfileSummary>>
    suspend fun refreshProfiles(): ImmutableList<ProfileSummary>
    suspend fun activeProfile(): ProfileSummary
    suspend fun selectProfile(profileId: Long)
    suspend fun createProfile(name: String, avatar: String, isKids: Boolean): ProfileSummary
    suspend fun deleteProfile(profileId: Long)
    suspend fun setAdultContentVisible(visible: Boolean)
    suspend fun setGroupAllowedForKids(profileId: Long, kind: String, groupName: String, allowed: Boolean)
}

interface SettingsRepository {
    val preferencesFlow: Flow<AppPreferences>
    suspend fun currentPreferences(): AppPreferences
    suspend fun setOnboardingCompleted(completed: Boolean)
    suspend fun setAssumedMaxConnections(limit: Int)
    suspend fun setUiScale(scale: Float)
    suspend fun setTvPlaybackOptions(
        autoFrameRate: Boolean,
        audioPassthrough: Boolean,
        tunneling: Boolean,
    )
    suspend fun setDownloadOverCellular(allowed: Boolean)
    suspend fun setAdultCategoriesUnlocked(unlocked: Boolean)
    suspend fun setLastChannelId(channelId: Long)
    suspend fun updateAiConfig(config: AiSettingsConfig)
}

interface SecretStore {
    suspend fun putSecret(alias: String, plaintext: String)
    suspend fun getSecret(alias: String): String?
    suspend fun deleteSecret(alias: String)
}

interface WatchNextPublisher {
    suspend fun publishContinueWatching(
        itemId: Long,
        title: String,
        posterUrl: String?,
        positionMs: Long,
        durationMs: Long,
        isEpisode: Boolean,
    )

    suspend fun removeFromWatchNext(itemId: Long)
}

interface EngineDiagnosticsRepository {
    suspend fun engineVersion(): String
    suspend fun pollNetworkLogs(afterSeqId: Long = 0L, limit: Int = 100): ImmutableList<NetworkLogItem>
    suspend fun clearLogs()
}

