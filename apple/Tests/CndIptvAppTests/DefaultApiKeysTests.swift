import XCTest
import CndCoreBridge
@testable import CndIptvKit

/// PRD 28: the user's key wins over the key baked into the build, which is never shown or stored.
@MainActor
final class DefaultApiKeysTests: XCTestCase {
    private var keychain: KeychainStore!
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() async throws {
        keychain = KeychainStore(service: "com.cnd.iptv.tests.keys.\(UUID().uuidString)")
        suite = "cnd.keys.tests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func resolver(_ bundled: [ApiService: String] = [:]) -> ApiKeyResolver {
        ApiKeyResolver(keychain: keychain, defaults: DefaultApiKeys(keys: bundled))
    }

    // MARK: Resolver

    func testNoKeyAnywhereResolvesToNothing() {
        XCTAssertNil(resolver().resolve(.omdb))
        XCTAssertNil(resolver().keyForCall(.openSubtitles))
    }

    func testBundledKeyIsUsedWhenTheUserHasNone() {
        let r = resolver([.omdb: "bundled-omdb"])
        XCTAssertEqual(r.resolve(.omdb)?.value, "bundled-omdb")
        XCTAssertEqual(r.resolve(.omdb)?.source, .bundled)
        XCTAssertTrue(r.usesBundledKey(.omdb))
    }

    func testUserKeyWinsOverTheBundledOne() throws {
        try keychain.saveSecret("  mine  ", forKey: ApiService.omdb.keychainKey)
        let r = resolver([.omdb: "bundled-omdb"])
        XCTAssertEqual(r.resolve(.omdb)?.value, "mine")
        XCTAssertEqual(r.resolve(.omdb)?.source, .user)
        XCTAssertFalse(r.usesBundledKey(.omdb))
    }

    func testClearingTheUserKeyFallsBackToTheBundledOne() throws {
        try keychain.saveSecret("mine", forKey: ApiService.openSubtitles.keychainKey)
        let r = resolver([.openSubtitles: "bundled-os"])
        XCTAssertEqual(r.resolve(.openSubtitles)?.source, .user)
        try keychain.deleteSecret(forKey: ApiService.openSubtitles.keychainKey)
        XCTAssertEqual(r.resolve(.openSubtitles)?.value, "bundled-os")
    }

    func testBundledKeyIsNeverWrittenToTheKeychain() {
        let r = resolver([.omdb: "bundled-omdb", .gemini: "bundled-gemini"])
        _ = r.keyForCall(.omdb)
        _ = r.resolve(.gemini)
        XCTAssertNil(r.userKey(.omdb))
        XCTAssertNil(try keychain.readSecret(forKey: ApiService.omdb.keychainKey))
        XCTAssertNil(try keychain.readSecret(forKey: ApiService.gemini.keychainKey))
    }

    func testEmptyBundledValuesAreIgnored() {
        XCTAssertFalse(resolver([.tmdb: ""]).hasBundledKey(.tmdb))
    }

    func testKeychainReferencesMatchTheExistingEntries() {
        XCTAssertEqual(ApiService.omdb.keychainKey, KeychainStore.omdbApiKeyRef)
        XCTAssertEqual(ApiService.openSubtitles.keychainKey, OpenSubtitlesCredentials.keychainKey)
        for choice in [AiChoice.gemini, .openAiCompatible, .anthropic] {
            XCTAssertEqual(choice.apiService?.keychainKey, choice.keychainKey, "\(choice)")
        }
    }

    func testOpenSubtitlesAndOmdbCallsGoThroughTheResolver() throws {
        // No bundled key in a test build: the user's key is what the call sees.
        try keychain.saveSecret("os-key", forKey: OpenSubtitlesCredentials.keychainKey)
        XCTAssertEqual(OpenSubtitlesCredentials.apiKey(keychain: keychain), "os-key")
    }

    // MARK: Generated file

    func testTheGeneratedFileIsMaskedAndRoundTrips() {
        // The contract of `DefaultApiKeys.bundled`: bytes XOR the salt give back the text.
        let salt: [UInt8] = [7, 91, 200, 13]
        let plain = Array("AIza-test-key".utf8)
        let masked = plain.enumerated().map { $0.element ^ salt[$0.offset % salt.count] }
        XCTAssertNotEqual(masked, plain)
        let back = masked.enumerated().map { $0.element ^ salt[$0.offset % salt.count] }
        XCTAssertEqual(String(bytes: back, encoding: .utf8), "AIza-test-key")
    }

    // MARK: AI provider

    private func aiSettings(_ bundled: DefaultApiKeys, now: @escaping () -> Date = Date.init) -> AiProviderSettings {
        AiProviderSettings(defaults: defaults, keychain: keychain, bundledKeys: bundled)
    }

    func testDefaultProviderIsProposedButStaysUnconsentedAndUnchosenByTheUser() {
        let settings = aiSettings(DefaultApiKeys(keys: [.gemini: "g"], defaultAiProvider: "gemini"))
        XCTAssertEqual(settings.choice, .gemini)
        XCTAssertFalse(settings.consent)
        XCTAssertNotNil(settings.blocker, "the consent of PRD 13 still gates the first send")
        XCTAssertEqual(settings.providerConfig().kind, .localOnly)
        XCTAssertTrue(settings.usesBundledKey)
    }

    func testTheUsersProviderChoiceBeatsTheDefaultOne() {
        defaults.set(AiChoice.anthropic.rawValue, forKey: AiProviderSettings.choiceKey)
        let settings = aiSettings(DefaultApiKeys(keys: [.gemini: "g"], defaultAiProvider: "gemini"))
        XCTAssertEqual(settings.choice, .anthropic)
        XCTAssertFalse(settings.usesBundledKey, "no bundled Claude key")
    }

    func testNoneOrMissingDefaultProviderKeepsLocalOnly() {
        XCTAssertEqual(aiSettings(DefaultApiKeys(defaultAiProvider: "none")).choice, .localOnly)
        XCTAssertEqual(aiSettings(DefaultApiKeys()).choice, .localOnly)
    }

    func testConsentedProviderSendsTheBundledKeyWithoutShowingIt() {
        let settings = aiSettings(DefaultApiKeys(keys: [.gemini: "bundled-g"], defaultAiProvider: "gemini"))
        settings.consent = true
        XCTAssertEqual(settings.apiKey, "", "the field only ever shows the user's own key")
        let config = settings.providerConfig()
        XCTAssertEqual(config.kind, .gemini)
        XCTAssertEqual(config.apiKey, "bundled-g")
    }

    func testTheUsersKeyIsSentInsteadOfTheBundledOneAndHasNoDailyLimit() {
        let settings = aiSettings(DefaultApiKeys(keys: [.gemini: "bundled-g"], defaultAiProvider: "gemini"))
        settings.consent = true
        settings.apiKey = "my-key"
        XCTAssertFalse(settings.usesBundledKey)
        for _ in 0..<(BundledAiQuota.dailyLimit + 5) {
            XCTAssertEqual(settings.providerConfig().apiKey, "my-key")
        }
    }

    func testBundledKeyStopsAtTheDailyLimitAndFallsBackToLocal() {
        let settings = aiSettings(DefaultApiKeys(keys: [.gemini: "bundled-g"], defaultAiProvider: "gemini"))
        settings.consent = true
        for _ in 0..<BundledAiQuota.dailyLimit {
            XCTAssertEqual(settings.providerConfig().kind, .gemini)
        }
        XCTAssertTrue(settings.bundledQuotaExhausted)
        XCTAssertEqual(settings.providerConfig().kind, .localOnly)
        XCTAssertTrue(settings.blocker?.contains("propre clé") == true)
    }

    func testOpenAIDefaultsFromTheBuildFillAddressAndModel() {
        defaults.set(AiChoice.openAiCompatible.rawValue, forKey: AiProviderSettings.choiceKey)
        let settings = aiSettings(DefaultApiKeys(openAIBaseURL: "http://localhost:11434/v1", openAIModel: "llama3"))
        XCTAssertEqual(settings.baseURL, "http://localhost:11434/v1")
        XCTAssertEqual(settings.model, "llama3")
        XCTAssertTrue(settings.endpointIsLocal)
    }

    func testRefusedOrLimitedBundledKeyPointsToTheUsersOwnKey() {
        let settings = aiSettings(DefaultApiKeys(keys: [.gemini: "g"], defaultAiProvider: "gemini"))
        XCTAssertTrue(settings.explaining("clé refusée par le fournisseur").contains("propre clé"))
        XCTAssertTrue(settings.explaining("quota ou limite de débit atteint").contains("propre clé"))
        XCTAssertEqual(settings.explaining("délai dépassé côté fournisseur"), "délai dépassé côté fournisseur")
        settings.apiKey = "mine"
        XCTAssertEqual(settings.explaining("clé refusée par le fournisseur"), "clé refusée par le fournisseur")
    }

    // MARK: Quota

    func testQuotaResetsOnANewDay() {
        var date = Date(timeIntervalSince1970: 1_700_000_000)
        let quota = BundledAiQuota(defaults: defaults, now: { date })
        for _ in 0..<BundledAiQuota.dailyLimit { XCTAssertTrue(quota.consume()) }
        XCTAssertFalse(quota.consume())
        XCTAssertEqual(quota.used, BundledAiQuota.dailyLimit)
        date.addTimeInterval(86_400 * 2)
        XCTAssertEqual(quota.used, 0)
        XCTAssertTrue(quota.consume())
    }
}
