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
}

