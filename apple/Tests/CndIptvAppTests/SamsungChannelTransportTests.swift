import XCTest
import Network
import CndCoreBridge
@testable import CndIptvKit

/// Format of the Samsung channel (PRD-45 § 3.1): the sealed envelope is the `data` of the relayed event.
final class SamsungChannelTransportTests: XCTestCase {

    private let envelopeFields: [String: Any] = [
        "household_id": "hh_1",
        "sender_device_id": "tv_1",
        "sequence": 42,
        "nonce_hex": "00",
        "ciphertext_hex": "ff",
    ]

    func testEnvelopeAsObject() {
        let envelope = SamsungChannelTransport.parseEnvelope(envelopeFields)
        XCTAssertEqual(envelope?.senderDeviceId, "tv_1")
        XCTAssertEqual(envelope?.sequence, 42)
    }

    func testEnvelopeAsJsonString() throws {
        let text = String(data: try JSONSerialization.data(withJSONObject: envelopeFields), encoding: .utf8)
        XCTAssertEqual(SamsungChannelTransport.parseEnvelope(text)?.householdId, "hh_1")
    }

    func testSequenceAsStringIsRejected() {
        var fields = envelopeFields
        fields["sequence"] = "42"
        XCTAssertNil(SamsungChannelTransport.parseEnvelope(fields))
    }

    func testHostDropsInterfaceAndIgnoresIPv6() {
        XCTAssertEqual(SamsungChannelTransport.hostString(.ipv4(IPv4Address("192.168.1.20")!)), "192.168.1.20")
        XCTAssertNil(SamsungChannelTransport.hostString(.ipv6(IPv6Address("fe80::1")!)))
    }

    func testRemoteTextPayloadTrimsAndRejectsBlank() throws {
        XCTAssertNil(LocalSyncService.remoteTextPayload(""))
        XCTAssertNil(LocalSyncService.remoteTextPayload("   \n\t  "))

        let json = try XCTUnwrap(LocalSyncService.remoteTextPayload("  Mets France 2 \n"))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(obj["type"] as? String, "remote_text")
        XCTAssertEqual(obj["text"] as? String, "Mets France 2")
    }

    func testRemoteTextSyncMessageRoundtripAndChannelEnvelope() throws {
        let keyHex = "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"
        let nonce = Data([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11])
        let payloadJson = try XCTUnwrap(LocalSyncService.remoteTextPayload("  Cherche Inception  "))

        let sealed = try syncSealEnvelope(
            householdKeyHex: keyHex,
            senderDeviceId: "dev_iphone_voice",
            sequence: 7,
            nonceBytes: nonce,
            messageJson: payloadJson
        )

        let channelDict: [String: Any] = [
            "household_id": sealed.householdId,
            "sender_device_id": sealed.senderDeviceId,
            "sequence": NSNumber(value: sealed.sequence),
            "nonce_hex": sealed.nonceHex,
            "ciphertext_hex": sealed.ciphertextHex,
        ]
        let parsed = try XCTUnwrap(SamsungChannelTransport.parseEnvelope(channelDict))
        XCTAssertEqual(parsed.householdId, sealed.householdId)
        XCTAssertEqual(parsed.senderDeviceId, "dev_iphone_voice")
        XCTAssertEqual(parsed.sequence, 7)

        let openedJson = try syncOpenEnvelope(
            householdKeyHex: keyHex,
            envelope: parsed,
            lastSeenSequence: 6
        )
        let opened = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(openedJson.utf8)) as? [String: Any])
        XCTAssertEqual(opened["type"] as? String, "remote_text")
        XCTAssertEqual(opened["text"] as? String, "Cherche Inception")
    }

    func testRemoteTextPayloadWithTargetDeviceId() throws {
        let broadcastJson = try XCTUnwrap(LocalSyncService.remoteTextPayload("  France 2 ", targetDeviceId: nil))
        let broadcastObj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(broadcastJson.utf8)) as? [String: Any])
        XCTAssertEqual(broadcastObj["type"] as? String, "remote_text")
        XCTAssertEqual(broadcastObj["text"] as? String, "France 2")
        XCTAssertNil(broadcastObj["target_device_id"])

        let blankTargetJson = try XCTUnwrap(LocalSyncService.remoteTextPayload("France 2", targetDeviceId: "   "))
        let blankTargetObj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(blankTargetJson.utf8)) as? [String: Any])
        XCTAssertNil(blankTargetObj["target_device_id"])

        let targetedJson = try XCTUnwrap(LocalSyncService.remoteTextPayload("Chaîne suivante", targetDeviceId: "tv_salon"))
        let targetedObj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(targetedJson.utf8)) as? [String: Any])
        XCTAssertEqual(targetedObj["type"] as? String, "remote_text")
        XCTAssertEqual(targetedObj["text"] as? String, "Chaîne suivante")
        XCTAssertEqual(targetedObj["target_device_id"] as? String, "tv_salon")
    }

    func testRemoteCommandTargetResolverConnectedPeersAndDefaultSelection() {
        let now = Date()
        let tv = DiscoveredPeer(id: "tv_1", name: "TV Salon", deviceType: "tv", lastSeen: now.addingTimeInterval(-10))
        let mac = DiscoveredPeer(id: "mac_1", name: "MacBook", deviceType: "mac", lastSeen: now.addingTimeInterval(-30))
        let stale = DiscoveredPeer(id: "old_1", name: "Ancien iPad", deviceType: "tablet", lastSeen: now.addingTimeInterval(-180))

        let connected = RemoteCommandTargetResolver.connectedPeers(from: [tv, stale, mac], now: now)
        XCTAssertEqual(connected.map(\.id), ["tv_1", "mac_1"])

        // 0 connected devices -> nil
        XCTAssertNil(RemoteCommandTargetResolver.defaultSelection(connectedPeers: [], current: nil))
        XCTAssertNil(RemoteCommandTargetResolver.defaultSelection(connectedPeers: [], current: "__all__"))

        // 1 connected device -> auto-selected regardless of previous selection
        XCTAssertEqual(RemoteCommandTargetResolver.defaultSelection(connectedPeers: [tv], current: nil), "tv_1")
        XCTAssertEqual(RemoteCommandTargetResolver.defaultSelection(connectedPeers: [tv], current: "__all__"), "tv_1")
        XCTAssertEqual(RemoteCommandTargetResolver.defaultSelection(connectedPeers: [tv], current: "other"), "tv_1")

        // >1 connected devices -> defaults to "__all__", keeps valid current selection
        XCTAssertEqual(RemoteCommandTargetResolver.defaultSelection(connectedPeers: [tv, mac], current: nil), "__all__")
        XCTAssertEqual(RemoteCommandTargetResolver.defaultSelection(connectedPeers: [tv, mac], current: "__all__"), "__all__")
        XCTAssertEqual(RemoteCommandTargetResolver.defaultSelection(connectedPeers: [tv, mac], current: "mac_1"), "mac_1")
        XCTAssertEqual(RemoteCommandTargetResolver.defaultSelection(connectedPeers: [tv, mac], current: "old_1"), "__all__")
    }

    func testShouldAcceptRemoteTextFiltersTargetAndBlankText() {
        let localId = "mac-local-1"

        // Broadcast (no target_device_id or empty) -> accepted & trimmed
        XCTAssertEqual(
            LocalSyncService.shouldAcceptRemoteText(["text": "  Mets France 2  "], localDeviceId: localId),
            "Mets France 2"
        )
        XCTAssertEqual(
            LocalSyncService.shouldAcceptRemoteText(["text": "Mets France 2", "target_device_id": ""], localDeviceId: localId),
            "Mets France 2"
        )

        // Matching target_device_id -> accepted
        XCTAssertEqual(
            LocalSyncService.shouldAcceptRemoteText(["text": "Mets France 2", "target_device_id": localId], localDeviceId: localId),
            "Mets France 2"
        )

        // Different target_device_id -> ignored
        XCTAssertNil(
            LocalSyncService.shouldAcceptRemoteText(["text": "Mets France 2", "target_device_id": "tv-other"], localDeviceId: localId)
        )

        // Blank or missing text -> ignored
        XCTAssertNil(
            LocalSyncService.shouldAcceptRemoteText(["text": "   \n  ", "target_device_id": localId], localDeviceId: localId)
        )
        XCTAssertNil(
            LocalSyncService.shouldAcceptRemoteText(["target_device_id": localId], localDeviceId: localId)
        )
    }
}
