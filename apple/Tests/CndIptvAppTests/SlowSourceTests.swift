import XCTest
@testable import CndIptvKit

/// "Ce fichier demande X Mbit/s, la connexion en donne Y" (one reading per second).
final class SlowSourceTests: XCTestCase {
    private func reading(_ mbps: Double, file fileMbps: Double = 6, downloading: Bool = true) -> NetworkReading {
        NetworkReading(downloadBytesPerSecond: mbps * 1_000_000 / 8, fileBitsPerSecond: fileMbps * 1_000_000, isDownloading: downloading)
    }

    func testAFileHeavierThanTheConnectionIsReportedOnce() {
        var detector = SlowSourceDetector()
        var notices: [SlowSourceNotice] = []
        for _ in 0..<12 {
            if let n = detector.add(reading(2.8), isBuffering: true, interval: 1) { notices.append(n) }
        }
        XCTAssertEqual(notices.count, 1)
        XCTAssertEqual(notices[0].neededMbps, 6, accuracy: 0.01)
        XCTAssertEqual(notices[0].availableMbps, 2.8, accuracy: 0.01)
    }

    func testAFastEnoughConnectionIsNeverReported() {
        var detector = SlowSourceDetector()
        for _ in 0..<30 {
            XCTAssertNil(detector.add(reading(9), isBuffering: true, interval: 1))
        }
    }

    func testNoReportWithoutBufferingOrWithTooFewReadings() {
        var detector = SlowSourceDetector()
        for _ in 0..<30 {
            XCTAssertNil(detector.add(reading(2), isBuffering: false, interval: 1), "it plays without stopping: no notice")
        }
        var early = SlowSourceDetector()
        for _ in 0..<5 {
            XCTAssertNil(early.add(reading(2), isBuffering: true, interval: 1), "too early to judge")
        }
    }

    func testAFullCacheIsNotASlowNetwork() {
        var detector = SlowSourceDetector()
        // The cache is full: the engine stops reading and its speed falls to 0. That says nothing.
        for _ in 0..<30 {
            XCTAssertNil(detector.add(reading(0.1, downloading: false), isBuffering: true, interval: 1))
        }
    }

    func testUnknownBitrateNeverReports() {
        var detector = SlowSourceDetector()
        let unknown = NetworkReading(downloadBytesPerSecond: 100_000, fileBitsPerSecond: nil, isDownloading: true)
        for _ in 0..<30 { XCTAssertNil(detector.add(unknown, isBuffering: true, interval: 1)) }
    }

    func testTheMessageGivesBothRates() {
        let text = SlowSourceBanner.message(SlowSourceNotice(neededMbps: 5.94, availableMbps: 2.81))
        XCTAssertTrue(text.contains("5") && text.contains("2"), text)
        XCTAssertTrue(text.contains("Mbit/s"))
    }
}
