import Foundation
import CndCoreBridge
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

    /// Called with the list of recordings (polled by `RecordingsModel`): starts the activity of a
    /// recording that began, refreshes running ones at most once a minute, ends the finished ones.
    public func sync(recordings: [RecordingRecord], now: Date = Date()) {
        #if canImport(ActivityKit) && !os(macOS) && !os(tvOS)
        guard isRecordingActivityEnabled else {
            for id in Array(activeRecordingActivities.keys) { endRecordingActivity(id: id) }
            return
        }
        let plan = RecordingActivityPlanner.plan(
            recordings: recordings, active: Set(activeRecordingActivities.keys), lastUpdate: lastRecordingUpdate, now: now
        )
        let byId = Dictionary(uniqueKeysWithValues: recordings.map { ($0.id, $0) })
        for id in plan.start {
            guard let recording = byId[id] else { continue }
            startRecordingActivity(recording, now: now)
        }
        for id in plan.update {
            guard let recording = byId[id] else { continue }
            updateRecordingActivity(recording, now: now)
        }
        for id in plan.end { endRecordingActivity(id: id) }
        #endif
    }

    #if canImport(ActivityKit) && !os(macOS) && !os(tvOS)
    private func startRecordingActivity(_ recording: RecordingRecord, now: Date) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let progress = RecordingActivityPlanner.progress(of: recording, now: now)
        // Names and times only: never the stream address or credentials.
        let attributes = RecordingActivityAttributes(
            recordingId: recording.id, channelName: recording.channelName, programTitle: recording.title
        )
        let state = RecordingActivityAttributes.ContentState(
            progress: progress.progress, elapsedSeconds: progress.elapsedSeconds,
            remainingSeconds: progress.remainingSeconds, fileSizeBytes: Int64(recording.bytesWritten), endsAt: progress.endsAt
        )
        do {
            let activity = try Activity.request(attributes: attributes, content: .init(state: state, staleDate: progress.endsAt))
            activeRecordingActivities[recording.id] = activity
            lastRecordingUpdate[recording.id] = now
        } catch {
            AppLog.shared.warn("ACTIVITY", "Activité d'enregistrement refusée : \(error.localizedDescription)")
        }
    }

    private func updateRecordingActivity(_ recording: RecordingRecord, now: Date) {
        guard let activity = activeRecordingActivities[recording.id] else { return }
        let progress = RecordingActivityPlanner.progress(of: recording, now: now)
        let state = RecordingActivityAttributes.ContentState(
            progress: progress.progress, elapsedSeconds: progress.elapsedSeconds,
            remainingSeconds: progress.remainingSeconds, fileSizeBytes: Int64(recording.bytesWritten), endsAt: progress.endsAt
        )
        lastRecordingUpdate[recording.id] = now
        Task { await activity.update(ActivityContent(state: state, staleDate: progress.endsAt)) }
    }
    #endif

    public func endRecordingActivity(id: Int64) {
        #if canImport(ActivityKit) && !os(macOS) && !os(tvOS)
        guard let activity = activeRecordingActivities.removeValue(forKey: id) else { return }
        lastRecordingUpdate.removeValue(forKey: id)
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
        #endif
    }

    // MARK: - Playback Activities

    #if canImport(ActivityKit) && !os(macOS) && !os(tvOS)
    @ObservationIgnored private var playbackRefreshTask: Task<Void, Never>?
    #endif

    /// Starts the "now playing" activity. `progress` (position and duration in seconds) is read once a
    /// minute to refresh it while the app runs.
    public func startPlaybackActivity(
        channelName: String,
        programTitle: String,
        durationSeconds: Int,
        progress: (@MainActor () -> (position: Int, duration: Int)?)? = nil
    ) {
        #if canImport(ActivityKit) && !os(macOS) && !os(tvOS)
        guard isPlaybackActivityEnabled, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        endPlaybackActivity()

        let attributes = PlaybackActivityAttributes(channelName: channelName)
        let state = PlaybackActivityAttributes.ContentState(
            programTitle: programTitle, positionSeconds: 0, durationSeconds: durationSeconds
        )
        do {
            let activity = try Activity.request(attributes: attributes, content: .init(state: state, staleDate: nil))
            activePlaybackActivity = activity
        } catch {
            AppLog.shared.warn("ACTIVITY", "Activité de lecture refusée : \(error.localizedDescription)")
            return
        }
        guard let progress else { return }
        playbackRefreshTask = Task { @MainActor [weak self, interval = minUpdateInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled, let activity = self?.activePlaybackActivity, let current = progress() else { continue }
                let updated = PlaybackActivityAttributes.ContentState(
                    programTitle: programTitle, positionSeconds: current.position, durationSeconds: current.duration
                )
                await activity.update(ActivityContent(state: updated, staleDate: nil))
            }
        }
        #endif
    }

    public func endPlaybackActivity() {
        #if canImport(ActivityKit) && !os(macOS) && !os(tvOS)
        playbackRefreshTask?.cancel()
        playbackRefreshTask = nil
        guard let activity = activePlaybackActivity else { return }
        activePlaybackActivity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
        #endif
    }
}
