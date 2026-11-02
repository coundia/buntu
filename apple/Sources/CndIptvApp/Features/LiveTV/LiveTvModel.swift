import Foundation
import Observation
import CndCoreBridge

enum LiveViewMode: String, CaseIterable, Identifiable {
    case grid
    case list

    var id: String { rawValue }
}

/// Data behind the Live TV screen: paged catalog, Recents / Favorites sections and the
/// "now playing" EPG of the channels currently on screen.
///
/// Every engine call runs off the main actor; a generation counter drops results that belong to a
/// previous query so fast typing or scrolling can never show stale rows.
@Observable
@MainActor
final class LiveTvModel {
    nonisolated static let pageSize = 60
    nonisolated static let epgBatchSize = 60
    nonisolated static let recentsLimit: UInt32 = 20
    nonisolated static let epgRefreshCap = 240

    let engine: CndEngine
    let filter: SearchFilterState
    @ObservationIgnored var onFavoriteChanged: () -> Void = {}

    private(set) var groups: [FacetCount] = []
    private(set) var hosts: [FacetCount] = []
    private(set) var recents: [IptvItemRecord] = []
    private(set) var favorites: [IptvItemRecord] = []
    private(set) var channels: [IptvItemRecord] = []
    private(set) var hasMore = false
    private(set) var isLoading = false
    private(set) var nowNext: [String: ChannelNowNext] = [:]
    private(set) var isLoadingEpg = false
    private(set) var errorMessage: String?

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loadedFacetsRevision: Int?
    @ObservationIgnored private var isLoadingMore = false
    @ObservationIgnored private var requestedEpg = Set<String>()
    @ObservationIgnored private var requestedOrder: [String] = []
    @ObservationIgnored private var pendingEpg: [String] = []
    @ObservationIgnored private var epgFlushTask: Task<Void, Never>?

    init(engine: CndEngine, filter: SearchFilterState? = nil) {
        self.engine = engine
        self.filter = filter ?? SearchFilterState(sort: .channelNumber)
    }

    /// Recents and Favorites are only shown when nothing narrows the catalog.
    var showsSections: Bool {
        filter.query.isEmpty && filter.group == nil && filter.host == nil
    }

    /// A search looks in every category; the selected one comes back when the search is cleared.
    var searchIgnoresCategory: Bool {
        !filter.query.isEmpty && filter.group != nil
    }

    private func makeFilter(offset: Int) -> CatalogFilter {
        CatalogFilter(
            kind: "live",
            sourceId: nil,
            query: filter.query,
            groupTitle: filter.query.isEmpty ? filter.group : nil,
            host: filter.host,
            favoritesOnly: false,
            sortBy: filter.sort,
            sortAsc: filter.ascending,
            limit: UInt32(Self.pageSize),
            offset: UInt32(offset)
        )
    }

    private struct Snapshot: Sendable {
        var page: [IptvItemRecord]
        var groups: [FacetCount]?
        var hosts: [FacetCount]?
        var recents: [IptvItemRecord]
        var favorites: [IptvItemRecord]
    }

    // MARK: Loading

    /// Runs the first query. `revision` identifies the catalog snapshot: group and host facets are
    /// only re-read when it changed, not on every keystroke.
    func reload(revision: Int = 0) async {
        generation += 1
        let gen = generation
        channels = []
        hasMore = false
        isLoadingMore = false
        errorMessage = nil
        requestedEpg = []
        requestedOrder = []
        pendingEpg = []
        epgFlushTask?.cancel()
        epgFlushTask = nil
        isLoadingEpg = false
        isLoading = true

        let engine = self.engine
        let first = makeFilter(offset: 0)
        let wantsSections = showsSections
        let wantsFacets = loadedFacetsRevision != revision
        do {
            let snapshot = try await Task.detached(priority: .userInitiated) { () -> Snapshot in
                Snapshot(
                    page: try engine.queryCatalog(filter: first),
                    groups: wantsFacets ? try engine.getGroups(kind: "live", sourceId: nil) : nil,
                    hosts: wantsFacets ? try engine.getHosts(kind: "live", sourceId: nil) : nil,
                    recents: wantsSections ? try engine.listRecentItems(kind: "live", limit: Self.recentsLimit) : [],
                    favorites: wantsSections ? try engine.listFavoriteItems(kind: "live") : []
                )
            }.value
            guard gen == generation else { return }
            channels = snapshot.page
            hasMore = snapshot.page.count >= Self.pageSize
            recents = snapshot.recents
            favorites = snapshot.favorites
            if let groups = snapshot.groups, let hosts = snapshot.hosts {
                self.groups = groups
                self.hosts = hosts
                loadedFacetsRevision = revision
            }
            isLoading = false
        } catch {
            guard gen == generation else { return }
            errorMessage = userMessage(for: error)
            isLoading = false
        }
    }

    func loadNextPage() async {
        guard hasMore, !isLoading, !isLoadingMore else { return }
        isLoadingMore = true
        let gen = generation
        let engine = self.engine
        let next = makeFilter(offset: channels.count)
        do {
            let page = try await Task.detached(priority: .userInitiated) { try engine.queryCatalog(filter: next) }.value
            guard gen == generation else { return }
            channels.append(contentsOf: page)
            hasMore = page.count >= Self.pageSize
        } catch {
            guard gen == generation else { return }
            errorMessage = userMessage(for: error)
        }
        isLoadingMore = false
    }

    /// Infinite scroll: asks for the next page when one of the last rows becomes visible.
    func loadMoreIfNeeded(current item: IptvItemRecord) {
        guard hasMore, let index = channels.lastIndex(where: { $0.id == item.id }),
              index >= channels.count - 10 else { return }
        Task { await loadNextPage() }
    }

    // MARK: EPG now/next (batched)

    func cardAppeared(_ item: IptvItemRecord) {
        guard let id = item.tvgId?.trimmingCharacters(in: .whitespaces), !id.isEmpty,
              requestedEpg.insert(id).inserted else { return }
        requestedOrder.append(id)
        pendingEpg.append(id)
        scheduleEpgFlush(after: .milliseconds(40))
    }

    /// Re-queries the most recently shown channels so programme titles and gauges stay current.
    func refreshEpg() {
        pendingEpg = Array(requestedOrder.suffix(Self.epgRefreshCap))
        scheduleEpgFlush(after: .zero)
    }

    private func scheduleEpgFlush(after delay: Duration) {
        guard epgFlushTask == nil else { return }
        isLoadingEpg = true
        epgFlushTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            await self.flushEpg()
        }
    }

    private func flushEpg() async {
        epgFlushTask = nil
        guard !pendingEpg.isEmpty else {
            isLoadingEpg = false
            return
        }
        let ids = Array(pendingEpg.prefix(Self.epgBatchSize))
        pendingEpg.removeFirst(ids.count)
        let gen = generation
        let engine = self.engine
        let results = try? await Task.detached(priority: .userInitiated) { try engine.getEpgNowNext(tvgIds: ids) }.value
        guard gen == generation else { return }
        for entry in results ?? [] { nowNext[entry.channelTvgId] = entry }
        if pendingEpg.isEmpty {
            isLoadingEpg = false
        } else {
            scheduleEpgFlush(after: .zero)
        }
    }

    func program(for item: IptvItemRecord) -> ChannelNowNext? {
        item.tvgId.flatMap { nowNext[$0] }
    }

    // MARK: Actions

    func toggleFavorite(_ item: IptvItemRecord) async {
        let engine = self.engine
        do {
            let isFavorite = try await Task.detached(priority: .userInitiated) {
                try engine.toggleFavorite(stableHash: item.stableHash, itemKind: item.kind)
            }.value
            apply(isFavorite: isFavorite, to: item)
            onFavoriteChanged()
        } catch {
            errorMessage = userMessage(for: error)
        }
    }

    private func apply(isFavorite: Bool, to item: IptvItemRecord) {
        for index in channels.indices where channels[index].stableHash == item.stableHash {
            channels[index].isFavorite = isFavorite
        }
        for index in recents.indices where recents[index].stableHash == item.stableHash {
            recents[index].isFavorite = isFavorite
        }
        favorites.removeAll { $0.stableHash == item.stableHash }
        if isFavorite {
            var added = item
            added.isFavorite = true
            favorites.insert(added, at: 0)
        }
    }

    /// Records the channel in the history (a live stream has no position) and moves it to the front
    /// of the Recents section without re-querying.
    func markWatched(_ item: IptvItemRecord) {
        let engine = self.engine
        Task.detached(priority: .utility) {
            try? engine.recordWatchProgress(stableHash: item.stableHash, positionMs: 0, durationMs: 0)
        }
        recents.removeAll { $0.stableHash == item.stableHash }
        recents.insert(item, at: 0)
        if recents.count > Int(Self.recentsLimit) { recents.removeLast(recents.count - Int(Self.recentsLimit)) }
    }
}
