import Foundation
import Observation
import CoreGraphics
import CndCoreBridge

/// Maps wall-clock time to horizontal points for the guide grid.
struct EpgTimeline: Equatable {
    var start: Date
    var hours: Int
    var pointsPerMinute: CGFloat

    var end: Date { start.addingTimeInterval(TimeInterval(hours * 3600)) }
    var totalWidth: CGFloat { CGFloat(hours * 60) * pointsPerMinute }
    var fromTs: Int64 { Int64(start.timeIntervalSince1970) }
    var toTs: Int64 { Int64(end.timeIntervalSince1970) }

    /// A window that opens `lookbackMinutes` before `now`, snapped down to a `stepMinutes` boundary.
    static func around(
        _ now: Date,
        lookbackMinutes: Int = 60,
        hours: Int = 12,
        pointsPerMinute: CGFloat = 4,
        stepMinutes: Int = 30
    ) -> EpgTimeline {
        let step = TimeInterval(stepMinutes * 60)
        let raw = now.timeIntervalSince1970 - TimeInterval(lookbackMinutes * 60)
        let snapped = (raw / step).rounded(.down) * step
        return EpgTimeline(start: Date(timeIntervalSince1970: snapped), hours: hours, pointsPerMinute: pointsPerMinute)
    }

    func x(for date: Date) -> CGFloat {
        CGFloat(date.timeIntervalSince(start) / 60) * pointsPerMinute
    }

    /// Position and width of a programme, clipped to the window; `nil` when it lies outside.
    func block(for program: EpgProgramRecord) -> (x: CGFloat, width: CGFloat)? {
        let from = max(program.startTs, fromTs)
        let to = min(program.endTs, toTs)
        guard to > from else { return nil }
        let x = CGFloat(from - fromTs) / 60 * pointsPerMinute
        let width = CGFloat(to - from) / 60 * pointsPerMinute
        return (x, width)
    }

    func ticks(stepMinutes: Int = 30) -> [Date] {
        (0..<(hours * 60 / stepMinutes)).map { start.addingTimeInterval(TimeInterval($0 * stepMinutes * 60)) }
    }

    func shifted(byHours delta: Int) -> EpgTimeline {
        var copy = self
        copy.start = start.addingTimeInterval(TimeInterval(delta * 3600))
        return copy
    }
}

/// A programme together with the channel it belongs to, for the detail sheet.
struct EpgSelection: Identifiable {
    let channel: IptvItemRecord
    let program: EpgProgramRecord
    var id: Int64 { program.id }
}

/// Data behind the EPG screens: the channel/time grid and the full schedule of one channel.
@Observable
@MainActor
final class EpgGuideModel {
    nonisolated static let pageSize = 60

    let engine: CndEngine
    let filter: SearchFilterState

    private(set) var timeline: EpgTimeline
    private(set) var channels: [IptvItemRecord] = []
    private(set) var hasMore = false
    private(set) var isLoading = false
    private(set) var programs: [String: [EpgProgramRecord]] = [:]
    private(set) var schedule: [EpgProgramRecord] = []
    private(set) var isLoadingSchedule = false
    var selection: EpgSelection?

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var windowGeneration = 0
    @ObservationIgnored private var requestedRows = Set<String>()
    @ObservationIgnored private var isLoadingMore = false

    init(engine: CndEngine, filter: SearchFilterState? = nil, now: Date = Date()) {
        self.engine = engine
        self.filter = filter ?? SearchFilterState(sort: .channelNumber)
        timeline = .around(now)
    }

    // MARK: Channels

    private func makeFilter(offset: Int) -> CatalogFilter {
        CatalogFilter(
            kind: "live", sourceId: nil, query: filter.query, groupTitle: nil, host: nil,
            favoritesOnly: false, includeBroken: filter.showBroken, includeHidden: false, sortBy: filter.sort, sortAsc: filter.ascending,
            limit: UInt32(Self.pageSize), offset: UInt32(offset)
        )
    }

    @ObservationIgnored private var rawOffset = 0

    func reload() async {
        generation += 1
        let gen = generation
        channels = []
        rawOffset = 0
        hasMore = false
        isLoadingMore = false
        isLoading = true
        resetPrograms()
        await fetchPages(generation: gen, minimumRows: 1)
        if gen == generation { isLoading = false }
    }

    func loadNextPage() async {
        guard hasMore, !isLoading, !isLoadingMore else { return }
        isLoadingMore = true
        await fetchPages(generation: generation, minimumRows: 1)
        isLoadingMore = false
    }

    func loadMoreIfNeeded(current item: IptvItemRecord) {
        guard hasMore, let index = channels.lastIndex(where: { $0.id == item.id }),
              index >= channels.count - 10 else { return }
        Task { await loadNextPage() }
    }

    /// Only channels with a `tvg-id` can have a guide, so the rest are skipped. When a whole page
    /// holds none, the next page is fetched (bounded) instead of leaving the grid stalled.
    private func fetchPages(generation gen: Int, minimumRows: Int) async {
        var added = 0
        var attempts = 0
        let engine = self.engine
        while attempts < 10 {
            attempts += 1
            let query = makeFilter(offset: rawOffset)
            guard let page = try? await Task.detached(priority: .userInitiated, operation: {
                try engine.queryCatalog(filter: query)
            }).value else { break }
            guard gen == generation else { return }
            rawOffset += page.count
            hasMore = page.count >= Self.pageSize
            let guided = page.filter { $0.tvgId?.isEmpty == false }
            channels.append(contentsOf: guided)
            added += guided.count
            if added >= minimumRows || !hasMore { break }
        }
    }

    // MARK: Grid programmes

    private func resetPrograms() {
        windowGeneration += 1
        programs = [:]
        requestedRows = []
    }

    func loadPrograms(for item: IptvItemRecord) async {
        guard let id = item.tvgId, !id.isEmpty, requestedRows.insert(id).inserted else { return }
        let gen = windowGeneration
        let from = timeline.fromTs
        let to = timeline.toTs
        let engine = self.engine
        let result = (try? await Task.detached(priority: .userInitiated) {
            try engine.getChannelEpg(tvgId: id, fromTs: from, toTs: to)
        }.value) ?? []
        guard gen == windowGeneration else { return }
        programs[id] = result
    }

    func shiftWindow(byHours delta: Int) {
        timeline = timeline.shifted(byHours: delta)
        resetPrograms()
    }

    func jumpToNow(now: Date = Date()) {
        timeline = .around(now, pointsPerMinute: timeline.pointsPerMinute)
        resetPrograms()
    }

    // MARK: Single-channel schedule

    /// Full programme of one channel: from lookback days (if catchup available) to three days ahead.
    func loadSchedule(for item: IptvItemRecord, now: Date = Date(), calendar: Calendar = .current) async {
        guard let id = item.tvgId, !id.isEmpty else {
            schedule = []
            return
        }
        isLoadingSchedule = true
        let startOfToday = Int64(calendar.startOfDay(for: now).timeIntervalSince1970)
        let retentionDays = (item.catchupType != nil || item.catchupSource != nil) ? max(1, Int64(item.catchupDays ?? 7)) : 0
        let from = startOfToday - (retentionDays * 86_400)
        let to = startOfToday + 4 * 86_400
        let engine = self.engine
        schedule = (try? await Task.detached(priority: .userInitiated) {
            try engine.getChannelEpg(tvgId: id, fromTs: from, toTs: to)
        }.value) ?? []
        isLoadingSchedule = false
    }

    // MARK: Catch-up & Replay

    func isCatchupAvailable(for channel: IptvItemRecord, program: EpgProgramRecord) -> Bool {
        (try? engine.isCatchupAvailable(itemId: channel.id, startTs: program.startTs)) ?? false
    }

    func buildCatchupUrl(for channel: IptvItemRecord, program: EpgProgramRecord) -> String? {
        (try? engine.buildCatchupUrl(itemId: channel.id, startTs: program.startTs, endTs: program.endTs)) ?? nil
    }

    static func groupByDay(_ programs: [EpgProgramRecord], calendar: Calendar = .current) -> [(day: Date, programs: [EpgProgramRecord])] {
        let grouped = Dictionary(grouping: programs) { program in
            calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(program.startTs)))
        }
        return grouped.keys.sorted().map { day in
            (day, (grouped[day] ?? []).sorted { $0.startTs < $1.startTs })
        }
    }
}
