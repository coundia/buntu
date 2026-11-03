import Foundation
import Security

public enum KeychainStoreError: Error, LocalizedError {
    case unexpectedStatus(OSStatus)
    /// iCloud Keychain needs an app signed with a team (not an ad-hoc or unsigned build).
    case iCloudUnavailable
    case invalidDataEncoding

    public var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            if let msg = SecCopyErrorMessageString(status, nil) as String? {
                return "Keychain error (\(status)): \(msg)"
            }
            return "Keychain error (\(status))"
        case .iCloudUnavailable:
            return "Le Trousseau iCloud n'est pas disponible dans cette version de l'app (signature locale ou Trousseau iCloud désactivé)."
        case .invalidDataEncoding:
            return "Unable to encode or decode UTF-8 Keychain secret"
        }
    }
}

/// Where a secret lives: only in this device's keychain, or in iCloud Keychain (synchronized).
public enum KeychainScope: Sendable {
    case local
    case iCloud

    var other: KeychainScope { self == .local ? .iCloud : .local }
}

public final class KeychainStore: @unchecked Sendable {
    /// Opt-in (off by default): Xtream passwords go to iCloud Keychain so another device finds them.
    public static let syncPasswordsDefaultsKey = "keychain.syncPasswords"

    public static let shared = KeychainStore()
    public static let defaultService = "com.cnd.iptv.credentials"
    public static let omdbApiKeyRef = "cnd.omdb.apikey"

    public let service: String
    private let fallbackLock = NSLock()
    private var memoryFallback: [String: String] = [:]

    private let defaults: UserDefaults

    public init(service: String = KeychainStore.defaultService, defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
    }

    /// Where new source passwords are written, from the user's choice in Settings.
    public var passwordScope: KeychainScope {
        get { defaults.bool(forKey: Self.syncPasswordsDefaultsKey) ? .iCloud : .local }
        set { defaults.set(newValue == .iCloud, forKey: Self.syncPasswordsDefaultsKey) }
    }

    /// Attributes selecting a keychain item. A `nil` scope matches the item wherever it is stored.
    static func itemQuery(service: String, key: String, scope: KeychainScope?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        switch scope {
        case .local?: break // not synchronizable is the default for an item
        case .iCloud?: query[kSecAttrSynchronizable as String] = kCFBooleanTrue
        case nil: query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        }
        return query
    }

    public static func xtreamKey(forSourceUuid uuid: String) -> String {
        "cnd.xtream.\(uuid)"
    }

    /// Writes a source password where the user chose (`passwordScope`).
    public func savePassword(_ secret: String, forKey key: String) throws {
        try saveSecret(secret, forKey: key, scope: passwordScope)
    }

    public func saveSecret(_ secret: String, forKey key: String, scope: KeychainScope = .local) throws {
        guard let data = secret.data(using: .utf8) else {
            throw KeychainStoreError.invalidDataEncoding
        }

        let baseQuery = Self.itemQuery(service: service, key: key, scope: scope)
        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecSuccess {
            finishSave(forKey: key, scope: scope)
            return
        }

        var failure = status
        if status == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if updateStatus == errSecSuccess {
                finishSave(forKey: key, scope: scope)
                return
            }
            failure = updateStatus
        }

        if isKeychainUnavailableInEnvironment(failure) {
            // A password kept only in memory would vanish at the next launch: never pretend for iCloud.
            if scope == .iCloud { throw KeychainStoreError.iCloudUnavailable }
            setFallback(secret, forKey: key)
            return
        }
        throw KeychainStoreError.unexpectedStatus(failure)
    }

    /// Only once the new copy is safely stored: the same account in both keychains would be two
    /// separate items, so the one in the other keychain is removed.
    private func finishSave(forKey key: String, scope: KeychainScope) {
        removeFallback(forKey: key)
        try? removeItems(forKey: key, scope: scope.other)
    }

    /// Moves existing secrets to the given keychain (e.g. when the user turns the iCloud option on or
    /// off). Secrets that do not exist are skipped. Returns how many were moved.
    @discardableResult
    public func move(keys: [String], to scope: KeychainScope) throws -> Int {
        var moved = 0
        for key in keys {
            guard let value = try readSecret(forKey: key) else { continue }
            try saveSecret(value, forKey: key, scope: scope)
            moved += 1
        }
        return moved
    }

    public func readSecret(forKey key: String) throws -> String? {
        var query = Self.itemQuery(service: service, key: key, scope: nil)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecItemNotFound {
            return getFallback(forKey: key)
        }

        if isKeychainUnavailableInEnvironment(status) {
            return getFallback(forKey: key)
        }

        guard status == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(status)
        }

        guard let data = item as? Data,
              let decoded = String(data: data, encoding: .utf8) else {
            throw KeychainStoreError.invalidDataEncoding
        }

        return decoded
    }

    public func deleteSecret(forKey key: String) throws {
        removeFallback(forKey: key)
        try removeItems(forKey: key, scope: nil)
    }

    private func removeItems(forKey key: String, scope: KeychainScope?) throws {
        let status = SecItemDelete(Self.itemQuery(service: service, key: key, scope: scope) as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound || isKeychainUnavailableInEnvironment(status) {
            return
        }
        throw KeychainStoreError.unexpectedStatus(status)
    }

    private func isKeychainUnavailableInEnvironment(_ status: OSStatus) -> Bool {
        // Unsigned CLI/headless test runners without entitlements may return -34018, -25291, or -25308
        status == -34018
            || status == errSecNotAvailable
            || status == errSecInteractionNotAllowed
    }

    private func setFallback(_ value: String, forKey key: String) {
        fallbackLock.lock()
        defer { fallbackLock.unlock() }
        memoryFallback[key] = value
    }

    private func getFallback(forKey key: String) -> String? {
        fallbackLock.lock()
        defer { fallbackLock.unlock() }
        return memoryFallback[key]
    }

    private func removeFallback(forKey key: String) {
        fallbackLock.lock()
        defer { fallbackLock.unlock() }
        memoryFallback.removeValue(forKey: key)
    }
}

