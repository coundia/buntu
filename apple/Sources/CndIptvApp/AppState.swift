import Foundation
import Observation
import CndCoreBridge

/// The player is created before the engine finishes opening; this forwards watch progress to the
/// engine once it is attached and drops it until then.
final class DeferredProgressRecorder: WatchProgressRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var engine: CndEngine?

    func attach(_ engine: CndEngine) {
        lock.withLock { self.engine = engine }
    }

    func recordWatchProgress(stableHash: String, positionMs: Int64, durationMs: Int64) throws {
        guard let engine = lock.withLock({ self.engine }) else { return }
        try engine.recordWatchProgress(stableHash: stableHash, positionMs: positionMs, durationMs: durationMs)
    }
}

/// App-wide state: the Rust engine, the counters shown in the sidebar and the shared player.
@Observable
@MainActor
public final class AppState {
    public private(set) var engine: CndEngine?
    public private(set) var stats: DbStats?
    public private(set) var sources: [IptvSourceRecord] = []
    /// Bumped whenever the catalog may have changed (sync, delete, import), so screens reload.
    public private(set) var catalogRevision = 0
    public var errorMessage: String?
    /// Mirrors `RuntimeSettings.showNetworkConsole`: whether the console drawer is shown.
    public var showNetworkConsole = false

    let player: CndPlayerController
    let downloadDirectory: DownloadDirectoryManager
    /// Provider choice and consent of the channel assistant (key in the Keychain).
    let aiSettings = AiProviderSettings()
    /// iCloud sync of sources, favorites and progress; reports "local only" when iCloud is unusable.
    private(set) var cloudSync: CloudKitSyncManager?
    @ObservationIgnored private let recorder = DeferredProgressRecorder()

    init(engine: CndEngine? = nil, downloadDirectory: DownloadDirectoryManager? = nil) {
        player = CndPlayerController(recorder: recorder)
        player.streamDiagnoser = { media in await StreamDiagnosis.probe(url: media.url, headers: media.headers) }
        self.downloadDirectory = downloadDirectory ?? DownloadDirectoryManager()
        if let engine {
            attach(engine)
        } else {
            openEngine()
        }
    }

    private func attach(_ engine: CndEngine) {
        recorder.attach(engine)
        self.engine = engine
        player.autoFailoverEnabled = UserDefaults.standard.object(forKey: "autoFailoverEnabled") as? Bool ?? true
        if let raw = UserDefaults.standard.string(forKey: "timeshiftDuration"),
           let duration = TimeshiftDuration(rawValue: raw) {
            player.timeshiftDuration = duration
        }
        player.favoriteHandler = { [weak self, weak engine] media in
            guard let self, let engine else { return false }
            return try await self.toggleFavorite(for: media, using: engine)
        }
        player.brokenHandler = { [weak self, weak engine] media in
            guard let self, let engine else { return false }
            return try await self.toggleBroken(for: media, using: engine)
        }
        player.mirrorFinder = { [weak engine] itemId in
            guard let engine else { return [] }
            return try engine.findMirrors(itemId: itemId)
        }
        let healthChecksEnabled = UserDefaults.standard.object(forKey: "healthChecksEnabled") as? Bool ?? true
        if healthChecksEnabled {
            engine.startHealthChecks(intervalMinutes: 30)
        }
        showNetworkConsole = engine.getSettings().showNetworkConsole
        let sync = CloudKitSyncManager(engine: engine)
        sync.onRemoteChange = { [weak self] _ in self?.reloadSnapshot() }
        cloudSync = sync
        sync.start()
        reloadSnapshot()
    }

    private func openEngine() {
        Task { [weak self] in
            do {
                let engine = try await Task.detached(priority: .userInitiated) { () -> CndEngine in
                    let appSupport = try FileManager.default.url(
                        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
                    )
                    let directory = appSupport.appendingPathComponent("CndIptvNative", isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    return try CndEngine(dbPath: directory.appendingPathComponent("cnd_iptv.db").path)
                }.value
                self?.attach(engine)
            } catch {
                self?.errorMessage = "Initialisation du moteur impossible : \(error.localizedDescription)"
            }
        }
    }

    /// Re-reads the sidebar counters and the source list. `notifyScreens: false` refreshes the
    /// counters only (e.g. after a favorite toggle) without making every list reload and lose its scroll.
    public func reloadSnapshot(notifyScreens: Bool = true) {
        guard let engine else { return }
        Task { [weak self] in
            do {
                let snapshot = try await Task.detached(priority: .userInitiated) {
                    (stats: try engine.getStats(), sources: try engine.listSources())
                }.value
                self?.stats = snapshot.stats
                self?.sources = snapshot.sources
                if notifyScreens { self?.catalogRevision += 1 }
                self?.cloudSync?.scheduleSync()
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    /// Toggles the favorite status for any playable media (live channel, movie, episode/series, download).
    func toggleFavorite(for media: PlayableMedia, using engine: CndEngine) async throws -> Bool {
        if media.kind == .episode {
            var targetHash = media.seriesStableHash
            if targetHash == nil, let seriesId = media.seriesId {
                let series = try await Task.detached(priority: .userInitiated) {
                    try engine.getSeriesById(seriesId: seriesId)
                }.value
                targetHash = series?.stableHash
            }
            if let seriesHash = targetHash {
                let newFav = try await Task.detached(priority: .userInitiated) {
                    try engine.toggleFavorite(stableHash: seriesHash, itemKind: "series")
                }.value
                if let epHash = media.stableHash {
                    _ = try? await Task.detached(priority: .userInitiated) {
                        try engine.toggleFavorite(stableHash: epHash, itemKind: "episode")
                    }.value
                }
                self.reloadSnapshot(notifyScreens: false)
                return newFav
            }
        }

        let hash = media.stableHash ?? "media:\(media.id)"
        let kind = media.itemKind ?? media.kind.rawValue
        let newFav = try await Task.detached(priority: .userInitiated) {
            try engine.toggleFavorite(stableHash: hash, itemKind: kind)
        }.value
        self.reloadSnapshot(notifyScreens: false)
        return newFav
    }

    func toggleBroken(for media: PlayableMedia, using engine: CndEngine) async throws -> Bool {
        if media.kind == .episode {
            var targetHash = media.seriesStableHash
            if targetHash == nil, let seriesId = media.seriesId {
                let series = try? await Task.detached(priority: .userInitiated) {
                    try engine.getSeriesById(seriesId: seriesId)
                }.value
                targetHash = series?.stableHash
            }
            if let seriesHash = targetHash {
                let newBroken = try await Task.detached(priority: .userInitiated) {
                    try engine.toggleBroken(stableHash: seriesHash, itemKind: "series")
                }.value
                if let epHash = media.stableHash {
                    _ = try? await Task.detached(priority: .userInitiated) {
                        try engine.toggleBroken(stableHash: epHash, itemKind: "episode")
                    }.value
                }
                self.reloadSnapshot(notifyScreens: false)
                return newBroken
            }
        }

        let hash = media.stableHash ?? "media:\(media.id)"
        let kind = media.itemKind ?? media.kind.rawValue
        let newBroken = try await Task.detached(priority: .userInitiated) {
            try engine.toggleBroken(stableHash: hash, itemKind: kind)
        }.value
        self.reloadSnapshot(notifyScreens: false)
        return newBroken
    }
}
