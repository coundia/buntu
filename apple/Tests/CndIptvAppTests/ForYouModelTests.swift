import XCTest
import CndCoreBridge
@testable import CndIptvKit

/// PRD 34 in the app: the « Pour vous » shelves of films, series and TV never mix, the AI only replaces
/// a shelf with a valid answer, and the feedback reaches the engine for the right kind.
final class FakeForYouBackend: ForYouBackend, @unchecked Sendable {
    private let lock = NSLock()
    var local: [RecoKind: [RecoShelf]] = [:]
    var refined: [RecoKind: [RecoShelf]] = [:]
    private var storedRefineCalls: [(kind: RecoKind, config: AiProviderConfig, sendRecent: Bool)] = []
    private var storedDismissed: [String] = []
    private var storedLess: [(RecoKind, String)] = []
    private var storedResets: [RecoKind] = []

    var refineCalls: [(kind: RecoKind, config: AiProviderConfig, sendRecent: Bool)] { lock.withLock { storedRefineCalls } }
    var dismissed: [String] { lock.withLock { storedDismissed } }
    var less: [(RecoKind, String)] { lock.withLock { storedLess } }
    var resets: [RecoKind] { lock.withLock { storedResets } }

    func localShelves(kind: RecoKind, limit: UInt32, utcOffsetMinutes: Int32) throws -> [RecoShelf] { local[kind] ?? [] }

    func refinedShelves(
        kind: RecoKind, config: AiProviderConfig, limit: UInt32, sendRecentTitles: Bool,
        locale: String, utcOffsetMinutes: Int32
    ) async -> [RecoShelf] {
        lock.withLock { storedRefineCalls.append((kind, config, sendRecentTitles)) }
        return refined[kind] ?? local[kind] ?? []
    }

    func dismiss(stableHash: String) throws { lock.withLock { storedDismissed.append(stableHash) } }
    func lessLikeThis(kind: RecoKind, stableHash: String) throws { lock.withLock { storedLess.append((kind, stableHash)) } }
    func resetTaste(kind: RecoKind) throws { lock.withLock { storedResets.append(kind) } }

    // Lot 34.5: the model of Apple.
    var appleStart: AppleRerankStart = .skip
    var appleFinished: [RecoShelf] = []
    private var storedPrepares: [RecoKind] = []
    private var storedFinishes: [(request: AppleRerankRequest, answer: String)] = []
    var prepares: [RecoKind] { lock.withLock { storedPrepares } }
    var finishes: [(request: AppleRerankRequest, answer: String)] { lock.withLock { storedFinishes } }

    func prepareAppleRerank(kind: RecoKind, limitPerShelf: UInt32, locale: String, utcOffsetMinutes: Int32) throws -> AppleRerankStart {
        lock.withLock { storedPrepares.append(kind) }
        return appleStart
    }

    func finishAppleRerank(request: AppleRerankRequest, answer: String) throws -> [RecoShelf] {
        lock.withLock { storedFinishes.append((request, answer)) }
        return appleFinished
    }
}

/// A model on this device that answers as scripted.
final class FakeOnDeviceModel: OnDeviceTextModel, @unchecked Sendable {
    private let lock = NSLock()
    var isAvailable = true
    var unavailableReason: String? { isAvailable ? nil : "indisponible" }
    var result: Result<String, Error> = .success("{}")
    private var storedPrompts: [(system: String, user: String)] = []
    var prompts: [(system: String, user: String)] { lock.withLock { storedPrompts } }

    func respond(system: String, user: String) async throws -> String {
        lock.withLock { storedPrompts.append((system, user)) }
        return try result.get()
    }
}

private func appleRequest(_ kind: RecoKind) -> AppleRerankRequest {
    AppleRerankRequest(
        kind: kind, system: "RULES", user: "CANDIDATES", now: 1_000, candidatesHash: "h",
        limitPerShelf: 12, locale: "fr-FR", utcOffsetMinutes: 60
    )
}

private func movie(_ id: Int64, _ name: String = "Film") -> IptvItemRecord {
    var item = makeChannel(id: id, name: "\(name) \(id)", hash: "m\(id)")
    item.kind = "movie"
    return item
}

private func series(_ id: Int64, _ title: String = "Série") -> SeriesRecord {
    SeriesRecord(
        id: id, sourceId: 1, canonicalKey: "k\(id)", stableHash: "s\(id)", title: "\(title) \(id)", groupTitle: "FR | SERIES",
        posterUrl: nil, backdropUrl: nil, imdbId: nil, imdbRating: nil, plot: nil, episodeCount: 10, seasonCount: 1,
        isFavorite: false, isBroken: false
    )
}

private func episode(_ id: Int64, of seriesId: Int64) -> IptvItemRecord {
    var item = makeChannel(id: id, name: "Épisode \(id)", hash: "e\(id)")
    item.kind = "episode"
    item.seriesId = seriesId
    return item
}

private func channel(_ id: Int64, tvgId: String? = nil) -> IptvItemRecord {
    var item = makeChannel(id: id, name: "Chaîne \(id)", hash: "c\(id)")
    item.tvgId = tvgId
    return item
}

private func program(on tvgId: String) -> EpgProgramRecord {
    EpgProgramRecord(id: 1, channelTvgId: tvgId, startTs: 0, endTs: 3600, title: "Journal", subtitle: nil, description: nil, category: nil, progressRatio: 0.5)
}

private func card(item: IptvItemRecord? = nil, series: SeriesRecord? = nil, program: EpgProgramRecord? = nil, next: IptvItemRecord? = nil) -> RecoCard {
    RecoCard(item: item, series: series, program: program, nextEpisode: next, reasonText: "Parce que", aiReason: false)
}

private func shelf(_ kind: RecoKind, _ cards: [RecoCard], id: String = "forYou", refinedBy: String? = nil, kindOfShelf: RecoShelfKind = .forYou) -> RecoShelf {
    RecoShelf(id: id, kind: kind, shelf: kindOfShelf, title: "Pour vous", items: cards, refinedBy: refinedBy, note: nil)
}

// MARK: - The kind lock

final class ForYouKindLockTests: XCTestCase {
    func testAFilmBelongsOnlyToTheFilmShelves() {
        let film = card(item: movie(1))
        XCTAssertTrue(ForYouModel.belongs(.movies, film))
        XCTAssertFalse(ForYouModel.belongs(.series, film))
        XCTAssertFalse(ForYouModel.belongs(.live, film))
    }

    func testASeriesBelongsOnlyToTheSeriesShelves() {
        let show = card(series: series(1))
        XCTAssertTrue(ForYouModel.belongs(.series, show))
        XCTAssertFalse(ForYouModel.belongs(.movies, show))
        XCTAssertFalse(ForYouModel.belongs(.live, show))
    }

    func testAChannelBelongsOnlyToTheTvShelves() {
        let live = card(item: channel(1, tvgId: "tf1"))
        XCTAssertTrue(ForYouModel.belongs(.live, live))
        XCTAssertFalse(ForYouModel.belongs(.movies, live))
        XCTAssertFalse(ForYouModel.belongs(.series, live))
    }

    func testTheNextEpisodeMustBeOfTheSameSeries() {
        XCTAssertTrue(ForYouModel.belongs(.series, card(series: series(1), next: episode(10, of: 1))))
        XCTAssertFalse(ForYouModel.belongs(.series, card(series: series(1), next: episode(11, of: 2))), "an episode of another series is refused")
        XCTAssertFalse(ForYouModel.belongs(.series, card(series: series(1), next: movie(12))), "a film is not an episode")
    }

    func testAProgramMustBeOnTheChannelOfTheCard() {
        XCTAssertTrue(ForYouModel.belongs(.live, card(item: channel(1, tvgId: "tf1"), program: program(on: "tf1"))))
        XCTAssertFalse(ForYouModel.belongs(.live, card(item: channel(1, tvgId: "tf1"), program: program(on: "m6"))))
    }

    func testAMixedCardIsRefused() {
        XCTAssertFalse(ForYouModel.belongs(.movies, card(item: movie(1), series: series(1))))
        XCTAssertFalse(ForYouModel.belongs(.series, card(item: movie(1), series: series(1))))
        XCTAssertFalse(ForYouModel.belongs(.movies, card()), "an empty card is nothing")
    }

    func testFilteringDropsForeignCardsAndEmptyShelves() {
        let mixed = shelf(.movies, [card(item: movie(1)), card(series: series(2)), card(item: channel(3, tvgId: "x"))])
        let onlyForeign = shelf(.movies, [card(series: series(4))], id: "other")
        let result = ForYouModel.filtered(.movies, [mixed, onlyForeign])

        XCTAssertEqual(result.count, 1, "a shelf left empty disappears")
        XCTAssertEqual(result[0].items.count, 1)
        XCTAssertEqual(result[0].items[0].item?.stableHash, "m1")
        XCTAssertEqual(result[0].kind, .movies)
    }

    func testTheGuideStaleBannerSurvivesWithoutCards() {
        let banner = shelf(.live, [], id: "stale", kindOfShelf: .guideStale)
        XCTAssertEqual(ForYouModel.filtered(.live, [banner]).count, 1)
    }

    func testTheHashIsTheSeriesOneForASeriesCard() {
        XCTAssertEqual(ForYouModel.hash(of: card(series: series(7), next: episode(70, of: 7))), "s7")
        XCTAssertEqual(ForYouModel.hash(of: card(item: movie(8))), "m8")
        XCTAssertEqual(ForYouModel.hash(of: card()), "")
    }

    func testTheUtcOffsetIsInMinutes() {
        let paris = TimeZone(identifier: "Europe/Paris")!
        let winter = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14
        XCTAssertEqual(ForYouModel.utcOffsetMinutes(paris, at: winter), 60)
        XCTAssertEqual(ForYouModel.utcOffsetMinutes(TimeZone(secondsFromGMT: 0)!, at: winter), 0)
    }
}

// MARK: - The model

@MainActor
final class ForYouModelTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""
    private var settings: AiProviderSettings!
    private var backend: FakeForYouBackend!
    private var hub: ForYouHub!
    private var onDevice: FakeOnDeviceModel!

    override func setUp() async throws {
        suite = "cnd.foryou.tests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)
        settings = AiProviderSettings(
            defaults: defaults,
            keychain: KeychainStore(service: "com.cnd.iptv.tests.foryou.\(UUID().uuidString)"),
            bundledKeys: DefaultApiKeys()
        )
        backend = FakeForYouBackend()
        onDevice = FakeOnDeviceModel()
        hub = ForYouHub(ai: settings, defaults: defaults, onDevice: onDevice, backend: { [unowned self] in backend })
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    /// An Ollama-like server on this machine: ready with no key and no consent.
    private func useLocalServer() {
        settings.choice = .openAiCompatible
        settings.baseURL = "http://localhost:11434/v1"
        settings.model = "llama3"
    }

    func testTheRowsAreOnByDefaultAndTheRemoteTitlesAreOff() {
        XCTAssertTrue(hub.moviesEnabled)
        XCTAssertTrue(hub.seriesEnabled)
        XCTAssertTrue(hub.liveEnabled)
        XCTAssertTrue(hub.aiRefine)
        XCTAssertFalse(hub.sendRecentTitles, "recent titles never go to a remote provider unless asked")
    }

    func testEachKindHasItsOwnModelAndSwitch() {
        XCTAssertEqual(hub.model(for: .movies).kind, .movies)
        XCTAssertEqual(hub.model(for: .series).kind, .series)
        XCTAssertEqual(hub.model(for: .live).kind, .live)
        hub.seriesEnabled = false
        XCTAssertTrue(hub.isEnabled(.movies))
        XCTAssertFalse(hub.isEnabled(.series))
        XCTAssertTrue(hub.isEnabled(.live))
        XCTAssertFalse(defaults.bool(forKey: ForYouHub.seriesKey), "the switch is kept")
    }

    func testTheLocalShelvesShowWithoutAnyAi() async {
        backend.local[.movies] = [shelf(.movies, [card(item: movie(1)), card(item: movie(2))])]
        await hub.movies.reload()

        XCTAssertEqual(hub.movies.shelves.count, 1)
        XCTAssertEqual(hub.movies.shelves[0].items.count, 2)
        XCTAssertNil(hub.movies.refinedBy)
        XCTAssertTrue(backend.refineCalls.isEmpty, "no provider, no call")
    }

    func testAForeignCardFromTheEngineNeverReachesTheScreen() async {
        backend.local[.series] = [shelf(.series, [card(series: series(1)), card(item: movie(9))])]
        await hub.series.reload()

        XCTAssertEqual(hub.series.shelves.first?.items.count, 1)
        XCTAssertEqual(hub.series.shelves.first?.items.first?.series?.stableHash, "s1")
    }

    func testADisabledKindShowsNothing() async {
        backend.local[.live] = [shelf(.live, [card(item: channel(1, tvgId: "tf1"))])]
        hub.liveEnabled = false
        await hub.live.reload()
        XCTAssertTrue(hub.live.shelves.isEmpty)
    }

    func testWithoutABackendThereIsNothing() async {
        hub.setBackend { nil }
        await hub.movies.reload()
        XCTAssertTrue(hub.movies.shelves.isEmpty)
    }

    func testTheProviderOfTheUserRefinesTheShelf() async {
        useLocalServer()
        backend.local[.movies] = [shelf(.movies, [card(item: movie(1)), card(item: movie(2))])]
        backend.refined[.movies] = [shelf(.movies, [card(item: movie(2)), card(item: movie(1))], refinedBy: "Ollama (local)")]
        await hub.movies.reload()

        XCTAssertEqual(backend.refineCalls.count, 1)
        XCTAssertEqual(backend.refineCalls[0].kind, .movies, "one kind per call")
        XCTAssertTrue(backend.refineCalls[0].sendRecent, "a server on this device may see the recent titles")
        XCTAssertEqual(hub.movies.shelves[0].items.map { $0.item?.stableHash }, ["m2", "m1"])
        XCTAssertEqual(hub.movies.refinedBy, "Ollama (local)")
        XCTAssertFalse(hub.movies.isRefining)
    }

    func testAnAnswerWithoutTheRefinedMarkKeepsTheLocalShelves() async {
        useLocalServer()
        backend.local[.movies] = [shelf(.movies, [card(item: movie(1)), card(item: movie(2))])]
        backend.refined[.movies] = [shelf(.movies, [card(item: movie(2))], refinedBy: nil)]
        await hub.movies.reload()

        XCTAssertEqual(hub.movies.shelves[0].items.count, 2, "a failed or refused answer changes nothing")
        XCTAssertNil(hub.movies.refinedBy)
    }

    func testARefinedShelfIsFilteredByKindToo() async {
        useLocalServer()
        backend.local[.series] = [shelf(.series, [card(series: series(1))])]
        backend.refined[.series] = [shelf(.series, [card(series: series(1)), card(item: movie(5))], refinedBy: "Ollama (local)")]
        await hub.series.reload()

        XCTAssertEqual(hub.series.shelves[0].items.count, 1)
        XCTAssertEqual(hub.series.shelves[0].items[0].series?.stableHash, "s1")
    }

    func testTheAiIsNotAskedWhenTheUserTurnedItOff() async {
        useLocalServer()
        hub.aiRefine = false
        backend.local[.movies] = [shelf(.movies, [card(item: movie(1))])]
        await hub.movies.reload()
        XCTAssertTrue(backend.refineCalls.isEmpty)
    }

    func testTheAiIsNotAskedWhenTheAssistantIsDisabledOrLocalOnly() async {
        backend.local[.movies] = [shelf(.movies, [card(item: movie(1))])]
        settings.choice = .disabled
        await hub.movies.reload()
        settings.choice = .localOnly
        await hub.movies.reload()
        XCTAssertTrue(backend.refineCalls.isEmpty)
    }

    func testARemoteProviderWithoutConsentIsNotAsked() async {
        settings.choice = .gemini
        settings.apiKey = "key"
        settings.consent = false
        backend.local[.movies] = [shelf(.movies, [card(item: movie(1))])]
        await hub.movies.reload()
        XCTAssertTrue(backend.refineCalls.isEmpty, "nothing leaves the device without consent")
    }

    func testARemoteProviderGetsTheRecentTitlesOnlyIfAsked() async {
        settings.choice = .gemini
        settings.apiKey = "key"
        settings.consent = true
        backend.local[.movies] = [shelf(.movies, [card(item: movie(1))])]
        backend.refined[.movies] = [shelf(.movies, [card(item: movie(1))], refinedBy: "Gemini")]

        await hub.movies.reload()
        XCTAssertEqual(backend.refineCalls.last?.sendRecent, false)

        hub.sendRecentTitles = true
        await hub.movies.reload()
        XCTAssertEqual(backend.refineCalls.last?.sendRecent, true)
    }

    func testAStaleGuideIsNotRefined() async {
        useLocalServer()
        backend.local[.live] = [
            shelf(.live, [], id: "stale", kindOfShelf: .guideStale),
            shelf(.live, [card(item: channel(1, tvgId: "tf1"))], id: "hours"),
        ]
        await hub.live.reload()

        XCTAssertTrue(backend.refineCalls.isEmpty, "there is nothing sensible to re-rank")
        XCTAssertTrue(hub.live.shelves.contains { $0.shelf == .guideStale })
    }

    // MARK: The model of Apple (lot 34.5)

    private func movieShelves() -> [RecoShelf] { [shelf(.movies, [card(item: movie(1)), card(item: movie(2))])] }

    func testTheModelOfAppleIsOffByDefaultEvenWhenTheDeviceHasIt() async {
        XCTAssertFalse(hub.preferOnDeviceModel)
        XCTAssertFalse(hub.usesOnDeviceModel)
        backend.local[.movies] = movieShelves()
        await hub.movies.reload()
        XCTAssertTrue(backend.prepares.isEmpty)
        XCTAssertTrue(onDevice.prompts.isEmpty)
    }

    func testTheModelOfAppleIsNotUsedWhenTheDeviceDoesNotHaveIt() async {
        hub.preferOnDeviceModel = true
        onDevice.isAvailable = false
        XCTAssertFalse(hub.usesOnDeviceModel)
        backend.local[.movies] = movieShelves()
        await hub.movies.reload()
        XCTAssertTrue(backend.prepares.isEmpty)
    }

    func testTheModelOfAppleReRanksThroughTheEngineWithoutAnyProvider() async {
        hub.preferOnDeviceModel = true
        backend.local[.movies] = movieShelves()
        backend.appleStart = .ask(request: appleRequest(.movies))
        onDevice.result = .success(#"{"kind":"movie"}"#)
        backend.appleFinished = [shelf(.movies, [card(item: movie(2)), card(item: movie(1))], refinedBy: "Modèle d'Apple")]
        await hub.movies.reload()

        XCTAssertEqual(onDevice.prompts.count, 1)
        XCTAssertEqual(onDevice.prompts[0].system, "RULES")
        XCTAssertEqual(onDevice.prompts[0].user, "CANDIDATES")
        XCTAssertEqual(backend.finishes.count, 1)
        XCTAssertEqual(backend.finishes[0].answer, #"{"kind":"movie"}"#, "the engine validates what the model said")
        XCTAssertEqual(hub.movies.shelves[0].items.map { $0.item?.stableHash }, ["m2", "m1"])
        XCTAssertEqual(hub.movies.refinedBy, "Modèle d'Apple")
        XCTAssertTrue(backend.refineCalls.isEmpty, "the provider of the assistant is not used")
        XCTAssertFalse(hub.movies.isRefining)
    }

    func testTheModelOfApplePrefersTheDeviceOverAReadyProvider() async {
        useLocalServer()
        hub.preferOnDeviceModel = true
        backend.local[.movies] = movieShelves()
        backend.appleStart = .skip
        await hub.movies.reload()
        XCTAssertEqual(backend.prepares, [.movies])
        XCTAssertTrue(backend.refineCalls.isEmpty, "one refinement only, the one the user chose")
    }

    func testAKeptAnswerIsShownWithoutAskingTheModel() async {
        hub.preferOnDeviceModel = true
        backend.local[.movies] = movieShelves()
        backend.appleStart = .cached(shelves: [shelf(.movies, [card(item: movie(2))], refinedBy: "Modèle d'Apple")])
        await hub.movies.reload()
        XCTAssertTrue(onDevice.prompts.isEmpty)
        XCTAssertEqual(hub.movies.refinedBy, "Modèle d'Apple")
    }

    func testNothingToAskKeepsTheLocalShelves() async {
        hub.preferOnDeviceModel = true
        backend.local[.movies] = movieShelves()
        backend.appleStart = .skip
        await hub.movies.reload()
        XCTAssertTrue(onDevice.prompts.isEmpty)
        XCTAssertEqual(hub.movies.shelves[0].items.count, 2)
        XCTAssertNil(hub.movies.refinedBy)
    }

    func testAFailingModelKeepsTheLocalShelves() async {
        hub.preferOnDeviceModel = true
        backend.local[.movies] = movieShelves()
        backend.appleStart = .ask(request: appleRequest(.movies))
        onDevice.result = .failure(OnDeviceModelError.unavailable)
        await hub.movies.reload()

        XCTAssertTrue(backend.finishes.isEmpty, "no answer, nothing to validate")
        XCTAssertEqual(hub.movies.shelves[0].items.count, 2)
        XCTAssertNil(hub.movies.refinedBy)
        XCTAssertFalse(hub.movies.isRefining)
    }

    func testARejectedAnswerKeepsTheLocalShelves() async {
        hub.preferOnDeviceModel = true
        backend.local[.movies] = movieShelves()
        backend.appleStart = .ask(request: appleRequest(.movies))
        onDevice.result = .success("Voici mes idées")
        backend.appleFinished = backend.local[.movies]! // the engine returns the local shelves, no `refinedBy`
        await hub.movies.reload()

        XCTAssertEqual(backend.finishes.count, 1)
        XCTAssertNil(hub.movies.refinedBy)
        XCTAssertEqual(hub.movies.shelves[0].items.count, 2)
    }

    func testTheModelOfAppleIsFilteredByKindToo() async {
        hub.preferOnDeviceModel = true
        backend.local[.series] = [shelf(.series, [card(series: series(1))])]
        backend.appleStart = .ask(request: appleRequest(.series))
        backend.appleFinished = [shelf(.series, [card(series: series(1)), card(item: movie(4))], refinedBy: "Modèle d'Apple")]
        await hub.series.reload()
        XCTAssertEqual(hub.series.shelves[0].items.count, 1)
    }

    func testAStaleGuideIsNotGivenToTheModelOfApple() async {
        hub.preferOnDeviceModel = true
        backend.local[.live] = [
            shelf(.live, [], id: "stale", kindOfShelf: .guideStale),
            shelf(.live, [card(item: channel(1, tvgId: "tf1"))], id: "hours"),
        ]
        await hub.live.reload()
        XCTAssertTrue(backend.prepares.isEmpty)
    }

    func testTheDeadlineStopsAModelThatIsTooSlow() async {
        do {
            _ = try await withDeadline(seconds: 0.05) {
                try await Task.sleep(for: .seconds(5))
                return "late"
            }
            XCTFail("a late answer must not be waited for")
        } catch {
            XCTAssertEqual(error as? OnDeviceModelError, .timedOut)
        }
        let quick = try? await withDeadline(seconds: 5) { "ok" }
        XCTAssertEqual(quick, "ok")
    }

    func testTheChoiceOfTheModelOfAppleIsKept() {
        hub.preferOnDeviceModel = true
        XCTAssertTrue(defaults.bool(forKey: ForYouHub.onDeviceKey))
    }

    // MARK: Feedback

    func testNotInterestedHidesTheCardAndTellsTheEngine() async {
        backend.local[.movies] = [shelf(.movies, [card(item: movie(1)), card(item: movie(2))])]
        await hub.movies.reload()
        hub.movies.dismiss(card(item: movie(1)))

        XCTAssertEqual(backend.dismissed, ["m1"])
        XCTAssertEqual(hub.movies.shelves[0].items.map { $0.item?.stableHash }, ["m2"])
    }

    func testDismissingTheLastCardRemovesTheShelf() async {
        backend.local[.movies] = [shelf(.movies, [card(item: movie(1))])]
        await hub.movies.reload()
        hub.movies.dismiss(card(item: movie(1)))
        XCTAssertTrue(hub.movies.shelves.isEmpty)
    }

    func testDismissingASeriesUsesTheSeriesHash() async {
        backend.local[.series] = [shelf(.series, [card(series: series(1), next: episode(10, of: 1)), card(series: series(2))])]
        await hub.series.reload()
        hub.series.dismiss(card(series: series(1), next: episode(10, of: 1)))

        XCTAssertEqual(backend.dismissed, ["s1"], "the series is dismissed, not its episode")
        XCTAssertEqual(hub.series.shelves[0].items.count, 1)
    }

    func testLessLikeThisIsForThisKindOnly() async {
        backend.local[.series] = [shelf(.series, [card(series: series(1)), card(series: series(2))])]
        await hub.series.reload()
        hub.series.lessLikeThis(card(series: series(1)))

        XCTAssertEqual(backend.less.count, 1)
        XCTAssertEqual(backend.less[0].0, .series)
        XCTAssertEqual(backend.less[0].1, "s1")
        XCTAssertEqual(hub.series.shelves[0].items.count, 1)
    }

    func testAnEmptyCardIsIgnoredByTheFeedback() {
        hub.movies.dismiss(card())
        hub.movies.lessLikeThis(card())
        XCTAssertTrue(backend.dismissed.isEmpty)
        XCTAssertTrue(backend.less.isEmpty)
    }

    func testResettingTheTasteIsPerKind() {
        hub.live.resetTaste()
        XCTAssertEqual(backend.resets, [.live])
    }
}
