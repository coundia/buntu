package com.pcoundia.buntu.core.domain.model

import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.persistentListOf

data class EpgSlot(
    val id: Long,
    val channelTvgId: String,
    val title: String,
    val description: String?,
    val category: String?,
    val startEpochSecs: Long,
    val endEpochSecs: Long,
    val isCatchupAvailable: Boolean,
) {
    fun isLiveAt(nowEpochSecs: Long): Boolean =
        nowEpochSecs in startEpochSecs until endEpochSecs
}

data class ChannelGuideRow(
    val channel: ChannelItem,
    val programs: ImmutableList<EpgSlot> = persistentListOf(),
)

enum class SearchScopeKind {
    ALL,
    LIVE,
    MOVIES,
    SERIES,
}

enum class SearchHitKind {
    LIVE,
    PROGRAMME,
    REPLAY,
    MOVIE,
    SERIES,
}

data class SearchHitItem(
    val id: Long,
    val seriesId: Long?,
    val stableHash: String,
    val kind: SearchHitKind,
    val title: String,
    val subtitle: String?,
    val posterUrl: String?,
    val reason: String,
    val startEpochSecs: Long?,
    val endEpochSecs: Long?,
)

data class SearchOutcome(
    val query: String,
    val hits: ImmutableList<SearchHitItem>,
    val missingTitles: ImmutableList<String> = persistentListOf(),
    val assistantReply: String = "",
    val resolvedBy: String = "local",
    val latencyMs: Long = 0L,
    val fallbackReason: String? = null,
)

enum class RecoDomainKind {
    MOVIES,
    SERIES,
    LIVE_TV,
}

data class RecoCardItem(
    val itemId: Long?,
    val seriesId: Long?,
    val stableHash: String,
    val kind: RecoDomainKind,
    val title: String,
    val subtitle: String?,
    val posterUrl: String?,
    val reasonLabel: String,
    val startEpochSecs: Long? = null,
    val endEpochSecs: Long? = null,
)

data class RecoShelfGroup(
    val id: String,
    val title: String,
    val kind: RecoDomainKind,
    val refinedByAi: String,
    val cards: ImmutableList<RecoCardItem>,
)

