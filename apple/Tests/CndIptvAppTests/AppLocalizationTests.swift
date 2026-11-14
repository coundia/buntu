import XCTest
@testable import CndIptvKit

@MainActor
final class AppLocalizationTests: XCTestCase {
    private func makeIsolatedDefaults() -> (UserDefaults, String) {
        let suiteName = "buntu.tests.localization.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    func testDefaultsToFrench() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = AppLanguageStore(defaults: defaults)
        XCTAssertEqual(store.language, .fr)
        XCTAssertEqual(store.t("tab.settings"), "Réglages")
        XCTAssertEqual(store.t("household.title"), "Appareils")
        XCTAssertEqual(store.t("remoteCommand.title"), "Commande TV")
    }

    func testInvalidStoredValueFallsBackToFrench() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("es", forKey: AppLanguageStore.defaultsKey)
        let store = AppLanguageStore(defaults: defaults)
        XCTAssertEqual(store.language, .fr)
    }

    func testSwitchingToEnglishAndPersistingInUserDefaults() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = AppLanguageStore(defaults: defaults)
        store.language = .en

        XCTAssertEqual(defaults.string(forKey: AppLanguageStore.defaultsKey), "en")
        XCTAssertEqual(store.t("tab.settings"), "Settings")
        XCTAssertEqual(store.t("household.title"), "Devices")
        XCTAssertEqual(store.t("remoteCommand.title"), "TV Remote")
        XCTAssertEqual(store.t("settings.language.picker"), "Language")

        let reloaded = AppLanguageStore(defaults: defaults)
        XCTAssertEqual(reloaded.language, .en)
        XCTAssertEqual(reloaded.t("tab.movies"), "Movies")

        reloaded.language = .fr
        XCTAssertEqual(defaults.string(forKey: AppLanguageStore.defaultsKey), "fr")
        XCTAssertEqual(reloaded.t("tab.movies"), "Films")
    }

    func testFullKeyParityBetweenFrenchAndEnglish() {
        let frKeys = Set(AppStringsFR.strings.keys)
        let enKeys = Set(AppStringsEN.strings.keys)

        let missingInEN = frKeys.subtracting(enKeys).sorted()
        let extraInEN = enKeys.subtracting(frKeys).sorted()

        XCTAssertTrue(missingInEN.isEmpty, "Keys present in FR but missing in EN: \(missingInEN)")
        XCTAssertTrue(extraInEN.isEmpty, "Keys present in EN but missing in FR: \(extraInEN)")
        XCTAssertFalse(frKeys.isEmpty)

        for key in frKeys {
            XCTAssertFalse(AppStringsFR.strings[key]?.isEmpty ?? true, "Empty FR string for key: \(key)")
            XCTAssertFalse(AppStringsEN.strings[key]?.isEmpty ?? true, "Empty EN string for key: \(key)")
        }
    }

    func testUnknownKeyFallsBackToKeyItself() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = AppLanguageStore(defaults: defaults)
        XCTAssertEqual(store.t("unknown.missing.key"), "unknown.missing.key")
        store.language = .en
        XCTAssertEqual(store.t("unknown.missing.key"), "unknown.missing.key")
    }

    func testFormattedLocalization() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = AppLanguageStore(defaults: defaults)
        XCTAssertEqual(store.t("settings.recommendations.seconds", 10), "10 secondes")
        store.language = .en
        XCTAssertEqual(store.t("settings.recommendations.seconds", 10), "10 seconds")
    }
}
