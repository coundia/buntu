package com.pcoundia.buntu.core.data.paging

import androidx.paging.PagingSource
import androidx.paging.PagingState
import com.pcoundia.buntu.core.data.mapper.EngineMappers.toChannelDomain
import com.pcoundia.buntu.core.data.mapper.EngineMappers.toEngineSort
import com.pcoundia.buntu.core.domain.model.CatalogQuery
import com.pcoundia.buntu.core.domain.model.ChannelItem
import com.pcoundia.buntu.core.engine.EngineProvider
import com.pcoundia.buntu.core.engine.ffi.CatalogFilter
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * PRD-37 § 3 & § 5.1:
 * Paginates Live TV channels via SQLite `limit` / `offset` on `Dispatchers.IO`,
 * batching `getEpgNowNext` once per page (never per item!).
 */
class LiveChannelsPagingSource(
    private val engineProvider: EngineProvider,
    private val query: CatalogQuery,
) : PagingSource<Int, ChannelItem>() {

    override fun getRefreshKey(state: PagingState<Int, ChannelItem>): Int? {
        val anchor = state.anchorPosition ?: return null
        val page = state.closestPageToPosition(anchor) ?: return null
        val pageSize = state.config.pageSize.coerceAtLeast(1)
        return page.prevKey?.plus(pageSize) ?: page.nextKey?.minus(pageSize)
    }

    override suspend fun load(params: LoadParams<Int>): LoadResult<Int, ChannelItem> =
        withContext(Dispatchers.IO) {
            runCatching {
                val offset = (params.key ?: 0).coerceAtLeast(0)
                val limit = params.loadSize.coerceIn(1, 200)
                val engine = engineProvider.awaitEngine()
                val (sortBy, sortAsc) = query.sort.toEngineSort()

                val rows = engine.queryCatalog(
                    CatalogFilter(
                        kind = "live",
                        sourceId = query.sourceId,
                        query = query.searchQuery,
                        groupTitle = query.groupName,
                        host = query.host,
                        favoritesOnly = query.favoritesOnly,
                        includeBroken = false,
                        includeHidden = false,
                        sortBy = sortBy,
                        sortAsc = sortAsc,
                        limit = limit.toUInt(),
                        offset = offset.toUInt(),
                    )
                )

                val tvgIds = rows.mapNotNull { it.tvgId?.takeIf(String::isNotBlank) }.distinct()
                val nowNextByTvg = if (tvgIds.isNotEmpty()) {
                    engine.getEpgNowNext(tvgIds).associateBy { it.channelTvgId }
                } else {
                    emptyMap()
                }

                val mapped = rows.map { row ->
                    row.toChannelDomain(nowNext = row.tvgId?.let(nowNextByTvg::get))
                }

                LoadResult.Page(
                    data = mapped,
                    prevKey = if (offset == 0) null else (offset - limit).coerceAtLeast(0),
                    nextKey = if (rows.size < limit) null else offset + rows.size,
                )
            }.getOrElse { err ->
                LoadResult.Error(err)
            }
        }
}

