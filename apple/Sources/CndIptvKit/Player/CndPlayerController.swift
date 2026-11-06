import Foundation
import Network
import Observation
import QuartzCore
import CndCoreBridge

// MARK: - Collaborators (injectable for tests)

public protocol WatchProgressRecording: AnyObject, Sendable {
    func recordWatchProgress(stableHash: String, positionMs: Int64, durationMs: Int64) throws
}

extension CndEngine: WatchProgressRecording {}

public protocol NetworkReachability: AnyObject, Sendable {
    var isConnected: Bool { get }
    /// Returns `true` as soon as a network path is available, `false` after `timeout` seconds.
    func waitUntilConnected(timeout: TimeInterval) async -> Bool
}

/// `NWPathMonitor` based reachability, cancelled on deinit.
public final class NWPathReachability: NetworkReachability, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "cnd.player.network")
    private let lock = NSLock()
    private var connected = true

    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self.connected = path.status == .satisfied
            self.lock.unlock()
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }

    public var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return connected
    }

    public func waitUntilConnected(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !isConnected {
            if Date() >= deadline || Task.isCancelled { return isConnected }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return true
    }
}

public struct PlayerTimings: Sendable {
    /// Cadence of position mirroring, watchdog evaluation and progress saving.
    public var tick: TimeInterval = 0.25
    public var watchdogInterval: TimeInterval = 1
    /// Frozen position while playing/buffering for this long triggers a reconnection.
    public var stallThreshold: TimeInterval = 4
    /// A stream stuck in `.loading` this long is treated as stalled.
    public var loadTimeout: TimeInterval = 15
    public var reconnectBackoff: [TimeInterval] = [1, 2, 4]
    /// A film or an episode read by mpv: opening a big MKV over a slow single connection (headers, then
    /// the index at the end) takes long, and reconnecting would only open a new session on the provider.
    /// (Once playing, a buffer that still receives data never counts as a stall.)
    public var vodLoadTimeout: TimeInterval = 60
    /// How long a reload may take to show progress before the attempt counts as failed.
    public var recoveryProbe: TimeInterval = 6
    public var progressInterval: TimeInterval = 5

    public init(
        tick: TimeInterval = 0.25,
        watchdogInterval: TimeInterval = 1,
        stallThreshold: TimeInterval = 4,
        loadTimeout: TimeInterval = 15,
        reconnectBackoff: [TimeInterval] = [1, 2, 4],
        recoveryProbe: TimeInterval = 6,
        progressInterval: TimeInterval = 5,
        vodLoadTimeout: TimeInterval = 60
    ) {
        self.vodLoadTimeout = vodLoadTimeout
        self.tick = tick
        self.watchdogInterval = watchdogInterval
        self.stallThreshold = stallThreshold
        self.loadTimeout = loadTimeout
        self.reconnectBackoff = reconnectBackoff
        self.recoveryProbe = recoveryProbe
        self.progressInterval = progressInterval
    }
}

// MARK: - Controller

/// Dual-engine controller: routes to `AVPlayer` or `mpv`, falls back transparently, watches for
/// stalls, reconnects and persists watch progress.
@Observable
@MainActor
public final class CndPlayerController {
    public let id: UUID
    public private(set) var media: PlayableMedia?
    public private(set) var queue: PlaylistQueue?
    public private(set) var state: PlaybackState = .idle {
        didSet {
            guard state != oldValue else { return }
            updateSleepAssertion()
        }
    }
    public private(set) var positionMs: Int64 = 0
    public private(set) var durationMs: Int64 = 0
    public private(set) var activeEngine: PlayerEngineKind?
    public private(set) var surfaceLayer: CALayer?
    public private(set) var audioTracks: [MediaTrack] = []
    public private(set) var subtitleTracks: [MediaTrack] = []
    /// Non-blocking HUD banner, e.g. `Reconnexion 1/3…`.
    public private(set) var reconnectBanner: String?
    /// Whether the currently playing media is in favorites.
    public private(set) var isFavorite: Bool = false
    /// Whether the currently playing media is flagged as broken.
    public private(set) var isBroken: Bool = false
    /// Increments on each explicit `open` / `openQueue` call so mobile shells can present the player in front.
    public private(set) var launchCount: Int = 0

    /// Whether automatic failover to alternative mirror streams is enabled.
    public var autoFailoverEnabled: Bool = true
    /// Async resolver for alternative mirror channels (item_id -> [IptvItemRecord]).
    public var mirrorFinder: (@Sendable (Int64) async throws -> [IptvItemRecord])?
    /// Callback invoked whenever an automatic failover to a mirror stream occurs.
    public var onFailoverOccurred: ((IptvItemRecord) -> Void)?
    /// List of alternative mirror channels available for the current stream.
    public private(set) var availableMirrors: [IptvItemRecord] = []
    /// Non-blocking HUD banner for mirror failover, e.g. « Bascule vers TF1 FHD ».
    public private(set) var failoverBanner: String?
    /// The film needs more than the connection to the server delivers (shown once per film).
    public private(set) var slowSourceNotice: SlowSourceNotice?
    /// Other copies of the film being played, offered with `slowSourceNotice`.
    public private(set) var otherVersions: [IptvItemRecord] = []
    /// Finds the other copies of a film (the engine's `otherVersions`).
    public var versionsFinder: (@Sendable (Int64) async throws -> [IptvItemRecord])?
    /// « Télécharger puis regarder »: starts the download of what is playing.
    public var downloadHandler: ((PlayableMedia) -> Void)?
    @ObservationIgnored private var slowDetector = SlowSourceDetector()
    @ObservationIgnored private var lastNetworkReadingAt: Date?
    @ObservationIgnored public private(set) var failoverCount = 0
    /// Explains why a stream failed (HTTP status, DNS, timeout…). Set by the app; `nil` skips the check.
    @ObservationIgnored public var streamDiagnoser: (@Sendable (PlayableMedia) async -> StreamDiagnosis)?
    /// Last diagnosis for the current media; a final one stops any further reconnection.
    @ObservationIgnored public private(set) var diagnosis: StreamDiagnosis?
    @ObservationIgnored private var diagnosisTask: Task<Void, Never>?
    @ObservationIgnored private var formatTask: Task<Void, Never>?
    @ObservationIgnored private var recentDropouts: [Date] = []

    /// Custom async handler for favorite persistence; returns the new `isFavorite` state.
    public var favoriteHandler: (@Sendable (PlayableMedia) async throws -> Bool)?
    /// Callback invoked whenever a favorite toggle completes.
    public var onFavoriteToggled: ((PlayableMedia, Bool) -> Void)?

    /// Custom async handler for broken flag persistence; returns the new `isBroken` state.
    public var brokenHandler: (@Sendable (PlayableMedia) async throws -> Bool)?
    /// Callback invoked whenever a broken toggle completes.
    public var onBrokenToggled: ((PlayableMedia, Bool) -> Void)?

    /// Callbacks for external features (e.g. Up Next recommendations, Live Activity)
    public var onMediaChanged: ((PlayableMedia?) -> Void)?
    public var onProgressUpdate: ((Int64, Int64) -> Void)?
    public var onPlaybackEnded: (() -> Void)?

    public var enginePreference: PlayerEnginePreference = .auto
    public var rate: Float = 1 { didSet { backend?.setRate(rate) } }
    public var volume: Float = 1 { didSet { backend?.setVolume(volume) } }
    public var isMuted = false { didSet { backend?.setMuted(isMuted) } }

    public var isLive: Bool { media?.kind == .live }

    // MARK: - Dialogue Boost & Audio Enhancement
    public var audioEnhancement: AudioEnhancementConfig = .init() {
        didSet {
            applyAudioEnhancement()
        }
    }
    public private(set) var showHlsAudioEnhancementNotice: Bool = false

    // MARK: - Subtitles & Delay
    public var subtitleDelaySeconds: Double = 0.0 {
        didSet {
            applySubtitleDelay()
        }
    }
    public let subtitleOverlay = SubtitleOverlayModel()

    // MARK: - Local Timeshift Pause Live (PRD-24)
    public var timeshiftDuration: TimeshiftDuration = .oneHour
    public var liveDelaySeconds: Double = 0
    @ObservationIgnored public var livePauseStartTime: Date?

    public var currentLiveDelaySeconds: Double {
        var delay = liveDelaySeconds
        if let pausedAt = livePauseStartTime {
            delay += Date().timeIntervalSince(pausedAt)
        }
        return delay
    }

    @ObservationIgnored private let sleepManager: PlaybackSleepManager
    @ObservationIgnored private var backend: (any VideoBackend)?
    @ObservationIgnored private let backendFactory: (PlayerEngineKind) -> (any VideoBackend)?
    @ObservationIgnored private let isEngineAvailable: (PlayerEngineKind) -> Bool
    @ObservationIgnored private let recorder: WatchProgressRecording?
    @ObservationIgnored private let reachability: NetworkReachability
    @ObservationIgnored private let timings: PlayerTimings
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    @ObservationIgnored private var recoveryTask: Task<Void, Never>?
    @ObservationIgnored private var fallbackUsed = false
    @ObservationIgnored private var lastAdvanceAt = Date()
    @ObservationIgnored private var lastWatchdogCheck = Date()
    @ObservationIgnored private var lastSavedAt = Date()
    @ObservationIgnored private var stallReferenceMs: Int64 = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var accessibleTracksAppliedGeneration = -1

    public init(
        recorder: WatchProgressRecording? = nil,
        reachability: NetworkReachability? = nil,
        timings: PlayerTimings = PlayerTimings(),
        backendFactory: ((PlayerEngineKind) -> (any VideoBackend)?)? = nil,
        isEngineAvailable: ((PlayerEngineKind) -> Bool)? = nil,
        sleepManager: PlaybackSleepManager? = nil,
        id: UUID = UUID()
    ) {
        self.id = id
        self.sleepManager = sleepManager ?? PlaybackSleepManager.shared
        self.recorder = recorder
        self.reachability = reachability ?? NWPathReachability()
        self.timings = timings
        self.backendFactory = backendFactory ?? CndPlayerController.defaultBackendFactory
        // With a custom factory every engine is assumed available unless told otherwise.
        self.isEngineAvailable = isEngineAvailable
            ?? (backendFactory == nil ? CndPlayerController.defaultEngineAvailability : { _ in true })
    }

    deinit {
        let token = id
        let manager = sleepManager
        Task { @MainActor in
            manager.remove(id: token)
        }
    }

    public static func defaultEngineAvailability(_ kind: PlayerEngineKind) -> Bool {
        kind == .avPlayer || MpvVideoToolboxBackend.isLibraryAvailable
    }

    public static func defaultBackendFactory(_ kind: PlayerEngineKind) -> (any VideoBackend)? {
        switch kind {
        case .avPlayer: return AVPlayerBackend()
        case .mpv: return defaultEngineAvailability(.mpv) ? MpvVideoToolboxBackend() : nil
        }
    }

    // MARK: Opening media

    public func open(_ media: PlayableMedia) {
        queue = nil
        launchCount &+= 1
        start(media, resumeAt: media.startPositionMs)
    }

    public func openQueue(_ items: [PlayableMedia], startIndex: Int = 0) {
        let playlist = PlaylistQueue(items: items, currentIndex: startIndex)
        guard let first = playlist.current else { return }
        queue = playlist
        launchCount &+= 1
        start(first, resumeAt: first.startPositionMs)
    }

    public func next() {
        guard var playlist = queue, let item = playlist.next() else { return }
        saveProgress()
        queue = playlist
        start(item, resumeAt: item.startPositionMs)
    }

    public func previous() {
        guard var playlist = queue, let item = playlist.previous() else { return }
        saveProgress()
        queue = playlist
        start(item, resumeAt: item.startPositionMs)
    }

    public var hasNext: Bool { queue?.hasNext ?? false }
    public var hasPrevious: Bool { queue?.hasPrevious ?? false }

    private func start(_ media: PlayableMedia, resumeAt: Int64) {
        AppLog.shared.info("PLAYER", "Ouverture de « \(media.title) » (\(AppLog.describe(media.url)))"
            + (resumeAt > 0 ? ", reprise à \(resumeAt / 1000) s" : ""))
        cancelRecovery()
        diagnosisTask?.cancel()
        diagnosisTask = nil
        diagnosis = nil
        fallbackUsed = false
        failoverCount = 0
        recentDropouts = []
        availableMirrors = []
        failoverBanner = nil
        slowSourceNotice = nil
        otherVersions = []
        slowDetector.reset()
        lastNetworkReadingAt = nil
        self.media = media
        self.isFavorite = media.isFavorite
        self.isBroken = media.isBroken
        positionMs = resumeAt
        durationMs = 0
        liveDelaySeconds = 0
        livePauseStartTime = nil
        TimeshiftCacheManager.cleanCacheDirectory()
        onMediaChanged?(media)
        loadBackend(media, resumeAt: resumeAt, engine: PlayerRouting.engine(for: media.url, preference: enginePreference))
        startMonitor()
    }

    /// Automatically switches to an alternative mirror stream, preserving player state.
    public func failoverToMirror(_ mirror: IptvItemRecord) {
        guard let mirrorMedia = PlayableMedia(item: mirror) else { return }
        failoverCount += 1
        failoverBanner = "Bascule vers \(mirror.name)"
        AppLog.shared.warn("PLAYER", "Bascule vers le flux miroir : \(mirror.name)")
        self.media = mirrorMedia
        self.isFavorite = mirrorMedia.isFavorite
        self.isBroken = mirrorMedia.isBroken
        self.reconnectBanner = nil
        self.recoveryTask = nil
        onMediaChanged?(mirrorMedia)

        let engine = PlayerRouting.engine(for: mirrorMedia.url, preference: enginePreference)
        loadBackend(mirrorMedia, resumeAt: 0, engine: engine)
        onFailoverOccurred?(mirror)

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            self?.failoverBanner = nil
        }
    }

    /// Replaces the current backend. Does not touch the recovery task, so reconnection can reuse it.
    private func loadBackend(_ media: PlayableMedia, resumeAt: Int64, engine: PlayerEngineKind) {
        releaseBackend()
        let other: PlayerEngineKind = engine == .mpv ? .avPlayer : .mpv
        let chosen = isEngineAvailable(engine) ? engine : other
        if chosen != engine {
            AppLog.shared.warn("PLAYER", "\(Self.engineName(engine)) indisponible (libmpv introuvable ?) : utilisation de \(Self.engineName(chosen))")
        }
        // Without libmpv, AVPlayer cannot read raw TS, MKV, AVI or FLV: use the channel's HLS form when
        // the server has one, otherwise say so at once instead of failing three reconnections later.
        var playable = media
        if chosen == .avPlayer, !PlayerRouting.avPlayerCanPlay(media.url) {
            if let hls = PlayerRouting.hlsAlternative(for: media.url) {
                playable = media.replacingURL(hls)
                AppLog.shared.info("PLAYER", "Chaîne lue en HLS (.m3u8) : le moteur libmpv n'est pas disponible sur cet appareil")
            } else {
                let ext = media.url.pathExtension.isEmpty ? "ce format" : "le format .\(media.url.pathExtension.lowercased())"
                let reason = "\(ext.prefix(1).uppercased() + ext.dropFirst()) n'est pas pris en charge sur cet appareil (le moteur libmpv n'y est pas inclus). Les films .mp4 et les chaînes disponibles en HLS fonctionnent ; sinon, ouvrez-le dans VLC ou Infuse avec le bouton ci-dessous."
                AppLog.shared.error("PLAYER", reason)
                state = .failed(reason)
                return
            }
        }
        guard isEngineAvailable(chosen), let newBackend = backendFactory(chosen) else {
            AppLog.shared.error("PLAYER", "Aucun moteur de lecture disponible")
            state = .failed("No playback engine available")
            return
        }
        AppLog.shared.info("PLAYER", "Moteur \(Self.engineName(chosen)) chargé")
        generation += 1
        let token = generation
        backend = newBackend
        activeEngine = chosen
        surfaceLayer = newBackend.displayLayer
        state = .loading
        audioTracks = []
        subtitleTracks = []

        newBackend.onStateChange = { [weak self] newState in
            guard let self, self.generation == token else { return }
            self.handleBackendState(newState)
        }
        newBackend.onTracksChange = { [weak self] in
            guard let self, self.generation == token else { return }
            self.refreshTracks()
        }
        if let mpv = newBackend as? MpvVideoToolboxBackend {
            mpv.timeshiftDuration = timeshiftDuration
        }
        newBackend.setRate(rate)
        newBackend.setVolume(volume)
        newBackend.setMuted(isMuted)
        newBackend.setAudioEnhancement(audioEnhancement)
        newBackend.setSubtitleDelay(seconds: subtitleDelaySeconds)
        newBackend.load(playable, startPositionMs: resumeAt)

        if chosen == .avPlayer, media.isHls, audioEnhancement.isActive {
            showHlsAudioEnhancementNotice = true
        } else {
            showHlsAudioEnhancementNotice = false
        }

        lastAdvanceAt = Date()
        lastWatchdogCheck = Date()
        stallReferenceMs = resumeAt
    }

    private nonisolated static func engineName(_ kind: PlayerEngineKind) -> String {
        kind == .mpv ? "mpv" : "AVPlayer"
    }

    private func releaseBackend() {
        formatTask?.cancel()
        formatTask = nil
        generation += 1
        backend?.teardown()
        backend = nil
        surfaceLayer = nil
    }

    // MARK: Transport

    public func play() {
        if isLive, let pausedAt = livePauseStartTime {
            liveDelaySeconds += Date().timeIntervalSince(pausedAt)
            livePauseStartTime = nil
        }
        backend?.play()
    }

    public func pause() {
        if isLive && timeshiftDuration.isEnabled && livePauseStartTime == nil {
            livePauseStartTime = Date()
        }
        backend?.pause()
    }

    public func togglePlayPause() {
        state == .playing || state == .buffering ? pause() : play()
    }

    /// Toggles favorite status for the currently playing media across all media kinds.
    public func toggleFavorite() {
        guard let currentMedia = media else { return }
        Task { @MainActor in
            do {
                let newFav: Bool
                if let handler = self.favoriteHandler {
                    newFav = try await handler(currentMedia)
                } else {
                    newFav = !self.isFavorite
                }
                self.isFavorite = newFav
                self.media?.isFavorite = newFav
                self.queue?.updateCurrentFavorite(newFav)
                self.onFavoriteToggled?(currentMedia, newFav)
                Haptics.light()
            } catch {
                AppLog.shared.error("PLAYER", "Impossible de modifier les favoris : \(error.localizedDescription)")
            }
        }
    }

    /// Toggles broken/non-functional flag for the currently playing media across all media kinds.
    public func toggleBroken() {
        guard let currentMedia = media else { return }
        Task { @MainActor in
            do {
                let newBroken: Bool
                if let handler = self.brokenHandler {
                    newBroken = try await handler(currentMedia)
                } else {
                    newBroken = !self.isBroken
                }
                self.isBroken = newBroken
                self.media?.isBroken = newBroken
                self.onBrokenToggled?(currentMedia, newBroken)
                Haptics.light()
            } catch {
                AppLog.shared.error("PLAYER", "Impossible de modifier l'état de panne : \(error.localizedDescription)")
            }
        }
    }

    public func seek(toMs target: Int64) {
        guard !isLive else { return }
        let upper = durationMs > 0 ? durationMs : Int64.max
        let clamped = min(max(0, target), upper)
        positionMs = clamped
        stallReferenceMs = clamped
        lastAdvanceAt = Date()
        backend?.seek(toMs: clamped)
    }

    public func skip(bySeconds seconds: Int) {
        if isLive {
            guard timeshiftDuration.isEnabled else { return }
            if seconds < 0 {
                liveDelaySeconds += Double(-seconds)
                backend?.seekLiveRelative(seconds: Double(seconds))
            } else {
                if liveDelaySeconds > Double(seconds) {
                    liveDelaySeconds -= Double(seconds)
                    backend?.seekLiveRelative(seconds: Double(seconds))
                } else {
                    catchUpToLive()
                }
            }
            return
        }
        seek(toMs: positionMs + Int64(seconds) * 1000)
    }

    public func catchUpToLive() {
        guard isLive else { return }
        liveDelaySeconds = 0
        livePauseStartTime = nil
        backend?.returnToLive()
        backend?.play()
    }

    public func selectAudioTrack(id: String) { backend?.selectAudioTrack(id: id) }
    public func selectSubtitleTrack(id: String?) { backend?.selectSubtitleTrack(id: id) }

    /// mpv does not read the system's caption and audio-description settings: turn on the matching
    /// accessible track once per media, never overriding a choice the user already made.
    private func applyAccessibleTrackPreferences() {
        guard activeEngine == .mpv, accessibleTracksAppliedGeneration != generation else { return }
        accessibleTracksAppliedGeneration = generation
        let prefs = AccessibleTrackPreferences.current()
        if let id = AccessibleTrackPolicy.subtitle(in: subtitleTracks, preferences: prefs),
           !subtitleTracks.contains(where: \.isSelected) {
            backend?.selectSubtitleTrack(id: id)
        }
        if let id = AccessibleTrackPolicy.audio(in: audioTracks, preferences: prefs) {
            backend?.selectAudioTrack(id: id)
        }
    }

    private func refreshTracks() {
        audioTracks = backend?.audioTracks() ?? []
        subtitleTracks = backend?.subtitleTracks() ?? []
    }

    // MARK: Backend events, fallback

    private func handleBackendState(_ newState: PlaybackState) {
        // During reconnection the recovery task owns the visible state transitions.
        let previous = state
        state = newState
        switch newState {
        case .failed(let reason):
            AppLog.shared.error("PLAYER", "Échec de lecture (\(activeEngine.map(Self.engineName) ?? "?")) : \(reason)")
            if diagnosis?.isFinal == true { return }
            diagnoseFailure()
            handleFailure(reason)
        case .ended:
            handleEnded()
        case .playing where previous != .playing:
            if previous == .loading { AppLog.shared.info("PLAYER", "Lecture démarrée") }
            refreshTracks()
            applyAccessibleTrackPreferences()
            scheduleFormatDetection()
        default:
            break
        }
    }

    /// `AVPlayer` refusing a stream switches to `mpv` at once, keeping headers and position.
    private func handleFailure(_ reason: String) {
        guard let media else { return }
        if activeEngine == .avPlayer, !fallbackUsed, isEngineAvailable(.mpv) {
            fallbackUsed = true
            AppLog.shared.warn("PLAYER", "AVPlayer a refusé le flux : bascule vers mpv")
            let resume = isLive ? 0 : max(positionMs, media.startPositionMs)
            loadBackend(media, resumeAt: resume, engine: .mpv)
            return
        }
        beginRecovery()
    }

    /// One request per media: the engines only say "loading failed". When the server's answer makes
    /// retrying pointless (429, 403, 404…), the recovery stops and the reason is shown instead.
    private func diagnoseFailure() {
        guard diagnosis == nil, diagnosisTask == nil, let media, let diagnoser = streamDiagnoser else { return }
        diagnosisTask = Task { @MainActor [weak self] in
            let result = await diagnoser(media)
            guard let self, !Task.isCancelled, self.media == media else { return }
            self.diagnosisTask = nil
            self.diagnosis = result
            if result.isFinal {
                AppLog.shared.error("PLAYER", "Diagnostic : \(result.message) Lecture arrêtée, pas de nouvelle tentative.")
                self.cancelRecovery()
                self.releaseBackend()
                self.state = .failed(result.message)
            } else {
                AppLog.shared.warn("PLAYER", "Diagnostic : \(result.message)")
            }
        }
    }

    /// Asks the engine for the video's frame rate and dynamic range for a few seconds after the start (the
    /// engines only know them once the first frames are decoded) and hands them to the display matcher.
    private func scheduleFormatDetection() {
        formatTask?.cancel()
        let token = generation
        formatTask = Task { @MainActor [weak self] in
            for _ in 0..<10 {
                guard let self, !Task.isCancelled, self.generation == token else { return }
                if let reading = self.backend?.currentVideoFormat() {
                    DisplayRateMatcher.shared.update(
                        rawFps: reading.fps, gamma: reading.gamma, primaries: reading.primaries,
                        width: reading.width, height: reading.height
                    )
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func handleEnded() {
        if let media, !isLive { saveProgress(positionOverride: durationMs > 0 ? durationMs : positionMs, for: media) }
        if let onPlaybackEnded {
            onPlaybackEnded()
        } else if hasNext {
            next()
        }
    }

    // MARK: Monitor loop: position mirror, stall watchdog, progress saving

    private func startMonitor() {
        monitorTask?.cancel()
        let tickNs = UInt64(timings.tick * 1_000_000_000)
        monitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: tickNs)
                guard let self, !Task.isCancelled else { return }
                self.monitorTick()
            }
        }
    }

    private func monitorTick() {
        guard let backend else { return }
        let now = Date()
        let position = backend.positionMs
        positionMs = position
        durationMs = backend.durationMs
        subtitleOverlay.update(positionMs: position)
        onProgressUpdate?(position, backend.durationMs)

        if abs(position - stallReferenceMs) >= 200 {
            stallReferenceMs = position
            lastAdvanceAt = now
        }

        if now.timeIntervalSince(lastWatchdogCheck) >= timings.watchdogInterval {
            lastWatchdogCheck = now
            evaluateNetwork(now: now)
            evaluateStall(now: now)
        }

        if now.timeIntervalSince(lastSavedAt) >= timings.progressInterval {
            lastSavedAt = now
            if state == .playing { saveProgress() }
        }
    }

    /// A film read by mpv: whether data is still arriving, and whether the file is too heavy for the connection.
    private var isVodOnMpv: Bool { !isLive && activeEngine == .mpv }

    private func evaluateNetwork(now: Date) {
        guard isVodOnMpv, let backend else { return }
        let reading = backend.networkReading()
        let interval = lastNetworkReadingAt.map { now.timeIntervalSince($0) } ?? timings.watchdogInterval
        lastNetworkReadingAt = now
        // Data still arrives: the picture waits for the buffer, the stream is alive.
        if let reading, reading.isDownloading, reading.downloadBytesPerSecond > 0, state == .buffering || state == .loading {
            lastAdvanceAt = now
        }
        let buffering = state == .buffering || state == .loading
        if let notice = slowDetector.add(reading, isBuffering: buffering, interval: interval) {
            slowSourceNotice = notice
            AppLog.shared.warn("PLAYER", String(
                format: "Débit insuffisant : le fichier demande %.1f Mbit/s, la connexion au serveur en donne %.1f",
                notice.neededMbps, notice.availableMbps
            ))
            if let itemId = media?.itemId, let versionsFinder {
                Task { @MainActor [weak self] in
                    let versions = (try? await versionsFinder(itemId)) ?? []
                    self?.otherVersions = versions
                }
            }
        }
    }

    private func evaluateStall(now: Date) {
        guard recoveryTask == nil else { return }
        let idle = now.timeIntervalSince(lastAdvanceAt)
        let stallLimit = timings.stallThreshold
        let loadLimit = isVodOnMpv ? timings.vodLoadTimeout : timings.loadTimeout
        switch state {
        case .playing, .buffering:
            if idle >= stallLimit { beginRecovery() }
        case .loading:
            if idle >= loadLimit { beginRecovery() }
        default:
            break
        }
    }

    // MARK: Slow source: another copy, or download first

    public func dismissSlowSourceNotice() { slowSourceNotice = nil }

    /// Plays another copy of the film from the same position.
    public func playVersion(_ item: IptvItemRecord) {
        let resume = positionMs
        guard let version = PlayableMedia(item: item, startPositionMs: resume) else { return }
        AppLog.shared.info("PLAYER", "Autre version : « \(item.name) »")
        open(version)
    }

    /// Stops playback and downloads the film (one connection): it then plays from the device.
    public func downloadInstead() {
        guard let media, let downloadHandler else { return }
        slowSourceNotice = nil
        close()
        downloadHandler(media)
    }

    // MARK: Reconnection (NWPathMonitor + backoff 1s, 2s, 4s)

    private func beginRecovery() {
        guard recoveryTask == nil, let media else { return }
        let now = Date()
        recentDropouts.append(now)
        recentDropouts = recentDropouts.filter { now.timeIntervalSince($0) <= 60 }
        let rapidDropouts = recentDropouts.count >= 2

        let attempts = timings.reconnectBackoff
        recoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }

            // If 2 dropouts occurred within 60 seconds on a live stream, attempt rapid failover to a mirror
            if rapidDropouts, self.isLive, let itemId = media.itemId, let mirrorFinder = self.mirrorFinder {
                let mirrors = (try? await mirrorFinder(itemId)) ?? []
                self.availableMirrors = mirrors
                if let best = mirrors.first, self.autoFailoverEnabled, self.failoverCount < 2 {
                    self.failoverToMirror(best)
                    return
                }
            }

            for (index, delay) in attempts.enumerated() {
                self.reconnectBanner = "Reconnexion \(index + 1)/\(attempts.count)…"
                AppLog.shared.warn("PLAYER", "Flux interrompu : reconnexion \(index + 1)/\(attempts.count)")
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if Task.isCancelled { return }
                _ = await self.reachability.waitUntilConnected(timeout: max(delay, 2))
                if Task.isCancelled { return }

                let resume = self.isLive ? 0 : max(self.positionMs, media.startPositionMs)
                self.loadBackend(media, resumeAt: resume, engine: self.activeEngine ?? PlayerRouting.engine(for: media.url, preference: self.enginePreference))
                if await self.waitForProgress(from: resume) {
                    self.reconnectBanner = nil
                    self.recoveryTask = nil
                    return
                }
                if Task.isCancelled { return }
            }

            // All reconnection attempts exhausted: attempt automatic failover to mirror
            if self.isLive, let itemId = media.itemId, let mirrorFinder = self.mirrorFinder {
                let mirrors = (try? await mirrorFinder(itemId)) ?? []
                self.availableMirrors = mirrors
                if let best = mirrors.first, self.autoFailoverEnabled, self.failoverCount < 2 {
                    self.failoverToMirror(best)
                    return
                }
            }

            self.reconnectBanner = nil
            self.recoveryTask = nil
            AppLog.shared.error("PLAYER", "Flux indisponible après \(attempts.count) tentatives de reconnexion"
                + (self.diagnosis.map { " : \($0.message)" } ?? ""))
            self.state = .failed(self.diagnosis?.message ?? "Stream unavailable after \(attempts.count) reconnection attempts")
        }
    }

    private func waitForProgress(from startMs: Int64) async -> Bool {
        let deadline = Date().addingTimeInterval(timings.recoveryProbe)
        while Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(timings.tick * 1_000_000_000))
            if state == .playing, abs((backend?.positionMs ?? 0) - startMs) >= 200 { return true }
        }
        return false
    }

    private func cancelRecovery() {
        recoveryTask?.cancel()
        recoveryTask = nil
        reconnectBanner = nil
    }

    // MARK: - Dialogue Boost & Audio Enhancement Actions

    public func setAudioEnhancement(_ config: AudioEnhancementConfig) {
        self.audioEnhancement = config
    }

    public func applyAudioEnhancement() {
        if activeEngine == .avPlayer, let media, media.isHls, audioEnhancement.isActive {
            showHlsAudioEnhancementNotice = true
        } else {
            showHlsAudioEnhancementNotice = false
        }
        backend?.setAudioEnhancement(audioEnhancement)
    }

    public func switchToMpvForAudioEnhancement() {
        guard let media, isEngineAvailable(.mpv) else { return }
        showHlsAudioEnhancementNotice = false
        enginePreference = .forceMpv
        let resume = isLive ? 0 : max(positionMs, media.startPositionMs)
        loadBackend(media, resumeAt: resume, engine: .mpv)
    }

    public func dismissHlsAudioEnhancementNotice() {
        showHlsAudioEnhancementNotice = false
    }

    // MARK: - Subtitle Actions & External Subtitles

    public func setSubtitleDelay(_ delay: Double) {
        self.subtitleDelaySeconds = delay
    }

    public func applySubtitleDelay() {
        subtitleOverlay.delaySeconds = subtitleDelaySeconds
        backend?.setSubtitleDelay(seconds: subtitleDelaySeconds)
    }

    public func loadExternalSubtitle(fileUrl: URL, engine: CndEngine? = nil) {
        // mpv draws the subtitle itself; the overlay is only for AVPlayer (a second layer would double it).
        if backend?.addExternalSubtitle(fileUrl: fileUrl) == true { return }
        if let content = try? String(contentsOf: fileUrl, encoding: .utf8) {
            let cues: [SubtitleCue]
            if let engine {
                cues = engine.parseSrt(srtContent: content)
            } else {
                cues = []
            }
            if !cues.isEmpty {
                subtitleOverlay.load(cues: cues)
            }
        }
    }

    // MARK: Watch progress

    public func saveProgress() {
        guard let media else { return }
        saveProgress(positionOverride: positionMs, for: media)
    }

    private func saveProgress(positionOverride: Int64, for media: PlayableMedia) {
        guard media.kind != .live, media.kind != .replay, let hash = media.stableHash, durationMs > 0 else { return }
        try? recorder?.recordWatchProgress(stableHash: hash, positionMs: positionOverride, durationMs: durationMs)
    }

    // MARK: Teardown

    /// Persists progress, then destroys the backend, the monitor and every watchdog task.
    public func close() {
        saveProgress()
        monitorTask?.cancel()
        monitorTask = nil
        cancelRecovery()
        releaseBackend()
        media = nil
        queue = nil
        state = .idle
        onMediaChanged?(nil)
        sleepManager.remove(id: id)
        activeEngine = nil
        positionMs = 0
        durationMs = 0
        audioTracks = []
        subtitleTracks = []
        subtitleOverlay.clear()
        showHlsAudioEnhancementNotice = false
        liveDelaySeconds = 0
        livePauseStartTime = nil
        TimeshiftCacheManager.cleanCacheDirectory()
        DisplayRateMatcher.shared.reset()
    }

    private func updateSleepAssertion() {
        let isPlaying: Bool
        switch state {
        case .playing, .buffering, .loading:
            isPlaying = true
        case .idle, .paused, .ended, .failed:
            isPlaying = false
        }
        sleepManager.setPlaying(isPlaying, for: id)
    }
}
