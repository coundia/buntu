#if os(macOS)
import XCTest
@testable import CndIptvKit

/// PRD 29: the "always on top" rule and its controller, without a real window.
@MainActor
final class WindowLevelTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""
    private var applied: [(floating: Bool, allSpaces: Bool)] = []

    override func setUp() async throws {
        suite = "cnd.window.tests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)
        applied = []
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func controller() -> WindowLevelController {
        let level = WindowLevelController(defaults: defaults, observesWindows: false)
        level.windowApplier = { [unowned self] floating, allSpaces in applied.append((floating, allSpaces)) }
        return level
    }

    // MARK: Policy

    func testPolicyForEveryMode() {
        typealias P = AlwaysOnTopPolicy
        XCTAssertFalse(P.shouldFloat(mode: .never, hasMedia: true, isFullscreen: false))
        XCTAssertTrue(P.shouldFloat(mode: .always, hasMedia: false, isFullscreen: false))
        XCTAssertFalse(P.shouldFloat(mode: .whilePlaying, hasMedia: false, isFullscreen: false))
        XCTAssertTrue(P.shouldFloat(mode: .whilePlaying, hasMedia: true, isFullscreen: false))
    }

    func testFullScreenNeverFloats() {
        for mode in AlwaysOnTopMode.allCases {
            XCTAssertFalse(AlwaysOnTopPolicy.shouldFloat(mode: mode, hasMedia: true, isFullscreen: true), "\(mode)")
        }
    }

    // MARK: Controller

    func testDefaultsToNever() {
        let level = controller()
        XCTAssertEqual(level.mode, .never)
        XCTAssertFalse(level.isFloating)
        XCTAssertFalse(level.showsOnAllSpaces)
    }

    func testWhilePlayingFloatsWithAMediaAndStopsWhenItIsClosed() {
        let level = controller()
        level.mode = .whilePlaying
        XCTAssertEqual(applied.last?.floating, false)
        level.hasMedia = true
        XCTAssertEqual(applied.last?.floating, true)
        level.hasMedia = false
        XCTAssertEqual(applied.last?.floating, false)
    }

    func testLevelIsRestoredAfterLeavingFullScreen() {
        let level = controller()
        level.mode = .always
        level.setFullscreen(true)
        XCTAssertEqual(applied.last?.floating, false)
        level.setFullscreen(false)
        XCTAssertEqual(applied.last?.floating, true)
    }

    func testToggleSwitchesBetweenNeverAndAlways() {
        let level = controller()
        level.toggle()
        XCTAssertEqual(level.mode, .always)
        level.toggle()
        XCTAssertEqual(level.mode, .never)
    }

    func testToggleTurnsOffAFloatingWhilePlayingMode() {
        let level = controller()
        level.mode = .whilePlaying
        level.hasMedia = true
        level.toggle()
        XCTAssertEqual(level.mode, .never)
        XCTAssertFalse(level.isFloating)
    }

    func testAllSpacesFlagIsPassedAlong() {
        let level = controller()
        level.mode = .always
        level.showsOnAllSpaces = true
        XCTAssertEqual(applied.last?.allSpaces, true)
    }

    func testModeAndAllSpacesArePersisted() {
        let first = controller()
        first.mode = .whilePlaying
        first.showsOnAllSpaces = true
        let second = WindowLevelController(defaults: defaults, observesWindows: false)
        XCTAssertEqual(second.mode, .whilePlaying)
        XCTAssertTrue(second.showsOnAllSpaces)
    }

    func testUnchangedValuesDoNotReapply() {
        let level = controller()
        level.mode = .always
        let count = applied.count
        level.mode = .always
        level.hasMedia = false
        level.setFullscreen(false)
        XCTAssertEqual(applied.count, count)
    }

    func testWindowGetsTheFloatingLevelAndNeverMoreThanThat() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        WindowLevelController.apply(to: window, floating: true, allSpaces: true)
        XCTAssertEqual(window.level, .floating)
        XCTAssertLessThanOrEqual(window.level.rawValue, NSWindow.Level.floating.rawValue)
        XCTAssertTrue(window.collectionBehavior.contains(.canJoinAllSpaces))
        // All spaces only applies while floating.
        WindowLevelController.apply(to: window, floating: false, allSpaces: true)
        XCTAssertEqual(window.level, .normal)
        XCTAssertFalse(window.collectionBehavior.contains(.canJoinAllSpaces))
    }

    // MARK: Compact player

    func testCompactNeedsAMediaAndAWindow() {
        let level = controller()
        level.enterCompact()
        XCTAssertFalse(level.isCompact, "nothing to show")
        level.hasMedia = true
        level.setFullscreen(true)
        level.enterCompact()
        XCTAssertFalse(level.isCompact, "not from full screen")
    }

    func testExitingWithoutALayoutIsHarmless() {
        let level = controller()
        level.exitCompact()
        XCTAssertFalse(level.isCompact)
    }

    func testCompactFrameConstants() {
        XCTAssertEqual(WindowLevelController.defaultCompactSize.width / WindowLevelController.defaultCompactSize.height, 16.0 / 9.0, accuracy: 0.001)
        XCTAssertEqual(WindowLevelController.minimumCompactSize.width / WindowLevelController.minimumCompactSize.height, 16.0 / 9.0, accuracy: 0.001)
    }
}
#endif
