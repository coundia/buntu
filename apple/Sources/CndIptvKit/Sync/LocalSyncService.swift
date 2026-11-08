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

    public private(set) var activePeers: [DiscoveredPeer] = []
    public private(set) var isListening: Bool = false
    public private(set) var isBrowsing: Bool = false
    public private(set) var lastSyncDate: Date?
    public private(set) var syncStatusMessage: String = "Prêt"

    public var onPlayRemote: (@Sendable (_ contentKey: String, _ positionMs: UInt64, _ title: String?, _ sourceKey: String?) -> Void)?
    public var onDeltaImported: (@Sendable () -> Void)?

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
        self.lastExportTimestamp = UserDefaults.standard.object(forKey: "cnd.sync.lastExportTs") as? Int64 ?? 0
    }

    deinit {
        stop()
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
                name: "\(store.deviceName) (\(store.deviceId.prefix(6)))",
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

            guard envelope.householdId == store.householdId else { return }

            let lastSeen = store.lastSeenSequence(for: envelope.senderDeviceId)
            let messageJson = try syncOpenEnvelope(
                householdKeyHex: keyHex,
                envelope: envelope,
                lastSeenSequence: lastSeen
            )

            _ = store.verifyAndAdvanceSequence(senderDeviceId: envelope.senderDeviceId, sequence: envelope.sequence)

            handleDecryptedMessageJson(messageJson, senderDeviceId: envelope.senderDeviceId, connection: connection)
        } catch {
            // Decryption failure or replay rejection
        }
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
                self.updatePeer(peer)
            }

        case "sync_delta":
            if let engine {
                do {
                    let decoder = JSONDecoder()
                    let deltaDto = try decoder.decode(SyncDeltaDTO.self, from: jsonData)
                    _ = try engine.importSyncDelta(delta: deltaDto.toNative())
                    Task { @MainActor in
                        self.lastSyncDate = Date()
                        self.onDeltaImported?()
                    }
                } catch {
                    // Ignored or invalid format
                }
            }

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
            if name.contains(store.deviceId.prefix(6)) { continue }

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
        if let idx = activePeers.firstIndex(where: { $0.id == peer.id }) {
            activePeers[idx] = peer
        } else {
            activePeers.append(peer)
        }
    }

    // MARK: - Sending Messages & Deltas

    public func sendAnnounce(on connection: NWConnection) {
        let announceJson = """
        {"type":"device_announce","device_id":"\(store.deviceId)","device_name":"\(store.deviceName)","device_type":"\(store.deviceType)","app_version":"1.1.0"}
        """
        if let sealed = try? sealMessage(announceJson) {
            sendEnvelope(sealed, on: connection)
        }
    }

    public func syncNow() {
        guard let engine, store.isJoined else { return }

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let delta = try engine.exportSyncDelta(sinceTs: self.lastExportTimestamp)
                let nowTs = Int64(Date().timeIntervalSince1970 * 1000)

                let deltaDto = SyncDeltaDTO(delta)
                let encoder = JSONEncoder()
                let deltaData = try encoder.encode(deltaDto)

                guard var dict = try JSONSerialization.jsonObject(with: deltaData) as? [String: Any] else { return }
                dict["type"] = "sync_delta"
                let messageData = try JSONSerialization.data(withJSONObject: dict)
                guard let messageJson = String(data: messageData, encoding: .utf8) else { return }

                self.broadcastMessage(messageJson)
                self.lastExportTimestamp = nowTs
                UserDefaults.standard.set(nowTs, forKey: "cnd.sync.lastExportTs")

                Task { @MainActor in
                    self.lastSyncDate = Date()
                }
            } catch {
                // No delta to export
            }
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

    private func sealMessage(_ messageJson: String) throws -> HouseholdSealedEnvelope {
        guard let keyHex = store.currentHouseholdKeyHex() else {
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
