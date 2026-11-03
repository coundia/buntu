import XCTest
@testable import CndIptvApp

/// PRD 25: the player reads the video's frame rate and dynamic range and hands them to the display matcher.
@MainActor
final class AutoFramerateTests: XCTestCase {
    override func setUp() async throws {
        DisplayRateMatcher.shared.reset()
    }

    override func tearDown() async throws {
        DisplayRateMatcher.shared.reset()
    }

    func testSnapsToStandardCadences() {
        XCTAssertEqual(StandardFrameRate.snap(rawFps: 23.976), .fps23_976)
        XCTAssertEqual(StandardFrameRate.snap(rawFps: 24.0), .fps24)
        XCTAssertEqual(StandardFrameRate.snap(rawFps: 25.01), .fps25)
        XCTAssertEqual(StandardFrameRate.snap(rawFps: 29.97), .fps29_97)
        XCTAssertEqual(StandardFrameRate.snap(rawFps: 49.9), .fps50)
        XCTAssertEqual(StandardFrameRate.snap(rawFps: 59.94), .fps59_94)
        XCTAssertNil(StandardFrameRate.snap(rawFps: 0))
        XCTAssertNil(StandardFrameRate.snap(rawFps: 200))
        XCTAssertNil(StandardFrameRate.snap(rawFps: 37.0), "no standard cadence close enough")
    }

    func testDynamicRangeFromMpvNames() {
        XCTAssertEqual(VideoDynamicRange.detect(gamma: "pq", primaries: "bt.2020"), .hdr10)
        XCTAssertEqual(VideoDynamicRange.detect(gamma: "hlg", primaries: "bt.2020"), .hlg)
        XCTAssertEqual(VideoDynamicRange.detect(gamma: "bt.1886", primaries: "bt.709"), .sdr)
        XCTAssertEqual(VideoDynamicRange.detect(gamma: nil, primaries: nil), .sdr)
    }

    func testThePlayerFeedsTheMatcherOnceThePictureIsRunning() async throws {
        let backend = MockBackend(.avPlayer)
        backend.videoFormat = VideoFormatReading(fps: 25.0, gamma: "pq", primaries: "bt.2020")
        let player = CndPlayerController(
            reachability: FakeReachability(),
            backendFactory: { _ in backend },
            isEngineAvailable: { _ in true }
        )
        DisplayRateMatcher.shared.isEnabled = false // nothing may touch a real display here
        player.open(PlayableMedia(title: "Film", url: URL(string: "http://h/a.mp4")!, kind: .movie))
        try await Task.sleep(nanoseconds: 300_000_000)

        let format = try XCTUnwrap(DisplayRateMatcher.shared.currentFormat)
        XCTAssertEqual(format.matchedRate, .fps25)
        XCTAssertEqual(format.dynamicRange, .hdr10)
        XCTAssertEqual(format.summary, "25 i/s · HDR10")
        player.close()
        XCTAssertNil(DisplayRateMatcher.shared.currentFormat, "closing the player resets the display")
    }

    func testAnUnknownFormatIsRetriedThenLeftAlone() async throws {
        let backend = MockBackend(.avPlayer) // reports nothing
        let player = CndPlayerController(
            reachability: FakeReachability(),
            backendFactory: { _ in backend },
            isEngineAvailable: { _ in true }
        )
        DisplayRateMatcher.shared.isEnabled = false
        player.open(PlayableMedia(title: "Film", url: URL(string: "http://h/a.mp4")!, kind: .movie))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(DisplayRateMatcher.shared.currentFormat)

        // The engine learns the rate a moment later: the next attempt picks it up.
        backend.videoFormat = VideoFormatReading(fps: 50.0)
        try await Task.sleep(nanoseconds: 1_300_000_000)
        XCTAssertEqual(DisplayRateMatcher.shared.currentFormat?.matchedRate, .fps50)
        player.close()
    }
}
