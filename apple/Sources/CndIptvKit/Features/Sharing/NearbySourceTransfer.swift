import Foundation
import Network
import CryptoKit

/// Lot 26.3 — direct transfer between two devices on the same network (Bonjour `_cndiptv._tcp`).
///
/// The receiver shows a random 6-digit code and listens while its screen is open. The channel is
/// TLS 1.2 with an ECDHE-PSK cipher suite whose key is derived from that code: the ephemeral
/// Diffie-Hellman exchange means a passive listener cannot test guesses offline, and an active one
/// gets a single guess per connection (the receiver stops after `maxFailedAttempts`). The code is
/// never advertised: the Bonjour name is only the device name.
///
/// What travels is the share link (`cndiptv://import#<envelope>.<code>`): the encrypted envelope and
/// its decryption code, which is why the channel itself has to be secret.
enum NearbyTransfer {
    static let serviceType = "_cndiptv._tcp"
    static let maxPayloadBytes = 1_048_576
    static let maxFailedAttempts = 3
    static let listenDuration: TimeInterval = 300
    private static let ack = Data([0x01])
    private static let pskIdentity = Data("cnd-nearby-v1".utf8)

    enum Failure: LocalizedError, Equatable {
        case wrongCode
        case timeout
        case noConfirmation
        case tooLarge
        case invalidPin

        var errorDescription: String? {
            switch self {
            case .wrongCode: return "Connexion refusée : code incorrect, ou l'appareil n'écoute plus."
            case .timeout: return "L'appareil ne répond pas. Vérifiez qu'il affiche « Recevoir » et qu'il est sur le même réseau."
            case .noConfirmation: return "L'appareil n'a pas confirmé la réception."
            case .tooLarge: return "Ce partage est trop volumineux pour un envoi direct."
            case .invalidPin: return "Saisissez le code à 6 chiffres affiché sur l'autre appareil."
            }
        }
    }

    static func isValid(pin: String) -> Bool { pin.count == 6 && pin.allSatisfy(\.isNumber) }

    static func makePin() -> String {
        var generator = SystemRandomNumberGenerator()
        return String(format: "%06d", Int.random(in: 0...999_999, using: &generator))
    }

    /// TLS-PSK parameters shared by both ends.
    static func parameters(pin: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let key = Data(SHA256.hash(data: Data("cnd-nearby-v1:\(pin)".utf8)))
        let options = tls.securityProtocolOptions
        sec_protocol_options_add_pre_shared_key(
            options,
            key.withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData,
            pskIdentity.withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData
        )
        // TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256 (0xCCAC)
        if let suite = tls_ciphersuite_t(rawValue: 0xCCAC) { sec_protocol_options_append_tls_ciphersuite(options, suite) }
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.includePeerToPeer = true
        return parameters
    }

    static func frame(_ payload: Data) -> Data {
        var length = UInt32(payload.count).bigEndian
        return Data(bytes: &length, count: 4) + payload
    }

    static let acknowledgement = ack
}

/// Receiving side. Listens only while it is started; stops after one transfer, too many wrong codes,
/// or `listenDuration`.
@Observable
@MainActor
final class NearbyTransferServer {
    static let serviceType = NearbyTransfer.serviceType

    /// 6-digit one-time pairing code shown on this device.
    let pairingCode: String

    enum State: Equatable, Sendable {
        case idle
        case listening(port: UInt16)
        case connected(peer: String)
        case completed(sourceCount: Int)
        case failed(String)
    }

    private(set) var state: State = .idle

    /// Called with the payload (the share link as UTF-8) once it is fully received.
    var onEnvelopeReceived: ((Data) -> Void)?

    @ObservationIgnored private let deviceName: String
    @ObservationIgnored private let listenDuration: TimeInterval
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var connection: NWConnection?
    @ObservationIgnored private var failedAttempts = 0
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?

    init(deviceName: String = DeviceName.current, listenDuration: TimeInterval = NearbyTransfer.listenDuration) {
        self.deviceName = deviceName
        self.listenDuration = listenDuration
        pairingCode = NearbyTransfer.makePin()
    }

    func startListening() {
        guard listener == nil else { return }
        do {
            let listener = try NWListener(using: NearbyTransfer.parameters(pin: pairingCode))
            listener.service = NWListener.Service(name: deviceName, type: Self.serviceType)
            listener.stateUpdateHandler = { [weak self] newState in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch newState {
                    case .ready: self.state = .listening(port: listener.port?.rawValue ?? 0)
                    case .failed(let error): self.finish(.failed(error.localizedDescription))
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in self?.accept(connection) }
            }
            listener.start(queue: .main)
            self.listener = listener
            timeoutTask = Task { @MainActor [weak self, listenDuration] in
                try? await Task.sleep(nanoseconds: UInt64(listenDuration * 1_000_000_000))
                guard !Task.isCancelled, let self, self.listener != nil else { return }
                self.finish(.failed("Le délai est écoulé : l'appareil n'écoute plus. Rouvrez « Recevoir »."))
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func accept(_ new: NWConnection) {
        guard connection == nil, listener != nil else { new.cancel(); return }
        connection = new
        new.stateUpdateHandler = { [weak self, weak new] connectionState in
            Task { @MainActor [weak self] in
                guard let self, let new, self.connection === new else { return }
                switch connectionState {
                case .ready:
                    self.state = .connected(peer: "appareil proche")
                    self.receiveFrame(on: new)
                case .failed, .cancelled:
                    self.connectionLost()
                default: break
                }
            }
        }
        new.start(queue: .main)
    }

    /// A handshake that fails (wrong code) or a connection that drops before the payload counts as an attempt.
    private func connectionLost() {
        guard connection != nil else { return }
        connection?.cancel()
        connection = nil
        if case .completed = state { return }
        failedAttempts += 1
        if failedAttempts >= NearbyTransfer.maxFailedAttempts {
            finish(.failed("Trop de tentatives avec un mauvais code : la réception est fermée."))
        } else if listener != nil, case .connected = state {
            state = .listening(port: listener?.port?.rawValue ?? 0)
        }
    }

    private func receiveFrame(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] header, _, _, error in
            Task { @MainActor [weak self] in
                guard let self, self.connection === connection else { return }
                guard error == nil, let header, header.count == 4 else { return self.connectionLost() }
                let length = Int(header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
                guard length > 0, length <= NearbyTransfer.maxPayloadBytes else { return self.connectionLost() }
                connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] payload, _, _, error in
                    Task { @MainActor [weak self] in
                        guard let self, self.connection === connection else { return }
                        guard error == nil, let payload, payload.count == length else { return self.connectionLost() }
                        self.onEnvelopeReceived?(payload)
                        connection.send(content: NearbyTransfer.acknowledgement, completion: .contentProcessed { _ in
                            connection.cancel()
                        })
                        self.finish(.completed(sourceCount: 1))
                    }
                }
            }
        }
    }

    private func finish(_ final: State) {
        timeoutTask?.cancel()
        timeoutTask = nil
        listener?.cancel()
        listener = nil
        if case .completed = final {} else { connection?.cancel() }
        connection = nil
        state = final
    }

    func stop() {
        timeoutTask?.cancel()
        timeoutTask = nil
        connection?.cancel()
        connection = nil
        listener?.cancel()
        listener = nil
        if case .listening = state { state = .idle } else if case .connected = state { state = .idle }
    }
}

/// Sending side: finds receivers and sends one payload over the secured channel.
@Observable
@MainActor
final class NearbyTransferClient {
    struct DiscoveredPeer: Identifiable, Hashable, Sendable {
        let id: String
        let name: String
        let endpoint: NWEndpoint
    }

    var discoveredPeers: [DiscoveredPeer] = []
    private(set) var isSearching = false

    @ObservationIgnored private var browser: NWBrowser?

    init() {}

    func startBrowsing() {
        guard !isSearching else { return }
        discoveredPeers = []
        isSearching = true
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: NearbyTransfer.serviceType, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                self?.discoveredPeers = results.compactMap { result in
                    guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                    return DiscoveredPeer(id: name, name: name, endpoint: result.endpoint)
                }.sorted { $0.name < $1.name }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        isSearching = false
    }

    func send(_ payload: Data, to peer: DiscoveredPeer, pin: String) async throws {
        try await send(payload, to: peer.endpoint, pin: pin)
    }

    /// Connects, sends the framed payload and waits for the receiver's confirmation byte.
    func send(_ payload: Data, to endpoint: NWEndpoint, pin: String, timeout: TimeInterval = 10) async throws {
        guard NearbyTransfer.isValid(pin: pin) else { throw NearbyTransfer.Failure.invalidPin }
        guard payload.count <= NearbyTransfer.maxPayloadBytes else { throw NearbyTransfer.Failure.tooLarge }
        let connection = NWConnection(to: endpoint, using: NearbyTransfer.parameters(pin: pin))
        let gate = ResumeOnce()
        defer { connection.cancel() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                gate.install(continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        connection.send(content: NearbyTransfer.frame(payload), completion: .contentProcessed { error in
                            if error != nil { gate.fail(NearbyTransfer.Failure.wrongCode); return }
                            connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { data, _, _, error in
                                if error == nil, data == NearbyTransfer.acknowledgement { gate.succeed() }
                                else { gate.fail(NearbyTransfer.Failure.noConfirmation) }
                            }
                        })
                    case .failed(let error), .waiting(let error):
                        // A wrong code fails the TLS handshake; an unreachable device is a plain network error.
                        if case .tls = error { gate.fail(NearbyTransfer.Failure.wrongCode) }
                        else if case .failed = state { gate.fail(NearbyTransfer.Failure.wrongCode) }
                        else { gate.fail(NearbyTransfer.Failure.timeout) }
                    default: break
                    }
                }
                connection.start(queue: .main)
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { gate.fail(NearbyTransfer.Failure.timeout) }
            }
        } onCancel: {
            connection.cancel()
        }
    }
}

/// Resumes a checked continuation exactly once, whichever callback gets there first.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    func install(_ continuation: CheckedContinuation<Void, Error>) {
        lock.withLock { self.continuation = continuation }
    }

    func succeed() { take()?.resume() }
    func fail(_ error: Error) { take()?.resume(throwing: error) }

    private func take() -> CheckedContinuation<Void, Error>? {
        lock.withLock {
            defer { continuation = nil }
            return continuation
        }
    }
}
