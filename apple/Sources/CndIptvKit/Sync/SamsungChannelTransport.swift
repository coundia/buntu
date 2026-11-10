import Foundation
import Network
import CndCoreBridge

/// Samsung TV link of the household (PRD-45 § 3.2).
///
/// A Tizen web app cannot open a port, so the TV is reached through the relay the TV itself provides:
/// every device connects as a client to `ws://<tv>:8001/api/v2/channels/buntu.sync.<household_id>`.
/// The TV is found by Bonjour (`_samsungmsf._tcp`). Messages are the same sealed envelopes as on TCP,
/// carried as the `data` of an `ms.channel.emit` (`event: buntu-sync-envelope`, `to: broadcast`).
///
/// Threading: the browser, the resolutions and the reconnection live on `queue`; what other threads read
/// (`isConnected`, the socket, the TV identifiers) is guarded by `lock`. Callbacks are called on `queue`.
public final class SamsungChannelTransport: @unchecked Sendable {
    public static let serviceType = "_samsungmsf._tcp"
    static let channelPort = 8001

    public var onEnvelopeReceived: (@Sendable (_ envelope: HouseholdSealedEnvelope) -> Void)?
    public var onConnected: (@Sendable () -> Void)?
    /// Called with the TVs that were reachable on the closed connection.
    public var onDisconnected: (@Sendable (_ tvDeviceIds: Set<String>) -> Void)?
    /// Journal of the « Appareils » screen (addresses and counts only, never a key or a message).
    public var onLog: (@Sendable (_ text: String, _ warning: Bool) -> Void)?

    private let queue = DispatchQueue(label: "com.pcoundia.buntu.samsungtransport", qos: .utility)
    private let lock = NSLock()

    // Guarded by `lock`.
    private var webSocketTask: URLSessionWebSocketTask?
    private var connected = false
    private var tvDeviceIds: Set<String> = []

    // Confined to `queue`.
    private var browser: NWBrowser?
    private var resolving: [String: NWConnection] = [:]
    private var currentHost: String?
    private var urlSession: URLSession?
    private var householdId: String?
    private var isRunning = false
    private var reconnectTimer: DispatchSourceTimer?
    private var reconnectAttempts = 0

    public init() {}

    deinit {
        browser?.cancel()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        urlSession?.invalidateAndCancel()
    }

    // MARK: - Public API (any thread)

    public func start(householdId: String) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.householdId != householdId { self.disconnectWebSocket() }
            self.householdId = householdId
            self.isRunning = true
            self.startBrowser()
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isRunning = false
            self.stopBrowser()
            self.stopReconnectTimer()
            self.disconnectWebSocket()
            self.currentHost = nil
        }
    }

    public func ensureRunning() {
        queue.async { [weak self] in
            guard let self, self.isRunning, let hId = self.householdId, !hId.isEmpty else { return }
            if self.browser == nil { self.startBrowser() }
            if self.currentTask() == nil, self.reconnectTimer == nil, let host = self.currentHost {
                self.connectToTvHost(host)
            }
        }
    }

    public var isConnected: Bool {
        lock.lock(); defer { lock.unlock() }
        return connected
    }

    /// `true` when `deviceId` is a TV heard on this channel (set by the sync service after decrypting
    /// its `device_announce`, never from the clear envelope: any client of the relay can send one).
    public func isTv(_ deviceId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return connected && tvDeviceIds.contains(deviceId)
    }

    public func markTv(_ deviceId: String) {
        lock.lock(); defer { lock.unlock() }
        tvDeviceIds.insert(deviceId)
    }

    @discardableResult
    public func sendEnvelope(_ envelope: HouseholdSealedEnvelope) -> Bool {
        guard let task = currentTask(), isConnected else { return false }
        let frame: [String: Any] = [
            "method": "ms.channel.emit",
            "params": [
                "event": "buntu-sync-envelope",
                "to": "broadcast",
                "data": [
                    "household_id": envelope.householdId,
                    "sender_device_id": envelope.senderDeviceId,
                    "sequence": NSNumber(value: envelope.sequence),
                    "nonce_hex": envelope.nonceHex,
                    "ciphertext_hex": envelope.ciphertextHex,
                ] as [String: Any],
            ] as [String: Any],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: frame),
              let text = String(data: data, encoding: .utf8) else { return false }
        task.send(.string(text)) { _ in }
        return true
    }

    // MARK: - Discovery (queue)

    private func startBrowser() {
        guard browser == nil else { return }
        let params = NWParameters()
        params.includePeerToPeer = false
        let b = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            self?.handleBrowseResults(results)
        }
        b.stateUpdateHandler = { [weak self] state in
            guard let self, case .failed = state else { return }
            self.browser?.cancel()
            self.browser = nil
        }
        b.start(queue: queue)
        browser = b
    }

    private func stopBrowser() {
        browser?.cancel()
        browser = nil
        resolving.values.forEach { $0.cancel() }
        resolving.removeAll()
    }

    private func handleBrowseResults(_ results: Set<NWBrowser.Result>) {
        // One TV at a time (PRD-45 § 8, question 3): nothing to resolve while a channel is open or opening.
        guard isRunning, currentTask() == nil else { return }
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint, resolving[name] == nil else { continue }
            resolve(name: name, endpoint: result.endpoint)
        }
    }

    /// Resolves the Bonjour name to an IPv4 address by opening (then closing) a TCP connection to it.
    /// IPv4 only: a link-local IPv6 with its `%en0` scope does not fit in a `ws://` URL.
    private func resolve(name: String, endpoint: NWEndpoint) {
        let params = NWParameters.tcp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let conn = NWConnection(to: endpoint, using: params)
        resolving[name] = conn
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn else { return }
            switch state {
            case .ready:
                let host: String?
                if case .hostPort(let h, _) = conn.currentPath?.remoteEndpoint { host = Self.hostString(h) } else { host = nil }
                conn.cancel()
                self.resolving[name] = nil
                if let host, self.currentTask() == nil {
                    self.onLog?("TV Samsung trouvée sur le réseau (\(host)) : ouverture de son canal…", false)
                    self.connectToTvHost(host)
                }
            case .failed, .waiting:
                conn.cancel()
                self.resolving[name] = nil
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    static func hostString(_ host: NWEndpoint.Host) -> String? {
        switch host {
        case .ipv4(let addr):
            // The description may carry the interface (`192.168.1.20%en0`): not valid in a URL.
            return "\(addr)".split(separator: "%").first.map(String.init)
        case .name(let name, _):
            return name
        case .ipv6:
            return nil
        @unknown default:
            return nil
        }
    }

    // MARK: - WebSocket (queue)

    private func currentTask() -> URLSessionWebSocketTask? {
        lock.lock(); defer { lock.unlock() }
        return webSocketTask
    }

    private func connectToTvHost(_ host: String) {
        guard isRunning, let householdId, !householdId.isEmpty else { return }
        guard let url = URL(string: "ws://\(host):\(Self.channelPort)/api/v2/channels/buntu.sync.\(householdId)") else { return }
        disconnectWebSocket()
        currentHost = host

        let session = URLSession(configuration: .ephemeral)
        urlSession = session
        let task = session.webSocketTask(with: url)
        lock.lock(); webSocketTask = task; lock.unlock()
        task.resume()
        receive(on: task)
    }

    private func disconnectWebSocket() {
        lock.lock()
        let task = webSocketTask
        let wasConnected = connected
        let tvs = tvDeviceIds
        webSocketTask = nil
        connected = false
        tvDeviceIds.removeAll()
        lock.unlock()

        task?.cancel(with: .normalClosure, reason: nil)
        urlSession?.invalidateAndCancel()
        urlSession = nil
        if wasConnected { onDisconnected?(tvs) }
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self, weak task] result in
            guard let self, let task else { return }
            self.queue.async {
                guard self.currentTask() === task else { return }
                switch result {
                case .success(let message):
                    self.handle(message)
                    self.receive(on: task)
                case .failure:
                    if self.reconnectAttempts == 0 {
                        self.onLog?("Canal de la TV Samsung fermé ou injoignable : nouvel essai bientôt.", true)
                    }
                    self.disconnectWebSocket()
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let s): data = Data(s.utf8)
        case .data(let d): data = d
        @unknown default: return
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }

        switch root["event"] as? String {
        case "ms.channel.connect":
            lock.lock(); connected = true; lock.unlock()
            reconnectAttempts = 0
            // The relay lists who is on this household channel, this device included.
            let others = max(0, ((root["data"] as? [String: Any])?["clients"] as? [Any])?.count ?? 1) - 1
            if others == 0 {
                onLog?("Canal de la TV ouvert, mais personne d'autre dessus : Buntu est-il ouvert sur la TV, "
                       + "et la TV est-elle dans ce foyer (même identifiant dans « Appareils ») ?", true)
            } else {
                onLog?("Canal de la TV ouvert : \(others) autre(s) appareil(s) connecté(s).", false)
            }
            onConnected?()
        case "ms.channel.clientConnect":
            onLog?("Un appareil vient de rejoindre le canal de la TV.", false)
        case "buntu-sync-envelope":
            if let envelope = Self.parseEnvelope(root["data"]) { onEnvelopeReceived?(envelope) }
        default:
            break
        }
    }

    /// The relay may hand `data` back as an object or as a JSON string.
    static func parseEnvelope(_ raw: Any?) -> HouseholdSealedEnvelope? {
        var value = raw
        if let str = value as? String, let strData = str.data(using: .utf8) {
            value = try? JSONSerialization.jsonObject(with: strData)
        }
        guard let dict = value as? [String: Any],
              let householdId = dict["household_id"] as? String,
              let senderId = dict["sender_device_id"] as? String,
              let sequence = (dict["sequence"] as? NSNumber)?.uint64Value,
              let nonce = dict["nonce_hex"] as? String,
              let cipher = dict["ciphertext_hex"] as? String else { return nil }
        return HouseholdSealedEnvelope(
            householdId: householdId, senderDeviceId: senderId, sequence: sequence,
            nonceHex: nonce, ciphertextHex: cipher
        )
    }

    // MARK: - Reconnection (queue)

    private func scheduleReconnect() {
        guard isRunning, reconnectTimer == nil else { return }
        reconnectAttempts += 1
        let delay = min(30.0, pow(2.0, Double(reconnectAttempts)))
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.stopReconnectTimer()
            guard self.isRunning else { return }
            if let host = self.currentHost, self.reconnectAttempts < 4 {
                self.connectToTvHost(host)
            } else {
                // The TV may have changed address (DHCP): look for it again.
                self.currentHost = nil
                self.stopBrowser()
                self.startBrowser()
            }
        }
        timer.resume()
        reconnectTimer = timer
    }

    private func stopReconnectTimer() {
        reconnectTimer?.cancel()
        reconnectTimer = nil
    }
}
