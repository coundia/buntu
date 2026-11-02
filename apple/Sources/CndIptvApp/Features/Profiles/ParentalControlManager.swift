import Foundation
import LocalAuthentication
import Observation
import Security
import CryptoKit

/// Manages PIN storage, Face ID / Touch ID authentication, and adult content session unlock.
@Observable
@MainActor
public final class ParentalControlManager {
    public static let shared = ParentalControlManager()

    private let service = "com.cnd.iptv.parental"
    private let account = "pin_hash"

    public private(set) var hasPin: Bool = false
    public private(set) var adultUnlockedUntil: Date?

    public var isAdultUnlocked: Bool {
        guard let until = adultUnlockedUntil else { return false }
        return until > Date()
    }

    public init() {
        self.hasPin = checkHasPin()
    }

    // MARK: - Adult Session Unlock

    public func unlockAdultSession(durationMinutes: Int = 15) {
        adultUnlockedUntil = Date().addingTimeInterval(TimeInterval(durationMinutes * 60))
    }

    public func lockAdultSession() {
        adultUnlockedUntil = nil
    }

    // MARK: - PIN Management (Keychain)

    public func setPin(_ pin: String) -> Bool {
        guard pin.count >= 4 else { return false }
        let salt = (0..<16).map { _ in UInt8.random(in: 0...255) }
        let saltedData = Data(salt) + Data(pin.utf8)
        let hash = SHA256.hash(data: saltedData)
        let payload = Data(salt) + Data(hash)

        let deleteQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: payload,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        let success = status == errSecSuccess
        if success {
            hasPin = true
        }
        return success
    }

    public func verifyPin(_ pin: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, data.count >= 48 else {
            return false
        }
        let salt = data.prefix(16)
        let storedHash = data.suffix(32)
        let computedHash = SHA256.hash(data: salt + Data(pin.utf8))
        return Data(computedHash) == storedHash
    }

    public func removePin() -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        let success = status == errSecSuccess || status == errSecItemNotFound
        if success {
            hasPin = false
            lockAdultSession()
        }
        return success
    }

    private func checkHasPin() -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: false,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    // MARK: - Biometrics (Face ID / Touch ID)

    public var isBiometricsAvailable: Bool {
        #if os(tvOS)
        return false
        #else
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        #endif
    }

    public func authenticateWithBiometrics(reason: String = "Déverrouiller le contenu protégé") async -> Bool {
        #if os(tvOS)
        return false
        #else
        let context = LAContext()
        context.localizedCancelTitle = "Annuler"
        var error: NSError?

        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            do {
                return try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
            } catch {
                return false
            }
        }
        return false
        #endif
    }
}
