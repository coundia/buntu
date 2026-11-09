import XCTest
import CryptoKit
@testable import CndIptvKit

final class HouseholdNearbyPairingTests: XCTestCase {

    /// Verifies that Swift `HouseholdSAS` produces the exact same 6-digit code as Rust `cnd_domain::pairing::compute_sas`.
    func testSASVectorParityWithRust() {
        let secretBytes = [UInt8](repeating: 42, count: 32)
        let key = SymmetricKey(data: secretBytes)
        let sas = HouseholdSAS.compute(sharedSecret: key, sessionId: "SESSION123")

        // Exact vector tested in crates/cnd-domain/src/pairing/tests.rs
        XCTAssertEqual(sas, "586507", "Swift SAS must match Rust compute_sas vector")
        XCTAssertEqual(sas.count, 6)
        XCTAssertTrue(sas.allSatisfy(\.isNumber))
    }

    func testSASIsDeterministicAndDistinctForSessions() {
        let key = SymmetricKey(size: .bits256)
        let sas1 = HouseholdSAS.compute(sharedSecret: key, sessionId: "SESSION_A")
        let sas2 = HouseholdSAS.compute(sharedSecret: key, sessionId: "SESSION_A")
        let sas3 = HouseholdSAS.compute(sharedSecret: key, sessionId: "SESSION_B")

        XCTAssertEqual(sas1, sas2, "Same session and key must yield same SAS code")
        XCTAssertNotEqual(sas1, sas3, "Different sessions must yield different SAS codes")
        XCTAssertEqual(sas1.count, 6)
        XCTAssertEqual(sas3.count, 6)
    }

    @MainActor
    func testHostInitialState() {
        let host = HouseholdNearbyPairingHost()
        XCTAssertEqual(host.state, .idle)
        XCTAssertNil(host.pendingRequest)
    }

    @MainActor
    func testClientInitialState() {
        let client = HouseholdNearbyPairingClient()
        XCTAssertEqual(client.state, .idle)
        XCTAssertTrue(client.discoveredHosts.isEmpty)
    }

    func testCredentialsRoundTripCarriesTheAuthenticationTag() throws {
        let key = SymmetricKey(size: .bits256)
        let plain = Data("household credentials".utf8)
        let sealed = try HouseholdPairingCrypto.seal(plain, key: key, sessionId: "abcd1234")
        // ciphertext + 16-byte tag: the bug was sending the ciphertext alone.
        XCTAssertEqual(sealed.payload.count, plain.count + HouseholdPairingCrypto.tagLength)
        XCTAssertEqual(try HouseholdPairingCrypto.open(payload: sealed.payload, nonce: sealed.nonce, key: key, sessionId: "abcd1234"), plain)
    }

    private func sealed() throws -> (key: SymmetricKey, box: (payload: Data, nonce: Data)) {
        let key = SymmetricKey(size: .bits256)
        return (key, try HouseholdPairingCrypto.seal(Data("secret".utf8), key: key, sessionId: "session1"))
    }

    func testCredentialsRefuseAnotherSession() throws {
        let s = try sealed()
        XCTAssertThrowsError(try HouseholdPairingCrypto.open(payload: s.box.payload, nonce: s.box.nonce, key: s.key, sessionId: "session2"))
    }

    func testCredentialsRefuseAnotherKey() throws {
        let s = try sealed()
        XCTAssertThrowsError(try HouseholdPairingCrypto.open(payload: s.box.payload, nonce: s.box.nonce, key: SymmetricKey(size: .bits256), sessionId: "session1"))
    }

    func testCredentialsRefuseTamperedPayload() throws {
        let s = try sealed()
        var tampered = s.box.payload
        tampered[tampered.startIndex] ^= 0xFF
        XCTAssertThrowsError(try HouseholdPairingCrypto.open(payload: tampered, nonce: s.box.nonce, key: s.key, sessionId: "session1"))
    }

    func testCredentialsRefuseTooShortPayload() throws {
        let s = try sealed()
        XCTAssertThrowsError(try HouseholdPairingCrypto.open(payload: Data(), nonce: s.box.nonce, key: s.key, sessionId: "session1"))
        XCTAssertThrowsError(try HouseholdPairingCrypto.open(payload: Data(count: 16), nonce: s.box.nonce, key: s.key, sessionId: "session1"))
    }

    // MARK: - Household roster (the host sees every device)

    func testKnownDevicesAreRememberedAndPersisted() {
        let key = "cnd.sync.knownDevices"
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let store = HouseholdStore()
        store.rememberDevice(id: "iphone-1", name: "iPhone de Paul", deviceType: "mobile")
        store.rememberDevice(id: "iphone-1", name: "iPhone de Paul", deviceType: "mobile") // refresh: no duplicate
        store.rememberDevice(id: store.deviceId, name: "Moi", deviceType: "desktop") // never lists itself
        store.rememberDevice(id: "", name: "Sans id", deviceType: "mobile")

        XCTAssertEqual(store.knownDevices.map(\.id), ["iphone-1"])

        let reloaded = HouseholdStore()
        XCTAssertEqual(reloaded.knownDevices.map(\.name), ["iPhone de Paul"], "the roster survives a restart")
    }

    func testKnownDeviceRenameIsKept() {
        let key = "cnd.sync.knownDevices"
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let store = HouseholdStore()
        store.rememberDevice(id: "tv-1", name: "TV", deviceType: "tv")
        store.rememberDevice(id: "tv-1", name: "TV du salon", deviceType: "tv")
        XCTAssertEqual(store.knownDevices.count, 1)
        XCTAssertEqual(store.knownDevices.first?.name, "TV du salon")
    }

    // MARK: - Removing a device (household_rekey)

    func testRekeyMessageRoundTrip() throws {
        let key = String(repeating: "ab", count: 32)
        let json = try XCTUnwrap(HouseholdRekeyMessage.json(newKeyHex: key, removedDeviceId: "apple_x"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let parsed = try XCTUnwrap(HouseholdRekeyMessage.parse(root))
        XCTAssertEqual(parsed.newKeyHex, key)
        XCTAssertEqual(parsed.removedDeviceId, "apple_x")
    }

    func testRekeyMessageRefusesBadKeys() {
        for bad in ["", "abc", String(repeating: "g", count: 64), String(repeating: "a", count: 65)] {
            XCTAssertNil(HouseholdRekeyMessage.parse(["type": "household_rekey", "new_key_hex": bad]), "refused: \(bad.prefix(8))")
        }
        // Upper case is normalised, not refused.
        XCTAssertEqual(HouseholdRekeyMessage.parse(["type": "household_rekey", "new_key_hex": String(repeating: "A", count: 64)])?.newKeyHex, String(repeating: "a", count: 64))
        XCTAssertNil(HouseholdRekeyMessage.parse(["type": "other", "new_key_hex": String(repeating: "a", count: 64)]))
    }

    // MARK: - "Lire sur…": provider id of a stream

    func testProviderRefIsTheStreamIdOnly() throws {
        let cases: [(String, String?)] = [
            ("http://server.example:80/movie/someuser/somepass/12345.mkv", "12345"),
            ("http://server.example/live/someuser/somepass/987.ts", "987"),
            ("https://server.example/someuser/somepass/55", "55"),
            ("http://server.example/stream/ab%20cd.mp4", nil),
            ("file:///Users/me/film.mkv", nil),
        ]
        for (raw, expected) in cases {
            let url = try XCTUnwrap(URL(string: raw))
            let ref = RemotePlaybackCoordinator.providerRef(from: url)
            XCTAssertEqual(ref, expected, raw)
            if let ref {
                XCTAssertFalse(ref.contains("someuser") || ref.contains("somepass"), "no credential leaves the device")
            }
        }
    }

    // MARK: - Household sync of accounts

    func testSyncedSourceDecodesWithAndWithoutPassword() throws {
        let base = #"{"uuid":"u1","name":"Compte","source_type":"xtream","server":"http://s.example","username":"bob","password_ref":"cnd.xtream.u1","updated_at":10"#
        let without = try JSONDecoder().decode(SyncSourceDTO.self, from: Data((base + "}").utf8))
        XCTAssertNil(without.password, "an older device sends no password")
        let with = try JSONDecoder().decode(SyncSourceDTO.self, from: Data((base + #","password":"pw"}"#).utf8))
        XCTAssertEqual(with.password, "pw")
        XCTAssertEqual(with.uuid, "u1")
    }
}
