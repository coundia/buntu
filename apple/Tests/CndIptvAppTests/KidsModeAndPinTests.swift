import XCTest
import CryptoKit
import CndCoreBridge
@testable import CndIptvApp

final class PinHasherTests: XCTestCase {
    func testOnlyFourToSixDigitsAreAccepted() {
        for ok in ["1234", "12345", "123456", "0000"] { XCTAssertTrue(PinHasher.isValid(pin: ok), ok) }
        for bad in ["", "123", "1234567", "12a4", "12 34", "١٢٣٤"] { XCTAssertFalse(PinHasher.isValid(pin: bad), bad) }
    }

    func testRoundTripAndWrongPin() throws {
        let stored = try XCTUnwrap(PinHasher.encode(pin: "4821", iterations: 1_000))
        XCTAssertEqual(PinHasher.verify(pin: "4821", stored: stored), .correct)
        XCTAssertEqual(PinHasher.verify(pin: "4822", stored: stored), .wrong)
        XCTAssertEqual(PinHasher.verify(pin: "", stored: stored), .wrong)
    }

    func testStoredValueHasNoPinInIt() throws {
        let stored = try XCTUnwrap(PinHasher.encode(pin: "4821", iterations: 1_000))
        XCTAssertEqual(stored.count, 2 + 4 + 16 + 32)
        XCTAssertEqual(stored.prefix(2), Data("P2".utf8))
        XCTAssertNil(String(decoding: stored, as: UTF8.self).range(of: "4821"))
    }

    func testTwoEncodingsOfTheSamePinDiffer() throws {
        let a = try XCTUnwrap(PinHasher.encode(pin: "4821", iterations: 1_000))
        let b = try XCTUnwrap(PinHasher.encode(pin: "4821", iterations: 1_000))
        XCTAssertNotEqual(a, b, "the salt is random")
    }

    func testTheDefaultCostIsHigh() {
        XCTAssertGreaterThanOrEqual(PinHasher.iterations, 600_000)
    }

    func testAnOldSha256PinStillWorksAndAsksForAnUpgrade() {
        let salt = Data((0..<16).map { UInt8($0) })
        let legacy = salt + Data(SHA256.hash(data: salt + Data("1234".utf8)))
        XCTAssertEqual(PinHasher.verify(pin: "1234", stored: legacy), .correctNeedsUpgrade)
        XCTAssertEqual(PinHasher.verify(pin: "9999", stored: legacy), .wrong)
    }

    func testGarbageIsNeverAccepted() {
        XCTAssertEqual(PinHasher.verify(pin: "1234", stored: Data()), .wrong)
        XCTAssertEqual(PinHasher.verify(pin: "1234", stored: Data(count: 54)), .wrong)
        XCTAssertEqual(PinHasher.verify(pin: "1234", stored: Data(count: 48)), .wrong)
    }
}

@MainActor
final class KidsModeTests: XCTestCase {
    func testTheKidsProfileHasNoSourcesNoSettingsAndNoAssistant() {
        let kids = KidsModePolicy.allowedTabs(isKids: true)
        XCTAssertFalse(kids.contains(.sources))
        XCTAssertFalse(kids.contains(.settings))
        XCTAssertTrue(kids.contains(.live))
        XCTAssertTrue(kids.contains(.movies))
        XCTAssertFalse(KidsModePolicy.canUseAssistant(isKids: true))

        XCTAssertEqual(KidsModePolicy.allowedTabs(isKids: false), AppTab.allCases)
        XCTAssertTrue(KidsModePolicy.canUseAssistant(isKids: false))
    }

    private func defaults() -> UserDefaults {
        let suite = "cnd.tests.kids.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    func testTheActiveProfileSurvivesARelaunch() throws {
        let engine = try CndEngine.inMemory()
        let defaults = defaults()
        let model = ProfilesModel(engine: engine, defaults: defaults)
        let kids = try XCTUnwrap(model.createProfile(name: "Léa", avatar: "star", isKids: true))
        model.forceSelectProfile(id: kids.id)
        XCTAssertTrue(model.isKidsModeActive)

        // A new launch: the engine starts on the main profile, then the stored choice is restored.
        let relaunched = try CndEngine.inMemory()
        let again = try XCTUnwrap(try relaunched.createProfile(name: "Léa", avatar: "star", isKids: true))
        XCTAssertEqual(relaunched.activeProfileId(), 1)
        defaults.set(Int(again.id), forKey: ProfilesModel.activeProfileDefaultsKey)
        ProfilesModel.restoreActiveProfile(engine: relaunched, defaults: defaults)
        XCTAssertEqual(relaunched.activeProfileId(), again.id)
        XCTAssertTrue(ProfilesModel(engine: relaunched, defaults: defaults).isKidsModeActive)
    }

    func testARemovedProfileFallsBackToThePrincipalOne() throws {
        let engine = try CndEngine.inMemory()
        let defaults = defaults()
        defaults.set(99, forKey: ProfilesModel.activeProfileDefaultsKey)
        ProfilesModel.restoreActiveProfile(engine: engine, defaults: defaults)
        XCTAssertEqual(engine.activeProfileId(), 1)
    }

    func testWithoutAStoredChoiceNothingChanges() throws {
        let engine = try CndEngine.inMemory()
        ProfilesModel.restoreActiveProfile(engine: engine, defaults: defaults())
        XCTAssertEqual(engine.activeProfileId(), 1)
    }

    func testSelectingAProfileIsRemembered() async throws {
        let engine = try CndEngine.inMemory()
        let defaults = defaults()
        let model = ProfilesModel(engine: engine, defaults: defaults)
        let kids = try XCTUnwrap(model.createProfile(name: "Léa", avatar: "star", isKids: true))
        _ = await model.selectProfile(kids)
        XCTAssertEqual(defaults.integer(forKey: ProfilesModel.activeProfileDefaultsKey), Int(kids.id))
    }
}
