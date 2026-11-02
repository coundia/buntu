import Foundation
import Network
import CryptoKit

/// Lot 26.3 — Direct peer-to-peer transfer across local network (Bonjour `_cndiptv._tcp`).
/// Allows effortless source transfer to Apple TV or any nearby device without a cloud server.
@Observable
@MainActor
public final class NearbyTransferServer {
    public static let serviceType = "_cndiptv._tcp"

    /// 6-digit one-time pairing code displayed on the receiving device (e.g. Apple TV).
    public let pairingCode: String

    /// State of the server.
    public enum State: Equatable, Sendable {
        case idle
        case listening(port: UInt16)
        case connected(peer: String)
        case completed(sourceCount: Int)
        case failed(String)
    }

    public private(set) var state: State = .idle

    @ObservationIgnored
    private var listener: NWListener?

    @ObservationIgnored
    private var connection: NWConnection?

    public var onEnvelopeReceived: ((Data) -> Void)?

    public init() {
        // Generate a random 6-digit PIN
        let pin = String(format: "%06d", Int.random(in: 100_000...999_999))
        self.pairingCode = pin
    }

    public func startListening() {
        do {
            let params = NWParameters.tcp
            params.includePeerToPeer = true

            let listener = try NWListener(using: params)
            listener.service = NWListener.Service(name: "CND-IPTV-\(pairingCode)", type: Self.serviceType)

            listener.stateUpdateHandler = { [weak self] newState in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch newState {
                    case .ready:
                        let port = listener.port?.rawValue ?? 0
                        self.state = .listening(port: port)
                    case .failed(let error):
                        self.state = .failed(error.localizedDescription)
                    default:
                        break
                    }
                }
            }

            listener.newConnectionHandler = { [weak self] conn in
                Task { @MainActor [weak self] in
                    self?.handleNewConnection(conn)
                }
            }

            listener.start(queue: .main)
            self.listener = listener
        } catch {
            self.state = .failed(error.localizedDescription)
        }
    }

    private func handleNewConnection(_ conn: NWConnection) {
        self.connection = conn
        conn.start(queue: .main)
        self.state = .connected(peer: conn.endpoint.debugDescription)

        // Receive framed envelope data (4-byte length prefix + payload)
        conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let self, let data, data.count == 4 else { return }
            let length = data.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }

            conn.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { [weak self] payload, _, _, _ in
                Task { @MainActor [weak self] in
                    guard let self, let payload else { return }
                    self.onEnvelopeReceived?(payload)
                    self.state = .completed(sourceCount: 1)
                    self.stop()
                }
            }
        }
    }

    public func stop() {
        connection?.cancel()
        connection = nil
        listener?.cancel()
        listener = nil
        if case .listening = state {
            state = .idle
        }
    }
}

/// Discovers nearby receivers and sends encrypted source packages over local network.
@Observable
@MainActor
public final class NearbyTransferClient {
    public struct DiscoveredPeer: Identifiable, Hashable, Sendable {
        public let id: String
        public let name: String
        public let endpoint: NWEndpoint

        public var pinCode: String {
            if let range = name.range(of: "CND-IPTV-") {
                return String(name[range.upperBound...])
            }
            return ""
        }
    }

    public private(set) var discoveredPeers: [DiscoveredPeer] = []
    public private(set) var isSearching = false

    @ObservationIgnored
    private var browser: NWBrowser?

    public init() {}

    public func startBrowsing() {
        guard !isSearching else { return }
        discoveredPeers = []
        isSearching = true

        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: NearbyTransferServer.serviceType, domain: nil), using: params)

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.discoveredPeers = results.compactMap { result in
                    switch result.endpoint {
                    case .service(let name, _, _, _):
                        return DiscoveredPeer(id: name, name: name, endpoint: result.endpoint)
                    default:
                        return nil
                    }
                }
            }
        }

        browser.start(queue: .main)
        self.browser = browser
    }

    public func stopBrowsing() {
        browser?.cancel()
        browser = nil
        isSearching = false
    }

    /// Sends an encrypted envelope payload to a selected peer with framed 4-byte length prefix.
    public func send(envelopeData: Data, to peer: DiscoveredPeer) async throws {
        let conn = NWConnection(to: peer.endpoint, using: .tcp)
        conn.start(queue: .main)

        var length = UInt32(envelopeData.count).bigEndian
        let header = Data(bytes: &length, count: 4)

        return try await withCheckedThrowingContinuation { continuation in
            conn.send(content: header + envelopeData, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
                conn.cancel()
            })
        }
    }
}
