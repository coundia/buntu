import Foundation
import Observation
import CndCoreBridge

/// The slice of the engine the coordinator drives; scripted in tests.
protocol DownloadControlling: AnyObject, Sendable {
    func listDownloads(query: String?) throws -> [DownloadTaskRecord]
    func pauseDownload(taskId: Int64) async throws
    func startDownload(taskId: Int64) async throws
}

extension CndEngine: DownloadControlling {}

/// Keeps downloads and playback inside the subscription's connection limit: with a single connection, the
/// downloads that share the playing stream's server are paused while it plays and resumed when it ends, and
/// a download requested during a playback waits for the end of it instead of failing with a 502.
@MainActor
final class DownloadConnectionCoordinator {
    private let backendProvider: () -> DownloadControlling?
    private let sourcesProvider: () -> [IptvSourceRecord]
    private let defaults: UserDefaults
    private let log: (String) -> Void

    /// Host of the stream being played (`nil` when nothing plays, or a local file).
    private(set) var playingHost: String?
    /// Tasks this coordinator paused or queued for a playback, to start once it is over.
    private(set) var heldTaskIds: [Int64] = []

    init(
        backendProvider: @escaping () -> DownloadControlling?,
        sourcesProvider: @escaping () -> [IptvSourceRecord],
        defaults: UserDefaults = .standard,
        log: @escaping (String) -> Void = { AppLog.shared.info("DL", $0) }
    ) {
        self.backendProvider = backendProvider
        self.sourcesProvider = sourcesProvider
        self.defaults = defaults
        self.log = log
    }

    private func limit(forHost host: String?) -> Int {
        ConnectionBudget.limit(
            forHost: host, sources: sourcesProvider(),
            assumed: ConnectionBudget.current(defaults: defaults).limit
        )
    }

    private func pausesDuringPlayback(host: String?) -> Bool {
        ConnectionBudget(limit: limit(forHost: host)).pausesDuringPlayback
    }

    /// The player's media changed (`nil`: playback ended or was closed).
    func playbackChanged(media: PlayableMedia?) async {
        let host = media.flatMap { $0.url.isFileURL ? nil : $0.url.host?.lowercased() }
        guard host != playingHost else { return }
        if playingHost != nil { await releaseHeld() }
        playingHost = host
        if let host, pausesDuringPlayback(host: host) { await holdDownloads(on: host) }
    }

    /// Whether a download of this address has to wait for the end of the current playback.
    func shouldHoldNewDownload(urlString: String) -> Bool {
        guard let playing = playingHost, ConnectionBudget.host(of: urlString) == playing else { return false }
        return pausesDuringPlayback(host: playing)
    }

    /// A download queued without starting, to start when the playback is over.
    func hold(taskId: Int64) {
        if !heldTaskIds.contains(taskId) { heldTaskIds.append(taskId) }
    }

    private func holdDownloads(on host: String) async {
        guard let backend = backendProvider(), let tasks = try? backend.listDownloads(query: nil) else { return }
        var paused = 0
        for task in tasks where ConnectionBudget.host(of: task.url) == host && (task.state == "running" || task.state == "queued") {
            if (try? await backend.pauseDownload(taskId: task.id)) != nil {
                hold(taskId: task.id)
                paused += 1
            }
        }
        if paused > 0 {
            log("\(paused) téléchargement(s) en pause pendant la lecture : l'abonnement n'autorise qu'une connexion")
        }
    }

    private func releaseHeld() async {
        let ids = heldTaskIds
        heldTaskIds = []
        guard !ids.isEmpty, let backend = backendProvider() else { return }
        let paused = Set(((try? backend.listDownloads(query: nil)) ?? []).filter { $0.state == "paused" }.map(\.id))
        var resumed = 0
        for id in ids where paused.contains(id) {
            if (try? await backend.startDownload(taskId: id)) != nil { resumed += 1 }
        }
        if resumed > 0 { log("\(resumed) téléchargement(s) repris après la lecture") }
    }
}

extension ConnectionBudget {
    /// Brings the engine's segments and parallel files under the budget (existing installs saved 4 and 2).
    @MainActor
    static func enforce(on engine: CndEngine, defaults: UserDefaults = .standard) {
        let budget = current(defaults: defaults)
        var settings = engine.getSettings()
        let clamped = budget.clamp(segments: Int(settings.segmentsPerFile), files: Int(settings.maxActiveFiles))
        guard clamped.segments != Int(settings.segmentsPerFile) || clamped.files != Int(settings.maxActiveFiles) else { return }
        settings.segmentsPerFile = UInt32(clamped.segments)
        settings.maxActiveFiles = UInt32(clamped.files)
        do {
            try engine.updateSettings(settings: settings)
            AppLog.shared.info("DL", "Téléchargements limités à \(clamped.segments) segment(s) × \(clamped.files) fichier(s) : abonnement à \(budget.limit) connexion(s)")
        } catch {
            AppLog.shared.warn("DL", "Limite de connexions non appliquée : \(userMessage(for: error))")
        }
    }
}
