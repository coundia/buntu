import Testing
import Foundation
@testable import CndIptvApp

@Suite("Source Sharing Lots 26.3 & 26.4 Tests (PRD-26)")
struct SharingNearbyAndCloudKitTests {

    @Test @MainActor func testNearbyTransferServerPairingCode() {
        let server = NearbyTransferServer()
        let pin = server.pairingCode

        #expect(pin.count == 6)
        #expect(Int(pin) != nil)
        #expect(server.state == .idle)
    }

    @Test func testDiscoveredPeerPinCodeExtraction() {
        let peer = NearbyTransferClient.DiscoveredPeer(
            id: "CND-IPTV-582910",
            name: "CND-IPTV-582910",
            endpoint: .service(name: "CND-IPTV-582910", type: "_cndiptv._tcp", domain: "local.", interface: nil)
        )

        #expect(peer.pinCode == "582910")
        #expect(peer.name == "CND-IPTV-582910")
    }

    @Test @MainActor func testCloudKitSourceShareLifecycle() async throws {
        let controller = CloudKitSourceShareController.shared

        let url = try await controller.createShare(
            sourceId: 101,
            sourceName: "Bouquet Famille",
            permission: .readWrite
        )

        #expect(url.absoluteString.contains("share") || url.absoluteString.contains("icloud"))
        #expect(controller.activeShares.contains { $0.sourceName == "Bouquet Famille" })

        if let first = controller.activeShares.first {
            #expect(first.isOwner == true)
            #expect(first.participantCount >= 1)
            controller.removeShare(id: first.id)
            #expect(!controller.activeShares.contains { $0.id == first.id })
        }
    }
}

