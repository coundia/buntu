import XCTest
import CndCoreBridge
@testable import CndIptvKit

/// PRD 31: spoken texts, announcements, and the choice of accessible tracks.
@MainActor
final class AccessibilityTests: XCTestCase {
    // MARK: Spoken text

    func testDurationsAreSpokenInFrench() {
        XCTAssertEqual(A11yText.duration(milliseconds: 6_480_000), "1 heure et 48 minutes")
        XCTAssertEqual(A11yText.duration(milliseconds: 720_000), "12 minutes")
        XCTAssertEqual(A11yText.duration(milliseconds: 12_000), "12 secondes")
    }

    func testPositionSaysBothTimes() {
        let text = A11yText.position(milliseconds: 720_000, durationMs: 6_480_000)
        XCTAssertTrue(text.contains("12 minutes"), text)
        XCTAssertTrue(text.contains(" sur "), text)
        XCTAssertTrue(text.contains("1 heure"), text)
        XCTAssertEqual(A11yText.position(milliseconds: 60_000, durationMs: 0), A11yText.duration(milliseconds: 60_000))
    }

    func testPercentRatingAndSpeed() {
        XCTAssertEqual(A11yText.percent(0.4), "40 pour cent")
        XCTAssertEqual(A11yText.percent(7), "100 pour cent")
        XCTAssertEqual(A11yText.percent(-1), "0 pour cent")
        XCTAssertEqual(A11yText.rating(7.5), "7,5 sur 10")
        XCTAssertEqual(A11yText.rating(8), "8 sur 10")
        XCTAssertEqual(A11yText.speed(1.5), "vitesse 1,5")
        XCTAssertEqual(A11yText.watched(0.4), "vu à 40 pour cent")
    }

    func testAbbreviationsAreSpelledOut() {
        XCTAssertEqual(A11yText.spoken("25 i/s"), "25 images par seconde")
        XCTAssertEqual(A11yText.spoken("Film VOSTFR"), "Film version originale sous-titrée")
    }

    func testChannelSentence() {
        let text = A11yText.channel(
            name: "TF1", number: 1, isPlaying: true, isFavorite: true, isBroken: false,
            nowTitle: "Journal", timeRange: "20:00 – 20:45"
        )
        XCTAssertEqual(text, "TF1, chaîne 1, en cours de lecture, favori. En ce moment : Journal, 20:00 – 20:45")
        XCTAssertEqual(
            A11yText.channel(name: "Arte", number: nil, isPlaying: false, isFavorite: false, isBroken: true, nowTitle: nil, timeRange: nil),
            "Arte, en panne"
        )
    }

    func testChannelSentenceNeverContainsAnAddress() {
        let text = A11yText.channel(name: "TF1", number: 1, isPlaying: false, isFavorite: false, isBroken: false, nowTitle: "x", timeRange: nil)
        XCTAssertFalse(text.contains("http"))
    }

    // MARK: Announcer

    private func announcer() -> (AccessibilityAnnouncer, () -> [String], (TimeInterval) -> Void) {
        let a = AccessibilityAnnouncer(repeatWindow: 30)
        var spoken: [(String, AnnouncementPriority)] = []
        var clock = Date(timeIntervalSince1970: 1_700_000_000)
        a.sink = { text, priority in spoken.append((text, priority)) }
        a.now = { clock }
        return (a, { spoken.map(\.0) }, { clock.addTimeInterval($0) })
    }

    func testAnnouncementIsDeliveredOnce() {
        let (a, spoken, _) = announcer()
        XCTAssertTrue(a.announce("Reconnexion au flux…"))
        XCTAssertEqual(spoken(), ["Reconnexion au flux…"])
    }

    func testTheSameAnnouncementIsNotRepeatedInALoop() {
        let (a, spoken, advance) = announcer()
        a.announce("Reconnexion au flux…")
        advance(5)
        XCTAssertFalse(a.announce("Reconnexion au flux…"))
        advance(40)
        XCTAssertTrue(a.announce("Reconnexion au flux…"))
        XCTAssertEqual(spoken().count, 2)
    }

    func testEmptyTextIsNeverSpokenAndForceBypassesTheWindow() {
        let (a, spoken, _) = announcer()
        XCTAssertFalse(a.announce("   "))
        a.announce("Erreur")
        XCTAssertTrue(a.announce("Erreur", force: true))
        XCTAssertEqual(spoken(), ["Erreur", "Erreur"])
    }

    func testDifferentTextsAreAllSpoken() {
        let (a, spoken, _) = announcer()
        a.announce("TF1, en direct")
        a.announce("France 2, en direct")
        XCTAssertEqual(spoken().count, 2)
    }

    func testPriorityIsPassedToTheSink() {
        let a = AccessibilityAnnouncer()
        var seen: AnnouncementPriority?
        a.sink = { _, priority in seen = priority }
        a.announce("Erreur", priority: .high)
        XCTAssertEqual(seen, .high)
    }

    func testToastsAreAnnounced() {
        let spoken = SpokenBox()
        let center = AccessibilityAnnouncer.shared
        let original = center.sink
        center.sink = { text, priority in spoken.items.append((text, priority)) }
        defer { center.sink = original }
        ToastCenter().show("Source ajoutée \(UUID())")
        ToastCenter().show("Échec \(UUID())", isError: true)
        XCTAssertEqual(spoken.items.count, 2)
        XCTAssertEqual(spoken.items.last?.1, .high)
    }

    final class SpokenBox { var items: [(String, AnnouncementPriority)] = [] }

    // MARK: Tracks

    private func track(_ id: String, _ lang: String?, selected: Bool = false, sdh: Bool = false, ad: Bool = false) -> MediaTrack {
        MediaTrack(id: id, title: "Piste \(id)", language: lang, isSelected: selected, isHearingImpaired: sdh, isAudioDescription: ad)
    }

    func testDisplayTitleNamesAccessibleTracks() {
        XCTAssertEqual(track("1", "fra", sdh: true).displayTitle, "Piste 1 (SDH)")
        XCTAssertEqual(track("2", "fra", ad: true).displayTitle, "Piste 2 (audiodescription)")
        XCTAssertEqual(track("3", "fra").displayTitle, "Piste 3")
        let named = MediaTrack(id: "4", title: "Français SDH", language: "fra", isSelected: false, isHearingImpaired: true)
        XCTAssertEqual(named.displayTitle, "Français SDH", "not repeated when the name already says it")
    }

    func testNothingIsChosenUnlessTheSystemAsks() {
        let tracks = [track("1", "fra", sdh: true)]
        XCTAssertNil(AccessibleTrackPolicy.subtitle(in: tracks, preferences: AccessibleTrackPreferences()))
        XCTAssertNil(AccessibleTrackPolicy.audio(in: [track("1", "fra", ad: true)], preferences: AccessibleTrackPreferences()))
    }

    func testSDHSubtitleMatchesThePreferredLanguage() {
        let tracks = [track("1", "eng", sdh: true), track("2", "fra", sdh: true), track("3", "fra")]
        let prefs = AccessibleTrackPreferences(wantsHearingImpairedSubtitles: true, languages: ["fr-FR", "en"])
        XCTAssertEqual(AccessibleTrackPolicy.subtitle(in: tracks, preferences: prefs), "2")
    }

    func testAudioDescriptionMatchesThePreferredLanguageAndFallsBack() {
        let prefs = AccessibleTrackPreferences(wantsAudioDescription: true, languages: ["fr"])
        XCTAssertEqual(AccessibleTrackPolicy.audio(in: [track("1", "eng", ad: true), track("2", "fre", ad: true)], preferences: prefs), "2")
        XCTAssertEqual(AccessibleTrackPolicy.audio(in: [track("1", "eng", ad: true)], preferences: prefs), "1", "no match: still better than none")
        XCTAssertNil(AccessibleTrackPolicy.audio(in: [track("1", "fra")], preferences: prefs), "no description track at all")
    }

    func testAnAlreadySelectedAccessibleTrackIsLeftAlone() {
        let prefs = AccessibleTrackPreferences(wantsHearingImpairedSubtitles: true, languages: ["fr"])
        XCTAssertNil(AccessibleTrackPolicy.subtitle(in: [track("1", "fra", selected: true, sdh: true)], preferences: prefs))
    }

    func testLanguageCodesAreNormalised() {
        XCTAssertEqual(AccessibleTrackPolicy.languageCode("fra"), "fr")
        XCTAssertEqual(AccessibleTrackPolicy.languageCode("fre"), "fr")
        XCTAssertEqual(AccessibleTrackPolicy.languageCode("fr-FR"), "fr")
        XCTAssertEqual(AccessibleTrackPolicy.languageCode("EN_us"), "en")
        XCTAssertNil(AccessibleTrackPolicy.languageCode(nil))
    }
}
