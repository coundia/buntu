import SwiftUI
import WidgetKit
import ActivityKit
import AppIntents

@main
struct CndLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        RecordingLiveActivity()
        PlaybackLiveActivity()
        DownloadLiveActivity()
    }
}

// MARK: - Recording

struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            RecordingLockScreenView(attributes: context.attributes, state: context.state)
                .padding()
                .activityBackgroundTint(Color.black.opacity(0.85))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.channelName, systemImage: "record.circle.fill")
                        .foregroundStyle(.red)
                        .font(.caption.bold())
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: Date()...max(context.state.endsAt, Date()), countsDown: true)
                        .monospacedDigit()
                        .font(.caption.bold())
                        .frame(maxWidth: 70, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.programTitle).font(.subheadline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        ProgressView(value: context.state.progress).tint(.red)
                        Button(intent: StopRecordingIntent(recordingId: context.attributes.recordingId)) {
                            Label("Arrêter", systemImage: "stop.fill").font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }
                }
            } compactLeading: {
                Image(systemName: "record.circle.fill").foregroundStyle(.red)
            } compactTrailing: {
                Text(timerInterval: Date()...max(context.state.endsAt, Date()), countsDown: true)
                    .monospacedDigit()
                    .frame(maxWidth: 48)
            } minimal: {
                Image(systemName: "record.circle.fill").foregroundStyle(.red)
            }
        }
    }
}

struct RecordingLockScreenView: View {
    let attributes: RecordingActivityAttributes
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Enregistrement", systemImage: "record.circle.fill")
                    .foregroundStyle(.red)
                    .font(.caption.bold())
                Spacer()
                Text(timerInterval: Date()...max(state.endsAt, Date()), countsDown: true)
                    .monospacedDigit()
                    .font(.caption.bold())
            }
            Text(attributes.programTitle).font(.headline).lineLimit(1)
            Text(attributes.channelName).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            ProgressView(value: state.progress).tint(.red)
            Button(intent: StopRecordingIntent(recordingId: attributes.recordingId)) {
                Label("Arrêter l'enregistrement", systemImage: "stop.fill")
            }
            .buttonStyle(.bordered)
            .tint(.red)
        }
        .foregroundStyle(.white)
    }
}

// MARK: - Now playing

struct PlaybackLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PlaybackActivityAttributes.self) { context in
            PlaybackLockScreenView(attributes: context.attributes, state: context.state)
                .padding()
                .activityBackgroundTint(Color.black.opacity(0.85))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.channelName, systemImage: "play.tv.fill")
                        .font(.caption.bold())
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.programTitle).font(.subheadline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if context.state.durationSeconds > 0 {
                        ProgressView(value: Double(context.state.positionSeconds), total: Double(context.state.durationSeconds))
                    }
                }
            } compactLeading: {
                Image(systemName: "play.tv.fill")
            } compactTrailing: {
                Text(context.state.programTitle).lineLimit(1).frame(maxWidth: 52)
            } minimal: {
                Image(systemName: "play.tv.fill")
            }
        }
    }
}

struct PlaybackLockScreenView: View {
    let attributes: PlaybackActivityAttributes
    let state: PlaybackActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(attributes.channelName, systemImage: "play.tv.fill").font(.caption.bold())
            Text(state.programTitle).font(.headline).lineLimit(1)
            if state.durationSeconds > 0 {
                ProgressView(value: Double(state.positionSeconds), total: Double(state.durationSeconds))
            }
        }
        .foregroundStyle(.white)
    }
}

// MARK: - Downloads (PRD 36)

struct DownloadLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            DownloadLockScreenView(attributes: context.attributes, state: context.state)
                .padding()
                .activityBackgroundTint(Color.black.opacity(0.85))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.primaryTitle, systemImage: "arrow.down.circle.fill")
                        .foregroundStyle(.blue)
                        .font(.caption.bold())
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(Int(context.state.progress * 100))%")
                        .font(.caption.bold())
                        .monospacedDigit()
                }
                DynamicIslandExpandedRegion(.center) {
                    if context.state.remainingTasksCount > 0 {
                        Text("(+\(context.state.remainingTasksCount) en file)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ProgressView(value: context.state.progress).tint(.blue)
                }
            } compactLeading: {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
            } compactTrailing: {
                Text("\(Int(context.state.progress * 100))%")
                    .font(.caption2.bold())
                    .monospacedDigit()
                    .frame(maxWidth: 42)
            } minimal: {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
            }
        }
    }
}

struct DownloadLockScreenView: View {
    let attributes: DownloadActivityAttributes
    let state: DownloadActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Téléchargement en cours", systemImage: "arrow.down.circle.fill")
                    .foregroundStyle(.blue)
                    .font(.caption.bold())
                Spacer()
                Text("\(Int(state.progress * 100))%")
                    .font(.caption.bold())
                    .monospacedDigit()
            }
            Text(attributes.primaryTitle).font(.headline).lineLimit(1)
            if state.remainingTasksCount > 0 {
                Text("+\(state.remainingTasksCount) autre(s) média(s) en file d'attente")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: state.progress).tint(.blue)
        }
        .foregroundStyle(.white)
    }
}
