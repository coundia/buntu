import XCTest
import Network
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
}
