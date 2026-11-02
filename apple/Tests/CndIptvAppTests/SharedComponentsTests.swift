import XCTest
import CoreGraphics
import CndCoreBridge
@testable import CndIptvApp

final class ImageThumbnailCacheTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try TestFixtures.makeTempDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private let url = URL(string: "http://logos.test/a.png")!

    func testDownsamplesToRequestedPixelBudget() async throws {
        let data = TestFixtures.pngData(width: 400, height: 200)
        let cache = ImageThumbnailCache(directory: directory, loader: { _ in data })
        let image = await cache.image(for: url, maxPixel: 120)
        let decoded = try XCTUnwrap(image)
        XCTAssertEqual(max(decoded.width, decoded.height), 120)
        XCTAssertEqual(decoded.width, 120)
        XCTAssertEqual(decoded.height, 60)
    }

    func testMemoryThenDiskCacheAvoidNetwork() async throws {
        let data = TestFixtures.pngData(width: 400, height: 400)
        let counter = CallCounter()
        let loader: ImageThumbnailCache.Loader = { _ in counter.increment(); return data }

        let cache = ImageThumbnailCache(directory: directory, loader: loader)
        _ = await cache.image(for: url, maxPixel: 120)
        _ = await cache.image(for: url, maxPixel: 120)
        XCTAssertEqual(counter.count, 1, "second hit must come from memory")

        // A fresh instance has an empty memory cache: the file in Caches/CndThumbnails serves it.
        let reopened = ImageThumbnailCache(directory: directory, loader: { _ in
            XCTFail("disk cache should have served the image")
            throw URLError(.notConnectedToInternet)
        })
        let image = await reopened.image(for: url, maxPixel: 120)
        XCTAssertNotNil(image)
        XCTAssertEqual(image.map { max($0.width, $0.height) }, 120)
    }

    func testDifferentPixelBudgetsAreCachedSeparately() async throws {
        let data = TestFixtures.pngData(width: 800, height: 800)
        let counter = CallCounter()
        let cache = ImageThumbnailCache(directory: directory, loader: { _ in counter.increment(); return data })
        let logo = await cache.image(for: url, maxPixel: ThumbnailSize.tvLogo.maxPixel)
        let poster = await cache.image(for: url, maxPixel: ThumbnailSize.poster.maxPixel)
        XCTAssertEqual(logo?.width, 120)
        XCTAssertEqual(poster?.width, 360)
        XCTAssertEqual(counter.count, 2)
    }

    func testConcurrentRequestsShareOneDownload() async throws {
        let data = TestFixtures.pngData(width: 300, height: 300)
        let counter = CallCounter()
        let cache = ImageThumbnailCache(directory: directory, loader: { _ in
            counter.increment()
            try await Task.sleep(for: .milliseconds(100))
            return data
        })
        let target = url
        await withTaskGroup(of: CGImage?.self) { group in
            for _ in 0..<8 { group.addTask { await cache.image(for: target, maxPixel: 120) } }
            for await image in group { XCTAssertNotNil(image) }
        }
        XCTAssertEqual(counter.count, 1)
    }

    func testFailuresAreNotCached() async throws {
        let counter = CallCounter()
        let data = TestFixtures.pngData(width: 100, height: 100)
        let cache = ImageThumbnailCache(directory: directory, loader: { _ in
            counter.increment()
            if counter.count == 1 { throw URLError(.timedOut) }
            return data
        })
        let first = await cache.image(for: url, maxPixel: 120)
        XCTAssertNil(first)
        let second = await cache.image(for: url, maxPixel: 120)
        XCTAssertNotNil(second)
        let garbage = await ImageThumbnailCache(directory: directory, loader: { _ in Data("not an image".utf8) })
            .image(for: URL(string: "http://logos.test/bad.png")!, maxPixel: 120)
        XCTAssertNil(garbage)
    }

    func testRejectsNonHttpSchemes() async {
        let cache = ImageThumbnailCache(directory: directory, loader: { _ in
            XCTFail("must not load")
            return Data()
        })
        let ftp = await cache.image(for: "ftp://x/y.png", size: .tvLogo)
        let empty = await cache.image(for: "", size: .tvLogo)
        XCTAssertNil(ftp)
        XCTAssertNil(empty)
    }

    func testDiskTrimRemovesOldestFirst() throws {
        for index in 0..<4 {
            let file = directory.appendingPathComponent("f\(index).png")
            try Data(count: 1000).write(to: file)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: TimeInterval(1000 + index))], ofItemAtPath: file.path
            )
        }
        ImageThumbnailCache.trimDisk(directory: directory, limitBytes: 2500)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(remaining, ["f2.png", "f3.png"])
    }
}

@MainActor
final class SearchFilterStateTests: XCTestCase {
    func testDebouncePublishesOnlyTheLastValue() async throws {
        let state = SearchFilterState(debounce: .milliseconds(120))
        state.text = "a"
        state.text = "ab"
        state.text = "abc"
        XCTAssertEqual(state.query, "", "nothing is published while typing")

        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(state.query, "")
        let published = await eventually { state.query == "abc" }
        XCTAssertTrue(published)
    }

    func testEachPauseRestartsTheWindow() async throws {
        let state = SearchFilterState(debounce: .milliseconds(120))
        state.text = "x"
        try await Task.sleep(for: .milliseconds(80))
        state.text = "xy"
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(state.query, "", "the second keystroke restarted the 120 ms window")
        let published = await eventually { state.query == "xy" }
        XCTAssertTrue(published)
    }

    func testCommitSkipsTheDebounce() {
        let state = SearchFilterState(debounce: .seconds(10))
        state.text = "news"
        state.commit()
        XCTAssertEqual(state.query, "news")
    }

    func testSignatureTracksFiltersAndSort() async {
        let state = SearchFilterState()
        let initial = state.signature
        state.group = "Sport"
        XCTAssertNotEqual(state.signature, initial)
        XCTAssertTrue(state.hasActiveFilter)
        state.resetFilters()
        XCTAssertEqual(state.signature, initial)
        state.ascending = false
        XCTAssertNotEqual(state.signature, initial)
    }
}

final class ChannelPresentationTests: XCTestCase {
    func testQualityBadges() {
        XCTAssertEqual(ChannelQuality.detect(in: "TF1 4K"), .uhd)
        XCTAssertEqual(ChannelQuality.detect(in: "FR: Canal+ UHD"), .uhd)
        XCTAssertEqual(ChannelQuality.detect(in: "France 2 FHD"), .fullHD)
        XCTAssertEqual(ChannelQuality.detect(in: "M6 HD"), .hd)
        XCTAssertEqual(ChannelQuality.detect(in: "M6 (HD)"), .hd)
        XCTAssertNil(ChannelQuality.detect(in: "Chad TV"))
        XCTAssertNil(ChannelQuality.detect(in: "Arte"))
    }

    func testProgressRatioIsClamped() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(EpgProgress.ratio(start: 900, end: 1_100, now: now), 0.5, accuracy: 0.001)
        XCTAssertEqual(EpgProgress.ratio(start: 1_100, end: 1_200, now: now), 0)
        XCTAssertEqual(EpgProgress.ratio(start: 0, end: 500, now: now), 1)
        XCTAssertEqual(EpgProgress.ratio(start: 5, end: 5, now: now), 0)
    }
}
