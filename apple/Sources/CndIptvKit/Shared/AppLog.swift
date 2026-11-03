import Foundation
import CndCoreBridge

/// Log of the Swift side of the app (player, sync, ...), shown in the same console as the engine's
/// network log. Entries use the engine's record type; their sequence ids start at `seqBase` so they
/// never collide with the engine's own counter.
final class AppLog: @unchecked Sendable {
    static let shared = AppLog()
    static let seqBase: UInt64 = 1 << 40
    static let capacity = 500

    private let lock = NSLock()
    private var storage: [NetworkLogEntry] = []
    private var counter: UInt64 = 0

    func record(_ level: LogLevel, _ category: String, _ message: String) {
        lock.withLock {
            counter += 1
            storage.append(NetworkLogEntry(
                seqId: Self.seqBase + counter,
                timestampMs: Int64(Date().timeIntervalSince1970 * 1000),
                level: level, category: category, method: nil, urlRedacted: nil,
                statusCode: nil, durationMs: nil, message: message
            ))
            if storage.count > Self.capacity { storage.removeFirst(storage.count - Self.capacity) }
        }
    }

    func info(_ category: String, _ message: String) { record(.info, category, message) }
    func warn(_ category: String, _ message: String) { record(.warn, category, message) }
    func error(_ category: String, _ message: String) { record(.error, category, message) }

    func entries(after seqId: UInt64) -> [NetworkLogEntry] {
        lock.withLock { storage.filter { $0.seqId > seqId } }
    }

    func clear() {
        lock.withLock { storage.removeAll() }
    }

    /// `host` and extension only: stream URLs often embed the account name and password in their path.
    static func describe(_ url: URL) -> String {
        let host = url.host ?? "?"
        let ext = url.pathExtension.isEmpty ? "sans extension" : ".\(url.pathExtension.lowercased())"
        return "\(host), \(ext)"
    }
}
