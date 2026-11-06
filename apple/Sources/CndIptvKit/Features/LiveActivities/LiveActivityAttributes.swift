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
        /// When the recording ends: the widget counts down to it on its own, with no update per second.
        public var endsAt: Date

        public init(progress: Double, elapsedSeconds: Int, remainingSeconds: Int, fileSizeBytes: Int64 = 0, endsAt: Date = Date()) {
            self.progress = progress
            self.elapsedSeconds = elapsedSeconds
            self.remainingSeconds = remainingSeconds
            self.fileSizeBytes = fileSizeBytes
            self.endsAt = endsAt
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

// MARK: - Download Activity Attributes

public struct DownloadActivityAttributes: ActivityAttributes, Sendable {
    public struct ContentState: Codable, Hashable, Sendable {
        public var progress: Double
        public var downloadedBytes: Int64
        public var totalBytes: Int64
        public var speedBps: Double
        public var remainingTasksCount: Int

        public init(
            progress: Double,
            downloadedBytes: Int64,
            totalBytes: Int64,
            speedBps: Double = 0,
            remainingTasksCount: Int = 0
        ) {
            self.progress = progress
            self.downloadedBytes = downloadedBytes
            self.totalBytes = totalBytes
            self.speedBps = speedBps
            self.remainingTasksCount = remainingTasksCount
        }
    }

    public let primaryTitle: String

    public init(primaryTitle: String) {
        self.primaryTitle = primaryTitle
    }
}
#endif
