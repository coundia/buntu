import XCTest
@testable import CndIptvKit

final class SlowSourceTests: XCTestCase {
    private func reading(_ mbps: Double, file fileMbps: Double = 6, downloading: Bool = true) -> NetworkReading {
        NetworkReading(downloadBytesPerSecond: mbps * 1_000_000 / 8, fileBitsPerSecond: fileMbps * 1_000_000, isDownloading: downloading)
    }

    func testWarningEscalatesAsReserveFallsAndPlaybackStops() throws {
        var detector = SlowSourceDetector()
        var notice: SlowSourceNotice?
        for _ in 0..<12 {
            notice = detector.add(reading(4.5), bufferedAhead: 92, isBuffering: false, interval: 1)
        }
        let initial = try XCTUnwrap(notice)
        XCTAssertEqual(initial.stage, .continuing)
        XCTAssertEqual(initial.availableMbps, 4.5, accuracy: 0.01)
        XCTAssertFalse(initial.showsDownload)

        for reserve in [14.0, 13, 12, 11] {
            notice = detector.add(reading(4.5), bufferedAhead: reserve, isBuffering: false, interval: 1)
        }
        XCTAssertEqual(notice?.stage, .atRisk)
        for _ in 0..<8 {
            notice = detector.add(reading(4.5), bufferedAhead: 2, isBuffering: true, interval: 1)
        }
        XCTAssertEqual(notice?.stage, .refilling)
        XCTAssertEqual(notice?.showsDownload, true)
    }

    func testSustainedThroughputRecoveryClearsWarning() {
        var detector = SlowSourceDetector()
        var notice: SlowSourceNotice?
        for _ in 0..<15 {
            notice = detector.add(reading(4), bufferedAhead: 20, isBuffering: false, interval: 1)
        }
        XCTAssertEqual(notice?.stage, .continuing)
        for _ in 0..<25 {
            notice = detector.add(reading(7), bufferedAhead: 35, isBuffering: false, interval: 1)
        }
        XCTAssertNil(notice)
    }

    func testFullCacheClearsExistingWarningWithoutTreatingIdleSpeedAsLow() {
        var detector = SlowSourceDetector()
        var notice: SlowSourceNotice?
        for _ in 0..<15 {
            notice = detector.add(reading(5), bufferedAhead: 80, isBuffering: false, interval: 1)
        }
        XCTAssertEqual(notice?.stage, .continuing)
        for _ in 0..<5 {
            notice = detector.add(reading(0, downloading: false), bufferedAhead: 120, isBuffering: false, interval: 1)
        }
        XCTAssertNil(notice)
    }

    func testFastConnectionAndUnknownBitrateDoNotWarn() {
        var detector = SlowSourceDetector()
        let unknown = NetworkReading(downloadBytesPerSecond: 100_000, fileBitsPerSecond: nil, isDownloading: true)
        for _ in 0..<30 {
            XCTAssertNil(detector.add(reading(9), bufferedAhead: 2, isBuffering: true, interval: 1))
        }
        for _ in 0..<30 {
            XCTAssertNil(detector.add(unknown, bufferedAhead: 2, isBuffering: true, interval: 1))
        }
    }
}
