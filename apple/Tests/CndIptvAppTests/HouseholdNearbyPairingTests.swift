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
}
