import Foundation
import Observation
import Security
import CndCoreBridge

/// Manages household credentials, persistent device identity, and monotonic sequence barriers (PRD-41 § 5 & § 6).
@Observable
public final class HouseholdStore: @unchecked Sendable {
    public static let shared = HouseholdStore()

    private static let serviceName = "com.pcoundia.buntu.household"
    private static let keyAccount = "household_key_v1"
    private static let deviceIdDefaultsKey = "cnd.sync.deviceId"
    private static let sequenceDefaultsKey = "cnd.sync.sequence"
    private static let knownDevicesDefaultsKey = "cnd.sync.knownDevices"
    private static let previousKeyAccount = "household_key_prev_v1"
    private static let rekeyStateDefaultsKey = "cnd.sync.rekeyState"
    /// How long the previous key is kept to hand the new one to devices that were offline.
    static let rekeyGraceInterval: TimeInterval = 30 * 24 * 3600

    public private(set) var deviceId: String
    public private(set) var deviceName: String
    public private(set) var deviceType: String
    public private(set) var householdId: String?
    public private(set) var isJoined: Bool = false
    public private(set) var sequence: UInt64 = 0

    private let lock = NSLock()
    private var lastSeenSequenceByDevice: [String: UInt64] = [:]

    public init() {
        // 1. Device identity
        let defaults = UserDefaults.standard
        if let existingId = defaults.string(forKey: Self.deviceIdDefaultsKey), !existingId.isEmpty {
            self.deviceId = existingId
        } else {
            let newId = "apple_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            defaults.set(newId, forKey: Self.deviceIdDefaultsKey)
            self.deviceId = newId
        }

        self.deviceName = DeviceName.current

        #if os(iOS)
        self.deviceType = "mobile"
        #elseif os(macOS)
        self.deviceType = "desktop"
        #elseif os(tvOS)
        self.deviceType = "tv"
        #else
        self.deviceType = "mobile"
        #endif

        self.sequence = UInt64(defaults.integer(forKey: Self.sequenceDefaultsKey))
        if self.sequence == 0 {
            self.sequence = UInt64(Date().timeIntervalSince1970 * 1000)
        }

        if let data = defaults.data(forKey: Self.knownDevicesDefaultsKey),
           let saved = try? JSONDecoder().decode([KnownDevice].self, from: data) {
            self.knownDevices = saved
        }

        if let data = defaults.data(forKey: Self.rekeyStateDefaultsKey),
           let saved = try? JSONDecoder().decode(RekeyState.self, from: data) {
            self.rekeyState = saved
        }

        // 2. Load household key from Keychain
        reloadFromKeychain()
        expireRekeyIfNeeded()
    }

    public func reloadFromKeychain() {
        lock.lock()
        defer { lock.unlock() }

        guard let keyHex = try? KeychainStore.shared.readSecret(forKey: Self.keyAccount),
              keyHex.count == 64 else {
            self.householdId = nil
            self.isJoined = false
            return
        }

        do {
            let derivedId = try syncDeriveHouseholdId(householdKeyHex: keyHex)
            self.householdId = derivedId
            self.isJoined = true
        } catch {
            self.householdId = nil
            self.isJoined = false
        }
    }

    /// Creates a brand new household with 32 cryptographically secure random bytes.
    public func createHousehold() throws -> HouseholdCredentials {
        var entropy = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, 32, &entropy)
        guard status == errSecSuccess else {
            throw NSError(domain: "HouseholdStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Échec génération aléatoire sécurisée"])
        }

        let creds = try syncCreateHousehold(entropy: Data(entropy))
        try KeychainStore.shared.saveSecret(creds.householdKeyHex, forKey: Self.keyAccount)

        lock.lock()
        self.householdId = creds.householdId
        self.isJoined = true
        self.lastSeenSequenceByDevice.removeAll()
        clearKnownDevicesLocked()
        lock.unlock()

        return creds
    }

    /// Joins an existing household using a 64-char hex key (e.g. from a QR code or pairing invite).
    public func joinHousehold(keyHex: String) throws -> String {
        let trimmed = keyHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.count == 64 else {
            throw NSError(domain: "HouseholdStore", code: 2, userInfo: [NSLocalizedDescriptionKey: "Clé de foyer invalide (64 caractères hexadécimaux attendus)"])
        }

        let derivedId = try syncDeriveHouseholdId(householdKeyHex: trimmed)
        try KeychainStore.shared.saveSecret(trimmed, forKey: Self.keyAccount)

        lock.lock()
        self.householdId = derivedId
        self.isJoined = true
        self.lastSeenSequenceByDevice.removeAll()
        clearKnownDevicesLocked()
        lock.unlock()

        return derivedId
    }

    /// Leaves the household and purges the key from Keychain.
    public func leaveHousehold() {
        try? KeychainStore.shared.deleteSecret(forKey: Self.keyAccount)
        lock.lock()
        self.householdId = nil
        self.isJoined = false
        self.lastSeenSequenceByDevice.removeAll()
        clearKnownDevicesLocked()
        lock.unlock()
    }

    // MARK: - Known devices (roster)

    /// A device that belongs to the household, remembered even when it is offline.
    public struct KnownDevice: Codable, Identifiable, Hashable, Sendable {
        public let id: String
        public var name: String
        public var deviceType: String
        public var lastSeen: Date
    }

    /// Every device this one has accepted or seen in the household, most recent first.
    public private(set) var knownDevices: [KnownDevice] = []

    /// Records (or refreshes) a household device. Persists only when something visible changed.
    public func rememberDevice(id: String, name: String, deviceType: String, seenAt: Date = Date()) {
        guard !id.isEmpty, id != deviceId else { return }
        lock.lock()
        defer { lock.unlock() }
        if let idx = knownDevices.firstIndex(where: { $0.id == id }) {
            let old = knownDevices[idx]
            let changed = old.name != name || old.deviceType != deviceType
            if !changed && seenAt.timeIntervalSince(old.lastSeen) < 60 { return }
            knownDevices[idx] = KnownDevice(id: id, name: name, deviceType: deviceType, lastSeen: max(seenAt, old.lastSeen))
        } else {
            knownDevices.append(KnownDevice(id: id, name: name, deviceType: deviceType, lastSeen: seenAt))
        }
        persistKnownDevicesLocked()
    }

    private func persistKnownDevicesLocked() {
        if let data = try? JSONEncoder().encode(knownDevices) {
            UserDefaults.standard.set(data, forKey: Self.knownDevicesDefaultsKey)
        }
    }

    private func clearKnownDevicesLocked() {
        clearRekeyLocked()
        knownDevices = []
        UserDefaults.standard.removeObject(forKey: Self.knownDevicesDefaultsKey)
    }

    // MARK: - Removing a device (key change, PRD-41 lot 41.3)

    /// After a key change: the previous household id and the devices that have not yet been seen with
    /// the new key. Until each one shows up, the previous key is kept to hand it the new key.
    public struct RekeyState: Codable, Equatable, Sendable {
        public var previousHouseholdId: String
        public var pendingDeviceIds: [String]
        public var since: Date
        /// The device that was removed, so that a device told later forgets it too.
        public var removedDeviceId: String?
    }

    public private(set) var rekeyState: RekeyState?

    /// A fresh random 64-hex household key.
    public func generateKeyHex() throws -> String {
        var entropy = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, 32, &entropy) == errSecSuccess else {
            throw NSError(domain: "HouseholdStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Échec génération aléatoire sécurisée"])
        }
        return try syncCreateHousehold(entropy: Data(entropy)).householdKeyHex
    }

    /// Switches to `newKeyHex`, forgets `removedDeviceId`, keeps the old key for the devices still to be told.
    public func applyRekey(newKeyHex: String, removing removedDeviceId: String?) throws {
        let newKey = newKeyHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard HouseholdRekeyMessage.isValidKeyHex(newKey) else {
            throw NSError(domain: "HouseholdStore", code: 2, userInfo: [NSLocalizedDescriptionKey: "Clé de foyer invalide"])
        }
        lock.lock()
        defer { lock.unlock() }
        guard isJoined, let oldId = householdId,
              let oldKey = try? KeychainStore.shared.readSecret(forKey: Self.keyAccount) else {
            throw NSError(domain: "HouseholdStore", code: 5, userInfo: [NSLocalizedDescriptionKey: "Aucun foyer"])
        }
        let newId = try syncDeriveHouseholdId(householdKeyHex: newKey)
        guard newId != oldId else { return }

        try KeychainStore.shared.saveSecret(oldKey, forKey: Self.previousKeyAccount)
        try KeychainStore.shared.saveSecret(newKey, forKey: Self.keyAccount)

        let pending = knownDevices.map(\.id).filter { $0 != removedDeviceId && $0 != deviceId }
        if let removedDeviceId { knownDevices.removeAll { $0.id == removedDeviceId } }
        persistKnownDevicesLocked()
        householdId = newId
        if pending.isEmpty {
            clearRekeyLocked()
        } else {
            rekeyState = RekeyState(previousHouseholdId: oldId, pendingDeviceIds: pending, since: Date(), removedDeviceId: removedDeviceId)
            persistRekeyLocked()
        }
    }

    /// The key to read messages of a device that has not yet received the new one.
    public func previousKeyHex(for senderDeviceId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let state = rekeyState, state.pendingDeviceIds.contains(senderDeviceId) else { return nil }
        return try? KeychainStore.shared.readSecret(forKey: Self.previousKeyAccount)
    }

    /// The device spoke with the new key: it no longer needs the old one.
    public func markRekeyDelivered(_ senderDeviceId: String) {
        lock.lock()
        defer { lock.unlock() }
        guard var state = rekeyState, state.pendingDeviceIds.contains(senderDeviceId) else { return }
        state.pendingDeviceIds.removeAll { $0 == senderDeviceId }
        if state.pendingDeviceIds.isEmpty {
            clearRekeyLocked()
        } else {
            rekeyState = state
            persistRekeyLocked()
        }
    }

    public func isKnownDevice(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return knownDevices.contains { $0.id == id }
    }

    /// Drops the old key once the grace period is over (a device that never came back stays out).
    public func expireRekeyIfNeeded(now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        if let state = rekeyState, now.timeIntervalSince(state.since) > Self.rekeyGraceInterval {
            clearRekeyLocked()
        }
    }

    private func persistRekeyLocked() {
        if let data = try? JSONEncoder().encode(rekeyState) {
            UserDefaults.standard.set(data, forKey: Self.rekeyStateDefaultsKey)
        }
    }

    private func clearRekeyLocked() {
        rekeyState = nil
        UserDefaults.standard.removeObject(forKey: Self.rekeyStateDefaultsKey)
        try? KeychainStore.shared.deleteSecret(forKey: Self.previousKeyAccount)
    }

    /// Gets current 64-char household key hex if joined.
    public func currentHouseholdKeyHex() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard isJoined else { return nil }
        return try? KeychainStore.shared.readSecret(forKey: Self.keyAccount)
    }

    /// Returns next monotonic sequence number for outgoing envelopes.
    public func nextSequence() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        sequence += 1
        UserDefaults.standard.set(Int(sequence), forKey: Self.sequenceDefaultsKey)
        return sequence
    }

    /// Verifies and updates the sequence barrier for incoming peer envelopes to reject replays.
    public func verifyAndAdvanceSequence(senderDeviceId: String, sequence: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let lastSeen = lastSeenSequenceByDevice[senderDeviceId] ?? 0
        if sequence <= lastSeen {
            return false // Replay or out of order
        }
        lastSeenSequenceByDevice[senderDeviceId] = sequence
        return true
    }

    public func lastSeenSequence(for senderDeviceId: String) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return lastSeenSequenceByDevice[senderDeviceId] ?? 0
    }
}

/// `household_rekey`: the new household key, sent (sealed with the old key) to each remaining device
/// when one device is removed.
public enum HouseholdRekeyMessage {
    public static func isValidKeyHex(_ hex: String) -> Bool {
        hex.count == 64 && hex.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    public static func json(newKeyHex: String, removedDeviceId: String) -> String? {
        let dict: [String: Any] = ["type": "household_rekey", "new_key_hex": newKeyHex, "removed_device_id": removedDeviceId]
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func parse(_ root: [String: Any]) -> (newKeyHex: String, removedDeviceId: String?)? {
        guard root["type"] as? String == "household_rekey",
              let key = (root["new_key_hex"] as? String)?.lowercased(),
              isValidKeyHex(key) else { return nil }
        return (key, root["removed_device_id"] as? String)
    }
}
