import XCTest
@testable import CndIptvKit

final class HouseholdAiCredentialsTests: XCTestCase {
    func testOnlyPersonalAiKeychainEntriesAreRead() {
        var requested: [String] = []
        let configs = LocalSyncService.householdAiCredentials { reference in
            requested.append(reference)
            return reference == "cnd.ai.gemini.apikey" ? "test-only-value" : nil
        }
        XCTAssertEqual(requested.count, 3)
        XCTAssertTrue(requested.allSatisfy { $0.hasPrefix("cnd.ai.") })
        XCTAssertEqual(configs.count, 1)
        XCTAssertEqual(configs.first?["provider"], "gemini")
        XCTAssertEqual(configs.first?["api_key"], "test-only-value")
    }
    func testEmptyOrUnavailableKeysAreNotTransferred() {
        XCTAssertTrue(LocalSyncService.householdAiCredentials { _ in "  " }.isEmpty)
        XCTAssertTrue(LocalSyncService.householdAiCredentials { _ in throw CocoaError(.fileReadNoPermission) }.isEmpty)
    }

    func testReceivedKeysAreStoredOnlyForProvidersTheRuleAccepts() {
        var saved: [String: String] = [:]
        let stored = LocalSyncService.storeReceivedAiCredentials(
            [["provider": "gemini", "api_key": "test-only-value"], ["provider": "anthropic", "api_key": "other-value"]],
            readSecret: { $0 == "cnd.ai.gemini.apikey" ? "mine" : nil },
            saveSecret: { key, reference in saved[reference] = key },
            missing: { configs, existing in configs.filter { !existing.contains($0["provider"] as? String ?? "") } }
        )
        XCTAssertEqual(stored, 1)
        XCTAssertEqual(saved, ["cnd.ai.anthropic.apikey": "other-value"])
    }
    func testAnUnknownProviderIsNotStored() {
        var saved: [String: String] = [:]
        let stored = LocalSyncService.storeReceivedAiCredentials(
            [["provider": "mystery", "api_key": "x"]],
            readSecret: { _ in nil },
            saveSecret: { key, reference in saved[reference] = key },
            missing: { configs, _ in configs }
        )
        XCTAssertEqual(stored, 0)
        XCTAssertTrue(saved.isEmpty)
    }

    func testOnlyTheUsersOwnOmdbKeyIsExported() {
        var requested: [String] = []
        let keys = LocalSyncService.householdMetadataKeys { reference in
            requested.append(reference)
            return " test-only-value \n"
        }
        XCTAssertEqual(requested, [KeychainStore.omdbApiKeyRef])
        XCTAssertEqual(keys, [["service": "omdb", "api_key": "test-only-value"]])
        XCTAssertTrue(LocalSyncService.householdMetadataKeys { _ in "  " }.isEmpty)
        XCTAssertTrue(LocalSyncService.householdMetadataKeys { _ in nil }.isEmpty)
        XCTAssertTrue(LocalSyncService.householdMetadataKeys { _ in throw CocoaError(.fileReadNoPermission) }.isEmpty)
    }

    func testReceivedOmdbKeyIsStoredOnlyWhenTheRuleAcceptsIt() {
        var saved: [String: String] = [:]
        let stored = LocalSyncService.storeReceivedMetadataKeys(
            [["service": "omdb", "api_key": "test-only-value"], ["service": "mystery", "api_key": "x"]],
            readSecret: { _ in nil },
            saveSecret: { key, reference in saved[reference] = key },
            missing: { keys, existing in keys.filter { !existing.contains($0["service"] as? String ?? "") } }
        )
        XCTAssertEqual(stored, 1)
        XCTAssertEqual(saved, [KeychainStore.omdbApiKeyRef: "test-only-value"])
    }
    func testAnOmdbKeyAlreadySavedIsNeverReplaced() {
        var saved: [String: String] = [:]
        let stored = LocalSyncService.storeReceivedMetadataKeys(
            [["service": "omdb", "api_key": "other-value"]],
            readSecret: { _ in "mine" },
            saveSecret: { key, reference in saved[reference] = key },
            missing: { keys, existing in keys.filter { !existing.contains($0["service"] as? String ?? "") } }
        )
        XCTAssertEqual(stored, 0)
        XCTAssertTrue(saved.isEmpty)
    }

    func testTemporarySwiftFilterFollowsTheSharedRule() {
        let key: [String: Any] = ["service": "omdb", "api_key": "test-only-value"]
        XCTAssertEqual(LocalSyncService.missingMetadataKeys([key], existing: []).count, 1)
        XCTAssertTrue(LocalSyncService.missingMetadataKeys([key], existing: ["omdb"]).isEmpty)
        XCTAssertTrue(LocalSyncService.missingMetadataKeys([["service": "mystery", "api_key": "x"]], existing: []).isEmpty)
        XCTAssertTrue(LocalSyncService.missingMetadataKeys([["service": "omdb", "api_key": " "]], existing: []).isEmpty)
        XCTAssertTrue(LocalSyncService.missingMetadataKeys([key, key], existing: []).isEmpty)
    }
}
