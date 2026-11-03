import Foundation
import Observation
import CndCoreBridge

extension RecordingRecord: @retroactive Identifiable {}
extension SeriesRuleRecord: @retroactive Identifiable {}

public protocol RecordingsBackend: AnyObject, Sendable {
    func listRecordings(stateFilter: String?) throws -> [RecordingRecord]
    func scheduleRecording(req: NewRecordingRequest) throws -> Int64
    func recordNow(itemId: Int64, durationMinutes: UInt32) throws -> Int64
    func cancelRecording(id: Int64) throws -> Bool
    func deleteRecording(id: Int64, deleteFile: Bool) throws -> Bool
    func setRecordingDirectory(dir: String)
    func addSeriesRule(channelTvgId: String?, title: String) throws -> Int64
    func removeSeriesRule(id: Int64) throws -> Bool
    func listSeriesRules() throws -> [SeriesRuleRecord]
}

extension CndEngine: RecordingsBackend {}

public enum RecordingFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case recording
    case scheduled
    case completed
    case rules

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: return "Tous"
        case .recording: return "En cours"
        case .scheduled: return "Planifiés"
        case .completed: return "Terminés"
        case .rules: return "Series-Link"
        }
    }
}

@Observable
@MainActor
public final class RecordingsModel {
    private let backend: RecordingsBackend
    public var recordings: [RecordingRecord] = []
    public var seriesRules: [SeriesRuleRecord] = []
    public var filter: RecordingFilter = .all
    public var searchText: String = ""
    public var errorMessage: String?
    public var isRefreshing = false

    #if os(macOS)
    @ObservationIgnored nonisolated(unsafe) private var sleepActivityToken: NSObjectProtocol?
    #endif

    @ObservationIgnored nonisolated(unsafe) private var pollTask: Task<Void, Never>?

    public init(backend: RecordingsBackend) {
        self.backend = backend
        #if os(iOS)
        // The "Arrêter" button of the Live Activity stops the recording in this process.
        LiveActivityActions.stopRecording = { [weak self] id in await MainActor.run { self?.cancel(id: id) } }
        #endif
        loadAll()
        startPolling()
    }

    deinit {
        pollTask?.cancel()
        #if os(macOS)
        if let token = sleepActivityToken {
            ProcessInfo.processInfo.endActivity(token)
        }
        #endif
    }

    public func loadAll() {
        do {
            recordings = try backend.listRecordings(stateFilter: nil)
            seriesRules = try backend.listSeriesRules()
            errorMessage = nil
            updateSleepAssertion()
            LiveActivityManager.shared.sync(recordings: recordings)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { break }
                self?.loadAll()
            }
        }
    }

    public func schedule(req: NewRecordingRequest) throws -> Int64 {
        let id = try backend.scheduleRecording(req: req)
        loadAll()
        return id
    }

    public func recordNow(itemId: Int64, durationMinutes: UInt32 = 120) throws -> Int64 {
        let id = try backend.recordNow(itemId: itemId, durationMinutes: durationMinutes)
        loadAll()
        return id
    }

    public func cancel(id: Int64) {
        do {
            _ = try backend.cancelRecording(id: id)
            loadAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func delete(id: Int64, deleteFile: Bool = true) {
        do {
            _ = try backend.deleteRecording(id: id, deleteFile: deleteFile)
            loadAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func addSeriesRule(channelTvgId: String?, title: String) throws -> Int64 {
        let id = try backend.addSeriesRule(channelTvgId: channelTvgId, title: title)
        loadAll()
        return id
    }

    public func removeSeriesRule(id: Int64) {
        do {
            _ = try backend.removeSeriesRule(id: id)
            loadAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public var filteredRecordings: [RecordingRecord] {
        recordings.filter { rec in
            let matchesFilter: Bool
            switch filter {
            case .all:
                matchesFilter = true
            case .recording:
                matchesFilter = rec.state == "recording"
            case .scheduled:
                matchesFilter = rec.state == "scheduled"
            case .completed:
                matchesFilter = rec.state == "completed" || rec.state == "partial"
            case .rules:
                matchesFilter = false
            }

            if !matchesFilter { return false }
            if searchText.isEmpty { return true }
            return rec.title.localizedCaseInsensitiveContains(searchText) ||
                   rec.channelName.localizedCaseInsensitiveContains(searchText) ||
                   (rec.subtitle?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    private func updateSleepAssertion() {
        #if os(macOS)
        let hasActiveRecording = recordings.contains { $0.state == "recording" }
        if hasActiveRecording && sleepActivityToken == nil {
            sleepActivityToken = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "Enregistrement TV CND IPTV en cours"
            )
        } else if !hasActiveRecording, let token = sleepActivityToken {
            ProcessInfo.processInfo.endActivity(token)
            sleepActivityToken = nil
        }
        #endif
    }
}
