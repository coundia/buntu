import AVFoundation
import Foundation
import QuartzCore

/// Native engine: lowest power draw, HLS, AirPlay and PiP friendly.
@MainActor
public final class AVPlayerBackend: VideoBackend {
    public let engineKind: PlayerEngineKind = .avPlayer
    public var displayLayer: CALayer { playerLayer }
    public private(set) var state: PlaybackState = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    public var onStateChange: ((PlaybackState) -> Void)?
    public var onTracksChange: (() -> Void)?

    /// The video track's nominal frame rate (files and HLS variants) and, from its format description,
    /// the transfer function: PQ and HLG are what make a stream HDR.
    public func currentVideoFormat() -> VideoFormatReading? {
        guard let item = player.currentItem else { return nil }
        for itemTrack in item.tracks {
            guard let asset = itemTrack.assetTrack, asset.mediaType == .video else { continue }
            let fps = Double(asset.nominalFrameRate)
            guard fps > 0 else { continue }
            var gamma: String?
            var primaries: String?
            for description in asset.formatDescriptions as? [CMFormatDescription] ?? [] {
                if let transfer = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String {
                    if transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) { gamma = "pq" }
                    else if transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) { gamma = "hlg" }
                }
                if let colors = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String,
                   colors == (kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String) {
                    primaries = "bt.2020"
                }
            }
            return VideoFormatReading(fps: fps, gamma: gamma, primaries: primaries)
        }
        return nil
    }

    private let player = AVPlayer()
    private let playerLayer: AVPlayerLayer
    private var itemObservation: NSKeyValueObservation?
    private var controlObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?
    private var audioGroup: AVMediaSelectionGroup?
    private var legibleGroup: AVMediaSelectionGroup?
    private var pendingStartMs: Int64 = 0
    private var wantsPlayback = true
    private var rate: Float = 1
    private var trackTask: Task<Void, Never>?
    private var isTornDown = false

    public init() {
        playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspect
        player.automaticallyWaitsToMinimizeStalling = true
        controlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.syncTimeControl() }
        }
    }

    public var positionMs: Int64 {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? Int64(max(0, seconds) * 1000) : 0
    }

    public var durationMs: Int64 {
        guard let seconds = player.currentItem?.duration.seconds, seconds.isFinite, seconds > 0 else { return 0 }
        return Int64(seconds * 1000)
    }

    public func load(_ media: PlayableMedia, startPositionMs: Int64) {
        guard !isTornDown else { return }
        clearItem()
        state = .loading
        pendingStartMs = startPositionMs
        wantsPlayback = true

        var options: [String: Any] = [:]
        if !media.headers.isEmpty {
            options["AVURLAssetHTTPHeaderFieldsKey"] = media.headers
        }
        let asset = AVURLAsset(url: media.url, options: options.isEmpty ? nil : options)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = media.kind == .live ? 3 : 0

        itemObservation = item.observe(\.status, options: [.new]) { [weak self, weak item] _, _ in
            Task { @MainActor [weak self] in
                guard let self, let item else { return }
                self.handleItemStatus(item)
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.state = .ended }
        }
        failObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] note in
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            Task { @MainActor [weak self] in
                self?.state = .failed(error?.localizedDescription ?? "Playback interrupted")
            }
        }
        player.replaceCurrentItem(with: item)
    }

    private func handleItemStatus(_ item: AVPlayerItem) {
        guard !isTornDown, item === player.currentItem else { return }
        switch item.status {
        case .readyToPlay:
            if pendingStartMs > 0 {
                let target = CMTime(value: pendingStartMs, timescale: 1000)
                pendingStartMs = 0
                player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            }
            if wantsPlayback { player.playImmediately(atRate: rate) }
            loadTracks(for: item.asset)
        case .failed:
            state = .failed(item.error?.localizedDescription ?? "AVPlayer cannot decode this stream")
        default:
            break
        }
    }

    private func syncTimeControl() {
        guard !isTornDown, player.currentItem?.status == .readyToPlay else { return }
        if state == .ended { return }
        switch player.timeControlStatus {
        case .playing: state = .playing
        case .paused: state = .paused
        case .waitingToPlayAtSpecifiedRate: state = .buffering
        @unknown default: break
        }
    }

    private func loadTracks(for asset: AVAsset) {
        trackTask?.cancel()
        trackTask = Task { @MainActor [weak self] in
            let audio = try? await asset.loadMediaSelectionGroup(for: .audible)
            let legible = try? await asset.loadMediaSelectionGroup(for: .legible)
            guard let self, !Task.isCancelled else { return }
            self.audioGroup = audio
            self.legibleGroup = legible
            self.onTracksChange?()
        }
    }

    private func clearItem() {
        trackTask?.cancel()
        itemObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failObserver { NotificationCenter.default.removeObserver(failObserver) }
        endObserver = nil
        failObserver = nil
        audioGroup = nil
        legibleGroup = nil
    }

    public func play() {
        wantsPlayback = true
        player.playImmediately(atRate: rate)
    }

    public func pause() {
        wantsPlayback = false
        player.pause()
    }

    public func seek(toMs positionMs: Int64) {
        player.seek(to: CMTime(value: max(0, positionMs), timescale: 1000))
    }

    public func setRate(_ rate: Float) {
        self.rate = rate
        if player.timeControlStatus != .paused { player.rate = rate }
    }

    public func setVolume(_ volume: Float) { player.volume = min(max(volume, 0), 1) }
    public func setMuted(_ muted: Bool) { player.isMuted = muted }

    public func audioTracks() -> [MediaTrack] { tracks(in: audioGroup, allowsNone: false) }
    public func subtitleTracks() -> [MediaTrack] { tracks(in: legibleGroup, allowsNone: true) }

    private func tracks(in group: AVMediaSelectionGroup?, allowsNone: Bool) -> [MediaTrack] {
        guard let group, let item = player.currentItem else { return [] }
        let selected = item.currentMediaSelection.selectedMediaOption(in: group)
        return group.options.enumerated().map { index, option in
            MediaTrack(
                id: String(index),
                title: option.displayName,
                language: option.locale?.identifier,
                isSelected: option == selected
            )
        }
    }

    public func selectAudioTrack(id: String) {
        guard let group = audioGroup, let index = Int(id), group.options.indices.contains(index) else { return }
        player.currentItem?.select(group.options[index], in: group)
        onTracksChange?()
    }

    public func selectSubtitleTrack(id: String?) {
        guard let group = legibleGroup else { return }
        if let id, let index = Int(id), group.options.indices.contains(index) {
            player.currentItem?.select(group.options[index], in: group)
        } else {
            player.currentItem?.select(nil, in: group)
        }
        onTracksChange?()
    }

    public func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        player.pause()
        clearItem()
        controlObservation = nil
        player.replaceCurrentItem(with: nil)
        playerLayer.player = nil
        onStateChange = nil
        onTracksChange = nil
    }
}
