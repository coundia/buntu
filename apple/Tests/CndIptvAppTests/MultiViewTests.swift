import XCTest
import CoreGraphics
import CndCoreBridge
@testable import CndIptvKit

@MainActor
final class MultiViewTests: XCTestCase {

    // MARK: - MultiViewLayout Tests

    func testSingleTileFillsContainer() {
        let size = CGSize(width: 1920, height: 1080)
        let frames = MultiViewLayout.calculateFrames(count: 1, in: size)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0], CGRect(origin: .zero, size: size))
    }

    func testTwoTilesLandscapeSideBySide() {
        let size = CGSize(width: 1920, height: 1080)
        let gutter: CGFloat = 4
        let frames = MultiViewLayout.calculateFrames(count: 2, in: size, layout: .sideBySide, gutter: gutter)
        XCTAssertEqual(frames.count, 2)

        let expectedWidth = (1920 - gutter) / 2
        XCTAssertEqual(frames[0].origin.x, 0)
        XCTAssertEqual(frames[0].width, expectedWidth)
        XCTAssertEqual(frames[0].height, 1080)

        XCTAssertEqual(frames[1].origin.x, expectedWidth + gutter)
        XCTAssertEqual(frames[1].width, expectedWidth)
        XCTAssertEqual(frames[1].height, 1080)
    }

    func testTwoTilesPortraitStacked() {
        let size = CGSize(width: 1080, height: 1920)
        let gutter: CGFloat = 6
        let frames = MultiViewLayout.calculateFrames(count: 2, in: size, layout: .sideBySide, gutter: gutter)
        XCTAssertEqual(frames.count, 2)

        let expectedHeight = (1920 - gutter) / 2
        XCTAssertEqual(frames[0].origin.y, 0)
        XCTAssertEqual(frames[0].height, expectedHeight)
        XCTAssertEqual(frames[0].width, 1080)

        XCTAssertEqual(frames[1].origin.y, expectedHeight + gutter)
        XCTAssertEqual(frames[1].height, expectedHeight)
        XCTAssertEqual(frames[1].width, 1080)
    }

    func testFourTilesGrid2x2() {
        let size = CGSize(width: 1920, height: 1080)
        let gutter: CGFloat = 4
        let frames = MultiViewLayout.calculateFrames(count: 4, in: size, layout: .grid2x2, gutter: gutter)
        XCTAssertEqual(frames.count, 4)

        let colWidth = (1920 - gutter) / 2
        let rowHeight = (1080 - gutter) / 2

        XCTAssertEqual(frames[0], CGRect(x: 0, y: 0, width: colWidth, height: rowHeight))
        XCTAssertEqual(frames[1], CGRect(x: colWidth + gutter, y: 0, width: colWidth, height: rowHeight))
        XCTAssertEqual(frames[2], CGRect(x: 0, y: rowHeight + gutter, width: colWidth, height: rowHeight))
        XCTAssertEqual(frames[3], CGRect(x: colWidth + gutter, y: rowHeight + gutter, width: colWidth, height: rowHeight))
    }

    func testFourTilesOnePlusThreeFocus() {
        let size = CGSize(width: 1920, height: 1080)
        let gutter: CGFloat = 4
        let frames = MultiViewLayout.calculateFrames(count: 4, in: size, layout: .onePlusThree, activeTileIndex: 0, gutter: gutter)
        XCTAssertEqual(frames.count, 4)

        let mainFrame = frames[0]
        XCTAssertTrue(mainFrame.width > 1000, "Main active tile takes majority of screen width")
        XCTAssertEqual(mainFrame.height, 1080)

        // Other 3 tiles must be stacked vertically
        XCTAssertEqual(frames[1].origin.x, mainFrame.maxX + gutter)
        XCTAssertEqual(frames[2].origin.x, mainFrame.maxX + gutter)
        XCTAssertEqual(frames[3].origin.x, mainFrame.maxX + gutter)
        XCTAssertTrue(frames[1].origin.y < frames[2].origin.y)
        XCTAssertTrue(frames[2].origin.y < frames[3].origin.y)
    }

    // MARK: - MultiViewController Tests

    private func makeItem(id: Int64, name: String, sourceId: Int64 = 1) -> IptvItemRecord {
        IptvItemRecord(
            id: id,
            sourceId: sourceId,
            seriesId: nil,
            stableHash: "hash_\(id)",
            kind: "live",
            seasonNum: nil,
            episodeNum: nil,
            name: name,
            nameClean: name.lowercased(),
            year: nil,
            groupTitle: "General",
            tvgId: "ch\(id)",
            logoUrl: nil,
            chno: UInt32(id),
            host: "server.io",
            containerExt: "ts",
            streamUrl: "http://server.io/live/ch\(id).ts",
            userAgent: nil,
            referer: nil,
            headersJson: nil,
            catchupType: nil,
            catchupSource: nil,
            catchupDays: nil,
            plot: nil,
            imdbId: nil,
            imdbRating: nil,
            isFavorite: false,
            isBroken: false,
            resumePositionMs: 0,
            durationMs: 0,
            isCompleted: false
        )
    }

    func testAddChannelsAndAudioExclusivity() {
        let controller = MultiViewController()
        let ch1 = makeItem(id: 1, name: "TF1")
        let ch2 = makeItem(id: 2, name: "France 2")
        let ch3 = makeItem(id: 3, name: "M6")

        XCTAssertTrue(controller.addChannel(ch1))
        XCTAssertEqual(controller.count, 1)
        XCTAssertEqual(controller.activeIndex, 0)
        XCTAssertFalse(controller.slots[0].controller.isMuted, "First channel should be unmuted")

        XCTAssertTrue(controller.addChannel(ch2))
        XCTAssertEqual(controller.count, 2)
        XCTAssertFalse(controller.slots[0].controller.isMuted, "Slot 0 remains unmuted")
        XCTAssertTrue(controller.slots[1].controller.isMuted, "Newly added slot 1 is muted")

        XCTAssertTrue(controller.addChannel(ch3))
        XCTAssertEqual(controller.count, 3)
        XCTAssertTrue(controller.slots[2].controller.isMuted)

        // Change active tile to slot 1
        controller.setActiveIndex(1)
        XCTAssertEqual(controller.activeIndex, 1)
        XCTAssertTrue(controller.slots[0].controller.isMuted, "Slot 0 now muted")
        XCTAssertFalse(controller.slots[1].controller.isMuted, "Slot 1 now unmuted")
        XCTAssertTrue(controller.slots[2].controller.isMuted, "Slot 2 remains muted")

        controller.closeAll()
    }

    func testMaxConnectionsGuardrail() {
        let controller = MultiViewController()
        let source = IptvSourceRecord(
            id: 1,
            uuid: "src_1",
            name: "Limited IPTV",
            sourceType: "xtream",
            url: nil,
            server: "http://limited.io",
            username: "u",
            passwordRef: "p",
            epgUrl: nil,
            expDate: nil,
            maxConnections: 2,
            activeCons: 0,
            accountStatus: "Active",
            itemCount: 100,
            updatedAt: 0
        )

        let ch1 = makeItem(id: 1, name: "Channel 1", sourceId: 1)
        let ch2 = makeItem(id: 2, name: "Channel 2", sourceId: 1)
        let ch3 = makeItem(id: 3, name: "Channel 3", sourceId: 1)

        XCTAssertTrue(controller.addChannel(ch1, sources: [source]))
        XCTAssertTrue(controller.addChannel(ch2, sources: [source]))

        // Third channel from same source exceeds maxConnections (2)
        let (allowed, reason) = controller.canAdd(channel: ch3, sources: [source])
        XCTAssertFalse(allowed)
        XCTAssertTrue(reason?.contains("autorise 2 connexion(s)") == true)

        let added = controller.addChannel(ch3, sources: [source])
        XCTAssertFalse(added)
        XCTAssertEqual(controller.count, 2)

        controller.closeAll()
    }

    func testRemoveSlotAndPopToSinglePlayer() {
        let controller = MultiViewController()
        let ch1 = makeItem(id: 1, name: "Channel 1")
        let ch2 = makeItem(id: 2, name: "Channel 2")
        let ch3 = makeItem(id: 3, name: "Channel 3")

        controller.addChannel(ch1)
        controller.addChannel(ch2)
        controller.addChannel(ch3)
        controller.setActiveIndex(2)

        // Remove active slot (slot 2)
        controller.removeSlot(at: 2)
        XCTAssertEqual(controller.count, 2)
        XCTAssertEqual(controller.activeIndex, 1, "Active index adjusts to last remaining slot")
        XCTAssertFalse(controller.slots[1].controller.isMuted, "New active slot becomes unmuted")

        // Pop active to single player
        let popped = controller.popActiveToSinglePlayer()
        XCTAssertEqual(popped?.id, ch2.id)
        XCTAssertEqual(controller.count, 0)
        XCTAssertFalse(controller.isPresented)
    }

    func testSwapSlots() {
        let controller = MultiViewController()
        let ch1 = makeItem(id: 1, name: "Channel 1")
        let ch2 = makeItem(id: 2, name: "Channel 2")

        controller.addChannel(ch1)
        controller.addChannel(ch2)
        controller.setActiveIndex(0)

        controller.swapSlots(from: 0, to: 1)
        XCTAssertEqual(controller.slots[0].channel.id, ch2.id)
        XCTAssertEqual(controller.slots[1].channel.id, ch1.id)
        XCTAssertEqual(controller.activeIndex, 1, "Active index follows the swapped channel")

        controller.closeAll()
    }
}
