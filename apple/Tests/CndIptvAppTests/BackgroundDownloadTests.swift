import XCTest
@testable import CndIptvKit

@MainActor
final class BackgroundDownloadTests: XCTestCase {

    func testSystemPowerCoordinatorInitialState() {
        let coordinator = SystemPowerCoordinator()
        XCTAssertFalse(coordinator.isDisplaySleepBlocked)
        XCTAssertFalse(coordinator.isSystemSleepBlocked)
        XCTAssertEqual(coordinator.activePlaybackCount, 0)
        XCTAssertEqual(coordinator.activeTransferCount, 0)
    }

    func testSystemPowerCoordinatorPlaybackActivity() {
        let coordinator = SystemPowerCoordinator()
        let id = UUID()

        coordinator.setHolding(true, kind: .videoPlayback, for: id)
        XCTAssertTrue(coordinator.isDisplaySleepBlocked)
        XCTAssertTrue(coordinator.isSystemSleepBlocked)
        XCTAssertEqual(coordinator.activePlaybackCount, 1)

        coordinator.setHolding(false, kind: .videoPlayback, for: id)
        XCTAssertFalse(coordinator.isDisplaySleepBlocked)
        XCTAssertFalse(coordinator.isSystemSleepBlocked)
        XCTAssertEqual(coordinator.activePlaybackCount, 0)
    }

    func testSystemPowerCoordinatorTransferActivityAllowsDisplaySleepOnMac() {
        let coordinator = SystemPowerCoordinator()
        let id = UUID()

        coordinator.setHolding(true, kind: .backgroundTransfer, for: id)
        XCTAssertTrue(coordinator.isSystemSleepBlocked)
        XCTAssertEqual(coordinator.activeTransferCount, 1)

        #if os(macOS)
        // On Mac, background transfer allows the display to turn black
        XCTAssertFalse(coordinator.isDisplaySleepBlocked)
        #endif

        coordinator.setHolding(false, kind: .backgroundTransfer, for: id)
        XCTAssertFalse(coordinator.isSystemSleepBlocked)
        XCTAssertEqual(coordinator.activeTransferCount, 0)
    }

    func testSystemPowerCoordinatorReset() {
        let coordinator = SystemPowerCoordinator()
        let id1 = UUID()
        let id2 = UUID()

        coordinator.setHolding(true, kind: .videoPlayback, for: id1)
        coordinator.setHolding(true, kind: .backgroundTransfer, for: id2)
        XCTAssertTrue(coordinator.isSystemSleepBlocked)

        coordinator.reset()
        XCTAssertFalse(coordinator.isDisplaySleepBlocked)
        XCTAssertFalse(coordinator.isSystemSleepBlocked)
        XCTAssertEqual(coordinator.activePlaybackCount, 0)
        XCTAssertEqual(coordinator.activeTransferCount, 0)
    }

    func testBackgroundDownloadCoordinatorIdentifier() {
        XCTAssertEqual(
            BackgroundDownloadCoordinator.sessionIdentifier,
            "com.pcoundia.buntu.downloads.v1"
        )
    }
}

