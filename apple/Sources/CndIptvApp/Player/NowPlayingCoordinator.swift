import AVFoundation
import MediaPlayer
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Pure builder of the `MPNowPlayingInfoCenter` dictionary.
enum NowPlayingInfoBuilder {
    static func info(
        media: PlayableMedia,
        subtitle: String?,
        positionMs: Int64,
        durationMs: Int64,
        isPlaying: Bool,
        rate: Float,
        artwork: MPMediaItemArtwork? = nil
    ) -> [String: Any] {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: media.title,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
        if let subtitle, !subtitle.isEmpty { info[MPMediaItemPropertyArtist] = subtitle }
        if media.kind == .live {
            info[MPNowPlayingInfoPropertyIsLiveStream] = true
        } else {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(max(positionMs, 0)) / 1000
            if durationMs > 0 { info[MPMediaItemPropertyPlaybackDuration] = Double(durationMs) / 1000 }
        }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        return info
    }

    static func defaultSubtitle(for media: PlayableMedia) -> String {
        switch media.kind {
        case .live: return "Direct"
        case .movie: return "Film"
        case .episode: return "Série"
        }
    }
}

enum NowPlayingCommand: Equatable {
    case play
    case pause
    case toggle
    case skip(seconds: Int)
    case next
    case previous
    case seek(toSeconds: Double)
}

/// Publishes what is playing to the system (Control Center, lock screen, keyboard media keys,
/// AirPods) and routes the system's remote commands back to the player.
@MainActor
final class NowPlayingCoordinator {
    static let skipInterval = 15

    private let controller: CndPlayerController
    /// Called for next/previous track: an episode in a queue, otherwise a channel zap.
    var onZap: (Int) -> Void = { _ in }
    var subtitleProvider: (PlayableMedia) -> String? = { NowPlayingInfoBuilder.defaultSubtitle(for: $0) }

    private var targets: [(command: MPRemoteCommand, token: Any)] = []
    private var artwork: MPMediaItemArtwork?
    private var artworkUrl: String?
    private var isActive = false
    private var audioSessionConfigured = false

    init(controller: CndPlayerController) {
        self.controller = controller
    }

    /// Maps a system command onto the player. Pure with respect to `MediaPlayer`, so it is testable.
    func perform(_ command: NowPlayingCommand) -> MPRemoteCommandHandlerStatus {
        guard controller.media != nil else { return .noActionableNowPlayingItem }
        switch command {
        case .play:
            controller.play()
        case .pause:
            controller.pause()
        case .toggle:
            controller.togglePlayPause()
        case .skip(let seconds):
            guard !controller.isLive else { return .commandFailed }
            controller.skip(bySeconds: seconds)
        case .seek(let seconds):
            guard !controller.isLive else { return .commandFailed }
            controller.seek(toMs: Int64(seconds * 1000))
        case .next:
            onZap(1)
        case .previous:
            onZap(-1)
        }
        refresh()
        return .success
    }

    // MARK: Activation

    func activate() {
        guard !isActive else { return }
        isActive = true
        let center = MPRemoteCommandCenter.shared()
        register(center.playCommand) { [weak self] _ in self?.perform(.play) ?? .commandFailed }
        register(center.pauseCommand) { [weak self] _ in self?.perform(.pause) ?? .commandFailed }
        register(center.togglePlayPauseCommand) { [weak self] _ in self?.perform(.toggle) ?? .commandFailed }
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
        register(center.skipForwardCommand) { [weak self] _ in self?.perform(.skip(seconds: Self.skipInterval)) ?? .commandFailed }
        register(center.skipBackwardCommand) { [weak self] _ in self?.perform(.skip(seconds: -Self.skipInterval)) ?? .commandFailed }
        register(center.nextTrackCommand) { [weak self] _ in self?.perform(.next) ?? .commandFailed }
        register(center.previousTrackCommand) { [weak self] _ in self?.perform(.previous) ?? .commandFailed }
        register(center.changePlaybackPositionCommand) { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            return self?.perform(.seek(toSeconds: event.positionTime)) ?? .commandFailed
        }
    }

    func deactivate() {
        for (command, token) in targets { command.removeTarget(token) }
        targets.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        isActive = false
    }

    private func register(_ command: MPRemoteCommand, handler: @escaping @MainActor (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
        command.isEnabled = true
        let token = command.addTarget { event in
            // Remote commands arrive on the main thread.
            MainActor.assumeIsolated { handler(event) }
        }
        targets.append((command, token))
    }

    /// `.playback` / `.moviePlayback` lets video keep playing with the screen locked and enables PiP.
    private func configureAudioSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
        #endif
    }

    // MARK: Publishing

    /// Call when the media or the playback state changes; the system extrapolates the position in
    /// between, so no timer is needed.
    func refresh() {
        guard let media = controller.media else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        if !audioSessionConfigured {
            // Deferred to the first playback so launching the app does not interrupt other apps' audio.
            audioSessionConfigured = true
            configureAudioSession()
        }
        loadArtworkIfNeeded(for: media)
        let playing = controller.state == .playing || controller.state == .buffering
        MPNowPlayingInfoCenter.default().nowPlayingInfo = NowPlayingInfoBuilder.info(
            media: media,
            subtitle: subtitleProvider(media),
            positionMs: controller.positionMs,
            durationMs: controller.durationMs,
            isPlaying: playing,
            rate: controller.rate,
            artwork: artwork
        )
        MPNowPlayingInfoCenter.default().playbackState = playing ? .playing : .paused
    }

    private func loadArtworkIfNeeded(for media: PlayableMedia) {
        guard media.artworkUrl != artworkUrl else { return }
        artworkUrl = media.artworkUrl
        artwork = nil
        guard let urlString = media.artworkUrl, !urlString.isEmpty else { return }
        Task { [weak self] in
            guard let image = await ImageThumbnailCache.shared.image(for: urlString, size: .poster) else { return }
            guard let self, self.artworkUrl == urlString else { return }
            let bounds = CGSize(width: image.width, height: image.height)
            #if os(macOS)
            let platformImage = NSImage(cgImage: image, size: bounds)
            #else
            let platformImage = UIImage(cgImage: image)
            #endif
            self.artwork = MPMediaItemArtwork(boundsSize: bounds) { _ in platformImage }
            self.refresh()
        }
    }
}
