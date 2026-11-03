import Testing
import Foundation
import QuartzCore
@testable import CndIptvKit

@MainActor
final class MockTimeshiftBackend: VideoBackend {
    let engineKind: PlayerEngineKind = .mpv
    let displayLayer = CALayer()
    var state: PlaybackState = .idle {
        didSet { onStateChange?(state) }
    }
    var positionMs: Int64 = 0
    var durationMs: Int64 = 0

    var onStateChange: ((PlaybackState) -> Void)?
    var onTracksChange: (() -> Void)?

    var relativeSeeks: [Double] = []
    var returnToLiveCallCount = 0
    var pauseCallCount = 0
    var playCallCount = 0

    func load(_ media: PlayableMedia, startPositionMs: Int64) {
        state = .playing
    }

    func play() {
        playCallCount += 1
        state = .playing
    }

    func pause() {
        pauseCallCount += 1
        state = .paused
    }

    func seek(toMs positionMs: Int64) {
        self.positionMs = positionMs
    }

    func setRate(_ rate: Float) {}
    func setVolume(_ volume: Float) {}
    func setMuted(_ muted: Bool) {}

    func audioTracks() -> [MediaTrack] { [] }
    func subtitleTracks() -> [MediaTrack] { [] }
    func selectAudioTrack(id: String) {}
    func selectSubtitleTrack(id: String?) {}
    func teardown() { state = .idle }

    func seekLiveRelative(seconds: Double) {
        relativeSeeks.append(seconds)
    }

    func returnToLive() {
        returnToLiveCallCount += 1
    }
}

final class TimeshiftFakeReachability: NetworkReachability, @unchecked Sendable {
    var isConnected = true
    func waitUntilConnected(timeout: TimeInterval) async -> Bool { true }
}

@Suite("Local Timeshift Pause Live Tests (PRD-24)", .serialized)
struct TimeshiftTests {

    @Test("TimeshiftDuration config properties")
    func testTimeshiftDurationConfigs() {
        let disabled = TimeshiftDuration.disabled
        #expect(!disabled.isEnabled)
        #expect(disabled.maxBackBytes == "0")

        let halfHour = TimeshiftDuration.halfHour
        #expect(halfHour.isEnabled)
        #expect(halfHour.maxBackBytes == "1024MiB")

        let oneHour = TimeshiftDuration.oneHour
        #expect(oneHour.isEnabled)
        #expect(oneHour.maxBackBytes == "2048MiB")

        let twoHours = TimeshiftDuration.twoHours
        #expect(twoHours.isEnabled)
        #expect(twoHours.maxBackBytes == "4096MiB")
    }

    @Test("TimeshiftCacheManager directory operations")
    func testTimeshiftCacheManager() throws {
        let path = TimeshiftCacheManager.ensureCacheDirectory()
        #expect(FileManager.default.fileExists(atPath: path))

        let testFile = TimeshiftCacheManager.cacheDirectory.appendingPathComponent("test_segment.ts")
        try "test data".write(to: testFile, atomically: true, encoding: .utf8)
        #expect(FileManager.default.fileExists(atPath: testFile.path))

        TimeshiftCacheManager.cleanCacheDirectory()
        #expect(!FileManager.default.fileExists(atPath: testFile.path))
    }

    @Test("Pause, relative skip and return to live in CndPlayerController")
    @MainActor
    func testPlayerControllerTimeshiftFlow() throws {
        let mock = MockTimeshiftBackend()
        let controller = CndPlayerController(
            reachability: TimeshiftFakeReachability(),
            backendFactory: { _ in mock },
            isEngineAvailable: { _ in true }
        )
        controller.timeshiftDuration = .oneHour

        let liveMedia = PlayableMedia(
            title: "BFM TV",
            url: URL(string: "http://example.com/live.ts")!,
            kind: .live
        )
        controller.open(liveMedia)

        #expect(controller.isLive)
        #expect(controller.liveDelaySeconds == 0)

        // 1. Pause live
        controller.pause()
        #expect(mock.pauseCallCount == 1)
        #expect(controller.livePauseStartTime != nil)

        // Simulate 5 seconds pause
        controller.livePauseStartTime = Date().addingTimeInterval(-5.0)
        #expect(controller.currentLiveDelaySeconds >= 4.9)

        // 2. Resume live
        controller.play()
        #expect(mock.playCallCount == 1)
        #expect(controller.livePauseStartTime == nil)
        #expect(controller.liveDelaySeconds >= 4.9)

        // 3. Skip back 10 seconds
        controller.skip(bySeconds: -10)
        #expect(mock.relativeSeeks.count == 1)
        #expect(mock.relativeSeeks.last == -10.0)
        #expect(controller.liveDelaySeconds >= 14.9)

        // 4. Skip forward 10 seconds
        controller.skip(bySeconds: 10)
        #expect(mock.relativeSeeks.count == 2)
        #expect(mock.relativeSeeks.last == 10.0)
        #expect(controller.liveDelaySeconds >= 4.9)

        // 5. Catch up to live
        controller.catchUpToLive()
        #expect(mock.returnToLiveCallCount == 1)
        #expect(controller.liveDelaySeconds == 0)

        // 6. Close cleans up
        controller.close()
        #expect(controller.liveDelaySeconds == 0)
    }
}
