import Foundation
import Network
import Observation
import Security
import CndCoreBridge

// MARK: - Wire DTOs for JSON Serialization

struct EnvelopeWireDTO: Codable {
    var household_id: String
    var sender_device_id: String
    var sequence: UInt64
    var nonce_hex: String
    var ciphertext_hex: String

    func toSealed() -> HouseholdSealedEnvelope {
        HouseholdSealedEnvelope(
            householdId: household_id,
            senderDeviceId: sender_device_id,
            sequence: sequence,
            nonceHex: nonce_hex,
            ciphertextHex: ciphertext_hex
        )
    }

    init(_ sealed: HouseholdSealedEnvelope) {
        self.household_id = sealed.householdId
        self.sender_device_id = sealed.senderDeviceId
        self.sequence = sealed.sequence
        self.nonce_hex = sealed.nonceHex
        self.ciphertext_hex = sealed.ciphertextHex
    }
}

struct SyncProfileDTO: Codable {
    var uuid: String
    var name: String
    var avatar: String
    var is_kids: Bool
    var updated_at: Int64

    func toNative() -> SyncProfile {
        SyncProfile(uuid: uuid, name: name, avatar: avatar, isKids: is_kids, updatedAt: updated_at)
    }
    init(_ p: SyncProfile) {
        self.uuid = p.uuid
        self.name = p.name
        self.avatar = p.avatar
        self.is_kids = p.isKids
        self.updated_at = p.updatedAt
    }
}

struct SyncSourceDTO: Codable {
    var uuid: String
    var name: String
    var source_type: String
    var url: String?
    var server: String?
    var username: String?
    var password_ref: String?
    var epg_url: String?
    var updated_at: Int64
    /// Xtream password, added when the delta travels between household devices (end-to-end encrypted by
    /// the envelope). Never stored in the database: it goes to the Keychain of the receiving device.
    var password: String?

    func toNative() -> SyncSource {
        SyncSource(uuid: uuid, name: name, sourceType: source_type, url: url, server: server, username: username, passwordRef: password_ref, epgUrl: epg_url, updatedAt: updated_at)
    }
    init(_ s: SyncSource) {
        self.uuid = s.uuid
        self.name = s.name
        self.source_type = s.sourceType
        self.url = s.url
        self.server = s.server
        self.username = s.username
        self.password_ref = s.passwordRef
        self.epg_url = s.epgUrl
        self.updated_at = s.updatedAt
    }
}

struct SyncFavoriteDTO: Codable {
    var stable_hash: String
    var item_kind: String
    var created_at: Int64
    var profile_uuid: String?

    func toNative() -> SyncFavorite {
        SyncFavorite(stableHash: stable_hash, itemKind: item_kind, createdAt: created_at, profileUuid: profile_uuid)
    }
    init(_ f: SyncFavorite) {
        self.stable_hash = f.stableHash
        self.item_kind = f.itemKind
        self.created_at = f.createdAt
        self.profile_uuid = f.profileUuid
    }
}

struct SyncWatchProgressDTO: Codable {
    var stable_hash: String
    var position_ms: Int64
    var duration_ms: Int64
    var completed: Bool
    var last_watched_at: Int64
    var profile_uuid: String?

    func toNative() -> SyncWatchProgress {
        SyncWatchProgress(stableHash: stable_hash, positionMs: position_ms, durationMs: duration_ms, completed: completed, lastWatchedAt: last_watched_at, profileUuid: profile_uuid)
    }
    init(_ w: SyncWatchProgress) {
        self.stable_hash = w.stableHash
        self.position_ms = w.positionMs
        self.duration_ms = w.durationMs
        self.completed = w.completed
        self.last_watched_at = w.lastWatchedAt
        self.profile_uuid = w.profileUuid
    }
}

struct SyncTombstoneDTO: Codable {
    var kind: String
    var key: String
    var deleted_at: Int64

    func toNative() -> SyncTombstone {
        SyncTombstone(kind: kind, key: key, deletedAt: deleted_at)
    }
    init(_ t: SyncTombstone) {
        self.kind = t.kind
        self.key = t.key
        self.deleted_at = t.deletedAt
    }
}

struct SyncDeltaDTO: Codable {
    var profiles: [SyncProfileDTO]
    var sources: [SyncSourceDTO]
    var favorites: [SyncFavoriteDTO]
    var watch_history: [SyncWatchProgressDTO]
    var tombstones: [SyncTombstoneDTO]

    func toNative() -> SyncDelta {
        SyncDelta(
            profiles: profiles.map { $0.toNative() },
            sources: sources.map { $0.toNative() },
            favorites: favorites.map { $0.toNative() },
            watchHistory: watch_history.map { $0.toNative() },
            tombstones: tombstones.map { $0.toNative() }
        )
    }
    init(_ d: SyncDelta) {
        self.profiles = d.profiles.map { SyncProfileDTO($0) }
        self.sources = d.sources.map { SyncSourceDTO($0) }
        self.favorites = d.favorites.map { SyncFavoriteDTO($0) }
        self.watch_history = d.watchHistory.map { SyncWatchProgressDTO($0) }
        self.tombstones = d.tombstones.map { SyncTombstoneDTO($0) }
    }
}

public struct DiscoveredPeer: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let deviceType: String
    public let canPlay: Bool
    public let capabilities: [String]
    public let state: String
    public let lastSeen: Date

    public init(
        id: String,
        name: String,
        deviceType: String,
        canPlay: Bool = true,
        capabilities: [String] = [],
        state: String = "idle",
        lastSeen: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.deviceType = deviceType
        self.canPlay = canPlay
        self.capabilities = capabilities
        self.state = state
        self.lastSeen = lastSeen
    }
}

public struct SyncLogEntry: Identifiable, Sendable {
    public let id = UUID()
    public let date: Date
    public let isWarning: Bool
    public let text: String
}

public struct PlayRequestDTO: Codable, Sendable {
    public var target_device_id: String
    public var request_id: String
    public var content_key: String
    public var source_key: String?
    public var item_kind: String
    public var provider_ref: String?
    public var title: String?
    public var position_ms: UInt64
    public var profile_uuid: String?
    public var replace: Bool
}

public struct PlaybackStateDTO: Codable, Sendable {
    public var device_id: String
    public var content_key: String?
    public var title: String?
    public var state: String
    public var position_ms: UInt64
    public var duration_ms: UInt64
    public var controls: [String]?
}

/// Serverless local network continuity transport over Bonjour (_buntu-sync._tcp) + TCP (PRD-41 Lot 41.4).
/// End-to-end encrypted with AES-256-GCM using the 256-bit Household Key from HouseholdStore.
@Observable
public final class LocalSyncService: @unchecked Sendable {
    public static let serviceType = "_buntu-sync._tcp"
    private static let exportCursorKey = "cnd.sync.lastExportTs.seconds"

    public private(set) var activePeers: [DiscoveredPeer] = []
    public private(set) var isListening: Bool = false
    public private(set) var isBrowsing: Bool = false
    public private(set) var lastSyncDate: Date?
    public private(set) var syncStatusMessage: String = "Prêt"
    /// Journal of the household sync shown on the Devices screen: device names, counts and states only,
    /// never a password, a key or a stream address.
    public private(set) var syncLog: [SyncLogEntry] = []

    public var onPlayRemote: (@Sendable (_ contentKey: String, _ positionMs: UInt64, _ title: String?, _ sourceKey: String?) -> Void)?
    public var onDeltaImported: (@Sendable () -> Void)?
    /// Sources created by a received delta: they have no catalog yet and must be refreshed.
    public var onSourcesInserted: (@Sendable (_ sourceIds: [Int64]) -> Void)?

    // PRD-42 Handoff Callbacks
    public var onPlayRequest: (@Sendable (_ req: PlayRequestDTO, _ senderId: String) -> Void)?
    public var onPlayReady: (@Sendable (_ requestId: String) -> Void)?
    public var onPlayRefused: (@Sendable (_ requestId: String, _ reason: String) -> Void)?
    public var onPlayGo: (@Sendable (_ requestId: String, _ positionMs: UInt64) -> Void)?
    public var onPlaybackState: (@Sendable (_ state: PlaybackStateDTO) -> Void)?
    public var onPlaybackControl: (@Sendable (_ action: String, _ value: Int64?) -> Void)?
    public var onReleaseStream: (@Sendable (_ sourceKey: String) -> Void)?
    public var onReleaseRequest: (@Sendable (_ requestId: String, _ senderId: String) -> Void)?
    public var onReleaseDone: (@Sendable (_ requestId: String, _ contentKey: String?, _ positionMs: UInt64) -> Void)?

    /// This device's household identifier (the one announced to the other devices).
    public var localDeviceId: String { store.deviceId }

    @ObservationIgnored private let engine: CndEngine?
    @ObservationIgnored private let store: HouseholdStore
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private let samsungTransport = SamsungChannelTransport()
    @ObservationIgnored private var connections: [String: NWConnection] = [:]
    /// Connection on which each household device was last heard (outgoing or incoming),
    /// so that a targeted message (PRD-42) reaches exactly that device.
    @ObservationIgnored private var deviceConnections: [String: NWConnection] = [:]
    @ObservationIgnored private var peerEndpoints: [String: NWEndpoint] = [:]
    /// Connections opened by the other devices (listener side): kept to send them the heartbeat, to
    /// sync over them, and to notice when they close.
    @ObservationIgnored private var incomingConnections: [ObjectIdentifier: NWConnection] = [:]
    /// Connections on which this device has already announced itself. An announce received on another
    /// one is answered once: a single connection, whichever side opened it, is then enough for both
    /// devices to see each other (before, a device only announced itself on the connections it opened,
    /// so the Mac could see the iPhone while the iPhone saw the Mac offline and could not play on it).
    @ObservationIgnored private var announcedConnections: Set<ObjectIdentifier> = []
    /// Devices this one already answered on the Samsung channel (one answer each per channel connection:
    /// the relay broadcasts, so answering every announce would make two phones answer each other forever).
    @ObservationIgnored private var channelAnsweredDevices: Set<String> = []
    /// Household device heard on each connection, to find another route when one closes.
    @ObservationIgnored private var connectionDeviceIds: [ObjectIdentifier: String] = [:]
    @ObservationIgnored private var heartbeatTicks = 0
    /// Every connected device is told "still here" this often. The Devices screen shows a device
    /// offline after 120 s without news: the announce used to be sent once per connection only.
    private static let heartbeatSeconds = 30
    @ObservationIgnored private let queue = DispatchQueue(label: "com.pcoundia.buntu.localsync", qos: .utility)
    @ObservationIgnored private var periodicSyncTimer: DispatchSourceTimer?
    @ObservationIgnored private var lastExportTimestamp: Int64 = 0
    /// `true` between `start()` and `stop()`: only then may a failed listener/browser be restarted.
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var restartAttempts = 0
    @ObservationIgnored private var restartScheduled = false

    public init(engine: CndEngine?, store: HouseholdStore = .shared) {
        self.engine = engine
        self.store = store
        // Seconds, like `updated_at` in the database. The old key held milliseconds: compared with seconds,
        // nothing was ever exported again after the first sync, so it is abandoned.
        self.lastExportTimestamp = UserDefaults.standard.object(forKey: Self.exportCursorKey) as? Int64 ?? 0
        setupSamsungTransport()
    }

    private func setupSamsungTransport() {
        samsungTransport.onConnected = { [weak self] in
            guard let self else { return }
            self.queue.async {
                self.channelAnsweredDevices.removeAll()
                self.sendAnnounceOnSamsungChannel()
            }
        }
        samsungTransport.onDisconnected = { [weak self] tvIds in
            guard let self, !tvIds.isEmpty else { return }
            Task { @MainActor in
                for tvId in tvIds where self.activePeers.contains(where: { $0.id == tvId }) {
                    self.activePeers.removeAll { $0.id == tvId }
                    self.log("\(self.peerName(tvId)) n'est plus joignable.")
                }
            }
        }
        samsungTransport.onEnvelopeReceived = { [weak self] envelope in
            guard let self else { return }
            // Same queue as the TCP messages: the routing tables are not shared across threads.
            self.queue.async { self.handleSamsungChannelEnvelope(envelope) }
        }
    }

    deinit {
        stop()
    }

    /// Bonjour name of this device. The suffix must differ from one device to the next: the old one
    /// was `deviceId.prefix(6)` = "apple_" on every Apple device, so each Apple device took the other
    /// for itself and never connected to it (the household list stayed empty).
    private var ownServiceName: String {
        let id = store.deviceId
        let unique = id.split(separator: "_", maxSplits: 1).last.map(String.init) ?? id
        return "\(store.deviceName) (\(unique.prefix(8)))"
    }

    public func start() {
        guard store.isJoined else {
            syncStatusMessage = "Aucun foyer configuré"
            return
        }

        isRunning = true
        log("Recherche des appareils du foyer sur le réseau local…")
        startListener()
        startBrowser()
        if let hId = store.householdId, !hId.isEmpty {
            samsungTransport.start(householdId: hId)
        }
        startPeriodicSync()
        syncStatusMessage = "Synchronisation active"
    }

    /// Called when the app comes back to the foreground: iOS kills the Bonjour connection of a
    /// suspended app (`DefunctConnection`), so the listener and the browser are rebuilt if they died.
    public func ensureRunning() {
        guard isRunning, store.isJoined else { return }
        if listener == nil || !isListening || browser == nil || !isBrowsing {
            restartNetworking()
        }
        samsungTransport.ensureRunning()
        // Back in the foreground: say we are here, and reopen the connections iOS closed meanwhile.
        queue.async { [weak self] in self?.heartbeat() }
    }

    private func restartNetworking() {
        stopBrowser()
        stopListener()
        startListener()
        startBrowser()
    }

    /// Retries after a failure, with a growing delay (2 s, 4 s … 30 s), instead of staying dead.
    @MainActor
    private func scheduleNetworkRestart() {
        guard isRunning, !restartScheduled else { return }
        restartScheduled = true
        restartAttempts += 1
        let delay = min(30.0, pow(2.0, Double(restartAttempts)))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.restartScheduled = false
            guard self.isRunning, self.store.isJoined else { return }
            self.restartNetworking()
        }
    }

    public func stop() {
        isRunning = false
        restartScheduled = false
        restartAttempts = 0
        samsungTransport.stop()
        stopPeriodicSync()
        stopBrowser()
        stopListener()
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        incomingConnections.values.forEach { $0.cancel() }
        incomingConnections.removeAll()
        deviceConnections.removeAll()
        connectionDeviceIds.removeAll()
        announcedConnections.removeAll()
        activePeers.removeAll()
        syncStatusMessage = "Arrêté"
    }

    // MARK: - Bonjour Listener (Server)

    private func startListener() {
        guard listener == nil else { return }

        do {
            let params = NWParameters.tcp
            params.includePeerToPeer = true
            let l = try NWListener(using: params)
            l.service = NWListener.Service(
                name: ownServiceName,
                type: Self.serviceType,
                domain: nil
            )

            l.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self.isListening = true
                        self.restartAttempts = 0
                        self.syncStatusMessage = "Synchronisation active"
                    case .waiting(let err):
                        self.isListening = false
                        self.syncStatusMessage = "En attente du réseau local : \(err.localizedDescription). Vérifiez l'autorisation « Réseau local » dans les Réglages de l'iPhone."
                    case .failed(let err):
                        self.isListening = false
                        self.syncStatusMessage = "Écoute interrompue, nouvelle tentative… (\(err.localizedDescription))"
                        // A failed listener cannot be reused: drop it so it can be rebuilt (it stayed dead before).
                        if self.listener === l { self.listener?.cancel(); self.listener = nil }
                        self.scheduleNetworkRestart()
                    case .cancelled:
                        self.isListening = false
                    default:
                        break
                    }
                }
            }

            l.newConnectionHandler = { [weak self] connection in
                self?.handleIncomingConnection(connection)
            }

            l.start(queue: queue)
            self.listener = l
        } catch {
            syncStatusMessage = "Erreur démarrage écoute: \(error.localizedDescription)"
        }
    }

    private func stopListener() {
        listener?.cancel()
        listener = nil
        isListening = false
    }

    private func handleIncomingConnection(_ connection: NWConnection) {
        incomingConnections[ObjectIdentifier(connection)] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed:
                connection.cancel()
            case .cancelled:
                self?.connectionClosed(connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveNextMessage(from: connection)
    }

    private func receiveNextMessage(from connection: NWConnection) {
        // Read 4-byte big-endian length prefix
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let self, let data, data.count == 4, error == nil else {
                connection.cancel()
                return
            }

            let payloadLength = data.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            guard payloadLength > 0 && payloadLength < 10_000_000 else {
                connection.cancel()
                return
            }

            connection.receive(minimumIncompleteLength: Int(payloadLength), maximumLength: Int(payloadLength)) { [weak self] payloadData, _, isComplete, err in
                guard let self, let payloadData, payloadData.count == Int(payloadLength), err == nil else {
                    connection.cancel()
                    return
                }

                self.processIncomingPayload(payloadData, from: connection)
                // Continue reading next messages on this connection
                self.receiveNextMessage(from: connection)
            }
        }
    }

    private func processIncomingPayload(_ data: Data, from connection: NWConnection) {
        guard let keyHex = store.currentHouseholdKeyHex() else { return }

        do {
            let decoder = JSONDecoder()
            let wire = try decoder.decode(EnvelopeWireDTO.self, from: data)
            let envelope = wire.toSealed()

            // A device that has not yet received the new key after a device was removed still speaks
            // with the old one: read only its announce, and answer with the new key.
            if envelope.householdId != store.householdId {
                handleOldKeyEnvelope(envelope, on: connection)
                return
            }

            let messageJson = try syncOpenEnvelope(
                householdKeyHex: keyHex,
                envelope: envelope,
                lastSeenSequence: store.replayFloor(for: envelope.senderDeviceId)
            )
            // The same message also arrives on the other connection: dropped quietly.
            guard store.acceptSequence(senderDeviceId: envelope.senderDeviceId, sequence: envelope.sequence) else { return }
            store.markRekeyDelivered(envelope.senderDeviceId)

            handleDecryptedMessageJson(messageJson, senderDeviceId: envelope.senderDeviceId, connection: connection)
        } catch {
            log("Message reçu illisible (\(error.localizedDescription)) : l'autre appareil a peut-être une autre clé de foyer.", warning: true)
        }
    }

    private func handleOldKeyEnvelope(_ envelope: HouseholdSealedEnvelope, on connection: NWConnection) {
        guard let state = store.rekeyState,
              envelope.householdId == state.previousHouseholdId,
              let oldKeyHex = store.previousKeyHex(for: envelope.senderDeviceId),
              let newKeyHex = store.currentHouseholdKeyHex() else { return }
        do {
            let json = try syncOpenEnvelope(
                householdKeyHex: oldKeyHex, envelope: envelope,
                lastSeenSequence: store.replayFloor(for: envelope.senderDeviceId)
            )
            guard store.acceptSequence(senderDeviceId: envelope.senderDeviceId, sequence: envelope.sequence),
                  let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                  root["type"] as? String == "device_announce",
                  let message = HouseholdRekeyMessage.json(newKeyHex: newKeyHex, removedDeviceId: state.removedDeviceId ?? ""),
                  let sealed = try? sealMessage(message, keyHex: oldKeyHex) else { return }
            sendEnvelope(sealed, on: connection)
        } catch {
            // Not readable with the old key either: ignore.
        }
    }

    /// Removes a device from the household: changes the household key, tells the other devices (sealed
    /// with the old key) and drops the removed one. Devices that are offline get the new key the next
    /// time they show up (`handleOldKeyEnvelope`).
    @MainActor
    public func removeDevice(_ removedId: String) throws {
        let newKey = try store.generateKeyHex()
        if let message = HouseholdRekeyMessage.json(newKeyHex: newKey, removedDeviceId: removedId) {
            for (deviceId, conn) in deviceConnections where deviceId != removedId {
                if let sealed = try? sealMessage(message) { sendEnvelope(sealed, on: conn) }
            }
        }
        try store.applyRekey(newKeyHex: newKey, removing: removedId)
        forget(deviceId: removedId)
    }

    @MainActor
    private func forget(deviceId: String) {
        deviceConnections[deviceId]?.cancel()
        deviceConnections.removeValue(forKey: deviceId)
        activePeers.removeAll { $0.id == deviceId }
    }

    private func handleSamsungChannelEnvelope(_ envelope: HouseholdSealedEnvelope) {
        guard let keyHex = store.currentHouseholdKeyHex() else { return }
        // Our own messages come back from the relay; another household's are not ours to read.
        guard envelope.senderDeviceId != store.deviceId, envelope.householdId == store.householdId else { return }

        do {
            let messageJson = try syncOpenEnvelope(
                householdKeyHex: keyHex,
                envelope: envelope,
                lastSeenSequence: store.replayFloor(for: envelope.senderDeviceId)
            )
            // Broadcasts of the Bonjour devices also come through the relay: the second copy is dropped here.
            guard store.acceptSequence(senderDeviceId: envelope.senderDeviceId, sequence: envelope.sequence) else { return }
            store.markRekeyDelivered(envelope.senderDeviceId)

            handleDecryptedMessageJson(messageJson, senderDeviceId: envelope.senderDeviceId, connection: nil)
        } catch {
            // Usually the copy of a message already read on TCP (replay check): not worth a warning.
        }
    }

    private func handleDecryptedMessageJson(_ json: String, senderDeviceId: String, connection: NWConnection?) {
        guard let jsonData = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let type = root["type"] as? String else {
            return
        }

        if let connection {
            deviceConnections[senderDeviceId] = connection
            connectionDeviceIds[ObjectIdentifier(connection)] = senderDeviceId
        }

        switch type {
        case "device_announce":
            // Answer on this connection if we have not announced ourselves on it yet, so the sender
            // sees this device too (once: the announces that follow are heartbeats).
            if let connection {
                if !announcedConnections.contains(ObjectIdentifier(connection)) {
                    sendAnnounce(on: connection)
                }
            } else if channelAnsweredDevices.insert(senderDeviceId).inserted {
                sendAnnounceOnSamsungChannel()
            }
            let name = (root["device_name"] as? String) ?? "Appareil"
            let devType = (root["device_type"] as? String) ?? "mobile"
            // Reachable only through the Samsung channel: the TV (PRD-45). Decided after decryption.
            let channelTv = connection == nil && devType == "tv"
            if channelTv { samsungTransport.markTv(senderDeviceId) }
            let peer = DiscoveredPeer(
                id: senderDeviceId,
                name: name,
                deviceType: devType,
                canPlay: (root["can_play"] as? Bool) ?? true,
                capabilities: (root["capabilities"] as? [String]) ?? [],
                state: (root["state"] as? String) ?? "idle",
                lastSeen: Date()
            )
            Task { @MainActor in
                // A device seen for the first time, or back after a while, gets everything (accounts,
                // favorites, progress): that is how a device that just joined the household catches up.
                let previous = self.activePeers.first(where: { $0.id == senderDeviceId })
                // Not to the Samsung TV: it does not read this format yet (PRD-45 § 1.4).
                let needsFullSync = !channelTv
                    && (previous == nil || peer.lastSeen.timeIntervalSince(previous?.lastSeen ?? .distantPast) > 120)
                self.updatePeer(peer)
                if previous == nil { self.log("\(name) est connecté.") }
                if needsFullSync { self.sendFullSync(to: senderDeviceId) }
            }

        case "household_rekey":
            // Only a device already known in the household may change the key.
            guard store.isKnownDevice(senderDeviceId),
                  let rekey = HouseholdRekeyMessage.parse(root),
                  rekey.removedDeviceId != store.deviceId,
                  (try? store.applyRekey(newKeyHex: rekey.newKeyHex, removing: rekey.removedDeviceId)) != nil else { return }
            // Tell the sender (and let it stop waiting for us) with the new key.
            if let connection {
                sendAnnounce(on: connection)
            } else {
                sendAnnounceOnSamsungChannel()
            }
            Task { @MainActor in
                if let removed = rekey.removedDeviceId { self.forget(deviceId: removed) }
                self.syncStatusMessage = "Un appareil a été retiré du foyer : la clé a changé."
            }

        case "household_data_delta":
            if let engine {
                do {
                    guard let deltaObject = root["delta"] else { throw CocoaError(.coderValueNotFound) }
                    let deltaData = try JSONSerialization.data(withJSONObject: deltaObject)
                    let deltaDto = try JSONDecoder().decode(SyncDeltaDTO.self, from: deltaData)
                    // Last write wins: remember what this device had, to place passwords only where the
                    // incoming account is new or newer.
                    let localUpdatedAt = Dictionary(
                        (try? engine.listSources())?.map { ($0.uuid, $0.updatedAt) } ?? [],
                        uniquingKeysWith: { first, _ in first }
                    )
                    let summary = try engine.importSyncDelta(delta: deltaDto.toNative())
                    let passwords = Self.storeReceivedPasswords(deltaDto.sources, localUpdatedAt: localUpdatedAt)
                    let inserted = summary.insertedSourceIds
                    let sender = peerName(senderDeviceId)
                    log("Reçu de \(sender) : \(deltaDto.sources.count) compte(s), \(deltaDto.favorites.count) favori(s), "
                        + "\(deltaDto.watch_history.count) reprise(s). Appliqué : \(summary.sourcesApplied) compte(s) "
                        + "(\(inserted.count) nouveau(x)), \(summary.favoritesApplied) favori(s), \(summary.watchApplied) reprise(s) ; "
                        + "\(summary.skipped) déjà à jour.")
                    if passwords.stored > 0 { log("Mot de passe enregistré pour \(passwords.stored) compte(s).") }
                    for name in passwords.missing {
                        log("Compte « \(name) » reçu sans mot de passe : mettez à jour Buntu sur \(sender), ou saisissez le mot de passe ici.", warning: true)
                    }
                    let received = (sources: Int(summary.sourcesApplied), favorites: Int(summary.favoritesApplied), progress: Int(summary.watchApplied))
                    Task { @MainActor in
                        self.lastSyncDate = Date()
                        if received.sources + received.favorites + received.progress > 0 {
                            self.syncStatusMessage = "Reçu : \(received.sources) compte(s), \(received.favorites) favori(s), \(received.progress) reprise(s)"
                        }
                        self.onDeltaImported?()
                        if !inserted.isEmpty { self.onSourcesInserted?(inserted) }
                    }
                } catch {
                    log("Données reçues de \(peerName(senderDeviceId)) mais non appliquées : \(error.localizedDescription)", warning: true)
                    Task { @MainActor in self.syncStatusMessage = "Données reçues mais non appliquées (voir le journal)." }
                }
            }

        case "sync_request":
            // A device asks for everything (its "Synchroniser maintenant", or it has just joined).
            log("\(peerName(senderDeviceId)) demande les données du foyer.")
            sendFullSync(to: senderDeviceId)

        case "play_remote":
            if let contentKey = root["content_key"] as? String,
               let positionMs = root["position_ms"] as? UInt64 {
                let title = root["title"] as? String
                let sourceKey = root["source_key"] as? String
                Task { @MainActor in
                    self.onPlayRemote?(contentKey, positionMs, title, sourceKey)
                }
            }

        case "play_request":
            if let req = try? JSONDecoder().decode(PlayRequestDTO.self, from: jsonData) {
                let localId = store.deviceId
                if req.target_device_id == localId {
                    Task { @MainActor in
                        self.onPlayRequest?(req, senderDeviceId)
                    }
                }
            }

        case "play_ready":
            if let reqId = root["request_id"] as? String {
                Task { @MainActor in
                    self.onPlayReady?(reqId)
                }
            }

        case "play_refused":
            if let reqId = root["request_id"] as? String,
               let reason = root["reason"] as? String {
                Task { @MainActor in
                    self.onPlayRefused?(reqId, reason)
                }
            }

        case "play_go":
            if let reqId = root["request_id"] as? String,
               let pos = root["position_ms"] as? UInt64 {
                Task { @MainActor in
                    self.onPlayGo?(reqId, pos)
                }
            }

        case "playback_state":
            if let stateDto = try? JSONDecoder().decode(PlaybackStateDTO.self, from: jsonData) {
                Task { @MainActor in
                    self.onPlaybackState?(stateDto)
                }
            }

        case "playback_control":
            if let targetId = root["target_device_id"] as? String,
               let action = root["action"] as? String {
                let localId = store.deviceId
                if targetId == localId {
                    let value = (root["value"] as? NSNumber)?.int64Value
                    Task { @MainActor in
                        self.onPlaybackControl?(action, value)
                    }
                }
            }

        case "release_stream":
            if let sourceKey = root["source_key"] as? String {
                Task { @MainActor in
                    self.onReleaseStream?(sourceKey)
                }
            }

        case "release_request":
            if let reqId = root["request_id"] as? String,
               let targetId = root["target_device_id"] as? String {
                let localId = store.deviceId
                if targetId == localId {
                    Task { @MainActor in
                        self.onReleaseRequest?(reqId, senderDeviceId)
                    }
                }
            }

        case "release_done":
            if let reqId = root["request_id"] as? String,
               let pos = root["position_ms"] as? UInt64 {
                let cKey = root["content_key"] as? String
                Task { @MainActor in
                    self.onReleaseDone?(reqId, cKey, pos)
                }
            }

        case "ping":
            let pongJson = "{\"type\":\"pong\"}"
            if let sealed = try? sealMessage(pongJson) {
                if let connection {
                    sendEnvelope(sealed, on: connection)
                } else {
                    samsungTransport.sendEnvelope(sealed)
                }
            }

        default:
            break
        }
    }

    // MARK: - Bonjour Browser (Client)

    private func startBrowser() {
        guard browser == nil else { return }

        let params = NWParameters()
        params.includePeerToPeer = true
        let b = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: params)

        b.browseResultsChangedHandler = { [weak self] results, _ in
            self?.handleBrowseResults(results)
        }

        b.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { @MainActor in
                switch state {
                case .ready: self.isBrowsing = true
                case .failed(let err):
                    self.isBrowsing = false
                    self.syncStatusMessage = "Recherche interrompue, nouvelle tentative… (\(err.localizedDescription))"
                    if self.browser === b { self.browser?.cancel(); self.browser = nil }
                    self.scheduleNetworkRestart()
                case .cancelled: self.isBrowsing = false
                default: break
                }
            }
        }

        b.start(queue: queue)
        self.browser = b
    }

    private func stopBrowser() {
        browser?.cancel()
        browser = nil
        isBrowsing = false
    }

    private func handleBrowseResults(_ results: Set<NWBrowser.Result>) {
        // Only the devices advertised right now: the heartbeat reconnects to these when a connection drops.
        var current: [String: NWEndpoint] = [:]
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint, name != ownServiceName else { continue }
            current[name] = result.endpoint
        }
        peerEndpoints = current

        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint else { continue }
            // Avoid connecting to self
            if name == ownServiceName { continue }

            let peerId = name

            // If not connected, initiate connection
            if connections[peerId] == nil {
                log("Appareil trouvé sur le réseau : \(name).")
                connectToPeer(id: peerId, endpoint: result.endpoint)
            }
        }
    }

    private func connectToPeer(id: String, endpoint: NWEndpoint) {
        let conn = NWConnection(to: endpoint, using: .tcp)
        connections[id] = conn

        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.sendAnnounce(on: conn)
                self.receiveNextMessage(from: conn)
            case .failed(let error):
                self.log("Connexion à \(id) perdue : \(error.localizedDescription)", warning: true)
                conn.cancel()
            case .cancelled:
                // A newer connection to the same device may already have replaced this one.
                if self.connections[id] === conn { self.connections.removeValue(forKey: id) }
                self.connectionClosed(conn)
            case .waiting(let error):
                // A waiting connection never becomes ready by itself here: drop it so the next browse retries.
                self.log("Connexion à \(id) en attente : \(error.localizedDescription)", warning: true)
                conn.cancel()
            default:
                break
            }
        }

        conn.start(queue: queue)
    }

    /// Forgets a closed connection (on `queue`). If it was the route to a household device, another
    /// live connection to that device takes over; with none left, the device leaves the list of
    /// available devices instead of staying "Disponible" with a dead connection.
    private func connectionClosed(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        announcedConnections.remove(key)
        incomingConnections.removeValue(forKey: key)
        guard let deviceId = connectionDeviceIds.removeValue(forKey: key),
              deviceConnections[deviceId] === connection else { return }
        let live = reachableConnections().filter { $0 !== connection }
        if let other = live.first(where: { connectionDeviceIds[ObjectIdentifier($0)] == deviceId }) {
            deviceConnections[deviceId] = other
            return
        }
        deviceConnections.removeValue(forKey: deviceId)
        let name = peerName(deviceId)
        Task { @MainActor in
            guard self.activePeers.contains(where: { $0.id == deviceId }) else { return }
            self.activePeers.removeAll { $0.id == deviceId }
            self.log("\(name) n'est plus joignable.")
        }
    }

    /// Runs every `heartbeatSeconds` (on `queue`): tells every connected device that this one is still
    /// here, and reopens a connection to the advertised devices this one lost.
    private func heartbeat() {
        guard isRunning, store.isJoined else { return }
        for conn in reachableConnections() { sendAnnounce(on: conn) }
        sendAnnounceOnSamsungChannel()
        // `start` again with the current id: after a key change the channel name changes too.
        if let hId = store.householdId, !hId.isEmpty { samsungTransport.start(householdId: hId) }
        samsungTransport.ensureRunning()
        for (name, endpoint) in peerEndpoints where connections[name] == nil {
            connectToPeer(id: name, endpoint: endpoint)
        }
    }

    /// Adds a line to the sync journal (and to the app console). Never a secret.
    public func log(_ text: String, warning: Bool = false) {
        if warning { AppLog.shared.warn("SYNC", text) } else { AppLog.shared.info("SYNC", text) }
        let entry = SyncLogEntry(date: Date(), isWarning: warning, text: text)
        Task { @MainActor in
            self.syncLog.append(entry)
            if self.syncLog.count > 100 { self.syncLog.removeFirst(self.syncLog.count - 100) }
        }
    }

    @MainActor
    public func clearLog() { syncLog.removeAll() }

    /// Name a device announced, or a short form of its id.
    private func peerName(_ deviceId: String) -> String {
        if let known = store.knownDevices.first(where: { $0.id == deviceId }) { return known.name }
        return "l'appareil \(deviceId.suffix(6))"
    }

    @MainActor
    private func updatePeer(_ peer: DiscoveredPeer) {
        store.rememberDevice(id: peer.id, name: peer.name, deviceType: peer.deviceType, seenAt: peer.lastSeen)
        if let idx = activePeers.firstIndex(where: { $0.id == peer.id }) {
            activePeers[idx] = peer
        } else {
            activePeers.append(peer)
        }
    }

    // MARK: - Sending Messages & Deltas

    private func makeDeviceAnnounceJson() -> String? {
        let announce: [String: Any] = [
            "type": "device_announce",
            "device_id": store.deviceId,
            "device_name": store.deviceName,
            "device_type": store.deviceType,
            "app_version": "1.1.0",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: announce) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func sendAnnounce(on connection: NWConnection) {
        guard let announceJson = makeDeviceAnnounceJson() else { return }
        if let sealed = try? sealMessage(announceJson) {
            announcedConnections.insert(ObjectIdentifier(connection))
            sendEnvelope(sealed, on: connection)
        }
    }

    private func sendAnnounceOnSamsungChannel() {
        guard let announceJson = makeDeviceAnnounceJson() else { return }
        if let sealed = try? sealMessage(announceJson) {
            samsungTransport.sendEnvelope(sealed)
        }
    }

    /// `full` is the button "Synchroniser maintenant": sends everything this device has to every
    /// connected device and asks them to send theirs, instead of only what changed since the last round.
    public func syncNow(full: Bool = false) {
        guard let engine, store.isJoined else { return }
        let peers = reachableConnections()
        // Nobody is connected: keep the cursor, or what changed meanwhile would never be sent.
        guard !peers.isEmpty else {
            if full {
                syncStatusMessage = "Aucun autre appareil joignable : ouvrez Buntu sur l'autre appareil, sur le même Wi‑Fi."
                log("Synchroniser : aucun autre appareil joignable (même Wi‑Fi ? Buntu ouvert sur l'autre appareil ? « Réseau local » autorisé ?).", warning: true)
            }
            return
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let nowTs = Int64(Date().timeIntervalSince1970)
            let since = full ? 0 : self.lastExportTimestamp
            if let messageJson = self.deltaMessageJson(engine: engine, since: since),
               let sealed = self.sealOrLog(messageJson) {
                for conn in peers { self.sendEnvelope(sealed, on: conn) }
            }
            if full, let sealed = self.sealOrLog(#"{"type":"sync_request"}"#) {
                for conn in peers { self.sendEnvelope(sealed, on: conn) }
                self.log("Synchroniser : données envoyées et demandées sur \(peers.count) connexion(s).")
            }
            if !full {
                self.lastExportTimestamp = nowTs
                UserDefaults.standard.set(nowTs, forKey: Self.exportCursorKey)
            }
            Task { @MainActor in
                self.lastSyncDate = Date()
                if full { self.syncStatusMessage = "Synchronisation demandée à \(peers.count) connexion(s)…" }
            }
        }
    }

    /// Every live connection, whichever side opened it.
    private func reachableConnections() -> [NWConnection] {
        var seen = Set<ObjectIdentifier>()
        let all = Array(connections.values) + Array(deviceConnections.values) + Array(incomingConnections.values)
        return all.filter { seen.insert(ObjectIdentifier($0)).inserted }
    }

    /// Sends everything this device has (accounts, favorites, progress) to one device.
    private func sendFullSync(to peerId: String) {
        guard let engine, store.isJoined else { return }
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let name = self.peerName(peerId)
            guard let messageJson = self.deltaMessageJson(engine: engine, since: 0) else {
                self.log("Rien à envoyer à \(name) : aucun compte, favori ni reprise sur cet appareil.")
                return
            }
            if self.sendToPeer(peerId: peerId, messageJson: messageJson) {
                self.log("Envoi de toutes les données à \(name).")
            } else {
                self.log("Envoi à \(name) impossible : plus de connexion.", warning: true)
            }
        }
    }

    /// The `sync_delta` message of everything changed after `since` (seconds), with the Xtream passwords
    /// of the accounts it contains. `nil` when there is nothing to send.
    private func deltaMessageJson(engine: CndEngine, since: Int64) -> String? {
        guard let delta = try? engine.exportSyncDelta(sinceTs: since) else { return nil }
        guard !(delta.profiles.isEmpty && delta.sources.isEmpty && delta.favorites.isEmpty
                && delta.watchHistory.isEmpty && delta.tombstones.isEmpty) else { return nil }
        var dto = SyncDeltaDTO(delta)
        dto.sources = dto.sources.map { source in
            var source = source
            if source.source_type == "xtream" {
                let key = source.password_ref ?? KeychainStore.xtreamKey(forSourceUuid: source.uuid)
                source.password = try? KeychainStore.shared.readSecret(forKey: key)
            }
            return source
        }
        // `household_data_delta` is the message the protocol (cnd-domain `SyncMessage`) knows for this
        // format; a bare `sync_delta` in this shape was refused by the sealer, so nothing was ever sent.
        guard let data = try? JSONEncoder().encode(dto),
              let deltaObject = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let wrapped: [String: Any] = ["type": "household_data_delta", "delta": deltaObject]
        guard let message = try? JSONSerialization.data(withJSONObject: wrapped) else { return nil }
        return String(data: message, encoding: .utf8)
    }

    /// Puts the passwords of received accounts in this device's Keychain (never in the database).
    /// Returns how many passwords were stored, and the accounts that arrived without one and have none here.
    private static func storeReceivedPasswords(
        _ sources: [SyncSourceDTO], localUpdatedAt: [String: Int64]
    ) -> (stored: Int, missing: [String]) {
        let keychain = KeychainStore.shared
        var stored = 0
        var missingNames: [String] = []
        for source in sources where source.source_type == "xtream" {
            let key = source.password_ref ?? KeychainStore.xtreamKey(forSourceUuid: source.uuid)
            let hasLocal = ((try? keychain.readSecret(forKey: key)) ?? nil) != nil
            guard let password = source.password, !password.isEmpty else {
                if !hasLocal { missingNames.append(source.name) }
                continue
            }
            let isNewOrNewer = localUpdatedAt[source.uuid].map { source.updated_at > $0 } ?? true
            guard !hasLocal || isNewOrNewer else { continue }
            if (try? keychain.saveSecret(password, forKey: key, scope: keychain.passwordScope)) != nil { stored += 1 }
        }
        return (stored, missingNames)
    }

    public func playRemote(contentKey: String, positionMs: UInt64, title: String? = nil, sourceKey: String? = nil) {
        var dict: [String: Any] = [
            "type": "play_remote",
            "content_key": contentKey,
            "position_ms": positionMs
        ]
        if let title { dict["title"] = title }
        if let sourceKey { dict["source_key"] = sourceKey }

        if let data = try? JSONSerialization.data(withJSONObject: dict),
           let json = String(data: data, encoding: .utf8) {
            broadcastMessage(json)
        }
    }

    /// Sends a message to ONE household device. Returns `false` (and sends nothing) when that device
    /// is not connected: a targeted order such as `play_request` must never fall back to a broadcast,
    /// or every device of the house would receive it.
    @discardableResult
    public func sendToPeer(peerId: String, messageJson: String) -> Bool {
        guard let sealed = sealOrLog(messageJson) else { return false }
        if let conn = deviceConnections[peerId] {
            sendEnvelope(sealed, on: conn)
            return true
        }
        if let conn = connections[peerId] {
            sendEnvelope(sealed, on: conn)
            return true
        }
        // The TV has no TCP connection: the relay broadcasts, the message carries `target_device_id`.
        if samsungTransport.isTv(peerId) {
            return samsungTransport.sendEnvelope(sealed)
        }
        return false
    }

    public func broadcastMessage(_ messageJson: String) {
        guard let sealed = sealOrLog(messageJson) else { return }
        for (_, conn) in connections {
            sendEnvelope(sealed, on: conn)
        }
        samsungTransport.sendEnvelope(sealed)
    }

    /// Seals, or writes in the journal why the message could not be prepared (type only, never content).
    private func sealOrLog(_ messageJson: String) -> HouseholdSealedEnvelope? {
        do {
            return try sealMessage(messageJson)
        } catch {
            let type = ((try? JSONSerialization.jsonObject(with: Data(messageJson.utf8))) as? [String: Any])?["type"] as? String
            log("Message « \(type ?? "?") » non préparé : \(error.localizedDescription)", warning: true)
            return nil
        }
    }

    private func sealMessage(_ messageJson: String, keyHex explicitKeyHex: String? = nil) throws -> HouseholdSealedEnvelope {
        guard let keyHex = explicitKeyHex ?? store.currentHouseholdKeyHex() else {
            throw NSError(domain: "LocalSyncService", code: 3, userInfo: [NSLocalizedDescriptionKey: "Non appairé"])
        }

        var nonce = [UInt8](repeating: 0, count: 12)
        let status = SecRandomCopyBytes(kSecRandomDefault, 12, &nonce)
        guard status == errSecSuccess else {
            throw NSError(domain: "LocalSyncService", code: 4, userInfo: [NSLocalizedDescriptionKey: "Aléatoire échoué"])
        }

        let seq = store.nextSequence()
        return try syncSealEnvelope(
            householdKeyHex: keyHex,
            senderDeviceId: store.deviceId,
            sequence: seq,
            nonceBytes: Data(nonce),
            messageJson: messageJson
        )
    }

    private func sendEnvelope(_ envelope: HouseholdSealedEnvelope, on connection: NWConnection) {
        do {
            let wire = EnvelopeWireDTO(envelope)
            let encoder = JSONEncoder()
            let payload = try encoder.encode(wire)

            var length = UInt32(payload.count).bigEndian
            let packet = Data(bytes: &length, count: 4) + payload

            connection.send(content: packet, completion: .contentProcessed({ _ in }))
        } catch {
            // Sending failed
        }
    }

    // MARK: - Periodic Sync

    private func startPeriodicSync() {
        stopPeriodicSync()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        heartbeatTicks = 0
        timer.schedule(deadline: .now() + 5, repeating: .seconds(Self.heartbeatSeconds))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.heartbeat()
            // The data itself still goes every 60 s (first tick, then every other one).
            if self.heartbeatTicks % 2 == 0 { self.syncNow() }
            self.heartbeatTicks += 1
        }
        timer.resume()
        self.periodicSyncTimer = timer
    }

    private func stopPeriodicSync() {
        periodicSyncTimer?.cancel()
        periodicSyncTimer = nil
    }
}
