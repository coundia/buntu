import Foundation
import Observation
import CndCoreBridge

/// A catalog row the generic VOD list can page through (a movie or a normalised series).
protocol CatalogEntry: Sendable, Hashable {
    var entryId: Int64 { get }
    var entryStableHash: String { get }
    var entryIsFavorite: Bool { get set }
    /// `itemKind` passed to `toggleFavorite`.
    var favoriteKind: String { get }
}

extension IptvItemRecord: CatalogEntry {
    var entryId: Int64 { id }
    var entryStableHash: String { stableHash }
    var entryIsFavorite: Bool {
        get { isFavorite }
        set { isFavorite = newValue }
    }
    var favoriteKind: String { kind }
}

extension SeriesRecord: CatalogEntry {
    var entryId: Int64 { id }
    var entryStableHash: String { stableHash }
    var entryIsFavorite: Bool {
        get { isFavorite }
        set { isFavorite = newValue }
    }
    var favoriteKind: String { "series" }
}

/// How a model reaches the engine for one kind of entry; closures keep the model generic and let
/// tests plug in anything.
struct VodSource<Entry: CatalogEntry>: Sendable {
    var query: @Sendable (CatalogFilter) throws -> [Entry]
    var resume: @Sendable () throws -> [Entry]
    var favorites: @Sendable () throws -> [Entry]
    var groups: @Sendable () throws -> [FacetCount]
    var hosts: @Sendable () throws -> [FacetCount]
}

extension VodSource where Entry == IptvItemRecord {
    static func movies(engine: CndEngine) -> VodSource {
        VodSource(
            query: { try engine.queryCatalog(filter: $0) },
            // "Continue watching": started and not finished.
            resume: {
                try engine.listRecentItems(kind: "movie", limit: 40)
                    .filter { $0.resumePositionMs > 0 && !$0.isCompleted }
                    .prefix(20).map { $0 }
            },
            favorites: { try engine.listFavoriteItems(kind: "movie") },
            groups: { try engine.getGroups(kind: "movie", sourceId: nil) },
            hosts: { try engine.getHosts(kind: "movie", sourceId: nil) }
        )
    }
}

extension VodSource where Entry == SeriesRecord {
    static func series(engine: CndEngine) -> VodSource {
        VodSource(
            query: { try engine.querySeries(filter: $0) },
            resume: { try engine.listRecentSeries(limit: 20) },
            favorites: { try engine.listFavoriteSeries() },
            groups: { try engine.getGroups(kind: "series", sourceId: nil) },
            hosts: { [] }
        )
    }
}

/// Paged, filterable catalog shared by Movies and Series. Same guarantees as `LiveTvModel`: engine
/// calls run off the main actor and a generation counter drops stale results.
@Observable
@MainActor
final class VodCatalogModel<Entry: CatalogEntry> {
    nonisolated static var pageSize: Int { 60 }

    let kind: String
    let source: VodSource<Entry>
    let filter: SearchFilterState

    private(set) var entries: [Entry] = []
    private(set) var resume: [Entry] = []
    private(set) var favorites: [Entry] = []
    private(set) var groups: [FacetCount] = []
    private(set) var hosts: [FacetCount] = []
    private(set) var hasMore = false
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loadedFacetsRevision: Int?
    @ObservationIgnored private var isLoadingMore = false

    init(kind: String, source: VodSource<Entry>, filter: SearchFilterState? = nil) {
        self.kind = kind
        self.source = source
        self.filter = filter ?? SearchFilterState(sort: .name)
    }

    var showsSections: Bool {
        filter.query.isEmpty && filter.group == nil && filter.host == nil
    }

    private func makeFilter(offset: Int) -> CatalogFilter {
        CatalogFilter(
            kind: kind, sourceId: nil, query: filter.query, groupTitle: filter.group, host: filter.host,
            favoritesOnly: false, sortBy: filter.sort, sortAsc: filter.ascending,
            limit: UInt32(Self.pageSize), offset: UInt32(offset)
        )
    }

    private struct Snapshot: Sendable {
        var page: [Entry]
        var resume: [Entry]
        var favorites: [Entry]
        var groups: [FacetCount]?
        var hosts: [FacetCount]?
    }

    func reload(revision: Int = 0) async {
        generation += 1
        let gen = generation
        entries = []
        hasMore = false
        isLoadingMore = false
        errorMessage = nil
        isLoading = true

        let source = self.source
        let first = makeFilter(offset: 0)
        let sections = showsSections
        let facets = loadedFacetsRevision != revision
        do {
            let snapshot = try await Task.detached(priority: .userInitiated) { () -> Snapshot in
                Snapshot(
                    page: try source.query(first),
                    resume: sections ? try source.resume() : [],
                    favorites: sections ? try source.favorites() : [],
                    groups: facets ? try source.groups() : nil,
                    hosts: facets ? try source.hosts() : nil
                )
            }.value
            guard gen == generation else { return }
            entries = snapshot.page
            hasMore = snapshot.page.count >= Self.pageSize
            resume = snapshot.resume
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
        let source = self.source
        let next = makeFilter(offset: entries.count)
        do {
            let page = try await Task.detached(priority: .userInitiated) { try source.query(next) }.value
            guard gen == generation else { return }
            entries.append(contentsOf: page)
            hasMore = page.count >= Self.pageSize
        } catch {
            guard gen == generation else { return }
            errorMessage = userMessage(for: error)
        }
        isLoadingMore = false
    }

    func loadMoreIfNeeded(current entry: Entry) {
        guard hasMore, let index = entries.lastIndex(where: { $0.entryId == entry.entryId }),
              index >= entries.count - 12 else { return }
        Task { await loadNextPage() }
    }

    /// Mirrors a favorite change made anywhere (card, details) into the loaded lists.
    func applyFavorite(_ isFavorite: Bool, to entry: Entry) {
        func update(_ list: inout [Entry]) {
            for index in list.indices where list[index].entryStableHash == entry.entryStableHash {
                list[index].entryIsFavorite = isFavorite
            }
        }
        update(&entries)
        update(&resume)
        favorites.removeAll { $0.entryStableHash == entry.entryStableHash }
        if isFavorite {
            var added = entry
            added.entryIsFavorite = true
            favorites.insert(added, at: 0)
        }
    }
}
