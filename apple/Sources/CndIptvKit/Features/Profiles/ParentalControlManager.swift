import Foundation
#if !os(tvOS)
import LocalAuthentication
#endif
import Observation
import Security
import CryptoKit
import CommonCrypto

/// How the parental PIN is stored: PBKDF2-HMAC-SHA256 with a random salt, so a leaked value cannot be
/// reversed by trying the few thousand possible PINs at memory speed.
///
/// Layout (v2): `"P2"` + iterations (UInt32, big endian) + salt (16) + derived key (32).
/// The first version was `salt (16) + SHA256(salt + pin)` (48 bytes); it still verifies and is upgraded.
enum PinHasher {
    static let iterations: UInt32 = 600_000
    private static let magic = Data("P2".utf8)
    private static let saltLength = 16
    private static let keyLength = 32

    /// 4 to 6 digits.
    static func isValid(pin: String) -> Bool {
        (4...6).contains(pin.count) && pin.allSatisfy { $0.isASCII && $0.isNumber }
    }

    static func derive(pin: String, salt: Data, iterations: UInt32) -> Data? {
        var key = Data(count: keyLength)
        let pinBytes = Array(pin.utf8)
        let status = key.withUnsafeMutableBytes { keyPointer in
            salt.withUnsafeBytes { saltPointer in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pinBytes.map { CChar(bitPattern: $0) }, pinBytes.count,
                    saltPointer.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                    keyPointer.bindMemory(to: UInt8.self).baseAddress, keyLength
                )
            }
        }
        return status == kCCSuccess ? key : nil
    }

    static func encode(pin: String, iterations: UInt32 = PinHasher.iterations) -> Data? {
        var generator = SystemRandomNumberGenerator()
        let salt = Data((0..<saltLength).map { _ in UInt8.random(in: 0...255, using: &generator) })
        guard let key = derive(pin: pin, salt: salt, iterations: iterations) else { return nil }
        var count = iterations.bigEndian
        return magic + Data(bytes: &count, count: 4) + salt + key
    }

    enum Verdict: Equatable {
        case wrong
        case correct
        /// Correct, but stored with the old scheme: the caller should store it again with `encode`.
        case correctNeedsUpgrade
    }

    static func verify(pin: String, stored: Data) -> Verdict {
        if stored.count == magic.count + 4 + saltLength + keyLength, stored.prefix(magic.count) == magic {
            let countStart = stored.startIndex + magic.count
            let iterations = stored[countStart..<countStart + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let salt = Data(stored[(countStart + 4)..<(countStart + 4 + saltLength)])
            let expected = Data(stored.suffix(keyLength))
            guard iterations > 0, let key = derive(pin: pin, salt: salt, iterations: iterations) else { return .wrong }
            return constantTimeEqual(key, expected) ? .correct : .wrong
        }
        if stored.count == saltLength + keyLength { // version 1
            let salt = stored.prefix(saltLength)
            let computed = Data(SHA256.hash(data: salt + Data(pin.utf8)))
            return constantTimeEqual(computed, Data(stored.suffix(keyLength))) ? .correctNeedsUpgrade : .wrong
        }
        return .wrong
    }

    private static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// Manages PIN storage, Face ID / Touch ID authentication, and adult content session unlock.
@Observable
@MainActor
public final class ParentalControlManager {
    public static let shared = ParentalControlManager()

    private let service: String
    private let account = "pin_hash"

    public private(set) var hasPin: Bool = false
    public private(set) var adultUnlockedUntil: Date?

    public var isAdultUnlocked: Bool {
        guard let until = adultUnlockedUntil else { return false }
        return until > Date()
    }

    public init(service: String = "com.cnd.iptv.parental") {
        self.service = service
        self.hasPin = checkHasPin()
    }

    // MARK: - Adult Session Unlock

    /// Called whenever the adult-content session starts or ends (the app then shows or hides the categories).
    @ObservationIgnored public var onAdultSessionChange: (() -> Void)?
    @ObservationIgnored private var relockTask: Task<Void, Never>?

    public func unlockAdultSession(durationMinutes: Int = 15) {
        unlockAdultSession(duration: TimeInterval(durationMinutes * 60))
    }

    /// Adult categories stay visible for `duration`, then lock again by themselves.
    func unlockAdultSession(duration: TimeInterval) {
        adultUnlockedUntil = Date().addingTimeInterval(duration)
        relockTask?.cancel()
        relockTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.lockAdultSession()
        }
        onAdultSessionChange?()
    }

    public func lockAdultSession() {
        relockTask?.cancel()
        relockTask = nil
        let wasUnlocked = adultUnlockedUntil != nil
        adultUnlockedUntil = nil
        if wasUnlocked { onAdultSessionChange?() }
    }

    // MARK: - PIN Management (Keychain)

    public func setPin(_ pin: String) -> Bool {
        guard PinHasher.isValid(pin: pin), let payload = PinHasher.encode(pin: pin) else { return false }

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
        guard status == errSecSuccess, let data = result as? Data else { return false }
        switch PinHasher.verify(pin: pin, stored: data) {
        case .wrong:
            return false
        case .correct:
            return true
        case .correctNeedsUpgrade:
            _ = setPin(pin) // store it again with PBKDF2
            return true
        }
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
