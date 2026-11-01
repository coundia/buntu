import Foundation
import Security

public enum KeychainStoreError: Error, LocalizedError {
    case unexpectedStatus(OSStatus)
    case invalidDataEncoding

    public var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            if let msg = SecCopyErrorMessageString(status, nil) as String? {
                return "Keychain error (\(status)): \(msg)"
            }
            return "Keychain error (\(status))"
        case .invalidDataEncoding:
            return "Unable to encode or decode UTF-8 Keychain secret"
        }
    }
}

public final class KeychainStore: @unchecked Sendable {
    public static let shared = KeychainStore()
    public static let defaultService = "com.cnd.iptv.credentials"
    public static let omdbApiKeyRef = "cnd.omdb.apikey"

    public let service: String
    private let fallbackLock = NSLock()
    private var memoryFallback: [String: String] = [:]

    public init(service: String = KeychainStore.defaultService) {
        self.service = service
    }

    public static func xtreamKey(forSourceUuid uuid: String) -> String {
        "cnd.xtream.\(uuid)"
    }

    public func saveSecret(_ secret: String, forKey key: String) throws {
        guard let data = secret.data(using: .utf8) else {
            throw KeychainStoreError.invalidDataEncoding
        }

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecSuccess {
            removeFallback(forKey: key)
            return
        }

        if status == errSecDuplicateItem {
            let attributesToUpdate: [String: Any] = [
                kSecValueData as String: data
            ]
            let updateStatus = SecItemUpdate(
                baseQuery as CFDictionary,
                attributesToUpdate as CFDictionary
            )
            if updateStatus == errSecSuccess {
                removeFallback(forKey: key)
                return
            }
            if isKeychainUnavailableInEnvironment(updateStatus) {
                setFallback(secret, forKey: key)
                return
            }
            throw KeychainStoreError.unexpectedStatus(updateStatus)
        }

        if isKeychainUnavailableInEnvironment(status) {
            setFallback(secret, forKey: key)
            return
        }

        throw KeychainStoreError.unexpectedStatus(status)
    }

    public func readSecret(forKey key: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

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

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        let status = SecItemDelete(query as CFDictionary)
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

