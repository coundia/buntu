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
    @ObservationIgnored private let recorder = DeferredProgressRecorder()

    init(engine: CndEngine? = nil, downloadDirectory: DownloadDirectoryManager? = nil) {
        player = CndPlayerController(recorder: recorder)
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
        showNetworkConsole = engine.getSettings().showNetworkConsole
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
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }
}
