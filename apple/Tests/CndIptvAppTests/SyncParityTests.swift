import XCTest
import CndCoreBridge
@testable import CndIptvKit

final class SyncParityTests: XCTestCase {

    func testSourceKeyXtreamParity() {
        let server = "http://My-Provider.COM:8080/path/"
        let username = "UserTest1"
        let key = syncComputeSourceKey(sourceType: "xtream", serverOrUrl: server, username: username)
        XCTAssertEqual(key, "09aaef741e3cdf73c3d8422cc78912c9d9e31c389e3438539833056f8f3fcb42")
    }

    func testSourceKeyM3uParity() {
        let url = "http://my-iptv.net:8000/get.php?username=alice&password=secret&type=m3u_plus"
        let key = syncComputeSourceKey(sourceType: "m3u", serverOrUrl: url, username: nil)
        XCTAssertEqual(key, "50da872e2da3b988f27f58dcbb926897ce56a8349fcc842b8a00352799fd8f82")
    }

    func testContentKeyLiveParity() {
        let sourceKey = "09aaef741e3cdf73c3d8422cc78912c9d9e31c389e3438539833056f8f3fcb42"
        let contentKey = syncComputeContentKey(sourceKey: sourceKey, itemKind: "live", providerId: "1001")
        XCTAssertEqual(contentKey, "eeeb12e4004a2cc37dbf6b5a296d06cf9540088628158a4ed8eb2cbec359ebfe")
    }

    func testContentKeyMovieParity() {
        let sourceKey = "09aaef741e3cdf73c3d8422cc78912c9d9e31c389e3438539833056f8f3fcb42"
        let contentKey = syncComputeContentKey(sourceKey: sourceKey, itemKind: "movie", providerId: "5002")
        XCTAssertEqual(contentKey, "f842040521748226742432154eb9904ccd45b2e598bd8b42bfca99dd1e62237b")
    }

    func testHouseholdIdDerivationParity() throws {
        let keyHex = "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"
        let hhId = try syncDeriveHouseholdId(householdKeyHex: keyHex)
        XCTAssertEqual(hhId, "buntu_hh_8c587a530f9f3a19")
    }

    func testEnvelopeSealAndOpenRoundtrip() throws {
        let keyHex = "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"
        let senderId = "dev_apple_test_1"
        let nonceData = Data([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11])
        let msgJson = "{\"type\":\"play_remote\",\"content_key\":\"test_key_1\",\"position_ms\":42000,\"title\":null,\"source_key\":null}"

        let env = try syncSealEnvelope(
            householdKeyHex: keyHex,
            senderDeviceId: senderId,
            sequence: 1,
            nonceBytes: nonceData,
            messageJson: msgJson
        )

        XCTAssertEqual(env.householdId, "buntu_hh_8c587a530f9f3a19")
        XCTAssertEqual(env.senderDeviceId, senderId)
        XCTAssertEqual(env.sequence, 1)

        let opened = try syncOpenEnvelope(
            householdKeyHex: keyHex,
            envelope: env,
            lastSeenSequence: 0
        )
        XCTAssertEqual(opened, msgJson)
    }

    func testEnvelopeReplayRejected() throws {
        let keyHex = "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"
        let senderId = "dev_apple_test_1"
        let nonceData = Data([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11])
        let msgJson = "{\"type\":\"ping\"}"

        let env = try syncSealEnvelope(
            householdKeyHex: keyHex,
            senderDeviceId: senderId,
            sequence: 5,
            nonceBytes: nonceData,
            messageJson: msgJson
        )

        // Opening with lastSeenSequence >= 5 must throw replay error
        XCTAssertThrowsError(try syncOpenEnvelope(householdKeyHex: keyHex, envelope: env, lastSeenSequence: 5))
    }
}
