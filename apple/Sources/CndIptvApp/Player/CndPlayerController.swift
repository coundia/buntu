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
    /// How long a reload may take to show progress before the attempt counts as failed.
    public var recoveryProbe: TimeInterval = 6
    public var progressInterval: TimeInterval = 5

    public init() {}
}

// MARK: - Controller

/// Dual-engine controller: routes to `AVPlayer` or `mpv`, falls back transparently, watches for
/// stalls, reconnects and persists watch progress.
@Observable
@MainActor
public final class CndPlayerController {
    public private(set) var media: PlayableMedia?
    public private(set) var queue: PlaylistQueue?
    public private(set) var state: PlaybackState = .idle
    public private(set) var positionMs: Int64 = 0
    public private(set) var durationMs: Int64 = 0
    public private(set) var activeEngine: PlayerEngineKind?
    public private(set) var surfaceLayer: CALayer?
    public private(set) var audioTracks: [MediaTrack] = []
    public private(set) var subtitleTracks: [MediaTrack] = []
    /// Non-blocking HUD banner, e.g. `Reconnexion 1/3…`.
    public private(set) var reconnectBanner: String?

    public var enginePreference: PlayerEnginePreference = .auto
    public var rate: Float = 1 { didSet { backend?.setRate(rate) } }
    public var volume: Float = 1 { didSet { backend?.setVolume(volume) } }
    public var isMuted = false { didSet { backend?.setMuted(isMuted) } }

    public var isLive: Bool { media?.kind == .live }

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

    public init(
        recorder: WatchProgressRecording? = nil,
        reachability: NetworkReachability? = nil,
        timings: PlayerTimings = PlayerTimings(),
        backendFactory: ((PlayerEngineKind) -> (any VideoBackend)?)? = nil,
        isEngineAvailable: ((PlayerEngineKind) -> Bool)? = nil
    ) {
        self.recorder = recorder
        self.reachability = reachability ?? NWPathReachability()
        self.timings = timings
        self.backendFactory = backendFactory ?? CndPlayerController.defaultBackendFactory
        // With a custom factory every engine is assumed available unless told otherwise.
        self.isEngineAvailable = isEngineAvailable
            ?? (backendFactory == nil ? CndPlayerController.defaultEngineAvailability : { _ in true })
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
        start(media, resumeAt: media.startPositionMs)
    }

    public func openQueue(_ items: [PlayableMedia], startIndex: Int = 0) {
        let playlist = PlaylistQueue(items: items, currentIndex: startIndex)
        guard let first = playlist.current else { return }
        queue = playlist
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
        cancelRecovery()
        fallbackUsed = false
        self.media = media
        positionMs = resumeAt
        durationMs = 0
        loadBackend(media, resumeAt: resumeAt, engine: PlayerRouting.engine(for: media.url, preference: enginePreference))
        startMonitor()
    }

    /// Replaces the current backend. Does not touch the recovery task, so reconnection can reuse it.
    private func loadBackend(_ media: PlayableMedia, resumeAt: Int64, engine: PlayerEngineKind) {
        releaseBackend()
        let other: PlayerEngineKind = engine == .mpv ? .avPlayer : .mpv
        let chosen = isEngineAvailable(engine) ? engine : other
        guard isEngineAvailable(chosen), let newBackend = backendFactory(chosen) else {
            state = .failed("No playback engine available")
            return
        }
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
        newBackend.setRate(rate)
        newBackend.setVolume(volume)
        newBackend.setMuted(isMuted)
        newBackend.load(media, startPositionMs: resumeAt)

        lastAdvanceAt = Date()
        lastWatchdogCheck = Date()
        stallReferenceMs = resumeAt
    }

    private func releaseBackend() {
        generation += 1
        backend?.teardown()
        backend = nil
        surfaceLayer = nil
    }

    // MARK: Transport

    public func play() { backend?.play() }
    public func pause() { backend?.pause() }

    public func togglePlayPause() {
        state == .playing || state == .buffering ? pause() : play()
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
        seek(toMs: positionMs + Int64(seconds) * 1000)
    }

    public func selectAudioTrack(id: String) { backend?.selectAudioTrack(id: id) }
    public func selectSubtitleTrack(id: String?) { backend?.selectSubtitleTrack(id: id) }

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
            handleFailure(reason)
        case .ended:
            handleEnded()
        case .playing where previous != .playing:
            refreshTracks()
        default:
            break
        }
    }

    /// `AVPlayer` refusing a stream switches to `mpv` at once, keeping headers and position.
    private func handleFailure(_ reason: String) {
        guard let media else { return }
        if activeEngine == .avPlayer, !fallbackUsed, isEngineAvailable(.mpv) {
            fallbackUsed = true
            let resume = isLive ? 0 : max(positionMs, media.startPositionMs)
            loadBackend(media, resumeAt: resume, engine: .mpv)
            return
        }
        beginRecovery()
    }

    private func handleEnded() {
        if let media, !isLive { saveProgress(positionOverride: durationMs > 0 ? durationMs : positionMs, for: media) }
        if hasNext { next() }
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

        if abs(position - stallReferenceMs) >= 200 {
            stallReferenceMs = position
            lastAdvanceAt = now
        }

        if now.timeIntervalSince(lastWatchdogCheck) >= timings.watchdogInterval {
            lastWatchdogCheck = now
            evaluateStall(now: now)
        }

        if now.timeIntervalSince(lastSavedAt) >= timings.progressInterval {
            lastSavedAt = now
            if state == .playing { saveProgress() }
        }
    }

    private func evaluateStall(now: Date) {
        guard recoveryTask == nil else { return }
        let idle = now.timeIntervalSince(lastAdvanceAt)
        switch state {
        case .playing, .buffering:
            if idle >= timings.stallThreshold { beginRecovery() }
        case .loading:
            if idle >= timings.loadTimeout { beginRecovery() }
        default:
            break
        }
    }

    // MARK: Reconnection (NWPathMonitor + backoff 1s, 2s, 4s)

    private func beginRecovery() {
        guard recoveryTask == nil, let media else { return }
        let attempts = timings.reconnectBackoff
        recoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for (index, delay) in attempts.enumerated() {
                self.reconnectBanner = "Reconnexion \(index + 1)/\(attempts.count)…"
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
            self.reconnectBanner = nil
            self.recoveryTask = nil
            self.state = .failed("Stream unavailable after \(attempts.count) reconnection attempts")
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

    // MARK: Watch progress

    public func saveProgress() {
        guard let media else { return }
        saveProgress(positionOverride: positionMs, for: media)
    }

    private func saveProgress(positionOverride: Int64, for media: PlayableMedia) {
        guard media.kind != .live, let hash = media.stableHash, durationMs > 0 else { return }
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
        activeEngine = nil
        positionMs = 0
        durationMs = 0
        audioTracks = []
        subtitleTracks = []
    }
}
