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

        // 2. Load household key from Keychain
        reloadFromKeychain()
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
        knownDevices = []
        UserDefaults.standard.removeObject(forKey: Self.knownDevicesDefaultsKey)
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

