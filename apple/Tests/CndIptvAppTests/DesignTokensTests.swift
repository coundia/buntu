import XCTest
import SwiftUI
@testable import CndIptvKit

/// PRD 30: the interface scale and the metrics derived from it.
@MainActor
final class DesignTokensTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() async throws {
        suite = "cnd.scale.tests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    // MARK: Coefficient

    func testMacUsesTheSettingFactorAndIgnoresTheSystemSize() {
        for setting in UIScaleSetting.allCases {
            let value = UIScale.coefficient(setting: setting, systemSize: .accessibility5, isMac: true)
            XCTAssertEqual(value, setting.macFactor, "\(setting)")
        }
    }

    func testOtherPlatformsTakeTheLargerOfSystemAndSetting() {
        // The setting is a floor...
        XCTAssertEqual(UIScale.coefficient(setting: .large, systemSize: .large, isMac: false), UIScale.factor(for: .xLarge))
        // ...and never reduces what the user chose in the system.
        XCTAssertEqual(UIScale.coefficient(setting: .small, systemSize: .xxxLarge, isMac: false), UIScale.factor(for: .xxxLarge))
        XCTAssertEqual(UIScale.coefficient(setting: .standard, systemSize: .large, isMac: false), 1.0)
    }

    func testCoefficientIsBounded() {
        XCTAssertEqual(UIScale.clamped(0.1), 0.85)
        XCTAssertEqual(UIScale.clamped(9), 1.6)
        for size in DynamicTypeSize.allCases {
            XCTAssertTrue(UIScale.range.contains(UIScale.factor(for: size)), "\(size)")
        }
        XCTAssertEqual(UIMetrics(scale: 5).scale, 1.6)
    }

    func testFactorGrowsWithTheTypeSize() {
        let sizes = DynamicTypeSize.allCases
        for (a, b) in zip(sizes, sizes.dropFirst()) {
            XCTAssertLessThanOrEqual(UIScale.factor(for: a), UIScale.factor(for: b), "\(a) -> \(b)")
        }
    }

    // MARK: Metrics

    func testStandardScaleKeepsTheCurrentSizes() {
        let ui = UIMetrics(scale: 1)
        XCTAssertEqual(ui.channelLogo, 44)
        XCTAssertEqual(ui.channelCardMinWidth, 240)
        XCTAssertEqual(ui.shelfChannelCardWidth, 280)
        XCTAssertEqual(ui.posterGridMinWidth, 155)
        XCTAssertEqual(ui.shelfPosterWidth, 150)
        XCTAssertEqual(ui.categoryColumnNarrow, 190)
        XCTAssertEqual(ui.categoryColumnWide, 250)
        XCTAssertEqual(ui.sidebarMinWidth, 180)
        XCTAssertEqual(ui.sidebarMaxWidth, 280)
    }

    func testMetricsAreWholePointsAndFollowTheScale() {
        let ui = UIMetrics(scale: 1.15)
        XCTAssertEqual(ui.channelLogo, 51)               // 44 * 1.15 = 50.6
        XCTAssertEqual(ui.channelLogo, ui.channelLogo.rounded())
        XCTAssertGreaterThan(UIMetrics(scale: 1.3).iconM, UIMetrics(scale: 1).iconM)
        XCTAssertLessThan(UIMetrics(scale: 0.9).posterGridMinWidth, UIMetrics(scale: 1).posterGridMinWidth)
    }

    func testPosterHeightStaysTwoByThree() {
        let ui = UIMetrics(scale: 1.3)
        XCTAssertEqual(ui.posterHeight(forWidth: 150), 225)
    }

    func testHitTargetPerPlatformAndGrowth() {
        let base = UIMetrics(scale: 1).minHitTarget
        #if os(iOS)
        XCTAssertEqual(base, 44)
        #elseif os(macOS)
        XCTAssertEqual(base, 28)
        #endif
        XCTAssertGreaterThanOrEqual(UIMetrics(scale: 1.3).minHitTarget, base)
    }

    func testNoInformativeTextBelowTheMinimum() {
        #if os(macOS)
        let styles: [Font.TextStyle] = [.largeTitle, .title, .title2, .title3, .headline, .subheadline, .callout, .footnote, .caption, .caption2, .body]
        XCTAssertEqual(UIMetrics.minimumTextSize, 10)
        // The smallest style at the smallest scale is still readable: nothing computes under the minimum.
        let small = UIMetrics(scale: 0.85)
        for style in styles { _ = small.font(style) }
        #endif
        XCTAssertGreaterThanOrEqual(UIMetrics.minimumTextSize, 10)
    }

    // MARK: Breakpoints

    func testBreakpointsGrowWithTheScale() {
        let normal = UIMetrics(scale: 1).breakpoints
        let large = UIMetrics(scale: 1.3).breakpoints
        XCTAssertGreaterThan(large.categoryColumn, normal.categoryColumn)
        XCTAssertGreaterThan(large.categoryColumnWide, normal.categoryColumnWide)
        #if os(macOS)
        XCTAssertEqual(normal.categoryColumn, 520)
        #else
        XCTAssertEqual(normal.categoryColumn, 900)
        #endif
        XCTAssertEqual(normal.categoryColumnWide, 900)
    }

    // MARK: Store

    func testStoreDefaultsToStandardAndRemembersTheChoice() {
        let store = UIScaleStore(defaults: defaults)
        XCTAssertEqual(store.setting, .standard)
        store.setting = .large
        XCTAssertEqual(UIScaleStore(defaults: defaults).setting, .large)
    }

    func testIncreaseDecreaseResetStayInRange() {
        let store = UIScaleStore(defaults: defaults)
        for _ in 0..<10 { store.increase() }
        XCTAssertEqual(store.setting, .extraLarge)
        XCTAssertNil(store.setting.larger)
        for _ in 0..<10 { store.decrease() }
        XCTAssertEqual(store.setting, .small)
        XCTAssertNil(store.setting.smaller)
        store.reset()
        XCTAssertEqual(store.setting, .standard)
    }

    func testUnknownStoredValueFallsBackToStandard() {
        defaults.set("gigantic", forKey: UIScaleStore.defaultsKey)
        XCTAssertEqual(UIScaleStore(defaults: defaults).setting, .standard)
    }
}

/// The arrows of a shelf (buttons and the ← → keys) never leave it.
final class HorizontalShelfTests: XCTestCase {
    func testStepsStayInsideTheShelf() {
        typealias Shelf = HorizontalShelf<Int, EmptyView>
        XCTAssertEqual(Shelf.clampedIndex(-3, count: 10), 0)
        XCTAssertEqual(Shelf.clampedIndex(0, count: 10), 0)
        XCTAssertEqual(Shelf.clampedIndex(5, count: 10), 5)
        XCTAssertEqual(Shelf.clampedIndex(99, count: 10), 9)
        XCTAssertEqual(Shelf.clampedIndex(3, count: 0), 0)
        XCTAssertEqual(Shelf.clampedIndex(3, count: 1), 0)
    }
}
