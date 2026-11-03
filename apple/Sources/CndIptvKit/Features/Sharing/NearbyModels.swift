import Foundation
import Observation
import CndCoreBridge

/// "Envoyer vers un autre appareil": builds the same encrypted share as the file/link flow, then hands
/// the link to a receiver found on the local network, through the code-protected channel.
@Observable
@MainActor
final class NearbySendModel {
    enum Status: Equatable {
        case idle
        case sending
        case sent
        case failed(String)
    }

    typealias Sender = (Data, NearbyTransferClient.DiscoveredPeer, String) async throws -> Void

    let share: ShareSourcesModel
    let client: NearbyTransferClient
    var selectedPeerID: String?
    var pin = "" { didSet { if status != .sending, status != .idle { status = .idle } } }
    private(set) var status: Status = .idle
    @ObservationIgnored private let sender: Sender

    init(share: ShareSourcesModel, client: NearbyTransferClient? = nil, sender: Sender? = nil) {
        let client = client ?? NearbyTransferClient()
        self.share = share
        self.client = client
        self.sender = sender ?? { [client] payload, peer, pin in try await client.send(payload, to: peer, pin: pin) }
        share.validity = .hour
    }

    var selectedPeer: NearbyTransferClient.DiscoveredPeer? {
        client.discoveredPeers.first { $0.id == selectedPeerID }
    }

    var canSend: Bool {
        !share.selected.isEmpty && selectedPeer != nil && NearbyTransfer.isValid(pin: pin) && status != .sending
    }

    func startSearching() { client.startBrowsing() }
    func stopSearching() { client.stopBrowsing() }

    func send() async {
        guard canSend, let peer = selectedPeer else { return }
        status = .sending
        await share.prepare()
        guard let package = share.package else {
            status = .failed(share.errorMessage ?? "Impossible de préparer le partage.")
            return
        }
        // The share is a one-shot: it is not kept once it has been sent or has failed.
        defer { share.reset() }
        do {
            try await sender(Data(package.link.utf8), peer, pin)
            status = .sent
        } catch {
            status = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}

/// "Recevoir depuis un autre appareil": shows the code and listens while the sheet is open.
@Observable
@MainActor
final class NearbyReceiveModel {
    enum Status: Equatable {
        case waiting
        case connected
        case received
        case failed(String)
    }

    let server: NearbyTransferServer
    private(set) var rejected = false
    @ObservationIgnored var onReceived: (IncomingShare) -> Void = { _ in }

    init(server: NearbyTransferServer? = nil) {
        let server = server ?? NearbyTransferServer()
        self.server = server
        server.onEnvelopeReceived = { [weak self] payload in self?.handle(payload) }
    }

    var pairingCode: String { server.pairingCode }

    var status: Status {
        if rejected { return .failed("Le contenu reçu n'est pas un partage CND IPTV.") }
        switch server.state {
        case .idle, .listening: return .waiting
        case .connected: return .connected
        case .completed: return .received
        case .failed(let message): return .failed(message)
        }
    }

    func start() { server.startListening() }
    func stop() { server.stop() }

    private func handle(_ payload: Data) {
        guard let text = String(data: payload, encoding: .utf8), let url = URL(string: text),
              let incoming = IncomingShare.from(url: url) else {
            rejected = true
            return
        }
        onReceived(incoming)
    }
}
