import Foundation

enum ApiKeySource: Equatable, Sendable {
    case user
    case bundled

    var label: String { self == .user ? "clé utilisateur" : "clé par défaut" }
}

struct ResolvedApiKey: Sendable {
    let value: String
    let source: ApiKeySource
}

/// The one place that decides which key a service uses: the user's own (Keychain), else the default
/// baked into the build, else none (the feature stays off). PRD 28.
struct ApiKeyResolver: Sendable {
    var keychain: KeychainStore = .shared
    var defaults: DefaultApiKeys = .bundled

    static let shared = ApiKeyResolver()

    /// The user's own key, ignoring the bundled one (what Settings edits).
    func userKey(_ service: ApiService) -> String? {
        guard let value = try? keychain.readSecret(forKey: service.keychainKey) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func resolve(_ service: ApiService) -> ResolvedApiKey? {
        if let user = userKey(service) { return ResolvedApiKey(value: user, source: .user) }
        guard let bundled = defaults.key(for: service) else { return nil }
        return ResolvedApiKey(value: bundled, source: .bundled)
    }

    /// Whether the build carries a default key for the service, whatever the user did.
    func hasBundledKey(_ service: ApiService) -> Bool { defaults.has(service) }

    /// `true` when the service works only thanks to the default key (the Settings field is empty).
    func usesBundledKey(_ service: ApiService) -> Bool { resolve(service)?.source == .bundled }

    /// The key to hand to a call, with a single log line per service and launch that says which kind
    /// was used (never the value).
    func keyForCall(_ service: ApiService) -> String? {
        guard let resolved = resolve(service) else { return nil }
        Self.logUse(service, resolved.source)
        return resolved.value
    }

    private static let logged = NSLock()
    nonisolated(unsafe) private static var loggedServices: Set<String> = []

    private static func logUse(_ service: ApiService, _ source: ApiKeySource) {
        let token = "\(service.rawValue).\(source)"
        let isNew = logged.withLock { loggedServices.insert(token).inserted }
        if isNew { AppLog.shared.info("KEYS", "\(service.displayName) : \(source.label)") }
    }
}

/// Daily budget for the AI calls made with the bundled key only (50 per day and per device).
/// A user's own key is never limited.
struct BundledAiQuota {
    static let dailyLimit = 50
    private static let dayKey = "keys.bundledAi.day"
    private static let countKey = "keys.bundledAi.count"

    var defaults: UserDefaults = .standard
    var now: () -> Date = Date.init

    private var today: String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: now())
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }

    var used: Int { defaults.string(forKey: Self.dayKey) == today ? defaults.integer(forKey: Self.countKey) : 0 }
    var isExhausted: Bool { used >= Self.dailyLimit }

    /// Counts one request; `false` (and nothing counted) once the day's budget is spent.
    func consume() -> Bool {
        guard !isExhausted else { return false }
        defaults.set(today, forKey: Self.dayKey)
        defaults.set(used + 1, forKey: Self.countKey)
        return true
    }
}
