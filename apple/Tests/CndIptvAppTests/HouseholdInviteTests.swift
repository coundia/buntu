import XCTest
@testable import CndIptvKit

final class HouseholdInviteTests: XCTestCase {
    private let key = String(repeating: "ab12", count: 16)

    func testLinkRoundTrip() throws {
        let link = try XCTUnwrap(HouseholdInvite.link(forKeyHex: key))
        XCTAssertEqual(link, "buntu://household?key=\(key)")
        XCTAssertEqual(HouseholdInvite.keyHex(fromScanned: link), key)
    }

    func testBareKeyIsAcceptedAndLowercased() {
        XCTAssertEqual(HouseholdInvite.keyHex(fromScanned: "  \(key.uppercased())\n"), key)
    }

    func testRejectsWrongLengthNonHexAndForeignCodes() {
        let tooShort = String(key.dropLast())
        let notHex = String(repeating: "zz", count: 32)
        for bad in [
            "", tooShort, key + "0", notHex,
            "https://example.com/?key=\(key)",
            "buntu://pair?key=\(key)",
            "buntu://household",
            "buntu://household?key=\(tooShort)",
            "buntu://household?other=\(key)",
        ] {
            XCTAssertNil(HouseholdInvite.keyHex(fromScanned: bad), bad)
        }
        XCTAssertNil(HouseholdInvite.link(forKeyHex: tooShort))
    }

    func testQrImageOnlyForAValidKey() {
        XCTAssertNotNil(HouseholdInvite.qrImage(forKeyHex: key))
        XCTAssertNil(HouseholdInvite.qrImage(forKeyHex: "not a key"))
    }
}
