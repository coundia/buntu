import XCTest
import CndCoreBridge
@testable import CndIptvKit

final class ShareEnvelopeTests: XCTestCase {
    private let document = Data(#"{"format":"cnd-source-share","sources":[{"name":"Salon","password":"s3cret-pass"}]}"#.utf8)
    private var future: Int64 { Int64(Date().addingTimeInterval(3_600).timeIntervalSince1970) }

    func testRoundTrip() throws {
        let code = ShareEnvelope.makeCode()
        let envelope = try ShareEnvelope.seal(document: document, code: code, sourceCount: 1, expiresAt: future)
        XCTAssertEqual(try ShareEnvelope.open(envelope: envelope, code: code), document)
    }

    func testWrongCodeIsRejected() throws {
        let envelope = try ShareEnvelope.seal(document: document, code: ShareEnvelope.makeCode(), sourceCount: 1, expiresAt: future)
        XCTAssertThrowsError(try ShareEnvelope.open(envelope: envelope, code: ShareEnvelope.makeCode())) {
            XCTAssertEqual($0 as? ShareEnvelope.Failure, .wrongCodeOrTampered)
        }
    }

    func testAnyModifiedByteIsDetected() throws {
        let code = ShareEnvelope.makeCode()
        let envelope = try ShareEnvelope.seal(document: document, code: code, sourceCount: 1, expiresAt: future)
        // Body (ciphertext), then header (authenticated as additional data).
        for index in [envelope.count - 1, envelope.count - 20, 12] {
            var tampered = envelope
            tampered[index] ^= 0x01
            XCTAssertThrowsError(try ShareEnvelope.open(envelope: tampered, code: code), "byte \(index)")
        }
    }

    func testExpiredShareIsRefused() throws {
        let code = ShareEnvelope.makeCode()
        let envelope = try ShareEnvelope.seal(document: document, code: code, sourceCount: 1, expiresAt: future)
        XCTAssertThrowsError(try ShareEnvelope.open(envelope: envelope, code: code, now: Date().addingTimeInterval(7_200))) {
            XCTAssertEqual($0 as? ShareEnvelope.Failure, .expired)
        }
    }

    func testClearHeaderHoldsNothingSensitive() throws {
        let code = ShareEnvelope.makeCode()
        let envelope = try ShareEnvelope.seal(document: document, code: code, sourceCount: 3, expiresAt: future)
        let parts = try ShareEnvelope.header(of: envelope)
        XCTAssertEqual(parts.header.sourceCount, 3)
        let text = String(decoding: envelope, as: UTF8.self)
        XCTAssertFalse(text.contains("s3cret-pass"))
        XCTAssertFalse(text.contains("Salon"))
        XCTAssertFalse(String(decoding: parts.headerData, as: UTF8.self).contains("Salon"))
    }

    func testGarbageAndUnsupportedVersionAreRejected() {
        XCTAssertThrowsError(try ShareEnvelope.header(of: Data("not a share".utf8)))
        XCTAssertThrowsError(try ShareEnvelope.header(of: Data()))
    }

    func testCodeFormatAndTolerantParsing() throws {
        let code = ShareEnvelope.makeCode()
        let text = ShareEnvelope.format(code: code)
        XCTAssertEqual(text.replacingOccurrences(of: "-", with: "").count, 26)
        XCTAssertEqual(try ShareEnvelope.parse(code: text), code)
        XCTAssertEqual(try ShareEnvelope.parse(code: text.lowercased()), code)
        XCTAssertEqual(try ShareEnvelope.parse(code: " " + text.replacingOccurrences(of: "-", with: " ") + " "), code)
        XCTAssertThrowsError(try ShareEnvelope.parse(code: "ABCD"))
        XCTAssertThrowsError(try ShareEnvelope.parse(code: "!" + text.dropFirst()))
    }

    func testCodesAreRandom() {
        let codes = Set((0..<50).map { _ in ShareEnvelope.makeCode() })
        XCTAssertEqual(codes.count, 50)
        XCTAssertTrue(codes.allSatisfy { $0.count == 16 })
    }

    func testLinkRoundTrip() throws {
        let code = ShareEnvelope.makeCode()
        let envelope = try ShareEnvelope.seal(document: document, code: code, sourceCount: 1, expiresAt: future)
        let link = ShareEnvelope.link(envelope: envelope, code: code)
        XCTAssertTrue(link.hasPrefix("cndiptv://import#"))
        let incoming = try XCTUnwrap(ShareEnvelope.parse(link: URL(string: link)!))
        XCTAssertEqual(incoming.envelope, envelope)
        XCTAssertEqual(try ShareEnvelope.parse(code: try XCTUnwrap(incoming.code)), code)
        XCTAssertNil(ShareEnvelope.parse(link: URL(string: "https://example.com/#abc")!))
        XCTAssertNil(ShareEnvelope.parse(link: URL(string: "cndiptv://other#abc")!))
    }

    func testIncomingShareFromFile() throws {
        let code = ShareEnvelope.makeCode()
        let envelope = try ShareEnvelope.seal(document: document, code: code, sourceCount: 1, expiresAt: future)
        let package = SharePackage(envelope: envelope, code: code, warnings: [], sourceCount: 1, expiresAt: Date().addingTimeInterval(3_600))
        let dir = try TestFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try package.writeFile(directory: dir)
        XCTAssertEqual(url.pathExtension, "cndshare")
        let incoming = try XCTUnwrap(IncomingShare.from(url: url))
        XCTAssertEqual(incoming.envelope, envelope)
        XCTAssertNil(incoming.code)
        XCTAssertNil(IncomingShare.from(url: dir.appendingPathComponent("x.txt")))
    }

    func testQrOnlyForSmallShares() throws {
        let code = ShareEnvelope.makeCode()
        let small = try ShareEnvelope.seal(document: document, code: code, sourceCount: 1, expiresAt: future)
        let smallPackage = SharePackage(envelope: small, code: code, warnings: [], sourceCount: 1, expiresAt: Date())
        XCTAssertTrue(smallPackage.linkFitsInQR)
        XCTAssertNotNil(smallPackage.qrImage())

        // Random bytes do not compress: a 4 KB document cannot fit.
        let noise = Data((0..<4_000).map { _ in UInt8.random(in: 0...255) })
        let big = try ShareEnvelope.seal(document: noise, code: code, sourceCount: 1, expiresAt: future)
        let bigPackage = SharePackage(envelope: big, code: code, warnings: [], sourceCount: 1, expiresAt: Date())
        XCTAssertFalse(bigPackage.linkFitsInQR)
        XCTAssertNil(bigPackage.qrImage())
    }
}

@MainActor
final class ShareModelTests: XCTestCase {
    private var directory: URL!
    private var sender: CndEngine!
    private var receiver: CndEngine!
    private var senderKeychain: KeychainStore!
    private var receiverKeychain: KeychainStore!

    override func setUp() async throws {
        directory = try TestFixtures.makeTempDirectory()
        sender = try CndEngine.inMemory()
        receiver = try CndEngine.inMemory()
        senderKeychain = KeychainStore(service: "com.cnd.iptv.tests.share.s.\(UUID().uuidString)")
        receiverKeychain = KeychainStore(service: "com.cnd.iptv.tests.share.r.\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func addXtream(name: String = "Abonnement", password: String = "p@ss-1234") throws -> IptvSourceRecord {
        let id = try sender.addSource(name: name, sourceType: "xtream", url: nil, server: "http://srv.example:8080", username: "bob", passwordRef: nil)
        let record = try XCTUnwrap(try sender.listSources().first { $0.id == id })
        let key = KeychainStore.xtreamKey(forSourceUuid: record.uuid)
        try senderKeychain.saveSecret(password, forKey: key)
        try sender.updateXtreamSource(sourceId: id, name: name, server: "http://srv.example:8080", username: "bob", passwordRef: key, epgUrl: nil)
        return try XCTUnwrap(try sender.listSources().first { $0.id == id })
    }

    private func makeShare(_ sources: [IptvSourceRecord], credentials: Bool) async throws -> SharePackage {
        let model = ShareSourcesModel(engine: sender, keychain: senderKeychain, sources: sources, preselected: Set(sources.map(\.id)))
        if credentials { model.includeCredentials = Set(sources.map(\.id)) }
        await model.prepare()
        return try XCTUnwrap(model.package, model.errorMessage ?? "no package")
    }

    private func makeImporter(_ package: SharePackage, code: String? = nil) -> ShareImportModel {
        let importer = ShareImportModel(
            engine: receiver, keychain: receiverKeychain,
            importsDirectory: directory.appendingPathComponent("imports"),
            incoming: IncomingShare(envelope: package.envelope, code: nil)
        )
        importer.codeText = code ?? package.codeText
        return importer
    }

    func testWithoutCredentialsNothingSecretLeavesTheSender() async throws {
        let source = try addXtream()
        let package = try await makeShare([source], credentials: false)
        let plain = try ShareEnvelope.open(envelope: package.envelope, code: package.code)
        let text = String(decoding: plain, as: UTF8.self)
        XCTAssertFalse(text.contains("p@ss-1234"))
        XCTAssertTrue(text.contains("bob"), "the user name is an identifier, only the password is withheld")
        XCTAssertFalse(String(decoding: package.envelope, as: UTF8.self).contains("p@ss-1234"))
    }

    func testImportStoresPasswordInKeychainAndNotInDatabase() async throws {
        let source = try addXtream()
        let package = try await makeShare([source], credentials: true)

        let importer = makeImporter(package)
        var synced: [Int64] = []
        importer.onImported = { synced = $0 }
        await importer.decrypt()
        XCTAssertEqual(importer.stage, .preview)
        XCTAssertEqual(importer.preview?.sources.count, 1)
        XCTAssertEqual(importer.chosenCount, 1)
        await importer.performImport()

        guard case .done(let summary) = importer.stage else { return XCTFail("not imported: \(importer.errorMessage ?? "")") }
        XCTAssertEqual(summary.imported, 1)
        XCTAssertTrue(summary.needingCredentials.isEmpty)
        let record = try XCTUnwrap(try receiver.listSources().first)
        XCTAssertEqual(record.username, "bob")
        let key = try XCTUnwrap(record.passwordRef)
        XCTAssertEqual(try receiverKeychain.readSecret(forKey: key), "p@ss-1234")
        XCTAssertEqual(synced, [record.id], "ready sources are synced after import")
        XCTAssertFalse("\(record)".contains("p@ss-1234"), "the password is not part of the stored record")
    }

    func testSourceWithoutPasswordIsFlaggedAndNotSynced() async throws {
        let source = try addXtream()
        let package = try await makeShare([source], credentials: false)
        let importer = makeImporter(package)
        var synced: [Int64] = [-1]
        importer.onImported = { synced = $0 }
        await importer.decrypt()
        await importer.performImport()
        guard case .done(let summary) = importer.stage else { return XCTFail("not imported: \(importer.errorMessage ?? "")") }
        XCTAssertEqual(summary.needingCredentials, [source.name])
        XCTAssertTrue(synced.isEmpty)
    }

    func testWrongCodeKeepsTheInputStageWithAMessage() async throws {
        let source = try addXtream()
        let package = try await makeShare([source], credentials: true)
        let importer = makeImporter(package, code: ShareEnvelope.format(code: ShareEnvelope.makeCode()))
        await importer.decrypt()
        XCTAssertEqual(importer.stage, .input)
        XCTAssertEqual(importer.errorMessage, ShareEnvelope.Failure.wrongCodeOrTampered.errorDescription)
        XCTAssertTrue(try receiver.listSources().isEmpty)
    }

    func testDuplicateIsSkippedByDefault() async throws {
        let source = try addXtream()
        let package = try await makeShare([source], credentials: true)
        // The receiver already has the same subscription.
        _ = try receiver.addSource(name: "Déjà là", sourceType: "xtream", url: nil, server: "http://srv.example:8080", username: "bob", passwordRef: nil)

        let importer = makeImporter(package)
        await importer.decrypt()
        let entry = try XCTUnwrap(importer.preview?.sources.first)
        XCTAssertNotNil(entry.duplicateOf)
        XCTAssertEqual(importer.decisions[entry.index], .skip)
        XCTAssertEqual(importer.chosenCount, 0)
        XCTAssertEqual(try receiver.listSources().count, 1)
    }

    func testNoImportBeforeConfirmation() async throws {
        let source = try addXtream()
        let package = try await makeShare([source], credentials: true)
        let importer = makeImporter(package)
        await importer.decrypt()
        XCTAssertTrue(try receiver.listSources().isEmpty, "the preview adds nothing")
    }

    func testLocalPlaylistTravelsOnlyWhenAsked() async throws {
        let file = directory.appendingPathComponent("maison.m3u")
        try "#EXTM3U\n#EXTINF:-1,Une chaîne\nhttp://example.com/live/1.ts\n".write(to: file, atomically: true, encoding: .utf8)
        let id = try sender.addSource(name: "Maison", sourceType: "m3u", url: file.absoluteString, server: nil, username: nil, passwordRef: nil)
        let source = try XCTUnwrap(try sender.listSources().first { $0.id == id })
        XCTAssertTrue(ShareSourcesModel.isLocalPlaylist(source))

        let refused = ShareSourcesModel(engine: sender, keychain: senderKeychain, sources: [source], preselected: [id])
        await refused.prepare()
        XCTAssertNil(refused.package, "a local file cannot be shared without include-playlist")
        XCTAssertNotNil(refused.errorMessage)

        let accepted = ShareSourcesModel(engine: sender, keychain: senderKeychain, sources: [source], preselected: [id])
        accepted.includePlaylist = [id]
        await accepted.prepare()
        let package = try XCTUnwrap(accepted.package)

        let importer = makeImporter(package)
        await importer.decrypt()
        await importer.performImport()
        let record = try XCTUnwrap(try receiver.listSources().first)
        let path = try XCTUnwrap(URL(string: try XCTUnwrap(record.url))?.path)
        XCTAssertTrue(try String(contentsOfFile: path, encoding: .utf8).contains("Une chaîne"))
    }

    func testCredentialWarningAndLimit() throws {
        let source = IptvSourceRecord(
            id: 1, uuid: "u", name: "A", sourceType: "xtream", url: nil, server: "http://s", username: "u", passwordRef: nil,
            epgUrl: nil, expDate: nil, maxConnections: 2, activeCons: nil, accountStatus: nil, itemCount: 0, updatedAt: 0
        )
        let model = ShareSourcesModel(engine: try CndEngine.inMemory(), keychain: senderKeychain, sources: [source], preselected: [1])
        XCTAssertFalse(model.sharesCredentials)
        XCTAssertNil(model.sharedConnectionLimit)
        model.includeCredentials = [1]
        XCTAssertTrue(model.sharesCredentials)
        XCTAssertEqual(model.sharedConnectionLimit, 2)
    }

    func testExpiredEnvelopeIsRefusedAtLoad() throws {
        let code = ShareEnvelope.makeCode()
        let past = Int64(Date().addingTimeInterval(-60).timeIntervalSince1970)
        let envelope = try ShareEnvelope.seal(document: Data("{}".utf8), code: code, sourceCount: 1, expiresAt: past)
        let importer = ShareImportModel(engine: receiver, keychain: receiverKeychain, importsDirectory: directory)
        importer.load(envelope: envelope)
        XCTAssertFalse(importer.hasEnvelope)
        XCTAssertEqual(importer.errorMessage, ShareEnvelope.Failure.expired.errorDescription)
    }
}
