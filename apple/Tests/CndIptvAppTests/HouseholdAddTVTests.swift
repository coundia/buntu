import XCTest
import CndCoreBridge
@testable import CndIptvKit

/// The TV in a box: opens the message with the same Rust pairing protocol the TV runs (WebAssembly there).
private final class FakeSamsungTV: PairingTransporting, @unchecked Sendable {
    let offer: PairingOffer
    var received: [String] = []
    var answer = "added"
    private let now: Int64

    init(now: Int64) throws {
        self.now = now
        offer = try pairingCreateOffer(
            entropy: Data(PairingRandom.bytes(40)), tvName: "Salon TV", transport: "msf",
            host: "192.168.1.7", port: 8001, now: now
        )
    }

    func exchange(link: PairingLink, message: String, onDelivered: @escaping @Sendable () -> Void) async throws -> String {
        let result = pairingOpen(state: offer.state, message: message, now: now + 1)
        guard let opened = result.opened else { throw PairingTransportError.badAnswer }
        received.append(opened.shareJson)
        return try pairingSealReply(
            replyKey: opened.replyKey, session: offer.session, entropy: Data(PairingRandom.bytes(12)),
            result: answer, count: 1
        )
    }
}

@MainActor
final class HouseholdAddTVTests: XCTestCase {
    private let now: Int64 = 1_800_000_000
    private let member = HouseholdAddTVModel.Credentials(
        householdId: "hh_0123456789abcdef", keyHex: String(repeating: "ab", count: 32),
        deviceId: "apple_iphone", deviceName: "iPhone"
    )

    /// A member that did not create the household sends it: the TV gets the same id and key.
    func testAnyMemberSendsTheHouseholdToTheTV() async throws {
        let tv = try FakeSamsungTV(now: now)
        let model = HouseholdAddTVModel(credentials: { [member] in member }, now: { [now] in now }, makeTransport: { _ in tv })

        XCTAssertTrue(model.accept(scanned: tv.offer.link))
        XCTAssertEqual(model.stage, .confirming)
        await model.send()

        XCTAssertEqual(model.stage, .done)
        let json = try XCTUnwrap(tv.received.first)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(root["type"] as? String, "household-join")
        XCTAssertEqual(root["household_id"] as? String, member.householdId)
        XCTAssertEqual(root["household_key"] as? String, member.keyHex)
        XCTAssertEqual(root["sender_device_id"] as? String, "apple_iphone")
    }

    func testRefusedOnTheTV() async throws {
        let tv = try FakeSamsungTV(now: now)
        tv.answer = "refused"
        let model = HouseholdAddTVModel(credentials: { [member] in member }, now: { [now] in now }, makeTransport: { _ in tv })
        XCTAssertTrue(model.accept(scanned: tv.offer.link))
        await model.send()
        XCTAssertEqual(model.stage, .refused)
    }

    func testWithoutHouseholdNothingIsSent() async throws {
        let tv = try FakeSamsungTV(now: now)
        let model = HouseholdAddTVModel(credentials: { nil }, now: { [now] in now }, makeTransport: { _ in tv })
        XCTAssertTrue(model.accept(scanned: tv.offer.link))
        await model.send()
        XCTAssertEqual(model.stage, .failed("Cet appareil n'est dans aucun foyer."))
        XCTAssertTrue(tv.received.isEmpty)
    }

    func testExpiredOrForeignCodeIsRefused() throws {
        let tv = try FakeSamsungTV(now: now)
        let late = HouseholdAddTVModel(credentials: { nil }, now: { [now] in now + 400 }, makeTransport: { _ in tv })
        XCTAssertFalse(late.accept(scanned: tv.offer.link))
        XCTAssertFalse(late.accept(scanned: "https://example.com"))
    }
}
