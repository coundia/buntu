import Foundation
import Observation
import CndCoreBridge

enum AiChoice: String, CaseIterable, Identifiable {
    case disabled
    case localOnly
    case gemini
    case openAiCompatible
    case anthropic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .disabled: return "Désactivé"
        case .localOnly: return "Local uniquement"
        case .gemini: return "Google Gemini"
        case .openAiCompatible: return "Compatible OpenAI"
        case .anthropic: return "Anthropic Claude"
        }
    }

    var isRemote: Bool { self == .gemini || self == .openAiCompatible || self == .anthropic }

    /// Gemini and Claude need a key; an OpenAI-compatible server may not (Ollama, LM Studio).
    var requiresKey: Bool { self == .gemini || self == .anthropic }

    var kind: AiProviderKind {
        switch self {
        case .disabled, .localOnly: return .localOnly
        case .gemini: return .gemini
        case .openAiCompatible: return .openAiCompatible
        case .anthropic: return .anthropic
        }
    }

    var keychainKey: String? {
        isRemote ? "cnd.ai.\(rawValue).apikey" : nil
    }

    /// The service whose key (user's or bundled) this provider uses.
    var apiService: ApiService? {
        switch self {
        case .gemini: return .gemini
        case .openAiCompatible: return .openAI
        case .anthropic: return .anthropic
        case .disabled, .localOnly: return nil
        }
    }

    /// `.env`'s `CND_DEFAULT_AI_PROVIDER`.
    init?(defaultProvider name: String?) {
        switch name?.lowercased() {
        case "gemini": self = .gemini
        case "openai": self = .openAiCompatible
        case "anthropic": self = .anthropic
        default: return nil
        }
    }

    var baseURLPlaceholder: String {
        switch self {
        case .openAiCompatible: return "https://api.openai.com/v1 ou http://localhost:11434/v1"
        case .gemini: return "Par défaut : API Google officielle"
        case .anthropic: return "Par défaut : API Anthropic officielle"
        default: return ""
        }
    }
}

/// The assistant's provider choice. Everything but the key lives in `UserDefaults`; the key lives in
/// the Keychain, one entry per provider. A remote provider is only used once the user consented,
/// except for a server on this device (nothing leaves it).
@Observable
@MainActor
final class AiProviderSettings {
    static let choiceKey = "ai.choice"
    nonisolated static var timeoutMs: UInt32 { 8_000 }

    private let defaults: UserDefaults
    private let keychain: KeychainStore
    private let resolver: ApiKeyResolver
    private let bundled: DefaultApiKeys
    private let quota: BundledAiQuota

    var choice: AiChoice {
        didSet {
            guard choice != oldValue else { return }
            defaults.set(choice.rawValue, forKey: Self.choiceKey)
            loadFields()
        }
    }
    var model = "" { didSet { if !isLoading { defaults.set(model, forKey: key("model")) } } }
    var baseURL = "" { didSet { if !isLoading { defaults.set(baseURL, forKey: key("baseURL")) } } }
    var apiKey = "" { didSet { if !isLoading { storeKey() } } }
    var consent = false { didSet { if !isLoading { defaults.set(consent, forKey: key("consent")) } } }
    /// Search with the provider while typing, without pressing Enter (on by default once a provider is ready).
    static let autoSearchKey = "assistant.autoSearch"
    var autoSearch: Bool {
        didSet { defaults.set(autoSearch, forKey: Self.autoSearchKey) }
    }

    /// The only thing between a chosen provider and its use is the user's consent: the palette offers it.
    var needsConsentOnly: Bool {
        choice.isRemote && !consent && !endpointIsLocal && blocker == "Cochez le consentement pour envoyer vos commandes à ce fournisseur."
    }
    private(set) var keychainError: String?

    @ObservationIgnored private var isLoading = false

    init(
        defaults: UserDefaults = .standard,
        keychain: KeychainStore = .shared,
        bundledKeys: DefaultApiKeys = .bundled
    ) {
        self.defaults = defaults
        self.keychain = keychain
        self.bundled = bundledKeys
        self.resolver = ApiKeyResolver(keychain: keychain, defaults: bundledKeys)
        self.quota = BundledAiQuota(defaults: defaults)
        autoSearch = defaults.object(forKey: Self.autoSearchKey) as? Bool ?? true
        // The provider `.env` proposes is only a starting point: the user's choice always wins, and a
        // remote provider still waits for the consent below.
        choice = defaults.string(forKey: Self.choiceKey).flatMap(AiChoice.init(rawValue:))
            ?? AiChoice(defaultProvider: bundledKeys.defaultAiProvider)
            ?? .localOnly
        loadFields()
    }

    private func key(_ field: String) -> String { "ai.\(choice.rawValue).\(field)" }

    private func loadFields() {
        isLoading = true
        defer { isLoading = false }
        model = defaults.string(forKey: key("model")) ?? (choice == .openAiCompatible ? bundled.openAIModel : nil) ?? ""
        baseURL = defaults.string(forKey: key("baseURL")) ?? (choice == .openAiCompatible ? bundled.openAIBaseURL : nil) ?? ""
        consent = defaults.bool(forKey: key("consent"))
        if let service = choice.apiService {
            // Only the user's own key is ever shown here; the bundled one never reaches the field.
            apiKey = resolver.userKey(service) ?? ""
        } else {
            apiKey = ""
        }
    }

    private func storeKey() {
        guard let keychainKey = choice.keychainKey else { return }
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if trimmed.isEmpty {
                try keychain.deleteSecret(forKey: keychainKey)
            } else {
                try keychain.saveSecret(trimmed, forKey: keychainKey)
            }
            keychainError = nil
        } catch {
            keychainError = error.localizedDescription
        }
    }

    var isAssistantEnabled: Bool { choice != .disabled }

    /// `localhost`, `127.0.0.1`, `::1` and `.local` hosts: the request never leaves this device.
    var endpointIsLocal: Bool {
        guard let host = URL(string: baseURL.trimmingCharacters(in: .whitespaces))?.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".local")
    }

    private var hasUserKey: Bool { !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// A key is available: the user's own, or the one baked into this build.
    var hasKey: Bool { hasUserKey || usesBundledKey }

    /// The provider runs on the default key of this build (the user has not entered one).
    var usesBundledKey: Bool {
        guard !hasUserKey, let service = choice.apiService else { return false }
        return bundled.has(service)
    }

    /// The day's budget of the bundled key is spent; the user's own key has none.
    var bundledQuotaExhausted: Bool { usesBundledKey && quota.isExhausted }

    /// What the call is going to use: the typed key, else the bundled one.
    private func effectiveKey() -> String? {
        if hasUserKey { return apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let service = choice.apiService else { return nil }
        return resolver.keyForCall(service)
    }

    /// Why a remote provider would not be used right now, or `nil` when it is ready.
    var blocker: String? {
        guard choice.isRemote else { return nil }
        if choice.requiresKey && !hasKey { return "Saisissez une clé API." }
        if bundledQuotaExhausted {
            return "La limite quotidienne de la clé intégrée (\(BundledAiQuota.dailyLimit) requêtes) est atteinte. Saisissez votre propre clé."
        }
        if choice == .openAiCompatible && baseURL.trimmingCharacters(in: .whitespaces).isEmpty && !hasKey {
            return "Saisissez l'adresse du serveur (ou une clé pour l'API officielle)."
        }
        if !consent && !endpointIsLocal { return "Cochez le consentement pour envoyer vos commandes à ce fournisseur." }
        return nil
    }

    /// With the bundled key, a refused key or an exhausted quota points the user to their own key.
    func explaining(_ message: String) -> String {
        guard usesBundledKey else { return message }
        let lower = message.lowercased()
        guard lower.contains("clé refusée") || lower.contains("quota") || lower.contains("limite") else { return message }
        return "\(message). Saisissez votre propre clé dans Réglages > Assistant IA."
    }

    var isRemoteReady: Bool { choice.isRemote && blocker == nil }

    /// The configuration for one call. Without consent or key it silently degrades to the local
    /// resolution: nothing is ever sent to a provider the user has not agreed to.
    func providerConfig() -> AiProviderConfig {
        guard isRemoteReady else {
            return AiProviderConfig(kind: .localOnly, model: "", baseUrl: nil, apiKey: nil, timeoutMs: Self.timeoutMs)
        }
        // The default key has a daily budget; a request past it degrades to the local resolution.
        if usesBundledKey, !quota.consume() {
            AppLog.shared.warn("KEYS", "Limite quotidienne de la clé par défaut atteinte (\(BundledAiQuota.dailyLimit))")
            return AiProviderConfig(kind: .localOnly, model: "", baseUrl: nil, apiKey: nil, timeoutMs: Self.timeoutMs)
        }
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespaces)
        return AiProviderConfig(
            kind: choice.kind,
            model: model.trimmingCharacters(in: .whitespaces),
            baseUrl: trimmedURL.isEmpty ? nil : trimmedURL,
            apiKey: effectiveKey(),
            timeoutMs: Self.timeoutMs
        )
    }

    /// Same as `providerConfig()` but ignoring the consent, for the explicit "Tester" button
    /// (pressing it is itself the user's decision to contact the provider).
    func testConfig() -> AiProviderConfig {
        guard choice.isRemote else { return providerConfig() }
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespaces)
        return AiProviderConfig(
            kind: choice.kind,
            model: model.trimmingCharacters(in: .whitespaces),
            baseUrl: trimmedURL.isEmpty ? nil : trimmedURL,
            apiKey: effectiveKey(),
            timeoutMs: Self.timeoutMs
        )
    }

    /// One line for the palette footer.
    var summary: String {
        switch choice {
        case .disabled: return "Assistant désactivé"
        case .localOnly: return "Résolution locale"
        default:
            if isRemoteReady { return "\(choice.title)\(endpointIsLocal ? " (sur cet appareil)" : "")" }
            return "Résolution locale (\(choice.title) non configuré)"
        }
    }
}
