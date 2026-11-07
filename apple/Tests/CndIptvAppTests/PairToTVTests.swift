import XCTest
import CndCoreBridge
@testable import CndIptvKit

/// The TV in a box: opens what the phone sent with the SAME Rust protocol the real TV runs
/// (WebAssembly there), and answers like the TV does after the user pressed « Ajouter ».
private final class FakeTV: PairingTransporting, @unchecked Sendable {
    let offer: PairingOffer
    var received: [String] = []
    var answer = "added"
    var count: UInt32 = 1
    var failure: PairingTransportError?
    private let now: Int64

    init(now: Int64) throws {
        self.now = now
        offer = try pairingCreateOffer(
            entropy: Data(PairingRandom.bytes(40)), tvName: "Salon TV", transport: "msf",
            host: "192.168.1.9", port: 8001, now: now
        )
    }

    func exchange(link: PairingLink, message: String, onDelivered: @escaping @Sendable () -> Void) async throws -> String {
        if let failure { throw failure }
        let result = pairingOpen(state: offer.state, message: message, now: now + 1)
        guard let opened = result.opened else { throw PairingTransportError.badAnswer }
        received.append(opened.shareJson)
        return try pairingSealReply(
            replyKey: opened.replyKey, session: offer.session, entropy: Data(PairingRandom.bytes(12)),
            result: answer, count: count
        )
    }
}

@MainActor
final class PairToTVTests: XCTestCase {
    private var engine: CndEngine!
    private var keychain: KeychainStore!
    private let now: Int64 = 1_800_000_000

    override func setUp() async throws {
        engine = try CndEngine.inMemory()
        keychain = KeychainStore(service: "com.cnd.iptv.tests.pair.\(UUID().uuidString)")
    }

    private func addXtream(password: String = "p@ss-1234") throws -> IptvSourceRecord {
        let id = try engine.addSource(name: "Premium", sourceType: "xtream", url: nil, server: "http://srv.example:8080", username: "bob", passwordRef: nil)
        let record = try XCTUnwrap(try engine.listSources().first { $0.id == id })
        let key = KeychainStore.xtreamKey(forSourceUuid: record.uuid)
        try keychain.saveSecret(password, forKey: key)
        try engine.updateXtreamSource(sourceId: id, name: "Premium", server: "http://srv.example:8080", username: "bob", passwordRef: key, epgUrl: nil)
        return try XCTUnwrap(try engine.listSources().first { $0.id == id })
    }

    private func makeModel(_ tv: FakeTV, sources: [IptvSourceRecord]) -> PairToTVModel {
        let share = ShareSourcesModel(engine: engine, keychain: keychain, sources: sources, preselected: Set(sources.map(\.id)))
        return PairToTVModel(share: share, phoneName: "iPhone de Papa", now: { [now] in now }, makeTransport: { _ in tv })
    }

    func testTheTVReceivesTheAccountWithItsPasswordAndAnswersAdded() async throws {
        let source = try addXtream()
        let tv = try FakeTV(now: now)
        let model = makeModel(tv, sources: [source])

        XCTAssertTrue(model.accept(scanned: tv.offer.link))
        XCTAssertEqual(model.stage, .choosing)
        XCTAssertEqual(model.link?.tvName, "Salon TV")
        await model.send()

        XCTAssertEqual(model.stage, .done(1))
        let json = try XCTUnwrap(tv.received.first)
        XCTAssertTrue(json.contains("p@ss-1234"), "the password reaches the TV, inside the encrypted message")
        XCTAssertTrue(json.contains("srv.example"))
    }

    func testAnExpiredOrForeignQrCodeIsRefused() throws {
        let tv = try FakeTV(now: now)
        let model = makeModel(tv, sources: [])
        XCTAssertFalse(PairToTVModel(share: model.share, now: { [now] in now + 400 }, makeTransport: { _ in tv }).accept(scanned: tv.offer.link))
        XCTAssertFalse(model.accept(scanned: "https://example.com"))
        XCTAssertFalse(model.accept(scanned: "buntu://pair?v=1"))
        XCTAssertEqual(model.stage, .scanning)
    }

    func testARefusalOnTheTVIsShown() async throws {
        let source = try addXtream()
        let tv = try FakeTV(now: now)
        tv.answer = "refused"
        let model = makeModel(tv, sources: [source])
        model.accept(scanned: tv.offer.link)
        await model.send()
        XCTAssertEqual(model.stage, .refused)
    }

    func testTransportProblemsBecomeAReadableMessage() async throws {
        let source = try addXtream()
        let tv = try FakeTV(now: now)
        tv.failure = .unreachable("192.168.1.9")
        let model = makeModel(tv, sources: [source])
        model.accept(scanned: tv.offer.link)
        await model.send()
        guard case .failed(let message) = model.stage else { return XCTFail("expected failure, got \(model.stage)") }
        XCTAssertTrue(message.contains("Wi-Fi"), message)
    }

    func testNothingIsSentWithoutAChosenSource() async throws {
        let source = try addXtream()
        let tv = try FakeTV(now: now)
        let model = makeModel(tv, sources: [source])
        model.share.selected = []
        model.accept(scanned: tv.offer.link)
        await model.send()
        XCTAssertTrue(tv.received.isEmpty)
        XCTAssertEqual(model.stage, .choosing)
    }

    func testPasswordsGoByDefaultAndCanBeUntickedPerSource() async throws {
        let source = try addXtream()
        let tv = try FakeTV(now: now)
        let model = makeModel(tv, sources: [source])
        XCTAssertTrue(model.share.includeCredentials.contains(source.id))
        model.share.includeCredentials = []
        model.accept(scanned: tv.offer.link)
        await model.send()
        XCTAssertFalse(try XCTUnwrap(tv.received.first).contains("p@ss-1234"))
    }

    func testTheRandomBytesAreFreshEveryTime() {
        XCTAssertNotEqual(PairingRandom.bytes(44), PairingRandom.bytes(44))
        XCTAssertEqual(PairingRandom.bytes(44).count, 44)
    }

    func testUnknownTransportsAreExplainedNotCrashed() {
        XCTAssertThrowsError(try PairingTransports.make(for: "tls")) {
            XCTAssertTrue(($0 as? PairingTransportError)?.errorDescription?.contains("pas encore") == true)
        }
        XCTAssertNoThrow(try PairingTransports.make(for: "msf"))
        XCTAssertNoThrow(try PairingTransports.make(for: "http"))
    }
}
