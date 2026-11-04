import XCTest
import CndCoreBridge
@testable import CndIptvKit

@MainActor
final class SettingsModelTests: XCTestCase {
    private var engine: CndEngine!
    private var keychain: KeychainStore!
    private var directory: DownloadDirectoryManager!
    private var root: URL!
    private var suite: String!

    override func setUpWithError() throws {
        root = try TestFixtures.makeTempDirectory()
        engine = try CndEngine.inMemory()
        keychain = KeychainStore(service: "com.cnd.iptv.tests.\(UUID().uuidString)")
        suite = "cnd.tests.\(UUID().uuidString)"
        directory = DownloadDirectoryManager(
            defaults: UserDefaults(suiteName: suite)!, platformDefault: root.appendingPathComponent("default")
        )
    }

    override func tearDownWithError() throws {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    /// The subscription's connection limit is raised so the segment and file settings can be exercised
    /// freely; `ConnectionSettingsTests` covers the default of one connection.
    private func makeModel(delay: Duration = .milliseconds(30), connections: Int = 10) -> SettingsModel {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(connections, forKey: ConnectionBudget.defaultsKey)
        return SettingsModel(engine: engine, keychain: keychain, directory: directory, saveDelay: delay, defaults: defaults)
    }

    func testLoadsEngineDefaults() {
        let model = makeModel()
        XCTAssertEqual(model.segmentsPerFile, 4)
        XCTAssertEqual(model.partSizeMB, 10)
        XCTAssertEqual(model.maxActiveFiles, 2)
        XCTAssertEqual(model.userAgent, "VLC/3.0.21 LibVLC/3.0.21")
        XCTAssertEqual(model.referer, "")
        XCTAssertFalse(model.showNetworkConsole)
        XCTAssertEqual(model.omdbKey, "")
        XCTAssertFalse(model.engineVersion.isEmpty)
    }

    func testChangesArePersistedInTheEngine() {
        let model = makeModel()
        model.segmentsPerFile = 3
        model.partSizeMB = 32
        model.maxActiveFiles = 3
        model.userAgent = "  CustomAgent/2  "
        model.referer = "http://portal.test/"
        model.flush()

        let stored = engine.getSettings()
        XCTAssertEqual(stored.segmentsPerFile, 3)
        XCTAssertEqual(stored.partSizeBytes, 32 * 1024 * 1024)
        XCTAssertEqual(stored.maxActiveFiles, 3)
        XCTAssertEqual(stored.defaultUserAgent, "CustomAgent/2")
        XCTAssertEqual(stored.defaultReferer, "http://portal.test/")
        XCTAssertNil(model.errorMessage)

        let reopened = makeModel()
        XCTAssertEqual(reopened.segmentsPerFile, 3)
        XCTAssertEqual(reopened.partSizeMB, 32)
    }

    func testValuesAreClampedAndEmptyUserAgentKeepsTheDefault() {
        let model = makeModel()
        model.segmentsPerFile = 99
        model.partSizeMB = 0
        model.maxActiveFiles = -4
        model.userAgent = "   "
        model.referer = "   "
        model.flush()

        let stored = engine.getSettings()
        XCTAssertEqual(stored.segmentsPerFile, 9, "16 at most, then under the 9 connections a 10-connection subscription leaves downloads")
        XCTAssertEqual(stored.partSizeBytes, 1 * 1024 * 1024)
        XCTAssertEqual(stored.maxActiveFiles, 1)
        XCTAssertEqual(stored.defaultUserAgent, "VLC/3.0.21 LibVLC/3.0.21")
        XCTAssertNil(stored.defaultReferer)
    }

    func testBurstOfEditsIsSavedOnce() async throws {
        let model = makeModel(delay: .milliseconds(80))
        model.userAgent = "A"
        model.userAgent = "Ag"
        model.userAgent = "Agent"
        model.segmentsPerFile = 6
        XCTAssertEqual(model.saveCount, 0, "nothing is written while typing")
        let saved = await eventually { model.saveCount == 1 }
        XCTAssertTrue(saved)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(model.saveCount, 1)
        XCTAssertEqual(engine.getSettings().defaultUserAgent, "Agent")
    }

    func testOmdbKeyLivesInTheKeychainOnly() throws {
        let model = makeModel()
        model.omdbKey = "  abc123  "
        model.flush()
        XCTAssertEqual(try keychain.readSecret(forKey: KeychainStore.omdbApiKeyRef), "abc123")
        XCTAssertEqual(engine.getSettings().omdbApiKeyRef, KeychainStore.omdbApiKeyRef, "SQLite keeps the reference, not the key")

        XCTAssertEqual(makeModel().omdbKey, "abc123")

        model.omdbKey = ""
        model.flush()
        XCTAssertNil(try keychain.readSecret(forKey: KeychainStore.omdbApiKeyRef))
        XCTAssertNil(engine.getSettings().omdbApiKeyRef)
    }

    func testConsoleToggleIsPersistedAndAnnouncedOnce() async throws {
        let model = makeModel()
        var announcements: [Bool] = []
        model.onConsoleVisibilityChanged = { announcements.append($0) }

        model.showNetworkConsole = true
        let saved = await eventually { model.saveCount == 1 }
        XCTAssertTrue(saved)
        XCTAssertTrue(engine.getSettings().showNetworkConsole)
        XCTAssertEqual(announcements, [true])

        model.userAgent = "Other"
        model.flush()
        XCTAssertEqual(announcements, [true], "unrelated changes do not re-announce")

        model.showNetworkConsole = false
        let off = await eventually { announcements == [true, false] }
        XCTAssertTrue(off)
    }

    func testCustomDownloadFolderIsStoredInSettings() throws {
        let model = makeModel()
        let custom = root.appendingPathComponent("SSD")
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        try directory.setDirectory(custom)
        model.downloadDirectoryChanged()
        model.flush()
        XCTAssertEqual(engine.getSettings().downloadDir, custom.path)

        directory.resetToDefault()
        model.flush()
        XCTAssertNil(engine.getSettings().downloadDir)
    }

    func testClearingTheImageCacheEmptiesTheCacheDirectory() async throws {
        let cacheDir = root.appendingPathComponent("thumbs")
        let cache = ImageThumbnailCache(directory: cacheDir, loader: { _ in TestFixtures.pngData(width: 200, height: 200) })
        _ = await cache.image(for: URL(string: "http://logos.test/a.png")!, maxPixel: 120)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: cacheDir.path).isEmpty)
        await cache.clearAll()
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: cacheDir.path).isEmpty)
    }
}

@MainActor
final class ConsoleModelTests: XCTestCase {
    private var engine: CndEngine!

    override func setUpWithError() throws {
        engine = try CndEngine.inMemory()
    }

    private var produced = 0

    /// Each source gets a distinct name: the engine derives its uuid from the second and the name.
    private func produceLogs(_ count: Int) throws {
        for _ in 0..<count {
            _ = try engine.addSource(name: "Source\(produced)", sourceType: "m3u", url: "http://x/\(produced).m3u", server: nil, username: nil, passwordRef: nil)
            produced += 1
        }
    }

    func testPollingIsIncremental() async throws {
        let model = ConsoleModel(engine: engine, pollInterval: .milliseconds(20), appLog: AppLog())
        try produceLogs(3)
        await model.poll()
        let first = model.entries.count
        XCTAssertGreaterThanOrEqual(first, 3)
        XCTAssertEqual(Set(model.entries.map(\.seqId)).count, first)

        await model.poll()
        XCTAssertEqual(model.entries.count, first, "an idle poll adds nothing and never re-delivers")

        try produceLogs(2)
        await model.poll()
        XCTAssertEqual(model.entries.count, first + 2)
        XCTAssertEqual(model.entries.map(\.seqId), model.entries.map(\.seqId).sorted())
    }

    func testBacklogLargerThanOneBatchIsFullyFetched() async throws {
        try produceLogs(450)
        let model = ConsoleModel(engine: engine, appLog: AppLog())
        await model.poll()
        XCTAssertGreaterThanOrEqual(model.entries.count, 450)
        XCTAssertEqual(Set(model.entries.map(\.seqId)).count, model.entries.count)
    }

    func testClearEmptiesAndOnlyNewEntriesFollow() async throws {
        let model = ConsoleModel(engine: engine, appLog: AppLog())
        try produceLogs(2)
        await model.poll()
        XCTAssertFalse(model.entries.isEmpty)

        model.clear()
        XCTAssertTrue(model.entries.isEmpty)
        await model.poll()
        XCTAssertTrue(model.entries.isEmpty, "cleared entries are not delivered again")

        try produceLogs(1)
        await model.poll()
        XCTAssertEqual(model.entries.count, 1)
    }

    func testCategoryAndLevelFilters() async throws {
        let model = ConsoleModel(engine: engine, appLog: AppLog())
        try produceLogs(2)
        await model.poll()
        XCTAssertEqual(model.categories, ["DB"])

        model.toggle(category: "HTTP")
        XCTAssertTrue(model.filtered.isEmpty)
        model.toggle(category: "DB")
        XCTAssertEqual(model.filtered.count, model.entries.count)
        model.toggle(category: "HTTP")
        model.toggle(category: "DB")
        XCTAssertTrue(model.selectedCategories.isEmpty)

        model.levelFilter = .errors
        XCTAssertTrue(model.filtered.isEmpty)
        model.levelFilter = .warnings
        XCTAssertTrue(model.filtered.isEmpty)
        model.levelFilter = .all
        XCTAssertEqual(model.filtered.count, model.entries.count)
    }

    func testPollingRunsOnlyInsideRunAndStopsWhenCancelled() async throws {
        let model = ConsoleModel(engine: engine, pollInterval: .milliseconds(20), appLog: AppLog())
        XCTAssertFalse(model.isPolling)

        let task = Task { await model.run() }
        let started = await eventually { model.isPolling && model.pollCount >= 2 }
        XCTAssertTrue(started)

        task.cancel()
        await task.value
        XCTAssertFalse(model.isPolling)
        let frozen = model.pollCount
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(model.pollCount, frozen, "no timer keeps running once the drawer is collapsed")
    }

    func testLiveRunPicksUpNewLogs() async throws {
        let model = ConsoleModel(engine: engine, pollInterval: .milliseconds(20), appLog: AppLog())
        let task = Task { await model.run() }
        try produceLogs(1)
        let seen = await eventually { model.entries.contains { $0.message.contains("Source0") } }
        XCTAssertTrue(seen)
        task.cancel()
        await task.value
    }

    func testStatusColorsAndLineFormatting() {
        XCTAssertEqual(LogStatusStyle.of(200), .success)
        XCTAssertEqual(LogStatusStyle.of(206), .success)
        XCTAssertEqual(LogStatusStyle.of(301), .redirect)
        XCTAssertEqual(LogStatusStyle.of(404), .failure)
        XCTAssertEqual(LogStatusStyle.of(503), .failure)
        XCTAssertEqual(LogStatusStyle.of(nil), .none)
        XCTAssertEqual(LogStatusStyle.of(100), .none)

        let entry = NetworkLogEntry(
            seqId: 7, timestampMs: 1_700_000_000_000, level: .warn, category: "HTTP", method: "GET",
            urlRedacted: "http://srv/get.php?password=***", statusCode: 404, durationMs: 120, message: "Not found"
        )
        let line = ConsoleModel.format(entry)
        for part in ["WARN", "HTTP", "GET", "404", "120ms", "password=***", "Not found"] {
            XCTAssertTrue(line.contains(part), "\(part) missing from \(line)")
        }

        XCTAssertTrue(LogLevelFilter.errors.matches(.error))
        XCTAssertFalse(LogLevelFilter.errors.matches(.warn))
        XCTAssertTrue(LogLevelFilter.warnings.matches(.warn))
        XCTAssertFalse(LogLevelFilter.warnings.matches(.info))
    }
}

/// With the default of one connection, downloads use one segment and one file at a time.
@MainActor
final class ConnectionSettingsTests: XCTestCase {
    private var engine: CndEngine!
    private var directory: DownloadDirectoryManager!
    private var root: URL!
    private var suite = ""

    override func setUpWithError() throws {
        root = try TestFixtures.makeTempDirectory()
        engine = try CndEngine.inMemory()
        suite = "cnd.conn.tests.\(UUID().uuidString)"
        directory = DownloadDirectoryManager(
            defaults: UserDefaults(suiteName: suite)!, platformDefault: root.appendingPathComponent("default")
        )
    }

    override func tearDownWithError() throws {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    private func makeModel() -> SettingsModel {
        SettingsModel(
            engine: engine, keychain: KeychainStore(service: "com.cnd.iptv.tests.\(UUID().uuidString)"),
            directory: directory, saveDelay: .milliseconds(10), defaults: UserDefaults(suiteName: suite)!
        )
    }

    func testTheEngineDefaultsOfFourSegmentsAndTwoFilesAreBroughtToOne() {
        XCTAssertEqual(engine.getSettings().segmentsPerFile, 4)
        let model = makeModel()
        XCTAssertEqual(model.connectionLimit, 1)
        XCTAssertEqual(model.segmentsPerFile, 1)
        XCTAssertEqual(model.maxActiveFiles, 1)
        model.flush()
        XCTAssertEqual(engine.getSettings().segmentsPerFile, 1)
        XCTAssertEqual(engine.getSettings().maxActiveFiles, 1)
    }

    func testEnforceFixesAnExistingInstall() {
        ConnectionBudget.enforce(on: engine, defaults: UserDefaults(suiteName: suite)!)
        XCTAssertEqual(engine.getSettings().segmentsPerFile, 1)
        XCTAssertEqual(engine.getSettings().maxActiveFiles, 1)
    }

    func testNoStepperValueCanExceedTheBudget() {
        let model = makeModel()
        model.segmentsPerFile = 16
        model.maxActiveFiles = 8
        model.flush()
        XCTAssertEqual(engine.getSettings().segmentsPerFile, 1)
        XCTAssertEqual(engine.getSettings().maxActiveFiles, 1)
    }

    func testRaisingTheLimitDoesNotRaiseTheSettingsButLoweringItClampsThem() {
        let model = makeModel()
        model.connectionLimit = 5            // 4 connections for downloads
        model.segmentsPerFile = 4
        XCTAssertEqual(model.segmentsPerFile, 4 * 1)
        model.connectionLimit = 2            // 1 connection for downloads
        XCTAssertEqual(model.segmentsPerFile, 1)
        XCTAssertEqual(model.maxActiveFiles, 1)
        XCTAssertEqual(UserDefaults(suiteName: suite)?.integer(forKey: ConnectionBudget.defaultsKey), 2)
    }
}
