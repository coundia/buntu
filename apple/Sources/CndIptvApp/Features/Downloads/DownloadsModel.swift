import Foundation
import Observation
import CoreGraphics
import CndCoreBridge

/// The slice of `CndEngine` the downloads screen uses; lets tests script task states.
protocol DownloadsBackend: AnyObject, Sendable {
    func listDownloads(query: String?) throws -> [DownloadTaskRecord]
    func enqueueDownload(req: NewDownloadRequest) async throws -> Int64
    func startDownload(taskId: Int64) async throws
    func pauseDownload(taskId: Int64) async throws
    func retryDownload(taskId: Int64) async throws
    func removeDownload(taskId: Int64, deleteFiles: Bool) async throws
    func startAllDownloads() async throws
    func pauseAllDownloads() async throws
    func getDownloadLogs(taskId: Int64, limit: UInt32) throws -> [DownloadLogRecord]
}

extension CndEngine: DownloadsBackend {}

enum DownloadStateFilter: String, CaseIterable, Identifiable {
    case all
    case active
    case paused
    case completed
    case error

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "Tous"
        case .active: return "En cours"
        case .paused: return "En pause"
        case .completed: return "Terminés"
        case .error: return "Erreurs"
        }
    }

    func matches(_ state: String) -> Bool {
        switch self {
        case .all: return true
        case .active: return DownloadsModel.isActive(state)
        case .paused: return state == "paused"
        case .completed: return state == "completed"
        case .error: return state == "error"
        }
    }
}

struct DownloadStats: Equatable {
    var total = 0
    var running = 0
    var queued = 0
    var paused = 0
    var completed = 0
    var errors = 0
    /// Summed throughput of running tasks, bytes per second.
    var speedBps: Double = 0
}

@Observable
@MainActor
final class DownloadsModel {
    let backend: DownloadsBackend
    let pollInterval: Duration

    private(set) var tasks: [DownloadTaskRecord] = []
    private(set) var isPolling = false
    /// Number of refreshes made by the polling loop (tests assert it stops growing at rest).
    private(set) var pollCount = 0
    private(set) var errorMessage: String?
    var query = ""
    var stateFilter: DownloadStateFilter = .all

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var pollGeneration = 0

    init(backend: DownloadsBackend, pollInterval: Duration = .milliseconds(250)) {
        self.backend = backend
        self.pollInterval = pollInterval
    }

    nonisolated static func isActive(_ state: String) -> Bool {
        state == "running" || state == "queued"
    }

    var hasActive: Bool { tasks.contains { Self.isActive($0.state) } }

    var stats: DownloadStats {
        var stats = DownloadStats(total: tasks.count)
        for task in tasks {
            switch task.state {
            case "running":
                stats.running += 1
                stats.speedBps += task.speedBps
            case "queued": stats.queued += 1
            case "paused": stats.paused += 1
            case "completed": stats.completed += 1
            case "error": stats.errors += 1
            default: break
            }
        }
        return stats
    }

    var visibleTasks: [DownloadTaskRecord] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return tasks.filter { task in
            stateFilter.matches(task.state)
                && (needle.isEmpty || task.fileName.localizedCaseInsensitiveContains(needle))
        }
    }

    // MARK: Polling

    func refresh() async {
        let backend = self.backend
        do {
            tasks = try await Task.detached(priority: .userInitiated) { try backend.listDownloads(query: nil) }.value
        } catch {
            errorMessage = userMessage(for: error)
        }
    }

    /// Refreshes at `pollInterval` only while a task is running or queued, then ends: no timer
    /// is left behind once everything is idle.
    func ensurePolling() {
        guard pollTask == nil else { return }
        pollGeneration += 1
        let generation = pollGeneration
        isPolling = true
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                self.pollCount += 1
                if !self.hasActive { break }
                try? await Task.sleep(for: self.pollInterval)
            }
            self?.finishPolling(generation)
        }
    }

    private func finishPolling(_ generation: Int) {
        guard generation == pollGeneration else { return }
        pollTask = nil
        isPolling = false
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        pollGeneration += 1
        isPolling = false
    }

    // MARK: Actions

    private func perform(_ operation: @escaping () async throws -> Void) async {
        errorMessage = nil
        do {
            try await operation()
        } catch {
            errorMessage = userMessage(for: error)
        }
        await refresh()
        if hasActive { ensurePolling() }
    }

    func start(_ task: DownloadTaskRecord) async { let b = backend; await perform { try await b.startDownload(taskId: task.id) } }
    func pause(_ task: DownloadTaskRecord) async { let b = backend; await perform { try await b.pauseDownload(taskId: task.id) } }
    func retry(_ task: DownloadTaskRecord) async { let b = backend; await perform { try await b.retryDownload(taskId: task.id) } }
    func startAll() async { let b = backend; await perform { try await b.startAllDownloads() } }
    func pauseAll() async { let b = backend; await perform { try await b.pauseAllDownloads() } }

    func remove(_ task: DownloadTaskRecord, deleteFile: Bool) async {
        let b = backend
        await perform { try await b.removeDownload(taskId: task.id, deleteFiles: deleteFile) }
    }

    func retryErrors() async {
        let failed = tasks.filter { $0.state == "error" }
        let b = backend
        await perform { for task in failed { try await b.retryDownload(taskId: task.id) } }
    }

    @discardableResult
    func enqueue(_ requests: [NewDownloadRequest]) async -> Int {
        var queued = 0
        var failure: String?
        for request in requests {
            do {
                _ = try await backend.enqueueDownload(req: request)
                queued += 1
            } catch {
                failure = userMessage(for: error)
            }
        }
        errorMessage = failure
        await refresh()
        if hasActive { ensurePolling() }
        return queued
    }

    func logs(for task: DownloadTaskRecord, limit: UInt32 = 500) async -> [DownloadLogRecord] {
        let backend = self.backend
        let id = task.id
        return (try? await Task.detached(priority: .userInitiated) { try backend.getDownloadLogs(taskId: id, limit: limit) }.value) ?? []
    }
}

// MARK: - Presentation helpers

enum DownloadFormat {
    static func percent(_ task: DownloadTaskRecord) -> Double? {
        guard task.totalBytes > 0 else { return nil }
        return min(Double(task.downloadedBytes) / Double(task.totalBytes), 1)
    }

    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }

    /// `45 s`, `2 min 05 s`, `1 h 03 min`.
    static func eta(seconds: UInt64) -> String {
        if seconds < 60 { return "\(seconds) s" }
        if seconds < 3600 { return String(format: "%d min %02d s", seconds / 60, seconds % 60) }
        return String(format: "%d h %02d min", seconds / 3600, (seconds % 3600) / 60)
    }
}

struct SegmentBar: Equatable {
    var x: CGFloat
    var width: CGFloat
    /// Filled fraction, 0...1.
    var fill: Double
}

enum SegmentGeometry {
    /// One bar per parallel segment, as wide as its share of the file, filled by its own progress.
    static func bars(parts: [DownloadPartRecord], width: CGFloat, gap: CGFloat = 2) -> [SegmentBar] {
        func span(_ part: DownloadPartRecord) -> Double {
            part.byteEnd >= part.byteStart ? Double(part.byteEnd - part.byteStart) + 1 : 0
        }
        let ordered = parts.sorted { $0.partIndex < $1.partIndex }
        let total = ordered.reduce(0) { $0 + span($1) }
        guard total > 0, width > 0 else { return [] }
        let usable = max(width - gap * CGFloat(ordered.count - 1), 0)
        var x: CGFloat = 0
        return ordered.map { part in
            let size = span(part)
            let barWidth = usable * CGFloat(size / total)
            defer { x += barWidth + gap }
            return SegmentBar(x: x, width: barWidth, fill: size > 0 ? min(Double(part.downloadedBytes) / size, 1) : 0)
        }
    }
}

enum AddUrlsParser {
    /// Splits a pasted block into valid HTTP(S) URLs (deduplicated, order kept) and rejected lines.
    static func parse(_ text: String) -> (valid: [URL], invalid: [String]) {
        var valid: [URL] = []
        var invalid: [String] = []
        var seen = Set<String>()
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https", url.host?.isEmpty == false else {
                invalid.append(trimmed)
                continue
            }
            if seen.insert(url.absoluteString).inserted { valid.append(url) }
        }
        return (valid, invalid)
    }
}
