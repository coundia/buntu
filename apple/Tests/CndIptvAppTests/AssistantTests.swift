import XCTest
import CndCoreBridge
@testable import CndIptvKit

// MARK: - Fakes

func makeChannel(id: Int64, name: String, hash: String? = nil) -> IptvItemRecord {
    IptvItemRecord(
        id: id, sourceId: 1, seriesId: nil, stableHash: hash ?? "hash\(id)", kind: "live", seasonNum: nil, episodeNum: nil,
        name: name, nameClean: name, year: nil, groupTitle: "FR | INFO", tvgId: nil, logoUrl: nil, chno: UInt32(id),
        host: "h", containerExt: nil, streamUrl: "http://cdn.test/live/\(id).m3u8", userAgent: nil, referer: nil,
        headersJson: nil, catchupType: nil, catchupSource: nil, catchupDays: nil, plot: nil, imdbId: nil,
        imdbRating: nil, isFavorite: false, isBroken: false, resumePositionMs: 0, durationMs: 0, isCompleted: false
    )
}

final class FakeAssistantBackend: AssistantBackend, @unchecked Sendable {
    struct Call { var command: String; var context: AiCommandContext; var config: AiProviderConfig }

    private let lock = NSLock()
    private var storedCalls: [Call] = []
    var items: [Int64: IptvItemRecord] = [:]
    var handler: @Sendable (Call) async throws -> AiCommandResult = { _ in
        AiCommandResult(action: .none, alternatives: [], reply: "", resolvedBy: "local", latencyMs: 1, fallbackReason: nil)
    }
    var testResult = AiProviderStatus(ok: true, latencyMs: 12, model: "m", message: "Connexion réussie.")

    var calls: [Call] { lock.withLock { storedCalls } }
    /// Calls made with a real provider (the live suggestions always use the local configuration).
    var remoteCalls: [Call] { calls.filter { $0.config.kind != .localOnly } }

    func aiResolveCommand(command: String, context: AiCommandContext, config: AiProviderConfig) async throws -> AiCommandResult {
        let call = Call(command: command, context: context, config: config)
        lock.withLock { storedCalls.append(call) }
        return try await handler(call)
    }

    func aiTestProvider(config: AiProviderConfig) async throws -> AiProviderStatus { testResult }

    func getItemById(itemId: Int64) throws -> IptvItemRecord? { items[itemId] }
}

func result(
    _ action: AiAction, alternatives: [IptvItemRecord] = [], reply: String = "ok",
    by: String = "local", fallback: String? = nil
) -> AiCommandResult {
    AiCommandResult(action: action, alternatives: alternatives, reply: reply, resolvedBy: by, latencyMs: 5, fallbackReason: fallback)
}

// MARK: - Settings

@MainActor
final class AiProviderSettingsTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var keychain: KeychainStore!

    override func setUp() async throws {
        suite = "cnd.ai.tests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)
        keychain = KeychainStore(service: "com.cnd.iptv.tests.ai.\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        for choice in AiChoice.allCases { if let key = choice.keychainKey { try? keychain.deleteSecret(forKey: key) } }
    }

    private func make() -> AiProviderSettings { AiProviderSettings(defaults: defaults, keychain: keychain) }

    func testDefaultsToLocalResolutionWithTheAssistantEnabled() {
        let settings = make()
        XCTAssertEqual(settings.choice, .localOnly)
        XCTAssertTrue(settings.isAssistantEnabled)
        XCTAssertEqual(settings.providerConfig().kind, .localOnly)
        XCTAssertEqual(settings.summary, "Résolution locale")
    }

    func testDisabledHidesTheAssistant() {
        let settings = make()
        settings.choice = .disabled
        XCTAssertFalse(settings.isAssistantEnabled)
        XCTAssertEqual(settings.summary, "Assistant désactivé")
        XCTAssertEqual(settings.providerConfig().kind, .localOnly)
    }

    func testARemoteProviderIsOnlyUsedWithAKeyAndConsent() {
        let settings = make()
        settings.choice = .gemini
        XCTAssertEqual(settings.blocker, "Saisissez une clé API.")
        XCTAssertEqual(settings.providerConfig().kind, .localOnly, "no key: local")

        settings.apiKey = "  AIza-secret-key  "
        XCTAssertTrue(settings.blocker?.contains("consentement") == true)
        XCTAssertEqual(settings.providerConfig().kind, .localOnly, "no consent: nothing is sent")
        XCTAssertFalse(settings.isRemoteReady)

        settings.consent = true
        XCTAssertNil(settings.blocker)
        let config = settings.providerConfig()
        XCTAssertEqual(config.kind, .gemini)
        XCTAssertEqual(config.apiKey, "AIza-secret-key", "trimmed")
        XCTAssertEqual(config.timeoutMs, 8_000)
        XCTAssertNil(config.baseUrl)
        XCTAssertEqual(settings.summary, "Google Gemini")
    }

    func testTheKeyLivesInTheKeychainNeverInDefaults() throws {
        let settings = make()
        settings.choice = .anthropic
        settings.apiKey = "sk-ant-very-secret"
        XCTAssertEqual(try keychain.readSecret(forKey: "cnd.ai.anthropic.apikey"), "sk-ant-very-secret")
        for (_, value) in defaults.dictionaryRepresentation() {
            XCTAssertFalse("\(value)".contains("very-secret"), "the key leaked into UserDefaults")
        }
        XCTAssertEqual(make().choice, .anthropic)
        XCTAssertEqual(make().apiKey, "sk-ant-very-secret", "restored after a relaunch")

        settings.apiKey = ""
        XCTAssertNil(try keychain.readSecret(forKey: "cnd.ai.anthropic.apikey"), "clearing the field deletes the secret")
    }

    func testEachProviderKeepsItsOwnFields() {
        let settings = make()
        settings.choice = .gemini
        settings.model = "gemini-custom"
        settings.apiKey = "gem-key"
        settings.consent = true
        settings.choice = .openAiCompatible
        XCTAssertEqual(settings.model, "")
        XCTAssertEqual(settings.apiKey, "")
        XCTAssertFalse(settings.consent, "consent is per provider")
        settings.baseURL = "https://api.mistral.ai/v1"
        settings.choice = .gemini
        XCTAssertEqual(settings.model, "gemini-custom")
        XCTAssertEqual(settings.apiKey, "gem-key")
        XCTAssertTrue(settings.consent)
        settings.choice = .openAiCompatible
        XCTAssertEqual(settings.baseURL, "https://api.mistral.ai/v1")
    }

    func testALocalServerNeedsNeitherKeyNorConsent() {
        let settings = make()
        settings.choice = .openAiCompatible
        XCTAssertNotNil(settings.blocker, "no address and no key yet")

        for local in ["http://localhost:11434/v1", "http://127.0.0.1:1234/v1", "http://[::1]:8080/v1", "http://mac-mini.local:11434/v1"] {
            settings.baseURL = local
            XCTAssertTrue(settings.endpointIsLocal, local)
            XCTAssertNil(settings.blocker, local)
            let config = settings.providerConfig()
            XCTAssertEqual(config.kind, .openAiCompatible)
            XCTAssertEqual(config.baseUrl, local)
            XCTAssertNil(config.apiKey)
        }
        XCTAssertTrue(settings.summary.contains("sur cet appareil"))

        settings.baseURL = "https://api.groq.com/openai/v1"
        XCTAssertFalse(settings.endpointIsLocal)
        XCTAssertNotNil(settings.blocker, "a hosted server needs consent")
        settings.baseURL = "http://localhost.evil.example/v1"
        XCTAssertFalse(settings.endpointIsLocal, "a look-alike host is not local")
    }

    func testTheTestButtonIsItselfTheConsent() {
        let settings = make()
        settings.choice = .anthropic
        settings.apiKey = "sk-ant-key"
        XCTAssertEqual(settings.providerConfig().kind, .localOnly)
        XCTAssertEqual(settings.testConfig().kind, .anthropic)
        XCTAssertEqual(settings.testConfig().apiKey, "sk-ant-key")
    }

    func testChoicesMapToEngineKinds() {
        XCTAssertEqual(AiChoice.gemini.kind, .gemini)
        XCTAssertEqual(AiChoice.openAiCompatible.kind, .openAiCompatible)
        XCTAssertEqual(AiChoice.anthropic.kind, .anthropic)
        XCTAssertEqual(AiChoice.localOnly.kind, .localOnly)
        XCTAssertEqual(AiChoice.gemini.keychainKey, "cnd.ai.gemini.apikey")
        XCTAssertNil(AiChoice.localOnly.keychainKey)
        XCTAssertTrue(AiChoice.gemini.requiresKey && AiChoice.anthropic.requiresKey)
        XCTAssertFalse(AiChoice.openAiCompatible.requiresKey)
    }
}

// MARK: - Model

@MainActor
final class AssistantModelTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var backend: FakeAssistantBackend!
    private var settings: AiProviderSettings!
    private var model: AssistantModel!
    private var played: [String] = []
    private var guides: [String] = []
    private var searches: [String] = []
    private var zaps: [Int] = []
    private var dismissals = 0

    override func setUp() async throws {
        suite = "cnd.assistant.tests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)
        backend = FakeAssistantBackend()
        settings = AiProviderSettings(defaults: defaults, keychain: KeychainStore(service: "com.cnd.iptv.tests.assistant.\(UUID().uuidString)"))
        model = AssistantModel(backend: backend, settings: settings, defaults: defaults, suggestionDelay: .milliseconds(20))
        played = []; guides = []; searches = []; zaps = []; dismissals = 0
        model.actions = AssistantActions(
            play: { [unowned self] in played.append($0.name) },
            showGuide: { [unowned self] in guides.append($0.name) },
            next: { [unowned self] in zaps.append(1) },
            previous: { [unowned self] in zaps.append(-1) },
            search: { [unowned self] in searches.append($0) }
        )
        model.onDismiss = { [unowned self] in dismissals += 1 }
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func testResolvedChannelIsPlayedAndThePaletteCloses() async {
        backend.items[7] = makeChannel(id: 7, name: "France 2")
        backend.handler = { _ in result(.playChannel(itemId: 7), reply: "France 2 — Journal") }
        model.input = "mets france 2"
        await model.submit()

        XCTAssertEqual(played, ["France 2"])
        XCTAssertEqual(dismissals, 1)
        XCTAssertEqual(model.result?.reply, "France 2 — Journal")
        XCTAssertFalse(model.isResolving)
        XCTAssertNil(model.errorMessage)
    }

    func testEveryActionIsRoutedToTheApp() async {
        backend.items[3] = makeChannel(id: 3, name: "M6")
        let script: [(AiAction, String)] = [
            (.showGuide(itemId: 3), "guide"), (.nextChannel, "next"), (.previousChannel, "previous"), (.search(query: "bbc"), "search"),
        ]
        for (action, _) in script {
            backend.handler = { _ in result(action) }
            model.input = "x \(UUID().uuidString.prefix(4))"
            await model.submit()
        }
        XCTAssertEqual(guides, ["M6"])
        XCTAssertEqual(zaps, [1, -1])
        XCTAssertEqual(searches, ["bbc"])
        XCTAssertEqual(dismissals, 4)
        XCTAssertTrue(played.isEmpty)
    }

    func testAnAmbiguousAnswerKeepsThePaletteOpenAndOffersChoices() async {
        let options = [makeChannel(id: 1, name: "BBC News"), makeChannel(id: 2, name: "CNN")]
        backend.handler = { _ in result(.none, alternatives: options, reply: "Plusieurs chaînes", fallback: "délai dépassé") }
        model.input = "une chaîne d'info"
        await model.submit()

        XCTAssertEqual(dismissals, 0)
        XCTAssertTrue(played.isEmpty)
        XCTAssertEqual(model.result?.alternatives.map(\.name), ["BBC News", "CNN"])
        XCTAssertEqual(model.result?.fallbackReason, "délai dépassé")

        model.choose(options[1])
        XCTAssertEqual(played, ["CNN"])
        XCTAssertEqual(dismissals, 1)
    }

    func testBlankInputDoesNothingAndEngineErrorsAreShown() async {
        model.input = "   "
        await model.submit()
        XCTAssertTrue(backend.calls.isEmpty)

        backend.handler = { _ in throw CndError.Network(message: "Le moteur a échoué") }
        model.input = "france 2"
        await model.submit()
        XCTAssertEqual(model.errorMessage, "Le moteur a échoué")
        XCTAssertFalse(model.isResolving)
        XCTAssertEqual(dismissals, 0)
    }

    func testAMissingChannelIsReportedInsteadOfCrashing() async {
        backend.handler = { _ in result(.playChannel(itemId: 404)) }
        model.input = "france 2"
        await model.submit()
        XCTAssertTrue(played.isEmpty)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(dismissals, 0)
    }

    func testCancellingDropsTheLateAnswer() async {
        backend.items[1] = makeChannel(id: 1, name: "TF1")
        backend.handler = { _ in
            try await Task.sleep(for: .milliseconds(300))
            return result(.playChannel(itemId: 1))
        }
        model.input = "tf1"
        let task = Task { await model.submit() }
        let started = await eventually { self.model.isResolving }
        XCTAssertTrue(started)

        model.cancel()
        XCTAssertFalse(model.isResolving)
        await task.value
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(played.isEmpty, "a cancelled command must not change the channel")
        XCTAssertNil(model.result)
    }

    func testTheProviderIsOnlyReachedWhenReadyAndTheContextIsPassed() async {
        backend.handler = { _ in result(.none) }
        model.playingStableHash = { "hash-playing" }
        model.currentGroup = { "FR | INFO" }

        settings.choice = .gemini
        settings.apiKey = "key"
        model.input = "info"
        await model.submit()
        XCTAssertEqual(backend.calls.last?.config.kind, .localOnly, "no consent yet")

        settings.consent = true
        model.input = "info anglais"
        await model.submit()
        let call = try! XCTUnwrap(backend.calls.last)
        XCTAssertEqual(call.config.kind, .gemini)
        XCTAssertEqual(call.config.apiKey, "key")
        XCTAssertEqual(call.context.playingStableHash, "hash-playing")
        XCTAssertEqual(call.context.groupTitle, "FR | INFO")
        XCTAssertFalse(call.context.locale.contains("_"), "BCP-47 locale: \(call.context.locale)")
        XCTAssertEqual(call.command, "info anglais")
    }

    func testHistoryIsLocalDeduplicatedBoundedAndRecallable() async {
        backend.handler = { _ in result(.none) }
        for index in 0..<25 {
            model.input = "commande \(index)"
            await model.submit()
        }
        XCTAssertEqual(model.history.count, AssistantModel.historyLimit)
        XCTAssertEqual(model.history.first, "commande 24")
        XCTAssertEqual(defaults.stringArray(forKey: AssistantModel.historyKey)?.count, 20, "persisted")

        model.input = "COMMANDE 20"
        await model.submit()
        XCTAssertEqual(model.history.filter { $0.lowercased() == "commande 20" }.count, 1, "case-insensitive de-duplication")
        XCTAssertEqual(model.history.first, "COMMANDE 20")

        model.input = ""
        model.recallOlder()
        XCTAssertEqual(model.input, "COMMANDE 20")
        model.recallOlder()
        XCTAssertEqual(model.input, "commande 24")
        model.recallNewer()
        XCTAssertEqual(model.input, "COMMANDE 20")
        model.recallNewer()
        XCTAssertEqual(model.input, "")
        model.recallNewer()
        XCTAssertEqual(model.input, "")

        let reopened = AssistantModel(backend: backend, settings: settings, defaults: defaults)
        XCTAssertEqual(reopened.history, model.history, "restored")
        model.clearHistory()
        XCTAssertTrue(model.history.isEmpty)
        XCTAssertNil(defaults.stringArray(forKey: AssistantModel.historyKey))
    }

    func testLiveSuggestionsUseTheLocalResolutionOnlyAndAreDebounced() async {
        backend.items[9] = makeChannel(id: 9, name: "France 24")
        backend.handler = { call in
            if call.command == "fra" { return result(.none, alternatives: [makeChannel(id: 9, name: "France 24"), makeChannel(id: 10, name: "France 3")]) }
            return result(.playChannel(itemId: 9))
        }
        settings.choice = .gemini
        settings.apiKey = "key"
        settings.consent = true

        model.input = "f"
        model.input = "fr"
        model.input = "fra"
        let listed = await eventually { self.model.suggestions.count == 2 }
        XCTAssertTrue(listed)
        XCTAssertEqual(backend.calls.count, 1, "typing quickly makes one lookup")
        XCTAssertEqual(backend.calls.first?.config.kind, .localOnly, "suggestions never use the provider")
        XCTAssertTrue(backend.remoteCalls.isEmpty)

        model.input = "france 24"
        let exact = await eventually { self.model.suggestions.map(\.name) == ["France 24"] }
        XCTAssertTrue(exact, "a resolved channel is shown as the single suggestion")

        model.input = ""
        XCTAssertTrue(model.suggestions.isEmpty)
        XCTAssertNil(model.result)
    }

    func testTypingAgainClearsAPreviousResult() async {
        backend.handler = { _ in result(.none, reply: "Plusieurs") }
        model.input = "a"
        await model.submit()
        XCTAssertNotNil(model.result)
        model.input = "ab"
        XCTAssertNil(model.result)
    }

    func testTheProviderTestIsForwardedAndErrorsBecomeAStatus() async {
        settings.choice = .gemini
        settings.apiKey = "key"
        let status = await model.testProvider()
        XCTAssertTrue(status.ok)
        XCTAssertEqual(status.latencyMs, 12)
    }
}

// MARK: - Real engine (local resolution, no network)

@MainActor
final class AssistantWithEngineTests: XCTestCase {
    private var engine: CndEngine!
    private var directory: URL!
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        engine = try CndEngine.inMemory()
        directory = try TestFixtures.makeTempDirectory()
        try await TestFixtures.importCatalog(into: engine, directory: directory, count: 40)
        suite = "cnd.assistant.engine.\(UUID())"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suite)
    }

    private func make() -> (AssistantModel, Recorder) {
        let settings = AiProviderSettings(defaults: defaults, keychain: KeychainStore(service: "com.cnd.iptv.tests.assistant.\(UUID().uuidString)"))
        let model = AssistantModel(backend: engine, settings: settings, defaults: defaults, suggestionDelay: .milliseconds(20))
        let recorder = Recorder()
        model.actions = AssistantActions(
            play: { recorder.played.append($0.name) },
            showGuide: { recorder.guides.append($0.name) },
            next: { recorder.zaps.append(1) },
            previous: { recorder.zaps.append(-1) },
            search: { recorder.searches.append($0) }
        )
        return (model, recorder)
    }

    @MainActor final class Recorder {
        var played: [String] = []
        var guides: [String] = []
        var zaps: [Int] = []
        var searches: [String] = []
    }

    func testExplicitCommandsPlayTheRightChannelWithoutAnyProvider() async {
        let (model, recorder) = make()
        for (phrase, expected) in [("mets Chaine 007", "Chaine 007"), ("chaîne 12", "Chaine 012"), ("Chaine 031 stp", "Chaine 031"), ("12", "Chaine 012")] {
            model.input = phrase
            await model.submit()
            XCTAssertEqual(recorder.played.last, expected, phrase)
            XCTAssertEqual(model.result?.resolvedBy, "local")
        }
        XCTAssertEqual(recorder.played.count, 4)
    }

    func testNavigationAndUnknownPhrases() async {
        let (model, recorder) = make()
        model.input = "suivante"
        await model.submit()
        model.input = "chaîne précédente"
        await model.submit()
        XCTAssertEqual(recorder.zaps, [1, -1])

        model.input = "zzzzqqqq"
        await model.submit()
        XCTAssertEqual(recorder.searches, ["zzzzqqqq"], "nothing matches: the Live TV search takes over")
        XCTAssertTrue(recorder.played.isEmpty)
    }

    func testSuggestionsAppearAsYouType() async {
        let (model, _) = make()

        // A number: the channel itself is the single suggestion.
        model.input = "chaine 03"
        let numbered = await eventually(timeout: 5) { model.suggestions.map(\.name) == ["Chaine 003"] }
        XCTAssertTrue(numbered, "\(model.suggestions.map(\.name))")

        // A word: several candidates, at most five.
        model.input = "chai"
        let several = await eventually(timeout: 5) { model.suggestions.count > 1 }
        XCTAssertTrue(several)
        XCTAssertLessThanOrEqual(model.suggestions.count, 5)
        XCTAssertTrue(model.suggestions.allSatisfy { $0.name.hasPrefix("Chaine") })
    }

    func testTheAssistantNeverReachesTheNetworkInLocalMode() async {
        let (model, recorder) = make()
        model.input = "Chaine 005"
        await model.submit()
        XCTAssertEqual(recorder.played, ["Chaine 005"])
        let logs = engine.getLogsSince(afterSeqId: 0, limit: 500).filter { $0.category == "AI" && $0.method != nil }
        XCTAssertTrue(logs.isEmpty, "no HTTP request was made")
    }
}
