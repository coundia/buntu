package com.pcoundia.buntu.core.data.paging

import androidx.paging.PagingSource
import androidx.paging.PagingState
import com.pcoundia.buntu.core.data.mapper.EngineMappers.toEngineSort
import com.pcoundia.buntu.core.data.mapper.EngineMappers.toMovieDomain
import com.pcoundia.buntu.core.domain.model.CatalogQuery
import com.pcoundia.buntu.core.domain.model.CatalogSort
import com.pcoundia.buntu.core.domain.model.MovieItem
import com.pcoundia.buntu.core.engine.EngineProvider
import com.pcoundia.buntu.core.engine.ffi.CatalogFilter
import com.pcoundia.buntu.core.engine.ffi.SortField
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

class MoviesPagingSource(
    private val engineProvider: EngineProvider,
    private val query: CatalogQuery,
) : PagingSource<Int, MovieItem>() {

    override fun getRefreshKey(state: PagingState<Int, MovieItem>): Int? {
        val anchor = state.anchorPosition ?: return null
        val page = state.closestPageToPosition(anchor) ?: return null
        val pageSize = state.config.pageSize.coerceAtLeast(1)
        return page.prevKey?.plus(pageSize) ?: page.nextKey?.minus(pageSize)
    }

    override suspend fun load(params: LoadParams<Int>): LoadResult<Int, MovieItem> =
        withContext(Dispatchers.IO) {
            runCatching {
                val offset = (params.key ?: 0).coerceAtLeast(0)
                val limit = params.loadSize.coerceIn(1, 200)
                val engine = engineProvider.awaitEngine()
                val (sortBy, sortAsc) = if (query.sort == CatalogSort.DEFAULT) {
                    SortField.RECENTLY_ADDED to false
                } else {
                    query.sort.toEngineSort()
                }

                val rows = engine.queryCatalog(
                    CatalogFilter(
                        kind = "movie",
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

                val mapped = rows.map { it.toMovieDomain() }
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

