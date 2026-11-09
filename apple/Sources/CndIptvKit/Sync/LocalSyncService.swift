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
    @ObservationIgnored private var connections: [String: NWConnection] = [:]
    /// Connection on which each household device was last heard (outgoing or incoming),
    /// so that a targeted message (PRD-42) reaches exactly that device.
    @ObservationIgnored private var deviceConnections: [String: NWConnection] = [:]
    @ObservationIgnored private var peerEndpoints: [String: NWEndpoint] = [:]
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
        startListener()
        startBrowser()
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
        stopPeriodicSync()
        stopBrowser()
        stopListener()
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
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

            let lastSeen = store.lastSeenSequence(for: envelope.senderDeviceId)
            let messageJson = try syncOpenEnvelope(
                householdKeyHex: keyHex,
                envelope: envelope,
                lastSeenSequence: lastSeen
            )

            _ = store.verifyAndAdvanceSequence(senderDeviceId: envelope.senderDeviceId, sequence: envelope.sequence)
            store.markRekeyDelivered(envelope.senderDeviceId)

            handleDecryptedMessageJson(messageJson, senderDeviceId: envelope.senderDeviceId, connection: connection)
        } catch {
            // Decryption failure or replay rejection
        }
    }

    private func handleOldKeyEnvelope(_ envelope: HouseholdSealedEnvelope, on connection: NWConnection) {
        guard let state = store.rekeyState,
              envelope.householdId == state.previousHouseholdId,
              let oldKeyHex = store.previousKeyHex(for: envelope.senderDeviceId),
              let newKeyHex = store.currentHouseholdKeyHex() else { return }
        do {
            let lastSeen = store.lastSeenSequence(for: envelope.senderDeviceId)
            let json = try syncOpenEnvelope(householdKeyHex: oldKeyHex, envelope: envelope, lastSeenSequence: lastSeen)
            guard store.verifyAndAdvanceSequence(senderDeviceId: envelope.senderDeviceId, sequence: envelope.sequence),
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

    private func handleDecryptedMessageJson(_ json: String, senderDeviceId: String, connection: NWConnection) {
        guard let jsonData = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let type = root["type"] as? String else {
            return
        }

        deviceConnections[senderDeviceId] = connection

        switch type {
        case "device_announce":
            let name = (root["device_name"] as? String) ?? "Appareil"
            let devType = (root["device_type"] as? String) ?? "mobile"
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
                let needsFullSync = previous == nil || peer.lastSeen.timeIntervalSince(previous?.lastSeen ?? .distantPast) > 120
                self.updatePeer(peer)
                if needsFullSync { self.sendFullSync(to: senderDeviceId) }
            }

        case "household_rekey":
            // Only a device already known in the household may change the key.
            guard store.isKnownDevice(senderDeviceId),
                  let rekey = HouseholdRekeyMessage.parse(root),
                  rekey.removedDeviceId != store.deviceId,
                  (try? store.applyRekey(newKeyHex: rekey.newKeyHex, removing: rekey.removedDeviceId)) != nil else { return }
            // Tell the sender (and let it stop waiting for us) with the new key.
            sendAnnounce(on: connection)
            Task { @MainActor in
                if let removed = rekey.removedDeviceId { self.forget(deviceId: removed) }
                self.syncStatusMessage = "Un appareil a été retiré du foyer : la clé a changé."
            }

        case "sync_delta":
            if let engine {
                do {
                    let decoder = JSONDecoder()
                    let deltaDto = try decoder.decode(SyncDeltaDTO.self, from: jsonData)
                    // Last write wins: remember what this device had, to place passwords only where the
                    // incoming account is new or newer.
                    let localUpdatedAt = Dictionary(
                        (try? engine.listSources())?.map { ($0.uuid, $0.updatedAt) } ?? [],
                        uniquingKeysWith: { first, _ in first }
                    )
                    let summary = try engine.importSyncDelta(delta: deltaDto.toNative())
                    Self.storeReceivedPasswords(deltaDto.sources, localUpdatedAt: localUpdatedAt)
                    let inserted = summary.insertedSourceIds
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
                    AppLog.shared.warn("SYNC", "Message de synchronisation reçu mais non appliqué : \(error.localizedDescription)")
                    Task { @MainActor in self.syncStatusMessage = "Données reçues mais non appliquées (voir la console)." }
                }
            }

        case "sync_request":
            // A device asks for everything (its "Synchroniser maintenant", or it has just joined).
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
                sendEnvelope(sealed, on: connection)
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
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint else { continue }
            // Avoid connecting to self
            if name == ownServiceName { continue }

            let peerId = name
            peerEndpoints[peerId] = result.endpoint

            // If not connected, initiate connection
            if connections[peerId] == nil {
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
            case .failed, .cancelled:
                self.connections.removeValue(forKey: id)
                self.deviceConnections = self.deviceConnections.filter { $0.value !== conn }
            default:
                break
            }
        }

        conn.start(queue: queue)
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

    public func sendAnnounce(on connection: NWConnection) {
        // Built with JSONSerialization: a device name containing a quote would break a hand-written string.
        let announce: [String: Any] = [
            "type": "device_announce",
            "device_id": store.deviceId,
            "device_name": store.deviceName,
            "device_type": store.deviceType,
            "app_version": "1.1.0",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: announce),
              let announceJson = String(data: data, encoding: .utf8) else { return }
        if let sealed = try? sealMessage(announceJson) {
            sendEnvelope(sealed, on: connection)
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
            }
            return
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let nowTs = Int64(Date().timeIntervalSince1970)
            let since = full ? 0 : self.lastExportTimestamp
            if let messageJson = self.deltaMessageJson(engine: engine, since: since),
               let sealed = try? self.sealMessage(messageJson) {
                for conn in peers { self.sendEnvelope(sealed, on: conn) }
            }
            if full, let sealed = try? self.sealMessage(#"{"type":"sync_request"}"#) {
                for conn in peers { self.sendEnvelope(sealed, on: conn) }
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
        return (Array(connections.values) + Array(deviceConnections.values)).filter { seen.insert(ObjectIdentifier($0)).inserted }
    }

    /// Sends everything this device has (accounts, favorites, progress) to one device.
    private func sendFullSync(to peerId: String) {
        guard let engine, store.isJoined else { return }
        Task.detached(priority: .utility) { [weak self] in
            guard let self, let messageJson = self.deltaMessageJson(engine: engine, since: 0) else { return }
            _ = self.sendToPeer(peerId: peerId, messageJson: messageJson)
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
        guard let data = try? JSONEncoder().encode(dto),
              var dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        dict["type"] = "sync_delta"
        guard let message = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return String(data: message, encoding: .utf8)
    }

    /// Puts the passwords of received accounts in this device's Keychain (never in the database).
    private static func storeReceivedPasswords(_ sources: [SyncSourceDTO], localUpdatedAt: [String: Int64]) {
        let keychain = KeychainStore.shared
        for source in sources where source.source_type == "xtream" {
            guard let password = source.password, !password.isEmpty else { continue }
            let key = source.password_ref ?? KeychainStore.xtreamKey(forSourceUuid: source.uuid)
            let isNewOrNewer = localUpdatedAt[source.uuid].map { source.updated_at > $0 } ?? true
            let missing = ((try? keychain.readSecret(forKey: key)) ?? nil) == nil
            guard missing || isNewOrNewer else { continue }
            try? keychain.saveSecret(password, forKey: key, scope: keychain.passwordScope)
        }
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
        guard let sealed = try? sealMessage(messageJson) else { return false }
        if let conn = deviceConnections[peerId] {
            sendEnvelope(sealed, on: conn)
            return true
        }
        if let conn = connections[peerId] {
            sendEnvelope(sealed, on: conn)
            return true
        }
        return false
    }

    public func broadcastMessage(_ messageJson: String) {
        guard let sealed = try? sealMessage(messageJson) else { return }
        for (_, conn) in connections {
            sendEnvelope(sealed, on: conn)
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
        timer.schedule(deadline: .now() + 5, repeating: .seconds(60))
        timer.setEventHandler { [weak self] in
            self?.syncNow()
        }
        timer.resume()
        self.periodicSyncTimer = timer
    }

    private func stopPeriodicSync() {
        periodicSyncTimer?.cancel()
        periodicSyncTimer = nil
    }
}
