import XCTest
import CndCoreBridge
@testable import CndIptvKit

/// One connection by default: downloads and playback never run together, and a download never uses
/// more connections than the subscription allows.
final class ConnectionBudgetTests: XCTestCase {
    private func source(server: String?, url: String? = nil, max: UInt32?) -> IptvSourceRecord {
        IptvSourceRecord(
            id: 1, uuid: "u", name: "S", sourceType: "xtream", url: url, server: server, username: nil, passwordRef: nil,
            epgUrl: nil, expDate: nil, maxConnections: max, activeCons: nil, accountStatus: nil, itemCount: 0, updatedAt: 0
        )
    }

    func testDefaultsToASingleConnection() {
        let defaults = UserDefaults(suiteName: "cnd.budget.\(UUID())")!
        XCTAssertEqual(ConnectionBudget.current(defaults: defaults).limit, 1)
        XCTAssertTrue(ConnectionBudget.current(defaults: defaults).pausesDuringPlayback)
    }

    func testOneConnectionMeansOneSegmentOneFileAndAPauseDuringPlayback() {
        let one = ConnectionBudget(limit: 1)
        XCTAssertEqual(one.downloadConnections, 1)
        XCTAssertTrue(one.pausesDuringPlayback)
        let clamped = one.clamp(segments: 4, files: 2)
        XCTAssertEqual(clamped.segments, 1)
        XCTAssertEqual(clamped.files, 1)
    }

    func testSeveralConnectionsKeepOneForWatching() {
        let three = ConnectionBudget(limit: 3)
        XCTAssertEqual(three.downloadConnections, 2)
        XCTAssertFalse(three.pausesDuringPlayback)
        XCTAssertEqual(three.clamp(segments: 4, files: 2).segments, 2)
        XCTAssertEqual(three.clamp(segments: 4, files: 2).files, 1)
        XCTAssertEqual(three.clamp(segments: 1, files: 8).files, 2)
    }

    func testSegmentsTimesFilesNeverExceedTheBudget() {
        for limit in 1...10 {
            let budget = ConnectionBudget(limit: limit)
            for segments in 1...16 {
                for files in 1...8 {
                    let c = budget.clamp(segments: segments, files: files)
                    XCTAssertLessThanOrEqual(c.segments * c.files, budget.downloadConnections, "limit \(limit) \(segments)x\(files)")
                    XCTAssertGreaterThanOrEqual(c.segments, 1)
                    XCTAssertGreaterThanOrEqual(c.files, 1)
                }
            }
        }
    }

    func testLimitIsBounded() {
        XCTAssertEqual(ConnectionBudget(limit: 0).limit, 1)
        XCTAssertEqual(ConnectionBudget(limit: 99).limit, 10)
    }

    func testHostOfAddresses() {
        XCTAssertEqual(ConnectionBudget.host(of: "http://TV.Konfatta.xyz:80/series/u/p/1.mp4"), "tv.konfatta.xyz")
        XCTAssertEqual(ConnectionBudget.host(of: "tv.konfatta.xyz:8080"), "tv.konfatta.xyz")
        XCTAssertNil(ConnectionBudget.host(of: nil))
        XCTAssertNil(ConnectionBudget.host(of: "  "))
    }

    func testSourceLimitNeverExceedsTheUsersSetting() {
        let sources = [source(server: "http://tv.konfatta.xyz:80", max: 4)]
        XCTAssertEqual(ConnectionBudget.limit(forHost: "tv.konfatta.xyz", sources: sources, assumed: 1), 1)
        XCTAssertEqual(ConnectionBudget.limit(forHost: "tv.konfatta.xyz", sources: sources, assumed: 6), 4)
        XCTAssertEqual(ConnectionBudget.limit(forHost: "tv.konfatta.xyz", sources: [source(server: "http://tv.konfatta.xyz", max: 1)], assumed: 3), 1)
        XCTAssertEqual(ConnectionBudget.limit(forHost: "other.test", sources: sources, assumed: 2), 2, "unknown host: the user's setting")
        XCTAssertEqual(ConnectionBudget.limit(forHost: nil, sources: sources, assumed: 1), 1)
    }
}

/// The coordinator pauses and resumes real tasks through a scripted engine.
@MainActor
final class DownloadConnectionCoordinatorTests: XCTestCase {
    final class FakeDownloads: DownloadControlling, @unchecked Sendable {
        private let lock = NSLock()
        var tasks: [DownloadTaskRecord]
        private(set) var paused: [Int64] = []
        private(set) var started: [Int64] = []

        init(_ tasks: [DownloadTaskRecord]) { self.tasks = tasks }

        func listDownloads(query: String?) throws -> [DownloadTaskRecord] { lock.withLock { tasks } }

        func pauseDownload(taskId: Int64) async throws {
            lock.withLock {
                paused.append(taskId)
                if let i = tasks.firstIndex(where: { $0.id == taskId }) { tasks[i].state = "paused" }
            }
        }

        func startDownload(taskId: Int64) async throws {
            lock.withLock {
                started.append(taskId)
                if let i = tasks.firstIndex(where: { $0.id == taskId }) { tasks[i].state = "running" }
            }
        }
    }

    private func task(_ id: Int64, _ url: String, _ state: String) -> DownloadTaskRecord {
        DownloadTaskRecord(
            id: id, url: url, fileName: "f", savePath: "/tmp/f", totalBytes: 100, downloadedBytes: 10, acceptRanges: true,
            state: state, speedBps: 0, etaSeconds: 0, parts: [], updatedAt: 0
        )
    }

    private func media(_ url: String) -> PlayableMedia {
        PlayableMedia(title: "Film", url: URL(string: url)!, kind: .movie, itemId: 1)
    }

    private func make(limit: Int?, tasks: [DownloadTaskRecord]) -> (DownloadConnectionCoordinator, FakeDownloads) {
        let defaults = UserDefaults(suiteName: "cnd.coord.\(UUID())")!
        if let limit { defaults.set(limit, forKey: ConnectionBudget.defaultsKey) }
        let fake = FakeDownloads(tasks)
        let coordinator = DownloadConnectionCoordinator(
            backendProvider: { fake }, sourcesProvider: { [] }, defaults: defaults, log: { _ in }
        )
        return (coordinator, fake)
    }

    func testPlaybackPausesTheDownloadsOfTheSameServerAndResumesThemAfterwards() async {
        let (coordinator, fake) = make(limit: nil, tasks: [
            task(1, "http://tv.konfatta.xyz/series/u/p/1.mp4", "running"),
            task(2, "http://tv.konfatta.xyz/series/u/p/2.mp4", "queued"),
            task(3, "http://other.test/movie/u/p/3.mp4", "running"),
            task(4, "http://tv.konfatta.xyz/series/u/p/4.mp4", "completed"),
        ])
        await coordinator.playbackChanged(media: media("http://tv.konfatta.xyz/series/u/p/9.mp4"))
        XCTAssertEqual(Set(fake.paused), [1, 2], "same server only, never a finished task")
        XCTAssertEqual(coordinator.heldTaskIds.sorted(), [1, 2])

        await coordinator.playbackChanged(media: nil)
        XCTAssertEqual(Set(fake.started), [1, 2])
        XCTAssertTrue(coordinator.heldTaskIds.isEmpty)
    }

    func testSeveralConnectionsLeaveTheDownloadsRunning() async {
        let (coordinator, fake) = make(limit: 3, tasks: [task(1, "http://tv.konfatta.xyz/series/u/p/1.mp4", "running")])
        await coordinator.playbackChanged(media: media("http://tv.konfatta.xyz/series/u/p/9.mp4"))
        XCTAssertTrue(fake.paused.isEmpty)
    }

    func testANewDownloadDuringPlaybackWaitsForItsEnd() async {
        let (coordinator, fake) = make(limit: nil, tasks: [])
        XCTAssertFalse(coordinator.shouldHoldNewDownload(urlString: "http://tv.konfatta.xyz/series/u/p/1.mp4"), "nothing plays")
        await coordinator.playbackChanged(media: media("http://tv.konfatta.xyz/series/u/p/9.mp4"))
        XCTAssertTrue(coordinator.shouldHoldNewDownload(urlString: "http://tv.konfatta.xyz/series/u/p/1.mp4"))
        XCTAssertFalse(coordinator.shouldHoldNewDownload(urlString: "http://other.test/movie/u/p/1.mp4"), "another server")

        fake.tasks = [task(7, "http://tv.konfatta.xyz/series/u/p/1.mp4", "paused")] // created without starting
        coordinator.hold(taskId: 7)
        await coordinator.playbackChanged(media: nil)
        XCTAssertEqual(fake.started, [7])
    }

    func testALocalFileOrAClosedPlayerHoldsNothing() async {
        let (coordinator, fake) = make(limit: nil, tasks: [task(1, "http://tv.konfatta.xyz/series/u/p/1.mp4", "running")])
        await coordinator.playbackChanged(media: media("file:///Users/x/Downloads/f.mp4"))
        XCTAssertTrue(fake.paused.isEmpty)
        XCTAssertNil(coordinator.playingHost)
    }

    func testATaskRemovedMeanwhileIsNotStarted() async {
        let (coordinator, fake) = make(limit: nil, tasks: [task(1, "http://tv.konfatta.xyz/series/u/p/1.mp4", "running")])
        await coordinator.playbackChanged(media: media("http://tv.konfatta.xyz/series/u/p/9.mp4"))
        fake.tasks = []
        await coordinator.playbackChanged(media: nil)
        XCTAssertTrue(fake.started.isEmpty)
    }

    func testSwitchingToAnotherServerReleasesTheFirstOne() async {
        let (coordinator, fake) = make(limit: nil, tasks: [task(1, "http://tv.konfatta.xyz/series/u/p/1.mp4", "running")])
        await coordinator.playbackChanged(media: media("http://tv.konfatta.xyz/series/u/p/9.mp4"))
        await coordinator.playbackChanged(media: media("http://other.test/movie/u/p/9.mp4"))
        XCTAssertEqual(fake.started, [1])
        XCTAssertEqual(coordinator.playingHost, "other.test")
    }
}
