import Foundation
import CndCoreBridge

/// Decides what to do with the Live Activities of the recordings, from the list the app already polls.
/// Pure, so the rules (start once, update at most once a minute, end when it stops) are testable
/// without ActivityKit.
enum RecordingActivityPlanner {
    struct Plan: Equatable {
        var start: [Int64] = []
        var update: [Int64] = []
        var end: [Int64] = []
    }

    static let minUpdateInterval: TimeInterval = 60

    static func plan(
        recordings: [RecordingRecord],
        active: Set<Int64>,
        lastUpdate: [Int64: Date],
        now: Date,
        minInterval: TimeInterval = minUpdateInterval
    ) -> Plan {
        var plan = Plan()
        let running = recordings.filter { $0.state == "recording" }
        for recording in running {
            if !active.contains(recording.id) {
                plan.start.append(recording.id)
            } else if now.timeIntervalSince(lastUpdate[recording.id] ?? .distantPast) >= minInterval {
                plan.update.append(recording.id)
            }
        }
        let runningIds = Set(running.map(\.id))
        plan.end = active.subtracting(runningIds).sorted()
        return plan
    }

    struct Progress: Equatable {
        var progress: Double
        var elapsedSeconds: Int
        var remainingSeconds: Int
        var endsAt: Date
    }

    static func progress(of recording: RecordingRecord, now: Date) -> Progress {
        let total = max(Int(recording.endTs - recording.startTs), 1)
        let elapsed = min(max(Int(now.timeIntervalSince1970) - Int(recording.startTs), 0), total)
        return Progress(
            progress: Double(elapsed) / Double(total),
            elapsedSeconds: elapsed,
            remainingSeconds: total - elapsed,
            endsAt: Date(timeIntervalSince1970: TimeInterval(recording.endTs))
        )
    }
}
