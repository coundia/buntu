import XCTest
import AVFoundation
import CoreMedia
import MediaPlayer
import CndCoreBridge
@testable import CndIptvKit

@MainActor
private func makeTestController() -> CndPlayerController {
    CndPlayerController(
        recorder: nil,
        reachability: FakeReachability(),
        backendFactory: { kind in MockBackend(kind) }
    )
}

private func vodMedia(_ name: String = "film.mp4") -> PlayableMedia {
    PlayableMedia(title: name, url: URL(string: "http://cdn.test/\(name)")!, kind: .movie, stableHash: "h")
}

private func liveMedia(_ id: Int) -> PlayableMedia {
    PlayableMedia(title: "Chaîne \(id)", url: URL(string: "http://cdn.test/live/\(id).m3u8")!, kind: .live)
}

// MARK: - Picture in Picture

@MainActor
final class PiPTests: XCTestCase {
    func testBackendLayersAreClassifiedForTheRightPiPSource() {
        XCTAssertEqual(PiPManager.kind(of: AVPlayerLayer()), .playerLayer)
        XCTAssertEqual(PiPManager.kind(of: AVSampleBufferDisplayLayer()), .sampleBuffer)
        XCTAssertEqual(PiPManager.kind(of: CALayer()), .unsupported)
        XCTAssertEqual(PiPManager.kind(of: nil), .unsupported)
    }

    func testBridgeExposesLiveAsUnboundedAndMovieWithItsDuration() {
        let bridge = PiPPlaybackBridge()
        bridge.update(isPaused: false, isLive: true, durationMs: 0)
        XCTAssertTrue(bridge.timeRange.duration.isPositiveInfinity)
        XCTAssertFalse(bridge.isPaused)

        bridge.update(isPaused: true, isLive: false, durationMs: 5_400_000)
        XCTAssertTrue(bridge.isPaused)
        XCTAssertEqual(bridge.timeRange.start, .zero)
        XCTAssertEqual(bridge.timeRange.duration.seconds, 5_400, accuracy: 0.001)

        bridge.update(isPaused: true, isLive: false, durationMs: 0)
        XCTAssertTrue(bridge.timeRange.duration.isPositiveInfinity, "an unknown duration is treated as unbounded")
    }

    func testBridgeForwardsPlayPauseAndSkipFromTheSystemWindow() {
        let bridge = PiPPlaybackBridge()
        let calls = CallCounter()
        let lastPlaying = LockedBox<Bool?>(nil)
        let lastSkip = LockedBox<Double?>(nil)
        bridge.setHandlers(
            onSetPlaying: { playing in calls.increment(); lastPlaying.value = playing },
            onSkip: { seconds in calls.increment(); lastSkip.value = seconds }
        )
        bridge.setPlaying(false)
        bridge.skip(bySeconds: 15)
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(lastPlaying.value, false)
        XCTAssertEqual(lastSkip.value, 15)
    }

    func testAttachAndDetachNeverCrashWhateverTheEnvironmentSupports() {
        let manager = PiPManager()
        let controller = makeTestController()
        manager.attach(layer: AVPlayerLayer(), controller: controller)
        manager.attach(layer: AVSampleBufferDisplayLayer(), controller: controller)
        manager.attach(layer: nil, controller: controller)
        manager.syncState(from: controller)
        manager.toggle()
        manager.detach()
        XCTAssertFalse(manager.isActive)
        XCTAssertFalse(manager.isPossible)
    }
}

final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

// MARK: - Now Playing

@MainActor
final class NowPlayingTests: XCTestCase {
    func testLiveInfoIsFlaggedAndHasNoTimeline() {
        let info = NowPlayingInfoBuilder.info(
            media: liveMedia(1), subtitle: "Journal de 20h", positionMs: 5_000, durationMs: 0,
            isPlaying: true, rate: 1
        )
        XCTAssertEqual(info[MPMediaItemPropertyTitle] as? String, "Chaîne 1")
        XCTAssertEqual(info[MPMediaItemPropertyArtist] as? String, "Journal de 20h")
        XCTAssertEqual(info[MPNowPlayingInfoPropertyIsLiveStream] as? Bool, true)
        XCTAssertNil(info[MPNowPlayingInfoPropertyElapsedPlaybackTime])
        XCTAssertNil(info[MPMediaItemPropertyPlaybackDuration])
        XCTAssertEqual(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1)
    }

    func testMovieInfoCarriesPositionDurationAndPausedRate() {
        let info = NowPlayingInfoBuilder.info(
            media: vodMedia("Oppenheimer"), subtitle: nil, positionMs: 2_535_000, durationMs: 10_800_000,
            isPlaying: false, rate: 1.5
        )
        XCTAssertEqual(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 2_535)
        XCTAssertEqual(info[MPMediaItemPropertyPlaybackDuration] as? Double, 10_800)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0, "paused reports a zero rate")
        XCTAssertNil(info[MPMediaItemPropertyArtist])
        XCTAssertNil(info[MPNowPlayingInfoPropertyIsLiveStream])
    }

    func testDefaultSubtitles() {
        XCTAssertEqual(NowPlayingInfoBuilder.defaultSubtitle(for: liveMedia(1)), "Direct")
        XCTAssertEqual(NowPlayingInfoBuilder.defaultSubtitle(for: vodMedia()), "Film")
        let episode = PlayableMedia(title: "e", url: URL(string: "http://x/e.mkv")!, kind: .episode)
        XCTAssertEqual(NowPlayingInfoBuilder.defaultSubtitle(for: episode), "Série")
    }

    func testRemoteCommandsDriveThePlayer() async {
        let controller = makeTestController()
        let coordinator = NowPlayingCoordinator(controller: controller)
        var zaps: [Int] = []
        coordinator.onZap = { zaps.append($0) }

        XCTAssertEqual(coordinator.perform(.play), .noActionableNowPlayingItem, "nothing is loaded yet")

        controller.open(vodMedia())
        _ = await eventually { controller.state == .playing }

        XCTAssertEqual(coordinator.perform(.pause), .success)
        XCTAssertEqual(controller.state, .paused)
        XCTAssertEqual(coordinator.perform(.play), .success)
        XCTAssertEqual(controller.state, .playing)
        XCTAssertEqual(coordinator.perform(.toggle), .success)
        XCTAssertEqual(controller.state, .paused)

        XCTAssertEqual(coordinator.perform(.seek(toSeconds: 120)), .success)
        XCTAssertEqual(controller.positionMs, 120_000)
        let before = controller.positionMs
        XCTAssertEqual(coordinator.perform(.skip(seconds: NowPlayingCoordinator.skipInterval)), .success)
        XCTAssertEqual(controller.positionMs, before + 15_000, "skip forward is +15 s")
        XCTAssertEqual(coordinator.perform(.skip(seconds: -NowPlayingCoordinator.skipInterval)), .success)
        XCTAssertEqual(controller.positionMs, before)

        XCTAssertEqual(coordinator.perform(.next), .success)
        XCTAssertEqual(coordinator.perform(.previous), .success)
        XCTAssertEqual(zaps, [1, -1])
        controller.close()
    }

    func testLiveStreamsRefuseSeekingButStillZap() async {
        let controller = makeTestController()
        let coordinator = NowPlayingCoordinator(controller: controller)
        var zaps: [Int] = []
        coordinator.onZap = { zaps.append($0) }
        controller.open(liveMedia(7))
        _ = await eventually { controller.state == .playing }

        XCTAssertEqual(coordinator.perform(.skip(seconds: 15)), .commandFailed)
        XCTAssertEqual(coordinator.perform(.seek(toSeconds: 10)), .commandFailed)
        XCTAssertEqual(coordinator.perform(.next), .success)
        XCTAssertEqual(zaps, [1])
        controller.close()
    }

    func testRefreshPublishesAndClearsTheSystemInfo() async {
        let controller = makeTestController()
        let coordinator = NowPlayingCoordinator(controller: controller)
        coordinator.subtitleProvider = { _ in "Magazine" }
        controller.open(liveMedia(3))
        _ = await eventually { controller.state == .playing }

        coordinator.refresh()
        XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, "Chaîne 3")
        XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtist] as? String, "Magazine")

        controller.close()
        coordinator.refresh()
        XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo)
    }

    func testPlayableFromCatalogCarriesTheLogoAsArtwork() throws {
        let engine = try CndEngine.inMemory()
        let directory = try TestFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try TestFixtures.writeM3u(in: directory, count: 1)
        let summary = try awaitSync { try await engine.importLocalM3u(name: "x", filePath: file.path) }
        XCTAssertEqual(summary.liveCount, 1)
        let item = try XCTUnwrap(engine.queryCatalog(filter: CatalogFilter(
            kind: "live", sourceId: nil, query: "", groupTitle: nil, host: nil, favoritesOnly: false,
            includeBroken: false, includeHidden: false,
            sortBy: .name, sortAsc: true, limit: 5, offset: 0
        )).first)
        XCTAssertEqual(PlayableMedia(item: item)?.artworkUrl, "http://logos.test/1.png")
    }

    private func awaitSync<T>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
        let box = LockedBox<Result<T, Error>?>(nil)
        let done = expectation(description: "async work")
        Task {
            do { box.value = .success(try await work()) } catch { box.value = .failure(error) }
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        return try XCTUnwrap(box.value).get()
    }
}

// MARK: - Zapping, gestures, commands

@MainActor
final class ZapAndGestureTests: XCTestCase {
    private func channel(_ id: Int64) -> IptvItemRecord {
        IptvItemRecord(
            id: id, sourceId: 1, seriesId: nil, stableHash: "h\(id)", kind: "live", seasonNum: nil, episodeNum: nil,
            name: "Chaîne \(id)", nameClean: "Chaîne \(id)", year: nil, groupTitle: nil, tvgId: nil, logoUrl: nil, chno: nil,
            host: "h", containerExt: nil, streamUrl: "http://cdn.test/live/\(id).m3u8", userAgent: nil, referer: nil,
            headersJson: nil, catchupType: nil, catchupSource: nil, catchupDays: nil, plot: nil, imdbId: nil,
            imdbRating: nil, isFavorite: false, isBroken: false, resumePositionMs: 0, durationMs: 0, isCompleted: false
        )
    }

    func testZapperWrapsAroundBothWays() {
        let zapper = LiveZapper()
        zapper.update(channels: [channel(1), channel(2), channel(3)]) { $0.id == 2 ? "Météo" : nil }

        XCTAssertEqual(zapper.neighbor(of: "http://cdn.test/live/1.m3u8", offset: 1)?.id, 2)
        XCTAssertEqual(zapper.neighbor(of: "http://cdn.test/live/3.m3u8", offset: 1)?.id, 1, "wraps to the first")
        XCTAssertEqual(zapper.neighbor(of: "http://cdn.test/live/1.m3u8", offset: -1)?.id, 3, "wraps to the last")
        XCTAssertEqual(zapper.neighbor(of: "http://cdn.test/live/2.m3u8", offset: 5)?.id, 1)
        XCTAssertNil(zapper.neighbor(of: "http://cdn.test/live/1.m3u8", offset: 0))
        XCTAssertEqual(zapper.nowTitle(forStreamUrl: "http://cdn.test/live/2.m3u8"), "Météo")
        XCTAssertNil(zapper.nowTitle(forStreamUrl: "http://cdn.test/live/1.m3u8"))
    }

    func testZapperStartsFromTheEdgesWhenTheCurrentStreamIsNotListed() {
        let zapper = LiveZapper()
        XCTAssertNil(zapper.neighbor(of: nil, offset: 1), "no channels yet")
        zapper.update(channels: [channel(1), channel(2)]) { _ in nil }
        XCTAssertEqual(zapper.neighbor(of: nil, offset: 1)?.id, 1)
        XCTAssertEqual(zapper.neighbor(of: "http://elsewhere/film.mkv", offset: -1)?.id, 2)
    }

    func testGestureMath() {
        XCTAssertEqual(PlayerGestureMath.side(forX: 100, width: 800), .left)
        XCTAssertEqual(PlayerGestureMath.side(forX: 500, width: 800), .right)
        XCTAssertEqual(PlayerGestureMath.skipSeconds(for: .left), -10)
        XCTAssertEqual(PlayerGestureMath.skipSeconds(for: .right), 10)

        XCTAssertEqual(PlayerGestureMath.adjusted(0.5, translationY: -100, height: 400), 0.75, accuracy: 0.0001)
        XCTAssertEqual(PlayerGestureMath.adjusted(0.5, translationY: 100, height: 400), 0.25, accuracy: 0.0001)
        XCTAssertEqual(PlayerGestureMath.adjusted(0.9, translationY: -400, height: 400), 1, "clamped to 1")
        XCTAssertEqual(PlayerGestureMath.adjusted(0.1, translationY: 400, height: 400), 0, "clamped to 0")
        XCTAssertEqual(PlayerGestureMath.adjusted(0.4, translationY: -50, height: 0), 0.4, "no height, no change")
    }

    func testMenuCommandsReachTheShellClosures() {
        let center = AppCommandCenter()
        var log: [String] = []
        center.addSource = { log.append("add") }
        center.importPlaylist = { log.append("import") }
        center.refreshAllSources = { log.append("refresh") }
        center.toggleNetworkConsole = { log.append("console") }
        center.zap = { log.append("zap\($0)") }
        center.togglePlayPause = { log.append("play") }
        center.toggleMute = { log.append("mute") }
        center.togglePictureInPicture = { log.append("pip") }

        center.addSource(); center.importPlaylist(); center.refreshAllSources(); center.toggleNetworkConsole()
        center.zap(1); center.zap(-1); center.togglePlayPause(); center.toggleMute(); center.togglePictureInPicture()
        XCTAssertEqual(log, ["add", "import", "refresh", "console", "zap1", "zap-1", "play", "mute", "pip"])
        XCTAssertFalse(center.hasMedia)
        _ = KeyboardCommands(center: center)
    }

    func testMenuRequestsSurviveTheTabSwitchThatCreatesTheList() throws {
        let model = SourcesModel(engine: try CndEngine.inMemory())
        XCTAssertNil(model.pendingAction)
        model.request(.addSource)
        XCTAssertEqual(model.pendingAction, .addSource, "kept until the Sources screen consumes it")
        model.request(.importPlaylist)
        XCTAssertEqual(model.pendingAction, .importPlaylist)
    }
}

// MARK: - Application log

@MainActor
final class AppLogTests: XCTestCase {
    func testEntriesAreSequencedAboveTheEngineRangeAndQueryableByCursor() {
        let log = AppLog()
        log.info("PLAYER", "un")
        log.warn("PLAYER", "deux")
        log.error("SYNC", "trois")
        let all = log.entries(after: 0)
        XCTAssertEqual(all.map(\.message), ["un", "deux", "trois"])
        XCTAssertTrue(all.allSatisfy { $0.seqId > AppLog.seqBase })
        XCTAssertEqual(all.map(\.level), [.info, .warn, .error])
        XCTAssertEqual(log.entries(after: all[1].seqId).map(\.message), ["trois"])
        XCTAssertTrue(log.entries(after: all[2].seqId).isEmpty)
        log.clear()
        XCTAssertTrue(log.entries(after: 0).isEmpty)
    }

    func testCapacityKeepsTheNewestEntries() {
        let log = AppLog()
        for index in 0..<(AppLog.capacity + 25) { log.info("T", "m\(index)") }
        let all = log.entries(after: 0)
        XCTAssertEqual(all.count, AppLog.capacity)
        XCTAssertEqual(all.last?.message, "m\(AppLog.capacity + 24)")
    }

    func testStreamUrlsAreDescribedWithoutCredentials() {
        let url = URL(string: "http://srv.example.com:8080/movie/alice/s3cret/12345.mkv?token=abc")!
        let text = AppLog.describe(url)
        XCTAssertEqual(text, "srv.example.com, .mkv")
        for secret in ["alice", "s3cret", "token", "12345"] { XCTAssertFalse(text.contains(secret)) }
        XCTAssertEqual(AppLog.describe(URL(string: "http://h/stream/9")!), "h, sans extension")
    }

    func testConsoleShowsAppEntriesInTimeOrderAndClearsThem() async throws {
        let engine = try CndEngine.inMemory()
        let log = AppLog()
        let console = ConsoleModel(engine: engine, appLog: log)

        _ = try engine.addSource(name: "Engine first", sourceType: "m3u", url: "http://x/a.m3u", server: nil, username: nil, passwordRef: nil)
        try await Task.sleep(for: .milliseconds(30))
        log.error("PLAYER", "Échec de lecture (mpv) : boom")
        await console.poll()

        let messages = console.entries.map(\.message)
        XCTAssertTrue(messages.contains { $0.contains("Engine first") })
        XCTAssertEqual(messages.last, "Échec de lecture (mpv) : boom", "ordered by time: the app entry came last")
        XCTAssertTrue(console.categories.contains("PLAYER"))

        await console.poll()
        XCTAssertEqual(console.entries.filter { $0.category == "PLAYER" }.count, 1, "no duplicate on the next poll")

        console.toggle(category: "PLAYER")
        XCTAssertEqual(console.filtered.map(\.message), ["Échec de lecture (mpv) : boom"])
        console.levelFilter = .errors
        XCTAssertEqual(console.filtered.count, 1)

        console.clear()
        XCTAssertTrue(console.entries.isEmpty)
        XCTAssertTrue(log.entries(after: 0).isEmpty)
    }

    func testThePlayerReportsOpeningFallbackAndFailureWithoutLeakingTheUrl() async {
        let before = AppLog.shared.entries(after: 0).count
        let controller = CndPlayerController(
            recorder: nil, reachability: FakeReachability(),
            backendFactory: { kind in
                let backend = MockBackend(kind)
                backend.behavior = kind == .avPlayer ? .fail("format non pris en charge") : .play
                return backend
            }
        )
        controller.open(PlayableMedia(
            title: "Mon film", url: URL(string: "http://srv.test/movie/alice/s3cret/7.mp4")!, kind: .movie
        ))
        _ = await eventually { controller.state == .playing }
        controller.close()

        let fresh = Array(AppLog.shared.entries(after: 0).dropFirst(before)).map(\.message)
        XCTAssertTrue(fresh.contains { $0.contains("Ouverture de « Mon film »") && $0.contains("srv.test, .mp4") })
        XCTAssertTrue(fresh.contains { $0.contains("Échec de lecture (AVPlayer)") && $0.contains("format non pris en charge") })
        XCTAssertTrue(fresh.contains { $0.contains("bascule vers mpv") })
        XCTAssertTrue(fresh.contains { $0.contains("Lecture démarrée") })
        XCTAssertFalse(fresh.contains { $0.contains("s3cret") || $0.contains("alice") })
    }
}
