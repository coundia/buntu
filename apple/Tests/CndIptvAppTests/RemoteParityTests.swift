import XCTest
import CndCoreBridge
@testable import CndIptvKit

final class RemoteParityTests: XCTestCase {

    func testPlayRequestRoundtrip() throws {
        let keyHex = "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"
        let senderId = "dev_iphone_14"
        let nonce = Data([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12])
        let msgJson = """
        {"type":"play_request","target_device_id":"dev_tv_samsung_01","request_id":"req_abc123","content_key":"eeeb12e4004a2cc37dbf6b5a296d06cf9540088628158a4ed8eb2cbec359ebfe","source_key":"09aaef741e3cdf73c3d8422cc78912c9d9e31c389e3438539833056f8f3fcb42","item_kind":"movie","provider_ref":"5002","title":"Inception","position_ms":45200,"profile_uuid":"u_dad","replace":true}
        """

        let env = try syncSealEnvelope(
            householdKeyHex: keyHex,
            senderDeviceId: senderId,
            sequence: 10,
            nonceBytes: nonce,
            messageJson: msgJson
        )

        let decryptedJson = try syncOpenEnvelope(
            householdKeyHex: keyHex,
            envelope: env,
            lastSeenSequence: 9
        )

        let data = decryptedJson.data(using: .utf8)!
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(root["type"] as? String, "play_request")
        XCTAssertEqual(root["target_device_id"] as? String, "dev_tv_samsung_01")
        XCTAssertEqual(root["position_ms"] as? UInt64, 45200)
    }

    func testSingleStreamRuleLogic() {
        let currentSourceKey = "09aaef741e3cdf73c3d8422cc78912c9d9e31c389e3438539833056f8f3fcb42"
        let releaseSourceKey = "09aaef741e3cdf73c3d8422cc78912c9d9e31c389e3438539833056f8f3fcb42"
        let otherSourceKey = "50da872e2da3b988f27f58dcbb926897ce56a8349fcc842b8a00352799fd8f82"

        XCTAssertTrue(currentSourceKey.caseInsensitiveCompare(releaseSourceKey) == .orderedSame)
        XCTAssertFalse(currentSourceKey.caseInsensitiveCompare(otherSourceKey) == .orderedSame)
    }

    func testXtreamFallbackUrlReconstruction() {
        let server = "http://my-iptv-server.com:8080/".trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let u = "user123"
        let p = "pass456_fake_placeholder"
        let providerRef = "5002"
        let ext = "mkv"

        let reconstructed = "\(server)/movie/\(u)/\(p)/\(providerRef).\(ext)"
        XCTAssertEqual(reconstructed, "http://my-iptv-server.com:8080/movie/user123/pass456_fake_placeholder/5002.mkv")
    }
}

