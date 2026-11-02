import XCTest
import CndCoreBridge
@testable import CndIptvApp

@MainActor
final class SourcesTests: XCTestCase {
    private var directory: URL!
    private var engine: CndEngine!
    private var keychain: KeychainStore!
    private var changes = 0

    override func setUp() async throws {
        directory = try TestFixtures.makeTempDirectory()
        engine = try CndEngine.inMemory()
        keychain = KeychainStore(service: "com.cnd.iptv.tests.\(UUID().uuidString)")
        changes = 0
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeModel() -> SourcesModel {
        SourcesModel(
            engine: engine, keychain: keychain,
            importsDirectory: directory.appendingPathComponent("imports"),
            onChange: { [unowned self] in self.changes += 1 }
        )
    }

    private func form(editing: IptvSourceRecord? = nil) -> SourceFormModel {
        SourceFormModel(engine: engine, keychain: keychain, editing: editing)
    }

    // MARK: Form validation

    func testValidationMessagesPerKind() {
        let model = form()
        XCTAssertNotNil(model.validationMessage)
        XCTAssertFalse(model.canSave)

        model.name = "Ma playlist"
        XCTAssertNotNil(model.validationMessage, "URL missing")
        model.m3uUrl = "ftp://x/y.m3u"
        XCTAssertNotNil(model.validationMessage, "scheme not supported")
        model.m3uUrl = " https://x/y.m3u "
        XCTAssertNil(model.validationMessage)
        XCTAssertTrue(model.canSave)

        model.kind = .xtream
        XCTAssertNotNil(model.validationMessage)
        model.server = "http://srv:8080"
        model.username = "bob"
        XCTAssertNotNil(model.validationMessage, "password missing")
        XCTAssertFalse(model.canTest)
        model.password = "secret"
        XCTAssertNil(model.validationMessage)
        XCTAssertTrue(model.canTest)
    }

    // MARK: M3U create / edit

    func testCreateThenEditM3uSource() async throws {
        let create = form()
        create.name = "  Freebox  "
        create.m3uUrl = "https://example.com/list.m3u"
        create.epgUrl = "https://example.com/epg.xml.gz"
        let id = try await create.save()

        var stored = try XCTUnwrap(engine.listSources().first { $0.id == id })
        XCTAssertEqual(stored.name, "Freebox")
        XCTAssertEqual(stored.sourceType, "m3u")
        XCTAssertEqual(stored.url, "https://example.com/list.m3u")
        XCTAssertEqual(stored.epgUrl, "https://example.com/epg.xml.gz")

        let edit = form(editing: stored)
        XCTAssertTrue(edit.isEditing)
        XCTAssertEqual(edit.name, "Freebox")
        XCTAssertEqual(edit.m3uUrl, "https://example.com/list.m3u")
        edit.name = "Freebox TV"
        edit.m3uUrl = "https://example.com/other.m3u8"
        edit.epgUrl = ""
        let editedId = try await edit.save()
        XCTAssertEqual(editedId, id)

        stored = try XCTUnwrap(engine.listSources().first { $0.id == id })
        XCTAssertEqual(stored.name, "Freebox TV")
        XCTAssertEqual(stored.url, "https://example.com/other.m3u8")
        XCTAssertNil(stored.epgUrl)
        XCTAssertEqual(try engine.listSources().count, 1, "editing must not create a second source")
    }

    // MARK: Xtream create / edit / Keychain

    func testXtreamPasswordLivesInKeychainNotInTheDatabase() async throws {
        let create = form()
        create.kind = .xtream
        create.name = "Mon Xtream"
        create.server = "http://srv.test:8080"
        create.username = "alice"
        create.password = "s3cret!"
        let id = try await create.save()

        let stored = try XCTUnwrap(engine.listSources().first { $0.id == id })
        let key = KeychainStore.xtreamKey(forSourceUuid: stored.uuid)
        XCTAssertEqual(stored.passwordRef, key)
        XCTAssertEqual(stored.username, "alice")
        XCTAssertEqual(try keychain.readSecret(forKey: key), "s3cret!")
        XCTAssertNotEqual(stored.passwordRef, "s3cret!")

        let edit = form(editing: stored)
        XCTAssertEqual(edit.kind, .xtream)
        XCTAssertEqual(edit.password, "s3cret!", "the stored password pre-fills the edit form")
        edit.password = "n3w-pass"
        edit.username = "alice2"
        _ = try await edit.save()

        let updated = try XCTUnwrap(engine.listSources().first { $0.id == id })
        XCTAssertEqual(updated.username, "alice2")
        XCTAssertEqual(updated.passwordRef, key)
        XCTAssertEqual(try keychain.readSecret(forKey: key), "n3w-pass")
        XCTAssertEqual(try engine.listSources().count, 1)

        let model = makeModel()
        model.delete(updated)
        XCTAssertTrue(try engine.listSources().isEmpty)
        XCTAssertNil(try keychain.readSecret(forKey: key), "deleting the source wipes its secret")
        XCTAssertEqual(changes, 1)
    }

    func testAccountTestFailureIsReportedWithoutThrowing() async {
        let model = form()
        model.kind = .xtream
        model.server = "http://127.0.0.1:9"
        model.username = "u"
        model.password = "p"
        await model.testConnection()
        guard case .failure(let message) = model.testState else {
            return XCTFail("expected a failure, got \(model.testState)")
        }
        XCTAssertFalse(message.isEmpty)

        model.password = "p2"
        XCTAssertEqual(model.testState, .idle, "editing a credential clears the previous result")
    }

    func testAccountDescriptionShowsStatusAndExpiry() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let active = XtreamAccountInfo(
            status: "active", expDateTs: 1_800_000_000 + 86_400 * 30, isTrial: false,
            activeConnections: 1, maxConnections: 2, serverTimezone: nil
        )
        let text = SourceFormModel.describe(active, now: now)
        XCTAssertTrue(text.contains("Active"))
        XCTAssertTrue(text.contains("expire le"))
        XCTAssertTrue(text.contains("1/2 connexions"))

        let expired = XtreamAccountInfo(
            status: "expired", expDateTs: 1_800_000_000 - 86_400, isTrial: true,
            activeConnections: 0, maxConnections: 0, serverTimezone: nil
        )
        let expiredText = SourceFormModel.describe(expired, now: now)
        XCTAssertTrue(expiredText.contains("expiré le"))
        XCTAssertTrue(expiredText.contains("essai"))
        XCTAssertFalse(expiredText.contains("connexions"))
    }

    // MARK: Sync / import / delete

    func testSyncRefreshesCountersAndReportsSummary() async throws {
        let file = try TestFixtures.writeM3u(in: directory, count: 25)
        let id = try engine.addSource(name: "Local", sourceType: "m3u", url: "file://\(file.path)", server: nil, username: nil, passwordRef: nil)
        let source = try XCTUnwrap(engine.listSources().first { $0.id == id })
        XCTAssertEqual(source.itemCount, 0)

        let model = makeModel()
        XCTAssertEqual(model.state(for: source), .idle)
        let ok = await model.sync(source)
        XCTAssertTrue(ok)
        guard case .done(let report) = model.state(for: source) else {
            return XCTFail("expected done, got \(model.state(for: source))")
        }
        XCTAssertEqual(report.summary.liveCount, 25)
        XCTAssertFalse(report.epgPending, "the follow-up guide refresh has finished")
        XCTAssertNil(report.epgPrograms.flatMap { $0 > 0 ? $0 : nil }, "no EPG URL: nothing to import")
        XCTAssertEqual(try engine.getStats().totalLiveChannels, 25)
        XCTAssertEqual(try engine.listSources().first?.itemCount, 25)
        XCTAssertGreaterThanOrEqual(changes, 1)
        XCTAssertEqual(model.banner?.isError, false)
        XCTAssertTrue(model.banner?.text.contains("25 chaînes") == true)
    }

    func testSyncFailureIsSurfacedPerSource() async throws {
        let id = try engine.addSource(name: "Broken", sourceType: "m3u", url: "file://\(directory.path)/missing.m3u", server: nil, username: nil, passwordRef: nil)
        let source = try XCTUnwrap(engine.listSources().first { $0.id == id })
        let model = makeModel()
        let ok = await model.sync(source)
        XCTAssertFalse(ok)
        guard case .failed(let message) = model.state(for: source) else { return XCTFail("expected failure") }
        XCTAssertFalse(message.isEmpty)
        XCTAssertEqual(model.banner?.isError, true)
    }

    func testXtreamSyncWithoutStoredPasswordExplainsWhy() async throws {
        let id = try engine.addSource(name: "X", sourceType: "xtream", url: nil, server: "http://127.0.0.1:9", username: "u", passwordRef: nil)
        let source = try XCTUnwrap(engine.listSources().first { $0.id == id })
        let model = makeModel()
        let ok = await model.sync(source)
        XCTAssertFalse(ok)
        guard case .failed(let message) = model.state(for: source) else { return XCTFail("expected failure") }
        XCTAssertTrue(message.contains("Trousseau"))
    }

    func testImportingADroppedPlaylistCreatesAndFillsASource() async throws {
        let dropped = try TestFixtures.writeM3u(in: directory, name: "Ma Liste.m3u8", count: 15)
        let model = makeModel()
        await model.importM3u(from: dropped)

        let sources = try engine.listSources()
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources[0].name, "Ma Liste")
        XCTAssertEqual(sources[0].itemCount, 15)
        XCTAssertEqual(try engine.getStats().totalLiveChannels, 15)
        XCTAssertEqual(changes, 1)

        // The source survives deletion of the dropped file: it reads its private copy.
        try FileManager.default.removeItem(at: dropped)
        let source = try XCTUnwrap(sources.first)
        let ok = await model.sync(source)
        XCTAssertTrue(ok)
    }

    func testImportRejectsOtherFileTypes() async throws {
        let text = directory.appendingPathComponent("notes.txt")
        try "hello".write(to: text, atomically: true, encoding: .utf8)
        let model = makeModel()
        await model.importM3u(from: text)
        XCTAssertTrue(try engine.listSources().isEmpty)
        XCTAssertEqual(model.banner?.isError, true)
        XCTAssertTrue(SourcesModel.isM3uFile(URL(fileURLWithPath: "/a/B.M3U")))
        XCTAssertTrue(SourcesModel.isM3uFile(URL(fileURLWithPath: "/a/b.m3u8")))
        XCTAssertFalse(SourcesModel.isM3uFile(URL(fileURLWithPath: "/a/b.mp4")))
    }

    func testSyncAllVisitsEverySource() async throws {
        for index in 1...3 {
            let file = try TestFixtures.writeM3u(in: directory, name: "l\(index).m3u", count: 5)
            _ = try engine.addSource(name: "S\(index)", sourceType: "m3u", url: "file://\(file.path)", server: nil, username: nil, passwordRef: nil)
        }
        let model = makeModel()
        await model.syncAll(try engine.listSources())
        XCTAssertFalse(model.isSyncingAll)
        for source in try engine.listSources() {
            guard case .done = model.state(for: source) else { return XCTFail("\(source.name) not synced") }
        }
    }

    // MARK: Pure helpers

    func testSummaryFormatting() {
        let one = SyncSummary(sourceId: 1, totalItems: 3, liveCount: 1, movieCount: 1, seriesCount: 0, episodeCount: 0, durationMs: 12)
        XCTAssertEqual(SyncSummaryFormatter.text(one), "1 chaîne · 1 film · 0 série · 12 ms")
        let many = SyncSummary(sourceId: 1, totalItems: 9, liveCount: 120, movieCount: 45, seriesCount: 6, episodeCount: 0, durationMs: 820)
        XCTAssertEqual(SyncSummaryFormatter.text(many), "120 chaînes · 45 films · 6 séries · 820 ms")
    }

    func testSourceFilterAndSearch() throws {
        let m3u = try engine.addSource(name: "Freebox", sourceType: "m3u", url: "http://a/l.m3u", server: nil, username: nil, passwordRef: nil)
        let xtream = try engine.addSource(name: "Premium", sourceType: "xtream", url: nil, server: "http://prem.tv", username: "u", passwordRef: nil)
        let all = try engine.listSources()
        XCTAssertEqual(all.count, 2)

        XCTAssertEqual(SourceFilter.apply(.all, query: "", to: all).count, 2)
        XCTAssertEqual(SourceFilter.apply(.m3u, query: "", to: all).map(\.id), [m3u])
        XCTAssertEqual(SourceFilter.apply(.xtream, query: "", to: all).map(\.id), [xtream])
        XCTAssertEqual(SourceFilter.apply(.all, query: "prem", to: all).map(\.id), [xtream])
        XCTAssertEqual(SourceFilter.apply(.all, query: "prem.tv", to: all).map(\.id), [xtream])
        XCTAssertTrue(SourceFilter.apply(.m3u, query: "premium", to: all).isEmpty)
    }
}
