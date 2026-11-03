import Foundation
#if canImport(ActivityKit) && !os(macOS) && !os(tvOS)
import AppIntents

/// Bridge between the "Arrêter" button of the Live Activity and the app: the intent runs in the app
/// process, which registers what stopping a recording means.
public enum LiveActivityActions {
    nonisolated(unsafe) public static var stopRecording: (@Sendable (Int64) async -> Void)?
}

/// Compiled into the app and into the widget extension (the button needs the type; iOS runs it in the app).
public struct StopRecordingIntent: LiveActivityIntent {
    public static var title: LocalizedStringResource = "Arrêter l'enregistrement"

    @Parameter(title: "Enregistrement")
    public var recordingId: Int

    public init() {}

    public init(recordingId: Int64) {
        self.recordingId = Int(recordingId)
    }

    public func perform() async throws -> some IntentResult {
        await LiveActivityActions.stopRecording?(Int64(recordingId))
        return .result()
    }
}
#endif
