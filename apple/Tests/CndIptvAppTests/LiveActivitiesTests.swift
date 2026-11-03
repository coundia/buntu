import Testing
import Foundation
@testable import CndIptvKit

@Suite("Live Activities & visionOS Tests (PRD-22)")
struct LiveActivitiesTests {

    #if canImport(ActivityKit) && !os(macOS) && !os(tvOS)
    @Test func testRecordingActivityAttributesStructure() {
        let attrs = RecordingActivityAttributes(
            recordingId: 42,
            channelName: "TF1 HD",
            programTitle: "Le Journal de 20h"
        )

        #expect(attrs.recordingId == 42)
        #expect(attrs.channelName == "TF1 HD")
        #expect(attrs.programTitle == "Le Journal de 20h")

        let state = RecordingActivityAttributes.ContentState(
            progress: 0.5,
            elapsedSeconds: 900,
            remainingSeconds: 900,
            fileSizeBytes: 1024 * 1024 * 500
        )

        #expect(state.progress == 0.5)
        #expect(state.elapsedSeconds == 900)
        #expect(state.remainingSeconds == 900)
        #expect(state.fileSizeBytes == 524_288_000)
    }

    @Test func testPlaybackActivityAttributesNoCredentials() {
        let attrs = PlaybackActivityAttributes(
            channelName: "Canal+ Sport",
            logoUrl: "https://example.com/logo.png"
        )

        #expect(attrs.channelName == "Canal+ Sport")
        #expect(attrs.logoUrl == "https://example.com/logo.png")

        let state = PlaybackActivityAttributes.ContentState(
            programTitle: "Grand Prix F1",
            positionSeconds: 1200,
            durationSeconds: 5400
        )

        #expect(state.programTitle == "Grand Prix F1")
        #expect(state.positionSeconds == 1200)
        #expect(state.durationSeconds == 5400)
    }
    #endif

    @Test @MainActor func testLiveActivityManagerSettings() {
        let manager = LiveActivityManager.shared

        manager.isRecordingActivityEnabled = true
        #expect(manager.isRecordingActivityEnabled == true)

        manager.isPlaybackActivityEnabled = false
        #expect(manager.isPlaybackActivityEnabled == false)

        #expect(manager.minUpdateInterval == 60.0)
    }
}
