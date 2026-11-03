import XCTest
import CndCoreBridge
@testable import CndIptvKit

final class LiveActivityPlannerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func recording(_ id: Int64, state: String = "recording", start: Int64 = 999_000, end: Int64 = 1_003_000) -> RecordingRecord {
        RecordingRecord(
            id: id, itemId: 1, channelTvgId: nil, channelName: "TF1", title: "Journal", subtitle: nil,
            streamUrl: "http://srv/live/u/p/1.ts", startTs: start, endTs: end, prePaddingS: 0, postPaddingS: 0,
            state: state, filePath: nil, bytesWritten: 0, ruleId: nil, error: nil, createdAt: 0
        )
    }

    func testARunningRecordingStartsOnceThenIsUpdatedAtMostEveryMinute() {
        let list = [recording(1)]
        XCTAssertEqual(RecordingActivityPlanner.plan(recordings: list, active: [], lastUpdate: [:], now: now).start, [1])

        let started = RecordingActivityPlanner.plan(recordings: list, active: [1], lastUpdate: [1: now], now: now.addingTimeInterval(30))
        XCTAssertEqual(started, .init(), "30 s after the last update: nothing")

        let later = RecordingActivityPlanner.plan(recordings: list, active: [1], lastUpdate: [1: now], now: now.addingTimeInterval(60))
        XCTAssertEqual(later.update, [1])
        XCTAssertTrue(later.start.isEmpty)
    }

    func testFinishedOrCancelledRecordingsEndTheirActivity() {
        let list = [recording(1, state: "completed"), recording(2, state: "scheduled"), recording(3)]
        let plan = RecordingActivityPlanner.plan(recordings: list, active: [1, 2, 3, 4], lastUpdate: [3: now], now: now)
        XCTAssertEqual(plan.end, [1, 2, 4], "everything no longer recording, including one that vanished from the list")
        XCTAssertTrue(plan.start.isEmpty)
    }

    func testScheduledRecordingsDoNotStartAnActivity() {
        let plan = RecordingActivityPlanner.plan(recordings: [recording(1, state: "scheduled")], active: [], lastUpdate: [:], now: now)
        XCTAssertEqual(plan, .init())
    }

    func testProgress() {
        // 4000 s long, 1000 s elapsed.
        let p = RecordingActivityPlanner.progress(of: recording(1), now: now)
        XCTAssertEqual(p.elapsedSeconds, 1000)
        XCTAssertEqual(p.remainingSeconds, 3000)
        XCTAssertEqual(p.progress, 1000.0 / 4000.0, accuracy: 0.0001)
        XCTAssertEqual(p.endsAt, Date(timeIntervalSince1970: 1_003_000))
    }

    func testProgressIsClampedBeforeStartAndAfterEnd() {
        let before = RecordingActivityPlanner.progress(of: recording(1, start: 1_001_000, end: 1_002_000), now: now)
        XCTAssertEqual(before.elapsedSeconds, 0)
        XCTAssertEqual(before.progress, 0)
        let after = RecordingActivityPlanner.progress(of: recording(1, start: 990_000, end: 995_000), now: now)
        XCTAssertEqual(after.remainingSeconds, 0)
        XCTAssertEqual(after.progress, 1)
    }

    /// No stream address or credential may reach the activity (PRD 22 guardrail).
    func testTheActivityAttributesCarryNoAddress() throws {
        #if canImport(ActivityKit) && !os(macOS) && !os(tvOS)
        let json = try JSONEncoder().encode(RecordingActivityAttributes(recordingId: 1, channelName: "TF1", programTitle: "Journal"))
        let text = String(decoding: json, as: UTF8.self)
        XCTAssertFalse(text.contains("http"))
        #endif
    }
}
