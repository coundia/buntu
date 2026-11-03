import XCTest
import CndCoreBridge
@testable import CndIptvApp

/// Lot 26.1: Xtream passwords in iCloud Keychain, opt-in. The tests run unsigned, where iCloud
/// Keychain is unavailable, so they check the queries, the choice, and that nothing is ever lost.
final class KeychainScopeTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        suite = "cnd.tests.keychain.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    private func store() -> KeychainStore {
        KeychainStore(service: "com.cnd.iptv.tests.scope.\(UUID().uuidString)", defaults: defaults)
    }

    func testItemQueryPerScope() {
        let local = KeychainStore.itemQuery(service: "s", key: "k", scope: .local)
        XCTAssertNil(local[kSecAttrSynchronizable as String], "a local item stays the plain, non-synchronizable kind")

        let cloud = KeychainStore.itemQuery(service: "s", key: "k", scope: .iCloud)
        XCTAssertEqual(cloud[kSecAttrSynchronizable as String] as? Bool, true)

        let any = KeychainStore.itemQuery(service: "s", key: "k", scope: nil)
        XCTAssertNotNil(any[kSecAttrSynchronizable as String], "reads find the item wherever it is")
        XCTAssertEqual(any[kSecAttrService as String] as? String, "s")
        XCTAssertEqual(any[kSecAttrAccount as String] as? String, "k")
    }

    func testICloudIsOffByDefaultAndTheChoiceIsRemembered() {
        let keychain = store()
        XCTAssertEqual(keychain.passwordScope, .local)
        keychain.passwordScope = .iCloud
        XCTAssertEqual(store().passwordScope, .iCloud, "another store on the same defaults sees it")
        keychain.passwordScope = .local
        XCTAssertEqual(store().passwordScope, .local)
    }

    func testSavePasswordFollowsTheChoice() throws {
        let keychain = store()
        let key = "cnd.xtream.test"
        defer { try? keychain.deleteSecret(forKey: key) }
        try keychain.savePassword("pw-1", forKey: key)
        XCTAssertEqual(try keychain.readSecret(forKey: key), "pw-1")
    }

    func testFailedICloudWriteNeverLosesTheLocalPassword() throws {
        let keychain = store()
        let key = "cnd.xtream.keep"
        defer { try? keychain.deleteSecret(forKey: key) }
        try keychain.saveSecret("local-secret", forKey: key)

        do {
            try keychain.saveSecret("local-secret", forKey: key, scope: .iCloud)
        } catch {
            guard case KeychainStoreError.iCloudUnavailable = error else { return XCTFail("unexpected \(error)") }
        }
        XCTAssertEqual(try keychain.readSecret(forKey: key), "local-secret")
    }

    func testMoveSkipsMissingKeysAndCountsTheRest() throws {
        let keychain = store()
        let present = "cnd.xtream.a"
        defer { try? keychain.deleteSecret(forKey: present) }
        try keychain.saveSecret("a", forKey: present)
        XCTAssertEqual(try keychain.move(keys: [present, "cnd.xtream.absent"], to: .local), 1)
        XCTAssertEqual(try keychain.readSecret(forKey: present), "a")
    }

    func testDeleteRemovesTheSecretFromEveryKeychain() throws {
        let keychain = store()
        let key = "cnd.xtream.del"
        try keychain.saveSecret("x", forKey: key)
        try keychain.deleteSecret(forKey: key)
        XCTAssertNil(try keychain.readSecret(forKey: key))
    }

    // MARK: Settings

    @MainActor
    func testTurningTheOptionOnKeepsPasswordsAndReportsAFailure() throws {
        let engine = try CndEngine.inMemory()
        let keychain = store()
        let root = try TestFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = DownloadDirectoryManager(defaults: defaults, platformDefault: root)
        let model = SettingsModel(engine: engine, keychain: keychain, directory: directory)

        let id = try engine.addSource(name: "A", sourceType: "xtream", url: nil, server: "http://s", username: "u", passwordRef: nil)
        let record = try XCTUnwrap(try engine.listSources().first { $0.id == id })
        let key = KeychainStore.xtreamKey(forSourceUuid: record.uuid)
        try keychain.saveSecret("pw", forKey: key)
        defer { try? keychain.deleteSecret(forKey: key) }
        XCTAssertFalse(model.syncsPasswords)

        model.setPasswordSync(true)

        XCTAssertEqual(try keychain.readSecret(forKey: key), "pw", "the password survives either outcome")
        if model.syncsPasswords {
            XCTAssertNil(model.passwordSyncError)
            XCTAssertEqual(keychain.passwordScope, .iCloud)
        } else {
            XCTAssertNotNil(model.passwordSyncError, "an unavailable iCloud Keychain is explained")
            XCTAssertEqual(keychain.passwordScope, .local, "the option is not recorded when the move failed")
        }

        model.setPasswordSync(false)
        XCTAssertFalse(model.syncsPasswords)
        XCTAssertEqual(try keychain.readSecret(forKey: key), "pw")
    }
}
