import Foundation
#if canImport(ActivityKit) && !os(macOS) && !os(tvOS)
import ActivityKit

// MARK: - Recording Activity Attributes (PVR)

public struct RecordingActivityAttributes: ActivityAttributes, Sendable {
    public struct ContentState: Codable, Hashable, Sendable {
        public var progress: Double
        public var elapsedSeconds: Int
        public var remainingSeconds: Int
        public var fileSizeBytes: Int64

        public init(progress: Double, elapsedSeconds: Int, remainingSeconds: Int, fileSizeBytes: Int64 = 0) {
            self.progress = progress
            self.elapsedSeconds = elapsedSeconds
            self.remainingSeconds = remainingSeconds
            self.fileSizeBytes = fileSizeBytes
        }
    }

    // Static metadata - NO sensitive credentials or URLs
    public let recordingId: Int64
    public let channelName: String
    public let programTitle: String

    public init(recordingId: Int64, channelName: String, programTitle: String) {
        self.recordingId = recordingId
        self.channelName = channelName
        self.programTitle = programTitle
    }
}

// MARK: - Now Playing Activity Attributes

public struct PlaybackActivityAttributes: ActivityAttributes, Sendable {
    public struct ContentState: Codable, Hashable, Sendable {
        public var programTitle: String
        public var positionSeconds: Int
        public var durationSeconds: Int

        public init(programTitle: String, positionSeconds: Int, durationSeconds: Int) {
            self.programTitle = programTitle
            self.positionSeconds = positionSeconds
            self.durationSeconds = durationSeconds
        }
    }

    public let channelName: String
    public let logoUrl: String?

    public init(channelName: String, logoUrl: String? = nil) {
        self.channelName = channelName
        self.logoUrl = logoUrl
    }
}
#endif
