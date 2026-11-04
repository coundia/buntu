import Foundation

/// Services that can have a default API key (PRD 28).
enum ApiService: String, CaseIterable, Sendable {
    case omdb, tmdb, openSubtitles, gemini, openAI, anthropic

    var displayName: String {
        switch self {
        case .omdb: return "OMDb"
        case .tmdb: return "TMDB"
        case .openSubtitles: return "OpenSubtitles"
        case .gemini: return "Google Gemini"
        case .openAI: return "Compatible OpenAI"
        case .anthropic: return "Anthropic Claude"
        }
    }

    var isAI: Bool { self == .gemini || self == .openAI || self == .anthropic }

    /// Where the user's own key for this service lives in the Keychain.
    var keychainKey: String {
        switch self {
        case .omdb: return KeychainStore.omdbApiKeyRef
        case .tmdb: return "cnd.tmdb.apikey"
        case .openSubtitles: return "cnd.opensubtitles.apikey"
        case .gemini: return "cnd.ai.gemini.apikey"
        case .openAI: return "cnd.ai.openAiCompatible.apikey"
        case .anthropic: return "cnd.ai.anthropic.apikey"
        }
    }
}

/// The keys baked into this build from `.env` (see `scripts/gen-default-keys.sh`). They are only
/// read through `ApiKeyResolver`: never displayed, copied, exported, written to the Keychain, the
/// database or the logs.
///
/// `DefaultApiKeysGenerated` lives in `Generated/` (git-ignored). If the build cannot find it, run `task keys`.
struct DefaultApiKeys: Sendable {
    private let keys: [ApiService: String]
    /// `gemini`, `openai`, `anthropic` or `none` (`.env`'s `CND_DEFAULT_AI_PROVIDER`).
    let defaultAiProvider: String?
    let openAIBaseURL: String?
    let openAIModel: String?

    init(keys: [ApiService: String] = [:], defaultAiProvider: String? = nil, openAIBaseURL: String? = nil, openAIModel: String? = nil) {
        self.keys = keys.filter { !$0.value.isEmpty }
        self.defaultAiProvider = defaultAiProvider
        self.openAIBaseURL = openAIBaseURL
        self.openAIModel = openAIModel
    }

    static let bundled: DefaultApiKeys = {
        typealias G = DefaultApiKeysGenerated
        let salt = G.salt
        func unmask(_ bytes: [UInt8]?) -> String? {
            guard let bytes, !bytes.isEmpty, !salt.isEmpty else { return nil }
            let plain = bytes.enumerated().map { $0.element ^ salt[$0.offset % salt.count] }
            return String(bytes: plain, encoding: .utf8)
        }
        var keys: [ApiService: String] = [:]
        for (service, masked) in [
            (ApiService.omdb, G.omdb), (.tmdb, G.tmdb), (.openSubtitles, G.openSubtitles),
            (.gemini, G.gemini), (.openAI, G.openAI), (.anthropic, G.anthropic)
        ] {
            if let value = unmask(masked) { keys[service] = value }
        }
        return DefaultApiKeys(
            keys: keys, defaultAiProvider: G.defaultAiProvider,
            openAIBaseURL: G.openAIBaseURL, openAIModel: G.openAIModel
        )
    }()

    func key(for service: ApiService) -> String? { keys[service] }
    func has(_ service: ApiService) -> Bool { keys[service] != nil }
}
