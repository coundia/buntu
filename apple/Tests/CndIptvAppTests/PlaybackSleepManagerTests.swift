import XCTest
@testable import CndIptvKit

@MainActor
final class PlaybackSleepManagerTests: XCTestCase {

    func testSleepManagerInitialState() {
        let manager = PlaybackSleepManager()
        XCTAssertFalse(manager.isBlockingSleep)
        XCTAssertEqual(manager.activeCount, 0)
    }

    func testSleepManagerSinglePlayerLifecycle() {
        let manager = PlaybackSleepManager()
        let id = UUID()

        manager.setPlaying(true, for: id)
        XCTAssertTrue(manager.isBlockingSleep)
        XCTAssertEqual(manager.activeCount, 1)

        // Redundant setPlaying(true) shouldn't inflate count
        manager.setPlaying(true, for: id)
        XCTAssertTrue(manager.isBlockingSleep)
        XCTAssertEqual(manager.activeCount, 1)

        manager.setPlaying(false, for: id)
        XCTAssertFalse(manager.isBlockingSleep)
        XCTAssertEqual(manager.activeCount, 0)
    }

    func testSleepManagerMultiPlayerLifecycle() {
        let manager = PlaybackSleepManager()
        let id1 = UUID()
        let id2 = UUID()

        manager.setPlaying(true, for: id1)
        XCTAssertTrue(manager.isBlockingSleep)
        XCTAssertEqual(manager.activeCount, 1)

        manager.setPlaying(true, for: id2)
        XCTAssertTrue(manager.isBlockingSleep)
        XCTAssertEqual(manager.activeCount, 2)

        // Player 1 pauses, but Player 2 is still streaming: sleep MUST remain blocked
        manager.setPlaying(false, for: id1)
        XCTAssertTrue(manager.isBlockingSleep)
        XCTAssertEqual(manager.activeCount, 1)

        // Player 2 pauses: now all streams stopped, sleep is restored
        manager.setPlaying(false, for: id2)
        XCTAssertFalse(manager.isBlockingSleep)
        XCTAssertEqual(manager.activeCount, 0)
    }

    func testSleepManagerRemoveAndReset() {
        let manager = PlaybackSleepManager()
        let id1 = UUID()
        let id2 = UUID()

        manager.setPlaying(true, for: id1)
        manager.setPlaying(true, for: id2)
        XCTAssertEqual(manager.activeCount, 2)

        manager.remove(id: id1)
        XCTAssertTrue(manager.isBlockingSleep)
        XCTAssertEqual(manager.activeCount, 1)

        manager.reset()
        XCTAssertFalse(manager.isBlockingSleep)
        XCTAssertEqual(manager.activeCount, 0)
    }

    func testSleepManagerAssertionChangedCallback() {
        let manager = PlaybackSleepManager()
        var toggles: [Bool] = []
        manager.onAssertionChanged = { blocked in
            toggles.append(blocked)
        }

        let id1 = UUID()
        let id2 = UUID()

        manager.setPlaying(true, for: id1) // triggers true
        manager.setPlaying(true, for: id2) // still true, no toggle
        manager.setPlaying(false, for: id1) // still true, no toggle
        manager.setPlaying(false, for: id2) // triggers false

        XCTAssertEqual(toggles, [true, false])
    }

    func testCndPlayerControllerDrivesSleepAssertion() {
        let sleepManager = PlaybackSleepManager()
        var backend: MockBackend?

        let controller = CndPlayerController(
            backendFactory: { kind in
                let mock = MockBackend(kind)
                backend = mock
                return mock
            },
            isEngineAvailable: { _ in true },
            sleepManager: sleepManager
        )

        XCTAssertFalse(sleepManager.isBlockingSleep)

        let media = PlayableMedia(
            title: "Test Stream",
            url: URL(string: "http://example.com/live.m3u8")!,
            kind: .live
        )

        controller.open(media)
        XCTAssertTrue(sleepManager.isBlockingSleep, "Opening a stream starts loading/playing and blocks sleep")

        backend?.pause()
        XCTAssertFalse(sleepManager.isBlockingSleep, "Pausing the stream allows sleep")

        backend?.play()
        XCTAssertTrue(sleepManager.isBlockingSleep, "Resuming the stream blocks sleep again")

        controller.close()
        XCTAssertFalse(sleepManager.isBlockingSleep, "Closing the player unblocks sleep")
    }

    func testCndPlayerControllerDeinitCleansUpSleepAssertion() async {
        let sleepManager = PlaybackSleepManager()

        var controller: CndPlayerController? = CndPlayerController(
            backendFactory: { kind in MockBackend(kind) },
            isEngineAvailable: { _ in true },
            sleepManager: sleepManager
        )

        let media = PlayableMedia(
            title: "Movie",
            url: URL(string: "http://example.com/movie.mp4")!,
            kind: .movie
        )

        controller?.open(media)
        XCTAssertTrue(sleepManager.isBlockingSleep)

        // Nil out the controller reference without calling close()
        controller = nil

        // Give the MainActor cleanup task a moment to execute
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertFalse(sleepManager.isBlockingSleep, "Controller deinit must release its sleep assertion")
    }
}
