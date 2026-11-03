import XCTest
import CndCoreBridge
@testable import CndIptvKit

@MainActor
final class HealthAndFailoverTests: XCTestCase {

    private func makeItem(
        id: Int64,
        name: String,
        streamUrl: String = "http://test.live/stream.ts",
        tvgId: String? = nil,
        isBroken: Bool = false
    ) -> IptvItemRecord {
        IptvItemRecord(
            id: id,
            sourceId: 1,
            seriesId: nil,
            stableHash: "hash_\(id)",
            kind: "live",
            seasonNum: nil,
            episodeNum: nil,
            name: name,
            nameClean: name.lowercased(),
            year: nil,
            groupTitle: "General",
            tvgId: tvgId,
            logoUrl: nil,
            chno: nil,
            host: "test.live",
            containerExt: "ts",
            streamUrl: streamUrl,
            userAgent: nil,
            referer: nil,
            headersJson: nil,
            catchupType: nil,
            catchupSource: nil,
            catchupDays: nil,
            plot: nil,
            imdbId: nil,
            imdbRating: nil,
            isFavorite: false,
            isBroken: isBroken,
            resumePositionMs: 0,
            durationMs: 0,
            isCompleted: false
        )
    }

    func testAutomaticFailoverToMirrorAfterReconnectionFailure() async {
        var backends: [MockBackend] = []
        let timings = PlayerTimings(
            tick: 0.01,
            watchdogInterval: 0.01,
            stallThreshold: 0.05,
            loadTimeout: 0.05,
            reconnectBackoff: [0.01, 0.01],
            recoveryProbe: 0.02
        )

        let controller = CndPlayerController(
            reachability: FakeReachability(),
            timings: timings,
            backendFactory: { kind in
                let b = MockBackend(kind)
                b.behavior = .fail("Stream 404")
                backends.append(b)
                return b
            }
        )

        let original = makeItem(id: 100, name: "TF1 4K", streamUrl: "http://srv1/tf1_4k.ts")
        let mirror = makeItem(id: 101, name: "TF1 FHD", streamUrl: "http://srv1/tf1_fhd.ts")

        var failoverNotified: IptvItemRecord?
        controller.onFailoverOccurred = { failoverNotified = $0 }
        controller.mirrorFinder = { (itemId: Int64) -> [IptvItemRecord] in
            if itemId == 100 {
                return [mirror]
            }
            return []
        }

        guard let playable = PlayableMedia(item: original) else {
            XCTFail("Could not create PlayableMedia")
            return
        }

        controller.open(playable)

        // Allow reconnect backoffs (2 x 0.01s) and recovery probe to complete
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(controller.failoverCount, 1, "Should have performed exactly 1 automatic failover")
        XCTAssertEqual(controller.media?.title, "TF1 FHD", "Should now be playing the mirror channel")
        XCTAssertEqual(failoverNotified?.id, 101, "Callback should receive mirror item")
        XCTAssertNotNil(controller.failoverBanner, "Non-blocking failover banner should be set")
        XCTAssertTrue(controller.failoverBanner?.contains("TF1 FHD") == true)
    }

    func testFailoverLimitIsCappedAtTwo() async {
        let timings = PlayerTimings(
            tick: 0.01,
            watchdogInterval: 0.01,
            stallThreshold: 0.05,
            loadTimeout: 0.05,
            reconnectBackoff: [0.01],
            recoveryProbe: 0.02
        )

        let controller = CndPlayerController(
            reachability: FakeReachability(),
            timings: timings,
            backendFactory: { kind in
                let b = MockBackend(kind)
                b.behavior = .fail("Immediate error")
                return b
            }
        )

        let item1 = makeItem(id: 1, name: "Stream 1")
        let item2 = makeItem(id: 2, name: "Stream 2")
        let item3 = makeItem(id: 3, name: "Stream 3")
        let item4 = makeItem(id: 4, name: "Stream 4")

        controller.mirrorFinder = { (itemId: Int64) -> [IptvItemRecord] in
            switch itemId {
            case 1: return [item2]
            case 2: return [item3]
            case 3: return [item4]
            default: return []
            }
        }

        guard let playable = PlayableMedia(item: item1) else { return }
        controller.open(playable)

        // Wait until failover count reaches cap 2
        for _ in 0..<60 {
            if controller.failoverCount >= 2 { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(controller.failoverCount, 2, "Failover count must be capped at 2 and not reach 3")

        // Wait until final stream recovery exhausts and state becomes permanently failed
        for _ in 0..<60 {
            if case .failed = controller.state, controller.reconnectBanner == nil { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertEqual(controller.media?.title, "Stream 3", "Final stream attempted was mirror 2 (Stream 3)")
        if case .failed = controller.state {
            // Success: player transitions to failed state
        } else {
            XCTFail("State should be failed after exceeding failover cap")
        }
    }

    func testAutoFailoverDisabledOffersAlternativesWithoutSwitching() async {
        let timings = PlayerTimings(
            tick: 0.01,
            watchdogInterval: 0.01,
            stallThreshold: 0.05,
            loadTimeout: 0.05,
            reconnectBackoff: [0.01],
            recoveryProbe: 0.02
        )

        let controller = CndPlayerController(
            reachability: FakeReachability(),
            timings: timings,
            backendFactory: { kind in
                let b = MockBackend(kind)
                b.behavior = .fail("Error")
                return b
            }
        )

        controller.autoFailoverEnabled = false
        let original = makeItem(id: 10, name: "Channel A")
        let mirror = makeItem(id: 11, name: "Channel A Mirror")

        controller.mirrorFinder = { (_: Int64) -> [IptvItemRecord] in [mirror] }

        guard let playable = PlayableMedia(item: original) else { return }
        controller.open(playable)

        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(controller.failoverCount, 0, "No failover should occur when disabled")
        XCTAssertEqual(controller.availableMirrors.count, 1, "Alternatives must be populated")
        XCTAssertEqual(controller.availableMirrors.first?.id, 11)
        XCTAssertEqual(controller.media?.title, "Channel A", "Original media is kept")
        if case .failed = controller.state {
            // expected
        } else {
            XCTFail("Player state should be failed when auto-failover is disabled")
        }
    }

    func testManualFailoverToMirrorPreservesVolumeAndSettings() {
        let controller = CndPlayerController()
        controller.volume = 0.65
        controller.isMuted = true

        let mirror = makeItem(id: 200, name: "Backup Channel")
        controller.failoverToMirror(mirror)

        XCTAssertEqual(controller.media?.title, "Backup Channel")
        XCTAssertEqual(controller.volume, 0.65, accuracy: 0.001)
        XCTAssertTrue(controller.isMuted)
        XCTAssertEqual(controller.failoverCount, 1)
        XCTAssertEqual(controller.failoverBanner, "Bascule vers Backup Channel")
    }
}
