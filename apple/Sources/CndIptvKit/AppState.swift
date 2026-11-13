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
        try? engine.libraryRecordProgress(fingerprint: stableHash, positionMs: positionMs, durationMs: durationMs)
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
    public let upNext: UpNextModel
    let downloadDirectory: DownloadDirectoryManager
    /// Provider choice and consent of the channel assistant (key in the Keychain).
    let aiSettings = AiProviderSettings()
    /// The « Pour vous » rows of Films, Séries and Live TV, and their settings (PRD 34).
    let forYou: ForYouHub
    /// iCloud sync of sources, favorites and progress; reports "local only" when iCloud is unusable.
    private(set) var cloudSync: CloudKitSyncManager?
    /// Serverless local network continuity across Apple, Android and Samsung devices (PRD-41).
    public private(set) var localSync: LocalSyncService?
    /// Profiles (Principal, Enfants…) shared by the shell and the profile screens.
    private(set) var profiles: ProfilesModel?
    @ObservationIgnored private let recorder = DeferredProgressRecorder()
    /// Keeps downloads and playback inside the subscription's connection limit (PRD: one connection by default).
    @ObservationIgnored private(set) lazy var downloadCoordinator = DownloadConnectionCoordinator(
        backendProvider: { [weak self] in self?.engine },
        sourcesProvider: { [weak self] in self?.sources ?? [] }
    )

    /// The app's state: opens the engine on the default database.
    public convenience init() {
        self.init(engine: nil, downloadDirectory: nil)
    }

    init(engine: CndEngine? = nil, downloadDirectory: DownloadDirectoryManager? = nil) {
        let player = CndPlayerController(recorder: recorder)
        self.player = player
        player.streamDiagnoser = { media in await StreamDiagnosis.probe(url: media.url, headers: media.headers) }
        self.downloadDirectory = downloadDirectory ?? DownloadDirectoryManager()
        let upNext = UpNextModel(engineProvider: { nil })
        self.upNext = upNext
        self.forYou = ForYouHub(ai: aiSettings)
        forYou.setBackend { [weak self] in self?.engine }

        upNext.setEngineProvider { [weak self] in self?.engine }
        upNext.setPlayHandler { [weak self] media in
            guard let self else { return }
            if self.player.hasNext {
                self.player.next()
            } else {
                self.player.open(media)
            }
        }
        upNext.setAiConfigProvider { [weak self] in
            self?.aiSettings.providerConfig() ?? AiProviderConfig(kind: .localOnly, model: "", baseUrl: nil, apiKey: nil, timeoutMs: 8_000)
        }
        upNext.fallbackNextHandler = { [weak self] in
            if self?.player.hasNext == true {
                self?.player.next()
            }
        }
        player.onMediaChanged = { [weak self] media in
            self?.upNext.onMediaChanged(media)
            self?.trackRemotePlayback(media)
            guard let coordinator = self?.downloadCoordinator else { return }
            Task { await coordinator.playbackChanged(media: media) }
        }
        player.onProgressUpdate = { [weak self] pos, dur in
            self?.upNext.onPlaybackProgress(positionMs: pos, durationMs: dur)
        }
        player.onPlaybackEnded = { [weak self] in
            self?.upNext.onPlaybackEnded()
        }

        if let engine {
            attach(engine)
        } else {
            openEngine()
        }
    }

    private func attach(_ engine: CndEngine) {
        // Films and episodes read by mpv go through the engine's relay: one provider connection at a time.
        MpvVideoToolboxBackend.addressRewriter = { [weak engine] media in
            guard let engine else { return nil }
            let address = engine.singleConnectionUrl(
                url: media.url.absoluteString, userAgent: media.userAgent, referer: media.referer, headers: media.headers
            )
            return URL(string: address)
        }
        recorder.attach(engine)
        self.engine = engine
        SystemPowerCoordinator.shared.attachEngine(engine)
        BackgroundDownloadCoordinator.shared.attachEngine(engine, coordinator: downloadCoordinator)
        ConnectionBudget.enforce(on: engine)
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
        player.playbackHealthHandler = { [weak self, weak engine] media, broken in
            guard let engine, let hash = media.stableHash else { return }
            _ = try await Task.detached(priority: .utility) {
                try engine.setBroken(stableHash: hash, itemKind: "live", broken: broken)
            }.value
            await self?.refreshLiveHealthCatalog()
        }
        player.mirrorFinder = { [weak engine] itemId in
            guard let engine else { return [] }
            return try engine.findMirrors(itemId: itemId)
        }
        // Other copies of a film, offered when the one playing is too heavy for the connection.
        player.versionsFinder = { [weak engine] itemId in
            guard let engine else { return [] }
            return try engine.otherVersions(itemId: itemId)
        }
        let healthChecksEnabled = UserDefaults.standard.object(forKey: "healthChecksEnabled") as? Bool ?? true
        if healthChecksEnabled {
            engine.startHealthChecks(intervalMinutes: 30)
        }
        showNetworkConsole = engine.getSettings().showNetworkConsole
        ProfilesModel.restoreActiveProfile(engine: engine)
        let profilesModel = ProfilesModel(engine: engine)
        profilesModel.onActiveProfileChanged = { [weak self] in self?.applyParentalVisibility() }
        profiles = profilesModel
        ParentalControlManager.shared.onAdultSessionChange = { [weak self] in self?.applyParentalVisibility() }
        applyParentalVisibility(reload: false)
        let sync = CloudKitSyncManager(engine: engine)
        sync.onRemoteChange = { [weak self] insertedIds in
            self?.reloadSnapshot()
            self?.refreshInsertedSources(insertedIds)
        }
        cloudSync = sync
        sync.start()

        let local = LocalSyncService(engine: engine)
        local.onDeltaImported = { [weak self] in
            Task { @MainActor [weak self] in
                self?.reloadSnapshot()
            }
        }
        local.onSourcesInserted = { [weak self] ids in
            Task { @MainActor [weak self] in self?.refreshInsertedSources(ids) }
        }
        localSync = local
        local.start()
        configureRemotePlayback(localSync: local, engine: engine)
        reloadSnapshot()
        if let currentMedia = player.media {
            upNext.onMediaChanged(currentMedia)
        }
    }

    /// Accounts that arrived from another device have no channels yet: download their catalog and guide,
    /// one at a time (one connection at the provider). An Xtream account whose password has not arrived is skipped.
    func refreshInsertedSources(_ ids: [Int64]) {
        guard let engine, !ids.isEmpty else { return }
        Task { [weak self] in
            for id in ids {
                let source = await Task.detached(priority: .utility) {
                    (try? engine.listSources())?.first(where: { $0.id == id })
                }.value
                guard let source else { continue }
                let log = self?.localSync
                do {
                    var password: String?
                    if source.sourceType == "xtream" {
                        let key = source.passwordRef ?? KeychainStore.xtreamKey(forSourceUuid: source.uuid)
                        guard let secret = (try? KeychainStore.shared.readSecret(forKey: key)) ?? nil else {
                            log?.log("Catalogue de « \(source.name) » non chargé : pas de mot de passe sur cet appareil.", warning: true)
                            continue
                        }
                        password = secret
                        log?.log("Chargement du catalogue de « \(source.name) »…")
                        let summary = try await engine.refreshXtreamSource(sourceId: id, password: secret)
                        log?.log("Catalogue de « \(source.name) » chargé : \(SyncSummaryFormatter.text(summary)).")
                    } else {
                        log?.log("Chargement du catalogue de « \(source.name) »…")
                        let summary = try await engine.refreshSource(sourceId: id)
                        log?.log("Catalogue de « \(source.name) » chargé : \(SyncSummaryFormatter.text(summary)).")
                    }
                    self?.reloadSnapshot()
                    _ = try? await engine.refreshSourceEpg(sourceId: id, password: password)
                    self?.reloadSnapshot()
                } catch {
                    log?.log("Catalogue de « \(source.name) » non chargé : \(error.localizedDescription)", warning: true)
                }
            }
        }
    }

    // MARK: - "Lire sur…" (PRD-42)

    /// A household device asks to play here and waits for this device's answer (10 s, no answer = refusal).
    public var remotePrompt: RemotePlayPrompt?
    /// Account of the media playing here (see `RemotePlaybackCoordinator`: one stream per account).
    @ObservationIgnored private var remoteSourceKey: String?
    /// Bumped each time another household device starts a playback here, so the shell shows the player
    /// (a playback started by `player.open` alone plays with sound but nothing on screen on the Mac).
    public private(set) var remotePlayStarts = 0

    /// Films, episodes and live channels of the catalog can be sent to another device.
    /// Local files, recordings and replays cannot: the other device does not have them.
    public var canPlayOnAnotherDevice: Bool {
        guard let media = player.media, media.stableHash != nil else { return false }
        return media.kind == .live || media.kind == .movie || media.kind == .episode
    }

    /// Devices of the household that can play and are reachable right now.
    public var remotePlaybackTargets: [DiscoveredPeer] {
        (localSync?.activePeers ?? []).filter { $0.canPlay }
    }

    /// Sends what is playing here to `peer`; this device stops once the peer is ready (one stream only).
    public func playCurrentMedia(on peer: DiscoveredPeer) {
        guard canPlayOnAnotherDevice, let media = player.media, let hash = media.stableHash else { return }
        let live = media.kind == .live
        RemotePlaybackCoordinator.shared.startRemotePlayback(
            targetPeer: peer,
            contentKey: hash,
            kind: media.itemKind ?? (live ? "live" : "movie"),
            title: media.title,
            positionMs: live ? 0 : UInt64(max(0, player.positionMs)),
            sourceKey: remoteSourceKey,
            providerRef: RemotePlaybackCoordinator.providerRef(from: media.url),
            containerExt: RemotePlaybackCoordinator.containerExt(from: media.url)
        )
    }

    private func configureRemotePlayback(localSync: LocalSyncService, engine: CndEngine) {
        let remote = RemotePlaybackCoordinator.shared
        remote.configure(localSync: localSync, engine: engine)
        // Every hook is called on the main thread (the sync service dispatches there).
        remote.localPlaybackSnapshot = { [weak self] in
            MainActor.assumeIsolated { self?.remoteSnapshot() }
        }
        remote.onStopLocalPlay = { [weak self] in
            MainActor.assumeIsolated { self?.player.close() }
        }
        remote.onRequestLocalPlay = { [weak self] item, positionMs in
            MainActor.assumeIsolated {
                guard let self, let media = PlayableMedia(item: item, startPositionMs: Int64(positionMs)) else { return }
                self.player.open(media)
                self.remotePlayStarts += 1
            }
        }
        // Kids profile: nothing is started from another device (the catalog filter is not applied to a lookup by key).
        remote.isItemAllowedForActiveProfile = { [weak self] _ in
            MainActor.assumeIsolated { !(self?.profiles?.isKidsModeActive ?? false) }
        }
        remote.onPromptRequest = { [weak self] title, senderName, answer in
            MainActor.assumeIsolated { self?.askRemotePrompt(title: title, senderName: senderName, answer: answer) ?? answer(false) }
        }
        remote.onRemoteControl = { [weak self] action, value in
            MainActor.assumeIsolated { self?.applyRemoteControl(action: action, value: value) }
        }
        remote.onStreamInterruptedByPeer = { [weak self] _ in
            MainActor.assumeIsolated { self?.errorMessage = "Lecture arrêtée : un autre appareil du foyer lit ce compte." }
        }
    }

    private func remoteSnapshot() -> LocalPlaybackSnapshot? {
        guard player.media != nil else { return nil }
        let state: String
        switch player.state {
        case .playing: state = "playing"
        case .paused: state = "paused"
        case .idle, .loading, .buffering: state = "loading"
        case .ended: state = "ended"
        case .failed: state = "error"
        }
        return LocalPlaybackSnapshot(
            state: state,
            positionMs: UInt64(max(0, player.positionMs)),
            durationMs: UInt64(max(0, player.durationMs))
        )
    }

    private func applyRemoteControl(action: String, value: Int64?) {
        switch action {
        case "pause": player.pause()
        case "resume": player.play()
        case "seek_to": if let value { player.seek(toMs: max(0, value)) }
        case "seek_by": if let value { player.seek(toMs: max(0, player.positionMs + value)) }
        case "stop": player.close()
        case "next": player.next()
        case "previous": player.previous()
        default: break
        }
    }

    private func askRemotePrompt(title: String?, senderName: String, answer: @escaping @Sendable (Bool) -> Void) {
        let prompt = RemotePlayPrompt(title: title, senderName: senderName, answer: answer)
        remotePrompt = prompt
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self, self.remotePrompt?.id == prompt.id else { return }
            self.remotePrompt = nil
            answer(false)
        }
    }

    /// Tells the coordinator what plays here, and finds the account of that media (off the main thread).
    private func trackRemotePlayback(_ media: PlayableMedia?) {
        let remote = RemotePlaybackCoordinator.shared
        remoteSourceKey = nil
        guard let media, let hash = media.stableHash, let engine else {
            remote.setLocalPlaybackActive(contentKey: nil, title: nil, sourceKey: nil)
            return
        }
        remote.setLocalPlaybackActive(contentKey: hash, title: media.title, sourceKey: nil)
        Task { [weak self] in
            let sourceId = await Task.detached(priority: .utility) { () -> Int64? in
                (try? engine.itemByContentKey(contentKey: hash, sourceKey: nil, providerRef: nil, itemKind: nil))?.sourceId
            }.value
            guard let self, let sourceId, self.player.media?.stableHash == hash,
                  let source = self.sources.first(where: { $0.id == sourceId }) else { return }
            let key = syncComputeSourceKey(
                sourceType: source.sourceType, serverOrUrl: source.server ?? source.url ?? "", username: source.username
            )
            self.remoteSourceKey = key
            remote.setLocalPlaybackActive(contentKey: hash, title: media.title, sourceKey: key)
        }
    }

    /// Adult categories are hidden unless the PIN unlocked them for the session, and never shown to the
    /// Kids profile. Hidden lists follow the active profile, so screens reload when either changes.
    func applyParentalVisibility(reload: Bool = true) {
        guard let engine else { return }
        let visible = ParentalControlManager.shared.isAdultUnlocked && !(profiles?.isKidsModeActive ?? false)
        try? engine.setAdultContentVisible(visible: visible)
        if reload { catalogRevision += 1 }
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
                    #if os(iOS) || os(tvOS) || os(visionOS)
                    try? (FileManager.default as FileManager).setAttributes(
                        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                        ofItemAtPath: directory.path
                    )
                    #endif
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

    private func refreshLiveHealthCatalog() { catalogRevision += 1 }

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

/// Request of another household device to play here, waiting for the user's answer.
public struct RemotePlayPrompt: Identifiable {
    public let id = UUID()
    public let title: String?
    public let senderName: String
    public let answer: @Sendable (Bool) -> Void
}
