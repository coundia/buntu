import XCTest
import QuartzCore
@testable import CndIptvKit

// MARK: - Test doubles

@MainActor
final class MockBackend: VideoBackend {
    let engineKind: PlayerEngineKind
    let displayLayer = CALayer()
    var state: PlaybackState = .idle { didSet { if state != oldValue { onStateChange?(state) } } }
    var positionMs: Int64 = 0
    var durationMs: Int64 = 0
    var onStateChange: ((PlaybackState) -> Void)?
    var onTracksChange: (() -> Void)?

    var loads: [(media: PlayableMedia, start: Int64)] = []
    var torndown = false
    /// What happens after `load`: succeed (play and advance), fail, or freeze at the start position.
    enum Behavior { case play, fail(String), freeze }
    var behavior: Behavior = .play
    var advanceTask: Task<Void, Never>?

    init(_ kind: PlayerEngineKind) { engineKind = kind }

    func load(_ media: PlayableMedia, startPositionMs: Int64) {
        loads.append((media, startPositionMs))
        positionMs = startPositionMs
        durationMs = media.kind == .live ? 0 : 600_000
        state = .loading
        switch behavior {
        case .fail(let message):
            state = .failed(message)
        case .freeze:
            state = .playing
        case .play:
            state = .playing
            advanceTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 20_000_000)
                    self?.positionMs += 300
                }
            }
        }
    }

    var videoFormat: VideoFormatReading?
    func currentVideoFormat() -> VideoFormatReading? { videoFormat }

    func play() { state = .playing }
    func pause() { state = .paused }
    func seek(toMs positionMs: Int64) { self.positionMs = positionMs }
    func setRate(_ rate: Float) {}
    func setVolume(_ volume: Float) {}
    func setMuted(_ muted: Bool) {}
    func audioTracks() -> [MediaTrack] { [] }
    func subtitleTracks() -> [MediaTrack] { [] }
    func selectAudioTrack(id: String) {}
    func selectSubtitleTrack(id: String?) {}
    func teardown() {
        torndown = true
        advanceTask?.cancel()
        onStateChange = nil
        onTracksChange = nil
    }
}

final class FakeReachability: NetworkReachability, @unchecked Sendable {
    var isConnected = true
    func waitUntilConnected(timeout: TimeInterval) async -> Bool { true }
}

final class FakeRecorder: WatchProgressRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(String, Int64, Int64)] = []
    var calls: [(String, Int64, Int64)] { lock.lock(); defer { lock.unlock() }; return storage }
    func recordWatchProgress(stableHash: String, positionMs: Int64, durationMs: Int64) throws {
        lock.lock(); storage.append((stableHash, positionMs, durationMs)); lock.unlock()
    }
}

private func media(_ name: String, kind: PlayableKind = .movie, headers: [String: String] = [:], start: Int64 = 0, hash: String? = nil) -> PlayableMedia {
    PlayableMedia(title: name, url: URL(string: "http://cdn.test/\(name)")!, headers: headers, kind: kind, startPositionMs: start, stableHash: hash)
}

// MARK: - Tests

final class CndPlayerTests: XCTestCase {

    @MainActor
    func testLiveHealthClearsAfterAudioTimeAdvancesWithoutVideo() async {
        var backend: MockBackend?
        var timings = PlayerTimings()
        timings.tick = 0.01
        timings.watchdogInterval = 100
        let recorder = PlaybackHealthRecorder()
        let controller = makeController(timings: timings, behaviors: [.mpv: .freeze], created: { backend = $0 })
        controller.playbackHealthHandler = { item, broken in await recorder.record(item.stableHash ?? "", broken) }
        controller.open(media("audio-live.ts", kind: .live, hash: "audio-live"))
        backend?.onStateChange?(.failed("Connexion interrompue"))
        XCTAssertTrue(controller.isBroken)
        backend?.onStateChange?(.playing)
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(controller.isBroken, "ready at timestamp zero is not recovery")
        backend?.positionMs = 1000
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertFalse(controller.isBroken)
        let states = await recorder.states
        XCTAssertEqual(states.map { $0.1 }, [true, false])
        XCTAssertTrue(states.allSatisfy { $0.0 == "audio-live" })
        controller.close()
    }

    @MainActor
    func testOldBackendFailureCannotMarkTheNewChannelBroken() async {
        var backend: MockBackend?
        var timings = PlayerTimings()
        timings.tick = 0.01
        timings.watchdogInterval = 100
        let controller = makeController(timings: timings, behaviors: [.mpv: .freeze], created: { backend = $0 })
        controller.open(media("old-health.ts", kind: .live, hash: "old-health"))
        let oldEvent = backend?.onStateChange
        controller.open(media("new-health.ts", kind: .live, hash: "new-health"))
        oldEvent?(.failed("Ancienne chaîne"))
        XCTAssertFalse(controller.isBroken)
        XCTAssertEqual(controller.media?.stableHash, "new-health")
        controller.close()
    }

    // MARK: Routing

    func testRoutingPicksEngineFromExtensionAndPreference() {
        func engine(_ url: String, _ pref: PlayerEnginePreference = .auto) -> PlayerEngineKind {
            PlayerRouting.engine(for: URL(string: url)!, preference: pref)
        }
        XCTAssertEqual(engine("http://h/live/a.m3u8"), .avPlayer)
        XCTAssertEqual(engine("http://h/vod/film.MP4?token=1"), .avPlayer)
        XCTAssertEqual(engine("http://h/vod/film.mov"), .avPlayer)
        XCTAssertEqual(engine("http://h/live/u/p/10.ts"), .mpv)
        XCTAssertEqual(engine("http://h/movie/u/p/20.mkv"), .mpv)
        XCTAssertEqual(engine("http://h/x.avi"), .mpv)
        XCTAssertEqual(engine("http://h/x.flv"), .mpv)
        XCTAssertEqual(engine("http://h/stream/12345"), .mpv)
        XCTAssertEqual(engine("http://h/live/a.m3u8", .forceMpv), .mpv)
    }

    func testPlayableFromCatalogItemKeepsHeaders() {
        let headers = ["X-Token": "abc", "user-agent": "from-json"]
        let m = PlayableMedia(title: "t", url: URL(string: "http://h/a.m3u8")!, headers: headers, kind: .live)
        XCTAssertEqual(m.userAgent, "from-json")
        XCTAssertEqual(m.orderedHeaders.map(\.name), ["User-Agent", "X-Token"])
        XCTAssertEqual(PlayerRouting.engine(for: m.url), .avPlayer)
    }

    // MARK: Command generators

    func testFfmpegCommandEscapesHeadersAndTitle() {
        let m = PlayableMedia(
            title: "Mission: Impossible / 2",
            url: URL(string: "http://h/movie/a.mkv?token=$x&u=1")!,
            headers: ["User-Agent": "VLC/3.0 it's", "Referer": "http://ref/", "X-Extra": "a\\b"],
            kind: .movie
        )
        XCTAssertEqual(
            ExternalPlayerLauncher.ffmpegCommand(for: m),
            #"ffmpeg -headers $'User-Agent: VLC/3.0 it\'s\r\nReferer: http://ref/\r\nX-Extra: a\\b\r\n' -i "http://h/movie/a.mkv?token=\$x&u=1" -c copy "Mission_ Impossible _ 2.mp4""#
        )
        let bare = PlayableMedia(title: "///", url: URL(string: "http://h/a.ts")!, kind: .live)
        XCTAssertEqual(ExternalPlayerLauncher.ffmpegCommand(for: bare), #"ffmpeg -i "http://h/a.ts" -c copy "___.mp4""#)
    }

    func testCurlCommandEscapesQuotesAndDollar() {
        let m = PlayableMedia(
            title: "Film \"X\"",
            url: URL(string: "http://h/a.mkv?x=$(id)")!,
            headers: ["User-Agent": "UA \"quoted\" $HOME", "Referer": "http://ref/"],
            kind: .movie
        )
        XCTAssertEqual(
            ExternalPlayerLauncher.curlCommand(for: m),
            #"curl -L -H "User-Agent: UA \"quoted\" \$HOME" -H "Referer: http://ref/" "http://h/a.mkv?x=\$(id)" -o "Film _X_.mp4""#
        )
    }

    func testExternalPlayerSchemeURLsEncodeStreamURL() {
        let m = PlayableMedia(title: "t", url: URL(string: "http://h/a.mkv?u=1&p=2")!, kind: .movie)
        XCTAssertEqual(
            ExternalPlayerLauncher.schemeURL(for: .iina, media: m)?.absoluteString,
            "iina://weblink?url=http%3A%2F%2Fh%2Fa.mkv%3Fu%3D1%26p%3D2"
        )
        XCTAssertEqual(
            ExternalPlayerLauncher.schemeURL(for: .infuse, media: m)?.absoluteString,
            "infuse://x-callback-url/play?url=http%3A%2F%2Fh%2Fa.mkv%3Fu%3D1%26p%3D2"
        )
    }

    func testMpvHeaderFieldEncodingKeepsCommasIntact() {
        let encoded = MpvVideoToolboxBackend.encodeHeaderFields([
            (name: "User-Agent", value: "skipped"),
            (name: "X-A", value: "1,2"),
            (name: "X-B", value: "é"),
        ])
        XCTAssertEqual(encoded, "%8%X-A: 1,2,%7%X-B: é")
    }

    // MARK: Playlist

    func testPlaylistQueueNavigation() {
        var queue = PlaylistQueue(items: [media("e1"), media("e2"), media("e3")], currentIndex: 1)
        XCTAssertEqual(queue.current?.title, "e2")
        XCTAssertNil(PlaylistQueue(items: []).current)
        XCTAssertEqual(queue.next()?.title, "e3")
        XCTAssertFalse(queue.hasNext)
        XCTAssertNil(queue.next())
        XCTAssertEqual(queue.currentIndex, 2)
        XCTAssertEqual(queue.previous()?.title, "e2")
        XCTAssertEqual(queue.previous()?.title, "e1")
        XCTAssertNil(queue.previous())
        XCTAssertEqual(PlaylistQueue(items: [media("a")], currentIndex: 9).currentIndex, 0)
    }

    // MARK: Controller

    @MainActor
    private func makeController(
        recorder: WatchProgressRecording? = nil,
        timings: PlayerTimings = PlayerTimings(),
        behaviors: [PlayerEngineKind: MockBackend.Behavior] = [:],
        created: @escaping (MockBackend) -> Void = { _ in }
    ) -> CndPlayerController {
        CndPlayerController(
            recorder: recorder,
            reachability: FakeReachability(),
            timings: timings,
            backendFactory: { kind in
                let backend = MockBackend(kind)
                backend.behavior = behaviors[kind] ?? .play
                created(backend)
                return backend
            }
        )
    }

    @MainActor
    func testAVPlayerFailureFallsBackToMpvKeepingHeadersAndPosition() async {
        var backends: [MockBackend] = []
        let controller = makeController(behaviors: [.avPlayer: .fail("unsupported")], created: { backends.append($0) })
        let m = media("a.mp4", headers: ["User-Agent": "UA", "Referer": "http://r/"], start: 42_000)

        // Warm up CALayer / Observation machinery so the timing below measures the switch itself.
        let warmup = makeController()
        warmup.open(media("w.mp4"))
        warmup.close()
        backends.removeAll()

        let started = Date()
        controller.open(m)

        XCTAssertEqual(backends.map(\.engineKind), [.avPlayer, .mpv])
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.2, "fallback must be synchronous and instant")
        XCTAssertEqual(controller.activeEngine, .mpv)
        XCTAssertTrue(backends[0].torndown)
        XCTAssertEqual(backends[1].loads.first?.media.headers, m.headers)
        XCTAssertEqual(backends[1].loads.first?.start, 42_000)
        XCTAssertEqual(controller.state, .playing)
        controller.close()
    }

    @MainActor
    func testRoutingOpensMpvDirectlyForTsAndForcedPreference() {
        var kinds: [PlayerEngineKind] = []
        let controller = makeController(created: { kinds.append($0.engineKind) })
        controller.open(media("live.ts", kind: .live))
        controller.enginePreference = .forceMpv
        controller.open(media("x.m3u8"))
        XCTAssertEqual(kinds, [.mpv, .mpv])
        controller.close()
    }

    @MainActor
    func testPlaylistAutoAdvancesAndSavesProgress() async {
        let recorder = FakeRecorder()
        var backends: [MockBackend] = []
        let controller = makeController(recorder: recorder, created: { backends.append($0) })
        controller.openQueue([media("e1.mp4", hash: "h1"), media("e2.mp4", hash: "h2")])

        try? await Task.sleep(nanoseconds: 700_000_000)
        backends[0].state = .ended

        XCTAssertEqual(controller.media?.title, "e2.mp4")
        XCTAssertEqual(controller.queue?.currentIndex, 1)
        let first = recorder.calls.first
        XCTAssertEqual(first?.0, "h1")
        XCTAssertEqual(first?.2, 600_000)
        XCTAssertEqual(first?.1, 600_000, "an ended episode is stored as fully watched")

        controller.previous()
        XCTAssertEqual(controller.media?.title, "e1.mp4")
        controller.close()
    }

    @MainActor
    func testPeriodicProgressSaveSkipsLive() async {
        let recorder = FakeRecorder()
        var timings = PlayerTimings()
        timings.tick = 0.02
        timings.progressInterval = 0.1
        let controller = makeController(recorder: recorder, timings: timings)
        controller.open(media("film.mp4", hash: "hv"))
        try? await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertGreaterThanOrEqual(recorder.calls.count, 2)
        XCTAssertTrue(recorder.calls.allSatisfy { $0.0 == "hv" })

        let before = recorder.calls.count
        controller.open(media("chan.ts", kind: .live, hash: "hl"))
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(recorder.calls.dropFirst(before).contains { $0.0 == "hl" })
        controller.close()
    }

    @MainActor
    func testStallWatchdogReconnectsThreeTimesThenFails() async {
        var backends: [MockBackend] = []
        var timings = PlayerTimings()
        timings.tick = 0.02
        timings.watchdogInterval = 0.05
        timings.stallThreshold = 0.2
        timings.reconnectBackoff = [0.05, 0.05, 0.05]
        timings.recoveryProbe = 0.2
        let controller = makeController(timings: timings, behaviors: [.mpv: .freeze], created: { backends.append($0) })

        var banners: [String] = []
        controller.open(media("live.ts", kind: .live))
        for _ in 0..<150 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            if let b = controller.reconnectBanner, banners.last != b { banners.append(b) }
            if case .failed = controller.state { break }
        }

        XCTAssertEqual(banners, ["Reconnexion 1/3…", "Reconnexion 2/3…", "Reconnexion 3/3…"])
        XCTAssertEqual(backends.count, 4, "initial load plus three reconnection reloads")
        guard case .failed = controller.state else { return XCTFail("expected failed state, got \(controller.state)") }
        XCTAssertNil(controller.reconnectBanner)
        controller.close()
    }

    @MainActor
    func testStallRecoveryResumesVodAtLastPosition() async {
        var backends: [MockBackend] = []
        var timings = PlayerTimings()
        timings.tick = 0.02
        timings.watchdogInterval = 0.05
        timings.stallThreshold = 0.2
        timings.reconnectBackoff = [0.05, 0.05, 0.05]
        timings.recoveryProbe = 1
        let controller = makeController(timings: timings, created: { backends.append($0) })

        controller.open(media("film.mkv", start: 5_000))
        try? await Task.sleep(nanoseconds: 150_000_000)
        // Freeze the first backend: position stops advancing while it still reports `.playing`.
        backends[0].advanceTask?.cancel()
        let frozenAt = backends[0].positionMs

        for _ in 0..<100 where backends.count < 2 { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertGreaterThanOrEqual(backends.count, 2)
        let resume = backends[1].loads.first?.start ?? -1
        XCTAssertGreaterThanOrEqual(resume, frozenAt - 400)
        XCTAssertGreaterThan(resume, 5_000)

        for _ in 0..<100 where controller.reconnectBanner != nil { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertNil(controller.reconnectBanner)
        XCTAssertEqual(controller.state, .playing)
        controller.close()
    }

    @MainActor
    func testCloseTearsEverythingDown() {
        var backends: [MockBackend] = []
        let controller = makeController(created: { backends.append($0) })
        controller.open(media("x.mp4"))
        controller.close()
        XCTAssertTrue(backends[0].torndown)
        XCTAssertNil(controller.surfaceLayer)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.media)
    }

    // MARK: - Favorites

    @MainActor
    func testPlayerTogglesFavoriteViaHandler() async throws {
        final class SafeBox: @unchecked Sendable {
            private let lock = NSLock()
            var handledMedia: PlayableMedia?
            var desiredReturn = true
            func setMedia(_ m: PlayableMedia) { lock.withLock { handledMedia = m } }
            func getMedia() -> PlayableMedia? { lock.withLock { handledMedia } }
            func setReturn(_ val: Bool) { lock.withLock { desiredReturn = val } }
            func getReturn() -> Bool { lock.withLock { desiredReturn } }
        }

        let controller = makeController()
        let movie = PlayableMedia(title: "Matrix", url: URL(string: "http://test/matrix.mp4")!, kind: .movie, stableHash: "hash_matrix", isFavorite: false)

        let box = SafeBox()
        var toggledCalls: [(PlayableMedia, Bool)] = []

        controller.favoriteHandler = { media in
            box.setMedia(media)
            return box.getReturn()
        }
        controller.onFavoriteToggled = { media, isFav in
            toggledCalls.append((media, isFav))
        }

        controller.open(movie)
        XCTAssertFalse(controller.isFavorite)
        XCTAssertFalse(controller.media?.isFavorite ?? true)

        controller.toggleFavorite()
        for _ in 0..<30 {
            if controller.isFavorite { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertTrue(controller.isFavorite)
        XCTAssertEqual(box.getMedia()?.stableHash, "hash_matrix")
        XCTAssertEqual(toggledCalls.count, 1)
        XCTAssertTrue(toggledCalls.first?.1 ?? false)
        XCTAssertTrue(controller.media?.isFavorite ?? false)

        // Toggle back to false
        box.setReturn(false)
        controller.toggleFavorite()
        for _ in 0..<30 {
            if !controller.isFavorite { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(controller.isFavorite)
        XCTAssertEqual(toggledCalls.count, 2)
        XCTAssertFalse(toggledCalls.last?.1 ?? true)
    }

    @MainActor
    func testPlayerFallbackToggleWithoutHandler() async throws {
        let controller = makeController()
        let live = PlayableMedia(title: "News", url: URL(string: "http://test/live.m3u8")!, kind: .live, isFavorite: false)
        controller.open(live)
        XCTAssertFalse(controller.isFavorite)

        controller.toggleFavorite()
        for _ in 0..<30 {
            if controller.isFavorite { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(controller.isFavorite)
        XCTAssertTrue(controller.media?.isFavorite ?? false)
    }

    @MainActor
    func testPlayerTogglesBrokenViaHandler() async throws {
        let controller = makeController()
        let movie = PlayableMedia(title: "Inception", url: URL(string: "http://test/m.mkv")!, kind: .movie, isBroken: false)

        final class SafeBrokenBox: @unchecked Sendable {
            private let lock = NSLock()
            private var willReturn: Bool
            private var calls: [String] = []

            init(willReturn: Bool) { self.willReturn = willReturn }

            func record(call: String) -> Bool {
                lock.lock()
                defer { lock.unlock() }
                calls.append(call)
                return willReturn
            }

            func setReturn(_ val: Bool) {
                lock.lock()
                defer { lock.unlock() }
                willReturn = val
            }

            var callCount: Int {
                lock.lock()
                defer { lock.unlock() }
                return calls.count
            }
        }

        let box = SafeBrokenBox(willReturn: true)
        controller.brokenHandler = { media in
            box.record(call: media.title)
        }

        var toggledCalls: [(PlayableMedia, Bool)] = []
        controller.onBrokenToggled = { media, isBroken in
            toggledCalls.append((media, isBroken))
        }

        controller.open(movie)
        XCTAssertFalse(controller.isBroken)

        controller.toggleBroken()
        for _ in 0..<30 {
            if controller.isBroken { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(controller.isBroken)
        XCTAssertTrue(controller.media?.isBroken ?? false)
        XCTAssertEqual(box.callCount, 1)
        XCTAssertEqual(toggledCalls.count, 1)
        XCTAssertTrue(toggledCalls.first?.1 ?? false)

        box.setReturn(false)
        controller.toggleBroken()
        for _ in 0..<30 {
            if !controller.isBroken { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(controller.isBroken)
        XCTAssertEqual(toggledCalls.count, 2)
        XCTAssertFalse(toggledCalls.last?.1 ?? true)
    }

    @MainActor
    func testPlaylistQueueUpdatesCurrentFavorite() {
        let item1 = PlayableMedia(title: "E01", url: URL(string: "http://test/e1.mkv")!, kind: .episode, isFavorite: false)
        let item2 = PlayableMedia(title: "E02", url: URL(string: "http://test/e2.mkv")!, kind: .episode, isFavorite: false)
        var queue = PlaylistQueue(items: [item1, item2], currentIndex: 0)

        XCTAssertFalse(queue.current?.isFavorite ?? true)
        queue.updateCurrentFavorite(true)
        XCTAssertTrue(queue.current?.isFavorite ?? false)

        queue.next()
        XCTAssertFalse(queue.current?.isFavorite ?? true)
    }

    // MARK: libmpv smoke test (macOS dev machines with libmpv + ffmpeg only)

    #if os(macOS)
    @MainActor
    func testMpvBackendPlaysLocalFileWithVideoToolbox() async throws {
        try XCTSkipUnless(MpvVideoToolboxBackend.isLibraryAvailable, "libmpv not installed")
        let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }
        try XCTSkipIf(ffmpeg == nil, "ffmpeg not installed")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cnd_mpv_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("clip.mkv")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpeg!)
        proc.arguments = ["-v", "error", "-f", "lavfi", "-i", "testsrc=size=640x360:rate=30:duration=4",
                          "-f", "lavfi", "-i", "sine=frequency=440:duration=4", "-c:v", "hevc_videotoolbox", "-c:a", "aac", "-shortest", file.path]
        try proc.run()
        proc.waitUntilExit()
        try XCTSkipIf(proc.terminationStatus != 0, "ffmpeg could not produce the test clip")

        let backend = MpvVideoToolboxBackend()
        defer { backend.teardown() }
        backend.load(PlayableMedia(title: "clip", url: file, kind: .movie), startPositionMs: 0)

        var reachedPlaying = false
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 50_000_000)
            if backend.state == .playing, backend.positionMs > 300 { reachedPlaying = true; break }
            if case .failed(let reason) = backend.state { return XCTFail("mpv failed: \(reason)") }
        }
        XCTAssertTrue(reachedPlaying, "mpv never reached playing (state \(backend.state))")
        XCTAssertGreaterThan(backend.durationMs, 3_000)
        XCTAssertTrue(backend.currentHardwareDecoder?.hasPrefix("videotoolbox") ?? false,
                      "hwdec-current = \(backend.currentHardwareDecoder ?? "nil")")
        XCTAssertFalse(backend.audioTracks().isEmpty)
    }
    #endif
}

private actor PlaybackHealthRecorder {
    private(set) var states: [(String, Bool)] = []
    func record(_ hash: String, _ broken: Bool) { states.append((hash, broken)) }
}
