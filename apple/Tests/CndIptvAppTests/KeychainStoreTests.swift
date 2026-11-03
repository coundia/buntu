import XCTest
@testable import CndIptvKit

final class KeychainStoreTests: XCTestCase {
    func testSaveReadUpdateAndDeleteSecret() throws {
        let store = KeychainStore(service: "com.cnd.iptv.tests.\(UUID().uuidString)")
        let key = KeychainStore.xtreamKey(forSourceUuid: "src_unit_test_01")
        defer { try? store.deleteSecret(forKey: key) }

        XCTAssertNil(try store.readSecret(forKey: key))

        try store.saveSecret("initial_password_123!", forKey: key)
        XCTAssertEqual(try store.readSecret(forKey: key), "initial_password_123!")

        // Overwrite existing secret (SecItemUpdate path)
        try store.saveSecret("rotated_password_456#", forKey: key)
        XCTAssertEqual(try store.readSecret(forKey: key), "rotated_password_456#")

        // Delete secret
        try store.deleteSecret(forKey: key)
        XCTAssertNil(try store.readSecret(forKey: key))
    }
}

