import XCTest
import CndCoreBridge
@testable import CndIptvKit

@MainActor
final class UpNextModelTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "upnext.shelf.enabled")
        UserDefaults.standard.removeObject(forKey: "upnext.card.enabled")
        UserDefaults.standard.removeObject(forKey: "upnext.autoplay.enabled")
        UserDefaults.standard.removeObject(forKey: "upnext.countdown.seconds")
        UserDefaults.standard.removeObject(forKey: "upnext.saga.order")
        UserDefaults.standard.removeObject(forKey: "upnext.ai.enabled")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "upnext.shelf.enabled")
        UserDefaults.standard.removeObject(forKey: "upnext.card.enabled")
        UserDefaults.standard.removeObject(forKey: "upnext.autoplay.enabled")
        UserDefaults.standard.removeObject(forKey: "upnext.countdown.seconds")
        UserDefaults.standard.removeObject(forKey: "upnext.saga.order")
        UserDefaults.standard.removeObject(forKey: "upnext.ai.enabled")
        super.tearDown()
    }

    private func makeDummyItem(id: Int64, name: String, hash: String) -> IptvItemRecord {
        IptvItemRecord(
            id: id,
            sourceId: 1,
            seriesId: nil,
            stableHash: hash,
            kind: "movie",
            seasonNum: nil,
            episodeNum: nil,
            name: name,
            nameClean: name.lowercased(),
            year: 2020,
            groupTitle: "Movies",
            tvgId: nil,
            logoUrl: nil,
            chno: UInt32(id),
            host: "h",
            containerExt: "mp4",
            streamUrl: "http://example.com/\(id).mp4",
            userAgent: nil,
            referer: nil,
            headersJson: nil,
            catchupType: nil,
            catchupSource: nil,
            catchupDays: nil,
            plot: nil,
            imdbId: nil,
            imdbRating: 8.0,
            isFavorite: false,
            isBroken: false,
            resumePositionMs: 0,
            durationMs: 0,
            isCompleted: false
        )
    }

    private func makeDummyRecommendation(id: Int64, name: String, hash: String) -> Recommendation {
        Recommendation(
            item: makeDummyItem(id: id, name: name, hash: hash),
            reasonKind: .sagaNext,
            reasonText: "Suite de la saga",
            sagaPosition: SagaPosition(index: 2, total: 4),
            alreadyWatched: false
        )
    }

    func testThresholdDetectionLongMovie() {
        let model = UpNextModel(engineProvider: { nil })
        let rec = makeDummyRecommendation(id: 2, name: "Avengers 2", hash: "h2")
        model.setNextUpForTesting(rec)

        // 120-minute movie = 7,200,000 ms. 3% is 216,000 ms (< 240,000 ms).
        let duration: Int64 = 7_200_000

        // Remaining 300,000 ms (> 216,000 ms) -> should NOT be presented
        model.onPlaybackProgress(positionMs: 6_900_000, durationMs: duration)
        XCTAssertFalse(model.isNextUpCardPresented)

        // Remaining 200,000 ms (<= 216,000 ms) -> should be presented
        model.onPlaybackProgress(positionMs: 7_000_000, durationMs: duration)
        XCTAssertTrue(model.isNextUpCardPresented)
    }

    func testThresholdDetectionShortMovie() {
        let model = UpNextModel(engineProvider: { nil })
        let rec = makeDummyRecommendation(id: 2, name: "Clip", hash: "h2")
        model.setNextUpForTesting(rec)

        // 20-minute film = 1,200,000 ms. 3% is 36,000 ms.
        let duration: Int64 = 1_200_000

        // Remaining 40,000 ms (> 36,000 ms) -> should NOT be presented
        model.onPlaybackProgress(positionMs: 1_160_000, durationMs: duration)
        XCTAssertFalse(model.isNextUpCardPresented)

        // Remaining 30,000 ms (<= 36,000 ms) -> should be presented
        model.onPlaybackProgress(positionMs: 1_170_000, durationMs: duration)
        XCTAssertTrue(model.isNextUpCardPresented)
    }

    func testPostCreditsProtection() {
        let model = UpNextModel(engineProvider: { nil })
        let rec = makeDummyRecommendation(id: 2, name: "Avengers 2", hash: "h2")
        model.setNextUpForTesting(rec)

        let duration: Int64 = 7_200_000
        // Progress reaches threshold
        model.onPlaybackProgress(positionMs: 7_100_000, durationMs: duration)
        XCTAssertTrue(model.isNextUpCardPresented)

        // Countdown MUST NOT start during playback (protecting post-credits scene)
        XCTAssertEqual(model.countdownSecondsRemaining, model.countdownDuration)

        // Countdown only starts when playback actually ends
        model.onPlaybackEnded()
        XCTAssertTrue(model.isNextUpCardPresented)
    }

    func testDismissForCredits() {
        let model = UpNextModel(engineProvider: { nil })
        let rec = makeDummyRecommendation(id: 2, name: "Avengers 2", hash: "h2")
        model.setNextUpForTesting(rec)

        let duration: Int64 = 7_200_000
        model.onPlaybackProgress(positionMs: 7_100_000, durationMs: duration)
        XCTAssertTrue(model.isNextUpCardPresented)

        // User clicks "Générique"
        model.dismissForCredits()
        XCTAssertFalse(model.isNextUpCardPresented)
        XCTAssertTrue(model.isDismissedForCredits)

        // Further progress while watching credits does not bring card back
        model.onPlaybackProgress(positionMs: 7_150_000, durationMs: duration)
        XCTAssertFalse(model.isNextUpCardPresented)

        // Real end of file reached: card re-appears and auto-play initiates
        model.onPlaybackEnded()
        XCTAssertTrue(model.isNextUpCardPresented)
        XCTAssertFalse(model.isDismissedForCredits)
    }

    func testSafetyGuardrail3Chains() {
        let model = UpNextModel(engineProvider: { nil })
        let rec = makeDummyRecommendation(id: 2, name: "Episode 4", hash: "h4")
        model.setNextUpForTesting(rec)

        var playedNext = false
        model.setPlayHandler { _ in
            playedNext = true
        }

        // Simulate 3 consecutive auto-chains without interaction
        model.setAutoChainCountForTesting(3)

        // On playback end, prompt "Êtes-vous toujours là ?" instead of auto-playing
        model.onPlaybackEnded()
        XCTAssertTrue(model.isPromptingStillWatching)
        XCTAssertFalse(playedNext)

        // User confirms they are still watching
        model.confirmStillWatchingAndPlay()
        XCTAssertFalse(model.isPromptingStillWatching)
        XCTAssertTrue(playedNext)
        XCTAssertEqual(model.autoChainCount, 1)
    }

    func testSettingsToggles() {
        let model = UpNextModel(engineProvider: { nil })
        let rec = makeDummyRecommendation(id: 2, name: "Avengers 2", hash: "h2")
        model.setNextUpForTesting(rec)

        // Disable card
        model.isNextUpCardEnabled = false
        model.onPlaybackProgress(positionMs: 7_150_000, durationMs: 7_200_000)
        XCTAssertFalse(model.isNextUpCardPresented)

        // Re-enable card, disable auto-play
        model.isNextUpCardEnabled = true
        model.isAutoPlayNextEnabled = false

        model.onPlaybackEnded()
        XCTAssertTrue(model.isNextUpCardPresented)
        // Countdown should NOT start because autoPlay is false
        XCTAssertEqual(model.countdownSecondsRemaining, model.countdownDuration)
    }

    func testDismissItem() {
        let model = UpNextModel(engineProvider: { nil })
        let rec1 = makeDummyRecommendation(id: 1, name: "Movie 1", hash: "h1")
        let rec2 = makeDummyRecommendation(id: 2, name: "Movie 2", hash: "h2")
        model.setNextUpForTesting(rec1, recommendations: [rec1, rec2])

        XCTAssertEqual(model.nextUp?.item.stableHash, "h1")
        XCTAssertEqual(model.recommendations.count, 2)

        model.dismissItem(stableHash: "h1")
        XCTAssertEqual(model.recommendations.count, 1)
        XCTAssertEqual(model.nextUp?.item.stableHash, "h2")
    }
}
