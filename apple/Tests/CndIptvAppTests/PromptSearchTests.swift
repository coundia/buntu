import XCTest
import CndCoreBridge
import SwiftUI
@testable import CndIptvKit

/// PRD 33 in the app: results while typing, the answer after Enter, and what a tap on a result does.
final class FakeSearchBackend: AssistantBackend, @unchecked Sendable {
    private let lock = NSLock()
    var supportsPromptSearch: Bool { true }
    var local = SearchResponse(command: nil, hits: [], missingTitles: [], reply: "", resolvedBy: "local", latencyMs: 1, fallbackReason: nil)
    var aiResult: Result<SearchResponse, Error> = .success(
        SearchResponse(command: nil, hits: [], missingTitles: [], reply: "", resolvedBy: "local", latencyMs: 1, fallbackReason: nil)
    )
    var aiDelay: Duration = .zero
    private var storedLocalTexts: [String] = []
    private var storedAiTexts: [String] = []
    var localTexts: [String] { lock.withLock { storedLocalTexts } }
    var aiTexts: [String] { lock.withLock { storedAiTexts } }

    func aiResolveCommand(command: String, context: AiCommandContext, config: AiProviderConfig) async throws -> AiCommandResult {
        XCTFail("the prompt search must not use the old command path")
        throw CndError.Internal(message: "unused")
    }

    func aiTestProvider(config: AiProviderConfig) async throws -> AiProviderStatus {
        AiProviderStatus(ok: true, latencyMs: 1, model: "m", message: "ok")
    }

    func getItemById(itemId: Int64) throws -> IptvItemRecord? { nil }

    func searchLocal(text: String, context: SearchContext) -> SearchResponse {
        lock.withLock { storedLocalTexts.append(text) }
        return local
    }

    func searchWithAi(text: String, context: SearchContext, config: AiProviderConfig) async throws -> SearchResponse {
        let answer = lock.withLock { storedAiTexts.append(text); return aiResult } // the answer as scripted when asked
        if aiDelay > .zero { try await Task.sleep(for: aiDelay) }
        return try answer.get()
    }
}

func makeHit(_ kind: SearchKind, name: String, program: EpgProgramRecord? = nil, reason: String = "Titre correspondant", id: Int64 = 1) -> SearchHit {
    var series: SeriesRecord?
    var item: IptvItemRecord?
    if kind == .series {
        series = SeriesRecord(
            id: id, sourceId: 1, canonicalKey: "k\(id)", stableHash: "s\(id)", title: name, groupTitle: "FR | SERIES", posterUrl: nil,
            backdropUrl: nil, imdbId: nil, imdbRating: nil, plot: nil, episodeCount: 10, seasonCount: 1, isFavorite: false, isBroken: false
        )
    } else {
        item = makeChannel(id: id, name: name)
    }
    return SearchHit(kind: kind, item: item, series: series, program: program, reason: reason, score: 1, fromAssistant: false)
}

func makeProgram(title: String, start: Int64, end: Int64) -> EpgProgramRecord {
    EpgProgramRecord(id: 1, channelTvgId: "c", startTs: start, endTs: end, title: title, subtitle: nil, description: nil, category: nil, progressRatio: 0)
}

@MainActor
final class PromptSearchTests: XCTestCase {
    private var backend: FakeSearchBackend!
    private var model: AssistantModel!
    private var defaults: UserDefaults!
    private var suite = ""
    private var played: [String] = []
    private var guides: [String] = []
    private var movies: [String] = []
    private var seriesOpened: [String] = []
    private var searches: [String] = []
    private var dismissals = 0

    override func setUp() async throws {
        suite = "cnd.promptsearch.tests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)
        backend = FakeSearchBackend()
        let settings = AiProviderSettings(
            defaults: defaults, keychain: KeychainStore(service: "com.cnd.iptv.tests.ps.\(UUID().uuidString)"), bundledKeys: DefaultApiKeys()
        )
        model = AssistantModel(backend: backend, settings: settings, defaults: defaults, suggestionDelay: .milliseconds(20))
        played = []; guides = []; movies = []; seriesOpened = []; searches = []; dismissals = 0
        model.actions = AssistantActions(
            play: { [unowned self] in played.append($0.name) },
            showGuide: { [unowned self] in guides.append($0.name) },
            next: {}, previous: {},
            search: { [unowned self] in searches.append($0) },
            multiView: { _ in },
            openMovie: { [unowned self] in movies.append($0.name) },
            openSeries: { [unowned self] in seriesOpened.append($0.title) }
        )
        model.onDismiss = { [unowned self] in dismissals += 1 }
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func response(hits: [SearchHit], command: AiAction? = nil, missing: [String] = [], reply: String = "", by: String = "gemini", fallback: String? = nil) -> SearchResponse {
        SearchResponse(command: command, hits: hits, missingTitles: missing, reply: reply, resolvedBy: by, latencyMs: 5, fallbackReason: fallback)
    }

    // MARK: Typing

    func testResultsAppearWhileTypingFromTheLocalSearch() async {
        backend.local = response(hits: [makeHit(.movie, name: "Top Gun: Maverick")], by: "local")
        model.input = "un film avec Tom Cruise"
        let shown = await eventually { !self.model.liveHits.isEmpty }
        XCTAssertTrue(shown)
        XCTAssertEqual(backend.localTexts.last, "un film avec Tom Cruise")
        XCTAssertTrue(backend.aiTexts.isEmpty, "nothing goes to the provider before Enter")
    }

    func testClearingTheFieldClearsTheResults() async {
        backend.local = response(hits: [makeHit(.movie, name: "Inception")], by: "local")
        model.input = "inception"
        _ = await eventually { !self.model.liveHits.isEmpty }
        model.input = ""
        XCTAssertTrue(model.liveHits.isEmpty)
        XCTAssertNil(model.searchResponse)
    }

    // MARK: Enter

    func testEnterShowsTheAssistantsResultsAndKeepsThePaletteOpen() async {
        backend.aiResult = .success(response(
            hits: [makeHit(.movie, name: "Top Gun: Maverick", reason: "Avec Tom Cruise")],
            missing: ["Jerry Maguire (1996)"], reply: "Films avec Tom Cruise"
        ))
        model.input = "un film avec Tom Cruise"
        await model.submit()
        XCTAssertEqual(model.searchResponse?.reply, "Films avec Tom Cruise")
        XCTAssertEqual(model.liveHits.count, 1)
        XCTAssertEqual(model.searchResponse?.missingTitles, ["Jerry Maguire (1996)"])
        XCTAssertEqual(dismissals, 0)
        XCTAssertFalse(model.isResolving)
        XCTAssertEqual(model.history.first, "un film avec Tom Cruise")
    }

    func testADirectCommandIsPerformedAndClosesThePalette() async {
        backend.aiResult = .success(response(hits: [], command: .nextChannel, by: "local"))
        model.input = "chaîne suivante"
        await model.submit()
        XCTAssertEqual(dismissals, 1)
        XCTAssertNil(model.searchResponse)
    }

    func testNothingFoundHandsTheWordsToTheCatalogSearch() async {
        backend.aiResult = .success(response(hits: [], by: "local"))
        model.input = "zzzzz"
        await model.submit()
        XCTAssertEqual(searches, ["zzzzz"])
        XCTAssertEqual(dismissals, 1)
    }

    func testOnlyMissingTitlesStillShowsThem() async {
        backend.aiResult = .success(response(hits: [], missing: ["Jerry Maguire (1996)"]))
        model.input = "un film avec Tom Cruise"
        await model.submit()
        XCTAssertEqual(searches, [], "not a plain search: the assistant knew titles")
        XCTAssertEqual(dismissals, 0)
        XCTAssertEqual(model.searchResponse?.missingTitles.count, 1)
    }

    func testAProviderErrorIsShownWithAHint() async {
        backend.aiResult = .failure(CndError.Network(message: "clé refusée par le fournisseur"))
        model.input = "un film avec Tom Cruise"
        await model.submit()
        XCTAssertNotNil(model.errorMessage)
        XCTAssertNil(model.searchResponse)
    }

    func testAnAnswerForAnOlderQuestionIsDropped() async {
        backend.aiDelay = .milliseconds(150)
        backend.aiResult = .success(response(hits: [makeHit(.movie, name: "Old answer")]))
        model.input = "premier"
        let first = Task { await model.submit() }
        try? await Task.sleep(for: .milliseconds(30))
        model.cancel()
        await first.value
        XCTAssertNil(model.searchResponse, "cancelled: the late answer must not appear")
    }

    // MARK: Taps

    func testATapDoesWhatTheResultIs() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let t = Int64(now.timeIntervalSince1970)
        model.choose(makeHit(.live, name: "TF1"), now: now)
        model.choose(makeHit(.movie, name: "Inception"), now: now)
        model.choose(makeHit(.series, name: "Squid Game"), now: now)
        model.choose(makeHit(.program, name: "beIN 1", program: makeProgram(title: "PSG", start: t - 600, end: t + 600)), now: now)
        model.choose(makeHit(.program, name: "beIN 2", program: makeProgram(title: "OM", start: t + 3_600, end: t + 7_200)), now: now)
        XCTAssertEqual(played, ["TF1", "beIN 1"], "live and on-air programmes play")
        XCTAssertEqual(movies, ["Inception"])
        XCTAssertEqual(seriesOpened, ["Squid Game"])
        XCTAssertEqual(guides, ["beIN 2"], "a later programme opens the guide")
        XCTAssertEqual(dismissals, 5)
    }
}

final class SearchHitTextTests: XCTestCase {
    func testTitlesAndActions() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let t = Int64(now.timeIntervalSince1970)
        let onAir = makeHit(.program, name: "beIN 1", program: makeProgram(title: "PSG - OM", start: t - 60, end: t + 60))
        let later = makeHit(.program, name: "beIN 1", program: makeProgram(title: "PSG - OL", start: t + 600, end: t + 900))
        XCTAssertEqual(SearchHitText.title(onAir), "PSG - OM")
        XCTAssertEqual(SearchHitText.actionLabel(onAir, now: now), "Lire la chaîne")
        XCTAssertEqual(SearchHitText.actionLabel(later, now: now), "Voir le guide de la chaîne")
        XCTAssertEqual(SearchHitText.actionSymbol(later, now: now), "calendar")
        XCTAssertEqual(SearchHitText.actionLabel(makeHit(.movie, name: "Inception"), now: now), "Ouvrir la fiche du film")
        XCTAssertEqual(SearchHitText.title(makeHit(.series, name: "Squid Game")), "Squid Game")
    }

    func testTheSpokenLabelNamesWhyAndWhoSuggestedIt() {
        var hit = makeHit(.movie, name: "Top Gun: Maverick", reason: "Avec Tom Cruise")
        XCTAssertEqual(SearchHitText.accessibilityLabel(hit), "Top Gun: Maverick. Avec Tom Cruise")
        hit.fromAssistant = true
        XCTAssertEqual(SearchHitText.accessibilityLabel(hit), "Top Gun: Maverick. Avec Tom Cruise. Proposé par l'assistant")
    }
}

/// PRD 33: once a provider is active it works on the search itself, not only when Enter is pressed.
@MainActor
final class AutoSearchTests: XCTestCase {
    private var backend: FakeSearchBackend!
    private var settings: AiProviderSettings!
    private var model: AssistantModel!
    private var defaults: UserDefaults!
    private var suite = ""
    private var dismissals = 0
    private var searches: [String] = []

    override func setUp() async throws {
        suite = "cnd.autosearch.tests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)
        backend = FakeSearchBackend()
        settings = AiProviderSettings(
            defaults: defaults, keychain: KeychainStore(service: "com.cnd.iptv.tests.auto.\(UUID().uuidString)"), bundledKeys: DefaultApiKeys()
        )
        settings.choice = .gemini
        settings.apiKey = "test-key"
        settings.consent = true
        model = AssistantModel(
            backend: backend, settings: settings, defaults: defaults,
            suggestionDelay: .milliseconds(10), autoSearchDelay: .milliseconds(30)
        )
        dismissals = 0
        searches = []
        model.actions = AssistantActions(search: { [unowned self] in searches.append($0) })
        model.onDismiss = { [unowned self] in dismissals += 1 }
        backend.local = SearchResponse(
            command: nil, hits: [makeHit(.movie, name: "Local result")], missingTitles: [], reply: "", resolvedBy: "local", latencyMs: 1, fallbackReason: nil
        )
        backend.aiResult = .success(SearchResponse(
            command: nil, hits: [makeHit(.movie, name: "Assistant result")], missingTitles: ["Jerry Maguire (1996)"],
            reply: "Films avec Tom Cruise", resolvedBy: "gemini", latencyMs: 9, fallbackReason: nil
        ))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func testAnActiveProviderRefinesTheSearchWhileTyping() async {
        model.input = "un film avec Tom Cruise"
        let refined = await eventually { self.model.searchResponse?.resolvedBy == "gemini" }
        XCTAssertTrue(refined)
        XCTAssertEqual(backend.aiTexts, ["un film avec Tom Cruise"])
        XCTAssertEqual(model.liveHits.first.map(SearchHitText.title), "Assistant result")
        XCTAssertEqual(dismissals, 0, "the palette stays open")
        XCTAssertFalse(model.isRefining)
    }

    func testTheLocalResultsAreThereBeforeTheProviderAnswers() async {
        backend.aiDelay = .milliseconds(300)
        model.input = "un film avec Tom Cruise"
        let local = await eventually { self.model.liveHits.first.map(SearchHitText.title) == "Local result" }
        XCTAssertTrue(local)
        let refining = await eventually { self.model.isRefining }
        XCTAssertTrue(refining)
        let done = await eventually(timeout: 5) { self.model.searchResponse != nil }
        XCTAssertTrue(done)
    }

    func testEnterReusesTheAnswerAlreadyGivenForTheSameText() async {
        model.input = "un film avec Tom Cruise"
        _ = await eventually { self.model.searchResponse != nil }
        await model.submit()
        XCTAssertEqual(backend.aiTexts.count, 1, "no second call for the same text")
        XCTAssertEqual(model.searchResponse?.reply, "Films avec Tom Cruise")
        XCTAssertEqual(model.history.first, "un film avec Tom Cruise")
    }

    func testEachDistinctTextIsSentOnceNotOnEveryKeystroke() async {
        model.input = "un fil"
        model.input = "un film"
        model.input = "un film avec"
        model.input = "un film avec Tom Cruise"
        _ = await eventually { self.model.searchResponse != nil }
        try? await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(backend.aiTexts, ["un film avec Tom Cruise"], "only the text the user stopped on")
    }

    func testNothingIsSentWithoutAReadyProviderOrWhenTurnedOff() async {
        settings.consent = false
        model.input = "un film avec Tom Cruise"
        _ = await eventually { !self.model.liveHits.isEmpty }
        try? await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(backend.aiTexts.isEmpty, "no consent: nothing leaves")

        settings.consent = true
        settings.autoSearch = false
        model.input = "une série coréenne"
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(backend.aiTexts.isEmpty, "switched off: only Enter sends")

        settings.autoSearch = true
        settings.choice = .localOnly
        model.input = "une comédie française"
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(backend.aiTexts.isEmpty, "local mode")
    }

    func testVeryShortTextIsNotSent() async {
        model.input = "ab"
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(backend.aiTexts.isEmpty)
    }

    func testACommandFoundWhileTypingIsNeverPerformedUntilEnter() async {
        backend.aiResult = .success(SearchResponse(command: .nextChannel, hits: [], missingTitles: [], reply: "", resolvedBy: "local", latencyMs: 1, fallbackReason: nil))
        model.input = "chaîne suivante"
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(dismissals, 0)
        XCTAssertNil(model.searchResponse)
    }

    func testAFailingProviderLeavesTheLocalResultsAloneAndSilent() async {
        backend.aiResult = .failure(CndError.Network(message: "délai dépassé"))
        model.input = "un film avec Tom Cruise"
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(model.errorMessage, "typing never shows an error")
        XCTAssertEqual(model.liveHits.first.map(SearchHitText.title), "Local result")
        XCTAssertFalse(model.isRefining)
    }

    func testTypingAgainDropsTheAnswerOfTheOlderText() async {
        backend.aiDelay = .milliseconds(150)
        model.input = "un film avec Tom Cruise"
        _ = await eventually { self.model.isRefining }
        // The first answer ("Films avec Tom Cruise") is still on its way when the text changes.
        backend.aiResult = .success(SearchResponse(
            command: nil, hits: [makeHit(.series, name: "Autre résultat")], missingTitles: [], reply: "Autre", resolvedBy: "gemini", latencyMs: 1, fallbackReason: nil
        ))
        model.input = "autre chose"
        let settled = await eventually(timeout: 5) { self.model.searchResponse?.reply == "Autre" }
        XCTAssertTrue(settled, "\(String(describing: model.searchResponse?.reply))")
        XCTAssertEqual(backend.aiTexts, ["un film avec Tom Cruise", "autre chose"])
        try? await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(model.searchResponse?.reply, "Autre", "the late answer for the old text never replaces it")
    }

    func testTheConsentIsTheOnlyThingToAskWhenAProviderIsChosen() {
        settings.consent = false
        XCTAssertTrue(settings.needsConsentOnly)
        settings.consent = true
        XCTAssertFalse(settings.needsConsentOnly)
        settings.apiKey = ""
        settings.consent = false
        XCTAssertFalse(settings.needsConsentOnly, "a missing key is a different problem")
    }

    func testAutoSearchIsOnByDefaultAndRemembered() {
        XCTAssertTrue(settings.autoSearch)
        settings.autoSearch = false
        let again = AiProviderSettings(defaults: defaults, keychain: KeychainStore(service: "x.\(UUID().uuidString)"), bundledKeys: DefaultApiKeys())
        XCTAssertFalse(again.autoSearch)
    }
}

/// The AI search button of the Films and Séries screens opens the assistant with a useful start.
final class AssistantStarterTests: XCTestCase {
    func testTheSearchFieldBecomesTheQuestionElseAStarterIsUsed() {
        typealias Catalog = VodCatalogView<IptvItemRecord, EmptyView>
        XCTAssertEqual(Catalog.assistantPhrase(typed: "  avec Tom Cruise ", starter: "un film "), "avec Tom Cruise")
        XCTAssertEqual(Catalog.assistantPhrase(typed: "", starter: "un film "), "un film ")
        XCTAssertEqual(Catalog.assistantPhrase(typed: "   ", starter: "une série "), "une série ")
    }
}
