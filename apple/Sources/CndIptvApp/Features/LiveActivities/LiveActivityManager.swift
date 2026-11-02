import Foundation
#if canImport(ActivityKit) && !os(macOS) && !os(tvOS)
import ActivityKit
#endif

/// Manages ActivityKit Live Activities & Dynamic Island for iOS/iPadOS.
/// Complies with PRD-22 SLA:
/// - Activity started < 1s after recording starts.
/// - Updates throttled to at most once every 60 seconds (battery conservation).
/// - No credentials or stream URLs leaked into ContentState.
@Observable
@MainActor
public final class LiveActivityManager {
    public static let shared = LiveActivityManager()

    /// User settings for Live Activities.
    public var isRecordingActivityEnabled: Bool {
        didSet { UserDefaults.standard.set(isRecordingActivityEnabled, forKey: "liveactivity.recording.enabled") }
    }
    public var isPlaybackActivityEnabled: Bool {
        didSet { UserDefaults.standard.set(isPlaybackActivityEnabled, forKey: "liveactivity.playback.enabled") }
    }

    /// Minimum time between updates in seconds (SLA: 60 seconds).
    public let minUpdateInterval: TimeInterval = 60.0

    @ObservationIgnored
    private var lastRecordingUpdate: [Int64: Date] = [:]

    #if canImport(ActivityKit) && !os(macOS) && !os(tvOS)
    @ObservationIgnored
    private var activeRecordingActivities: [Int64: Activity<RecordingActivityAttributes>] = [:]

    @ObservationIgnored
    private var activePlaybackActivity: Activity<PlaybackActivityAttributes>?
    #endif

    public init() {
        self.isRecordingActivityEnabled = UserDefaults.standard.object(forKey: "liveactivity.recording.enabled") != nil
            ? UserDefaults.standard.bool(forKey: "liveactivity.recording.enabled")
            : true
        self.isPlaybackActivityEnabled = UserDefaults.standard.object(forKey: "liveactivity.playback.enabled") != nil
            ? UserDefaults.standard.bool(forKey: "liveactivity.playback.enabled")
            : true
    }

    // MARK: - Recording Activities

    public func startRecordingActivity(id: Int64, channelName: String, programTitle: String, totalSeconds: Int) {
        #if canImport(ActivityKit) && !os(macOS) && !os(tvOS)
        guard isRecordingActivityEnabled, ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let attributes = RecordingActivityAttributes(
            recordingId: id,
            channelName: channelName,
            programTitle: programTitle
        )
        let state = RecordingActivityAttributes.ContentState(
            progress: 0.0,
            elapsedSeconds: 0,
            remainingSeconds: totalSeconds
        )

        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: nil)
            )
            activeRecordingActivities[id] = activity
            lastRecordingUpdate[id] = Date()
        } catch {
            // ActivityKit may be disabled or restricted by user settings
        }
        #endif
    }

    public func updateRecordingActivity(id: Int64, elapsedSeconds: Int, totalSeconds: Int, fileSizeBytes: Int64 = 0) {
        #if canImport(ActivityKit) && !os(macOS) && !os(tvOS)
        guard isRecordingActivityEnabled else { return }
        guard let activity = activeRecordingActivities[id] else { return }

        // Throttle updates to at most once per 60 seconds (PRD-22 SLA)
        if let last = lastRecordingUpdate[id], Date().timeIntervalSince(last) < minUpdateInterval {
            return
        }

        let progress = totalSeconds > 0 ? min(Double(elapsedSeconds) / Double(totalSeconds), 1.0) : 0.0
        let remaining = max(totalSeconds - elapsedSeconds, 0)
        let state = RecordingActivityAttributes.ContentState(
            progress: progress,
            elapsedSeconds: elapsedSeconds,
            remainingSeconds: remaining,
            fileSizeBytes: fileSizeBytes
        )

        Task {
            await activity.update(ActivityContent<RecordingActivityAttributes.ContentState>(state: state, staleDate: nil))
        }
        lastRecordingUpdate[id] = Date()
        #endif
    }

    public func endRecordingActivity(id: Int64) {
        #if canImport(ActivityKit) && !os(macOS) && !os(tvOS)
        guard let activity = activeRecordingActivities.removeValue(forKey: id) else { return }
        lastRecordingUpdate.removeValue(forKey: id)

        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        #endif
    }

    // MARK: - Playback Activities

    public func startPlaybackActivity(channelName: String, programTitle: String, durationSeconds: Int) {
        #if canImport(ActivityKit) && !os(macOS) && !os(tvOS)
        guard isPlaybackActivityEnabled, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        endPlaybackActivity()

        let attributes = PlaybackActivityAttributes(channelName: channelName)
        let state = PlaybackActivityAttributes.ContentState(
            programTitle: programTitle,
            positionSeconds: 0,
            durationSeconds: durationSeconds
        )

        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: nil)
            )
            activePlaybackActivity = activity
        } catch {
            // Activity request could be rejected or disabled
        }
        #endif
    }

    public func endPlaybackActivity() {
        #if canImport(ActivityKit) && !os(macOS) && !os(tvOS)
        guard let activity = activePlaybackActivity else { return }
        activePlaybackActivity = nil
        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        #endif
    }
}
