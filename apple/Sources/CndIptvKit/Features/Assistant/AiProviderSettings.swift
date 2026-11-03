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
    private(set) var keychainError: String?

    @ObservationIgnored private var isLoading = false

    init(defaults: UserDefaults = .standard, keychain: KeychainStore = .shared) {
        self.defaults = defaults
        self.keychain = keychain
        choice = defaults.string(forKey: Self.choiceKey).flatMap(AiChoice.init(rawValue:)) ?? .localOnly
        loadFields()
    }

    private func key(_ field: String) -> String { "ai.\(choice.rawValue).\(field)" }

    private func loadFields() {
        isLoading = true
        defer { isLoading = false }
        model = defaults.string(forKey: key("model")) ?? ""
        baseURL = defaults.string(forKey: key("baseURL")) ?? ""
        consent = defaults.bool(forKey: key("consent"))
        if let keychainKey = choice.keychainKey {
            apiKey = (try? keychain.readSecret(forKey: keychainKey)) ?? ""
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

    var hasKey: Bool { !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Why a remote provider would not be used right now, or `nil` when it is ready.
    var blocker: String? {
        guard choice.isRemote else { return nil }
        if choice.requiresKey && !hasKey { return "Saisissez une clé API." }
        if choice == .openAiCompatible && baseURL.trimmingCharacters(in: .whitespaces).isEmpty && !hasKey {
            return "Saisissez l'adresse du serveur (ou une clé pour l'API officielle)."
        }
        if !consent && !endpointIsLocal { return "Cochez le consentement pour envoyer vos commandes à ce fournisseur." }
        return nil
    }

    var isRemoteReady: Bool { choice.isRemote && blocker == nil }

    /// The configuration for one call. Without consent or key it silently degrades to the local
    /// resolution: nothing is ever sent to a provider the user has not agreed to.
    func providerConfig() -> AiProviderConfig {
        guard isRemoteReady else {
            return AiProviderConfig(kind: .localOnly, model: "", baseUrl: nil, apiKey: nil, timeoutMs: Self.timeoutMs)
        }
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespaces)
        return AiProviderConfig(
            kind: choice.kind,
            model: model.trimmingCharacters(in: .whitespaces),
            baseUrl: trimmedURL.isEmpty ? nil : trimmedURL,
            apiKey: hasKey ? apiKey.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
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
            apiKey: hasKey ? apiKey.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
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
