import Foundation
import Network
import CndCoreBridge

/// Samsung Smart TV MSF Channel Transport for Local Household Sync (PRD-45 § 3.2).
///
/// Discovers Samsung TVs on the local network via `_samsungmsf._tcp`, connects to the TV's internal
/// WebSocket relay (`ws://<tv_host>:8001/api/v2/channels/buntu.sync.<household_id>`), and exchanges
/// AES-256-GCM sealed envelopes using MSF 2.0 framing (`ms.channel.emit` / `buntu-sync-envelope`).
public final class SamsungChannelTransport: NSObject, @unchecked Sendable, NetServiceDelegate {
    public static let serviceType = "_samsungmsf._tcp"

    public var onEnvelopeReceived: (@Sendable (_ envelope: HouseholdSealedEnvelope) -> Void)?
    public var onConnected: (@Sendable () -> Void)?
    public var onDisconnected: (@Sendable () -> Void)?

    private let queue = DispatchQueue(label: "com.pcoundia.buntu.samsungtransport", qos: .utility)
    private var browser: NWBrowser?
    private var resolvingConnections: [NWConnection] = []
    private var resolvingNetServices: [NetService] = []

    private var currentHost: String?
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var householdId: String?
    private var isRunning = false
    private var isConnected = false
    private var reconnectTimer: DispatchSourceTimer?
    private var reconnectAttempts = 0

    /// Device ID of the Samsung TV heard on this transport.
    public private(set) var connectedTvDeviceId: String?

    public override init() {
        super.init()
    }

    deinit {
        stop()
    }

    public func start(householdId: String) {
        queue.async { [weak self] in
            guard let self else { return }
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
            self.disconnectWebSocket()
            self.stopReconnectTimer()
            self.connectedTvDeviceId = nil
        }
    }

    public func ensureRunning() {
        queue.async { [weak self] in
            guard let self, self.isRunning, let hId = self.householdId, !hId.isEmpty else { return }
            if self.browser == nil {
                self.startBrowser()
            }
            if self.webSocketTask == nil, let host = self.currentHost {
                self.connectToTvHost(host)
            }
        }
    }

    public func isPeer(_ deviceId: String) -> Bool {
        return connectedTvDeviceId == deviceId
    }

    public func recordPeerId(_ deviceId: String) {
        connectedTvDeviceId = deviceId
    }

    // MARK: - Browser

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
            if case .failed = state {
                self.queue.async {
                    self.browser?.cancel()
                    self.browser = nil
                }
            }
        }

        b.start(queue: queue)
        self.browser = b
    }

    private func stopBrowser() {
        browser?.cancel()
        browser = nil
        for conn in resolvingConnections { conn.cancel() }
        resolvingConnections.removeAll()
        for svc in resolvingNetServices { svc.stop() }
        resolvingNetServices.removeAll()
    }

    private func handleBrowseResults(_ results: Set<NWBrowser.Result>) {
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint else { continue }

            // Resolve via NWConnection
            let conn = NWConnection(to: result.endpoint, using: .tcp)
            resolvingConnections.append(conn)
            conn.stateUpdateHandler = { [weak self, weak conn] state in
                guard let self, let conn else { return }
                switch state {
                case .ready:
                    if case .hostPort(let host, _) = conn.currentPath?.remoteEndpoint {
                        let hostStr = self.extractHostString(host)
                        conn.cancel()
                        self.queue.async {
                            self.resolvingConnections.removeAll { $0 === conn }
                            if let hostStr, !hostStr.isEmpty {
                                self.connectToTvHost(hostStr)
                            }
                        }
                    }
                case .failed, .cancelled:
                    self.queue.async {
                        self.resolvingConnections.removeAll { $0 === conn }
                    }
                default:
                    break
                }
            }
            conn.start(queue: queue)

            // Also resolve via NetService as fallback
            let netService = NetService(domain: "local.", type: Self.serviceType + ".", name: name)
            netService.delegate = self
            resolvingNetServices.append(netService)
            netService.resolve(withTimeout: 5.0)
        }
    }

    private func extractHostString(_ host: NWEndpoint.Host) -> String? {
        switch host {
        case .ipv4(let addr): return "\(addr)"
        case .ipv6(let addr): return "\(addr)"
        case .name(let name, _): return name
        @unknown default: return nil
        }
    }

    // MARK: - NetServiceDelegate

    public func netServiceDidResolveAddress(_ sender: NetService) {
        queue.async { [weak self] in
            guard let self else { return }
            self.resolvingNetServices.removeAll { $0 === sender }
            if let addresses = sender.addresses {
                for data in addresses {
                    data.withUnsafeBytes { rawPtr in
                        let sockaddrPtr = rawPtr.bindMemory(to: sockaddr.self)
                        guard let base = sockaddrPtr.baseAddress, base.pointee.sa_family == sa_family_t(AF_INET) else { return }
                        let inPtr = rawPtr.bindMemory(to: sockaddr_in.self)
                        guard let sin = inPtr.baseAddress else { return }
                        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                        var sinAddr = sin.pointee.sin_addr
                        inet_ntop(AF_INET, &sinAddr, &buffer, socklen_t(INET_ADDRSTRLEN))
                        let ip = String(cString: buffer)
                        if !ip.isEmpty {
                            self.connectToTvHost(ip)
                        }
                    }
                }
            }
        }
    }

    public func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        queue.async { [weak self] in
            self?.resolvingNetServices.removeAll { $0 === sender }
        }
    }

    // MARK: - WebSocket Client (Samsung MSF 2.0 Channel)

    private func connectToTvHost(_ host: String) {
        guard isRunning, let householdId, !householdId.isEmpty else { return }
        if isConnected, currentHost == host { return }

        self.currentHost = host
        disconnectWebSocket()

        guard let url = URL(string: "ws://\(host):8001/api/v2/channels/buntu.sync.\(householdId)") else {
            return
        }

        let session = URLSession(configuration: .ephemeral)
        self.urlSession = session
        let task = session.webSocketTask(with: url)
        self.webSocketTask = task
        task.resume()

        listenForMessages(task)
    }

    private func disconnectWebSocket() {
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        if isConnected {
            isConnected = false
            onDisconnected?()
        }
    }

    private func listenForMessages(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self, weak task] result in
            guard let self, let task, self.webSocketTask === task else { return }

            switch result {
            case .success(let message):
                self.handleIncomingWebSocketMessage(message)
                self.listenForMessages(task)

            case .failure:
                self.queue.async {
                    if self.webSocketTask === task {
                        self.disconnectWebSocket()
                        self.scheduleReconnect()
                    }
                }
            }
        }
    }

    private func handleIncomingWebSocketMessage(_ message: URLSessionWebSocketTask.Message) {
        let text: String
        switch message {
        case .string(let s): text = s
        case .data(let d): text = String(decoding: d, as: UTF8.self)
        @unknown default: return
        }

        guard let data = text.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return
        }

        let event = root["event"] as? String

        if event == "ms.channel.connect" {
            queue.async {
                self.isConnected = true
                self.reconnectAttempts = 0
                self.onConnected?()
            }
            return
        }

        if event == "buntu-sync-envelope" {
            var rawEnvelope = root["data"]
            if let str = rawEnvelope as? String, let strData = str.data(using: .utf8) {
                rawEnvelope = try? JSONSerialization.jsonObject(with: strData)
            }

            guard let dict = rawEnvelope as? [String: Any],
                  let hId = dict["household_id"] as? String,
                  let sId = dict["sender_device_id"] as? String,
                  let seq = (dict["sequence"] as? NSNumber)?.uint64Value,
                  let nonce = dict["nonce_hex"] as? String,
                  let cipher = dict["ciphertext_hex"] as? String else {
                return
            }

            let envelope = HouseholdSealedEnvelope(
                householdId: hId,
                senderDeviceId: sId,
                sequence: seq,
                nonceHex: nonce,
                ciphertextHex: cipher
            )

            self.recordPeerId(sId)
            self.onEnvelopeReceived?(envelope)
        }
    }

    // MARK: - Sending Envelopes

    @discardableResult
    public func sendEnvelope(_ envelope: HouseholdSealedEnvelope) -> Bool {
        guard let task = webSocketTask, isConnected else { return false }

        let wireDict: [String: Any] = [
            "household_id": envelope.householdId,
            "sender_device_id": envelope.senderDeviceId,
            "sequence": envelope.sequence,
            "nonce_hex": envelope.nonceHex,
            "ciphertext_hex": envelope.ciphertextHex
        ]

        let frame: [String: Any] = [
            "method": "ms.channel.emit",
            "params": [
                "event": "buntu-sync-envelope",
                "to": "broadcast",
                "data": wireDict
            ]
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: frame),
              let frameText = String(data: data, encoding: .utf8) else {
            return false
        }

        task.send(.string(frameText)) { _ in }
        return true
    }

    // MARK: - Reconnection

    private func scheduleReconnect() {
        guard isRunning, reconnectTimer == nil else { return }
        reconnectAttempts += 1
        let delay = min(30.0, pow(2.0, Double(reconnectAttempts)))

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.stopReconnectTimer()
            guard self.isRunning, let host = self.currentHost else { return }
            self.connectToTvHost(host)
        }
        timer.resume()
        self.reconnectTimer = timer
    }

    private func stopReconnectTimer() {
        reconnectTimer?.cancel()
        reconnectTimer = nil
    }
}
