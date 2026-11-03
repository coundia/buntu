import XCTest
import CndCoreBridge
@testable import CndIptvKit

@MainActor
final class LiveTvModelTests: XCTestCase {
    private var directory: URL!
    private var engine: CndEngine!

    override func setUp() async throws {
        directory = try TestFixtures.makeTempDirectory()
        engine = try CndEngine.inMemory()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testPagesByLotsOfSixtyUntilExhausted() async throws {
        try await TestFixtures.importCatalog(into: engine, directory: directory, count: 130)
        let model = LiveTvModel(engine: engine)

        await model.reload()
        XCTAssertEqual(model.channels.count, 60)
        XCTAssertTrue(model.hasMore)
        XCTAssertEqual(model.channels.first?.name, "Chaine 001 4K")

        await model.loadNextPage()
        XCTAssertEqual(model.channels.count, 120)
        XCTAssertTrue(model.hasMore)

        await model.loadNextPage()
        XCTAssertEqual(model.channels.count, 130)
        XCTAssertFalse(model.hasMore)
        XCTAssertEqual(Set(model.channels.map(\.id)).count, 130, "no duplicate across pages")

        await model.loadNextPage()
        XCTAssertEqual(model.channels.count, 130)
    }

    func testScrollingNearTheEndRequestsTheNextPage() async throws {
        try await TestFixtures.importCatalog(into: engine, directory: directory, count: 130)
        let model = LiveTvModel(engine: engine)
        await model.reload()

        model.loadMoreIfNeeded(current: model.channels[5])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.channels.count, 60, "a row far from the end must not trigger loading")

        model.loadMoreIfNeeded(current: model.channels[55])
        let loaded = await eventually { model.channels.count == 120 }
        XCTAssertTrue(loaded)
    }

    func testGroupsCarryCountsAndFilterTheList() async throws {
        try await TestFixtures.importCatalog(into: engine, directory: directory, count: 90)
        let model = LiveTvModel(engine: engine)
        await model.reload()

        XCTAssertEqual(model.groups.map(\.value).sorted(), ["Kids", "News", "Sport"])
        XCTAssertEqual(model.groups.reduce(0) { $0 + Int($1.count) }, 90)
        XCTAssertTrue(model.showsSections)

        model.filter.group = "Sport"
        await model.reload()
        XCTAssertFalse(model.showsSections)
        XCTAssertEqual(model.channels.count, 30)
        XCTAssertTrue(model.channels.allSatisfy { $0.groupTitle == "Sport" })
    }

    func testSearchNarrowsTheCatalog() async throws {
        try await TestFixtures.importCatalog(into: engine, directory: directory, count: 40)
        let model = LiveTvModel(engine: engine)
        model.filter.text = "Chaine 017"
        model.filter.commit()
        await model.reload()
        XCTAssertEqual(model.channels.map(\.name), ["Chaine 017"])
        XCTAssertTrue(model.recents.isEmpty && model.favorites.isEmpty, "sections hide while searching")
    }

    func testFavoritesAndRecentsSections() async throws {
        try await TestFixtures.importCatalog(into: engine, directory: directory, count: 20)
        let model = LiveTvModel(engine: engine)
        var favoriteNotifications = 0
        model.onFavoriteChanged = { favoriteNotifications += 1 }
        await model.reload()
        XCTAssertTrue(model.recents.isEmpty)
        XCTAssertTrue(model.favorites.isEmpty)

        let first = model.channels[0]
        await model.toggleFavorite(first)
        XCTAssertEqual(model.favorites.map(\.stableHash), [first.stableHash])
        XCTAssertTrue(model.channels[0].isFavorite)
        XCTAssertEqual(favoriteNotifications, 1)

        let watched = model.channels[3]
        model.markWatched(watched)
        XCTAssertEqual(model.recents.first?.stableHash, watched.stableHash)
        try await Task.sleep(for: .milliseconds(200))

        await model.reload()
        XCTAssertEqual(model.favorites.map(\.stableHash), [first.stableHash])
        XCTAssertEqual(model.recents.map(\.stableHash), [watched.stableHash])

        await model.toggleFavorite(first)
        XCTAssertTrue(model.favorites.isEmpty)
        XCTAssertFalse(model.channels[0].isFavorite)
    }

    func testNowNextIsFetchedInBatchesForVisibleChannels() async throws {
        try await TestFixtures.importCatalog(into: engine, directory: directory, count: 12, withGuide: true)
        let model = LiveTvModel(engine: engine)
        await model.reload()

        for item in model.channels { model.cardAppeared(item) }
        XCTAssertTrue(model.isLoadingEpg, "the batch is pending right after cards appear")

        let loaded = await eventually { model.nowNext.count == 12 }
        XCTAssertTrue(loaded)
        let now = try XCTUnwrap(model.program(for: model.channels[0]))
        XCTAssertEqual(now.now?.title, "Journal")
        XCTAssertEqual(now.next?.title, "Film du soir")
        let ratio = EpgProgress.ratio(start: now.now!.startTs, end: now.now!.endTs)
        XCTAssertEqual(ratio, 0.5, accuracy: 0.05)

        let settled = await eventually { !model.isLoadingEpg }
        XCTAssertTrue(settled)

        // The same channel is never requested twice by `cardAppeared`.
        model.cardAppeared(model.channels[0])
        XCTAssertFalse(model.isLoadingEpg)
    }

    func testStaleQueryResultsAreDropped() async throws {
        try await TestFixtures.importCatalog(into: engine, directory: directory, count: 90)
        let model = LiveTvModel(engine: engine)

        model.filter.group = "News"
        async let stale: Void = model.reload()
        model.filter.group = "Kids"
        await model.reload()
        await stale
        XCTAssertTrue(model.channels.allSatisfy { $0.groupTitle == "Kids" })
        XCTAssertEqual(model.channels.count, 30)
    }
}

@MainActor
final class EpgGuideModelTests: XCTestCase {
    private var directory: URL!
    private var engine: CndEngine!

    override func setUp() async throws {
        directory = try TestFixtures.makeTempDirectory()
        engine = try CndEngine.inMemory()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testTimelineAlignsToHalfHoursAndClipsBlocks() {
        let now = Date(timeIntervalSince1970: 1_800_000_000 + 17 * 60)
        let timeline = EpgTimeline.around(now, lookbackMinutes: 60, hours: 12, pointsPerMinute: 4)
        XCTAssertEqual(Int(timeline.start.timeIntervalSince1970) % 1800, 0)
        XCTAssertLessThanOrEqual(timeline.start, now.addingTimeInterval(-3600))
        XCTAssertGreaterThan(timeline.start, now.addingTimeInterval(-3600 - 1800))
        XCTAssertEqual(timeline.totalWidth, 12 * 60 * 4)
        XCTAssertEqual(timeline.ticks().count, 24)
        XCTAssertEqual(timeline.x(for: timeline.start.addingTimeInterval(3600)), 240)

        func program(_ start: Int64, _ end: Int64) -> EpgProgramRecord {
            EpgProgramRecord(id: 1, channelTvgId: "a", startTs: start, endTs: end, title: "T", subtitle: nil, description: nil, category: nil, progressRatio: 0)
        }
        let from = timeline.fromTs
        let inside = timeline.block(for: program(from + 3600, from + 7200))
        XCTAssertEqual(inside?.x, 240)
        XCTAssertEqual(inside?.width, 240)
        let clippedLeft = timeline.block(for: program(from - 1800, from + 1800))
        XCTAssertEqual(clippedLeft?.x, 0)
        XCTAssertEqual(clippedLeft?.width, 120)
        let clippedRight = timeline.block(for: program(timeline.toTs - 600, timeline.toTs + 3600))
        XCTAssertEqual(clippedRight?.width, 40)
        XCTAssertNil(timeline.block(for: program(from - 7200, from - 3600)))
        XCTAssertNil(timeline.block(for: program(timeline.toTs, timeline.toTs + 600)))
    }

    func testGuideListsOnlyChannelsWithAnEpgIdAndPages() async throws {
        try await TestFixtures.importCatalog(into: engine, directory: directory, count: 130, withoutGuide: 70)
        let model = EpgGuideModel(engine: engine)
        await model.reload()

        // 60 channels have an id (1...60); the next raw pages hold none, so paging must keep going.
        XCTAssertEqual(model.channels.count, 60)
        XCTAssertTrue(model.channels.allSatisfy { $0.tvgId?.isEmpty == false })
        await model.loadNextPage()
        XCTAssertEqual(model.channels.count, 60)
        XCTAssertFalse(model.hasMore)
    }

    func testProgramsForVisibleRowsAndWindowShift() async throws {
        try await TestFixtures.importCatalog(into: engine, directory: directory, count: 6, withGuide: true)
        let model = EpgGuideModel(engine: engine)
        await model.reload()
        let channel = try XCTUnwrap(model.channels.first)

        await model.loadPrograms(for: channel)
        let programs = try XCTUnwrap(model.programs[channel.tvgId!])
        XCTAssertEqual(programs.map(\.title), ["Journal", "Film du soir", "Magazine"])
        XCTAssertTrue(programs.allSatisfy { model.timeline.block(for: $0) != nil })

        model.shiftWindow(byHours: 24)
        XCTAssertTrue(model.programs.isEmpty, "cache is dropped when the window moves")
        await model.loadPrograms(for: channel)
        XCTAssertEqual(model.programs[channel.tvgId!]?.count, 0, "nothing is scheduled a day later")

        model.jumpToNow()
        await model.loadPrograms(for: channel)
        XCTAssertEqual(model.programs[channel.tvgId!]?.count, 3)
    }

    func testFullScheduleOfOneChannelGroupedByDay() async throws {
        try await TestFixtures.importCatalog(into: engine, directory: directory, count: 3, withGuide: true)
        let model = EpgGuideModel(engine: engine)
        await model.reload()
        let channel = try XCTUnwrap(model.channels.first)

        await model.loadSchedule(for: channel)
        XCTAssertEqual(model.schedule.map(\.title), ["Journal", "Film du soir", "Magazine"])
        XCTAssertFalse(model.isLoadingSchedule)

        let days = EpgGuideModel.groupByDay(model.schedule)
        XCTAssertFalse(days.isEmpty)
        XCTAssertEqual(days.flatMap(\.programs).count, 3)
        XCTAssertEqual(days.map(\.day), days.map(\.day).sorted())
    }

    func testCatchupReplayUrlAndAvailability() async throws {
        let m3u = """
        #EXTM3U
        #EXTINF:-1 tvg-id="replay.channel" catchup="default" catchup-days="7",Replay Channel
        http://iptv.server.io:8080/live/user1/pass1/42.ts
        """
        let m3uUrl = directory.appendingPathComponent("replay.m3u")
        try m3u.write(to: m3uUrl, atomically: true, encoding: .utf8)

        _ = try await engine.importLocalM3u(name: "Catchup Source", filePath: m3uUrl.path)

        let model = EpgGuideModel(engine: engine)
        await model.reload()
        let channel = try XCTUnwrap(model.channels.first(where: { $0.tvgId == "replay.channel" }))

        let now = Int64(Date().timeIntervalSince1970)
        let pastProgram = EpgProgramRecord(
            id: 1,
            channelTvgId: "replay.channel",
            startTs: now - 3600,
            endTs: now - 1800,
            title: "Past News",
            subtitle: "Edition speciale",
            description: "Replay test",
            category: "News",
            progressRatio: 1.0
        )

        let futureProgram = EpgProgramRecord(
            id: 2,
            channelTvgId: "replay.channel",
            startTs: now + 3600,
            endTs: now + 5400,
            title: "Future Show",
            subtitle: nil,
            description: nil,
            category: nil,
            progressRatio: 0.0
        )

        XCTAssertTrue(model.isCatchupAvailable(for: channel, program: pastProgram))
        XCTAssertFalse(model.isCatchupAvailable(for: channel, program: futureProgram))

        let replayUrl = try XCTUnwrap(model.buildCatchupUrl(for: channel, program: pastProgram))
        XCTAssertTrue(replayUrl.contains("/timeshift/user1/pass1/30/"))
        XCTAssertTrue(replayUrl.hasSuffix("/42.ts"))

        let media = try XCTUnwrap(PlayableMedia(
            item: channel,
            overrideUrl: URL(string: replayUrl),
            customTitle: "\(channel.name) — \(pastProgram.title) [Replay]",
            kind: .movie
        ))
        XCTAssertEqual(media.title, "Replay Channel — Past News [Replay]")
        XCTAssertEqual(media.kind, PlayableKind.movie)
        XCTAssertEqual(media.url.absoluteString, replayUrl)
    }
}
