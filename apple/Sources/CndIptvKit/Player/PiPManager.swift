import AVFoundation
import AVKit
import CoreMedia
import Foundation
import Observation

/// What the system PiP window needs to know about playback, readable from any thread.
final class PiPPlaybackBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var paused = true
    private var live = false
    private var durationSeconds: Double = 0
    private var _onSetPlaying: (@Sendable (Bool) -> Void)?
    private var _onSkip: (@Sendable (Double) -> Void)?

    func update(isPaused: Bool, isLive: Bool, durationMs: Int64) {
        lock.withLock {
            paused = isPaused
            live = isLive
            durationSeconds = Double(max(durationMs, 0)) / 1000
        }
    }

    func setHandlers(onSetPlaying: @escaping @Sendable (Bool) -> Void, onSkip: @escaping @Sendable (Double) -> Void) {
        lock.withLock {
            _onSetPlaying = onSetPlaying
            _onSkip = onSkip
        }
    }

    var isPaused: Bool { lock.withLock { paused } }

    /// A live stream has an unbounded window (no scrubber in the PiP window); a movie spans its duration.
    var timeRange: CMTimeRange {
        let (isLive, duration) = lock.withLock { (live, durationSeconds) }
        if isLive || duration <= 0 {
            return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
        }
        return CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))
    }

    func setPlaying(_ playing: Bool) {
        let handler = lock.withLock { _onSetPlaying }
        handler?(playing)
    }

    func skip(bySeconds seconds: Double) {
        let handler = lock.withLock { _onSkip }
        handler?(seconds)
    }
}

/// Lets the system PiP window drive a `AVSampleBufferDisplayLayer` (mpv output): play/pause and skip.
final class SampleBufferPiPDelegate: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate {
    let bridge: PiPPlaybackBridge

    init(bridge: PiPPlaybackBridge) {
        self.bridge = bridge
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        bridge.setPlaying(playing)
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        bridge.timeRange
    }

    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        bridge.isPaused
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping @Sendable () -> Void
    ) {
        bridge.skip(bySeconds: skipInterval.seconds)
        completionHandler()
    }
}

/// Owns the Picture-in-Picture controller for whichever layer the active backend renders to:
/// `AVPlayerLayer` for `AVPlayer`, `AVSampleBufferDisplayLayer` for mpv.
@Observable
@MainActor
final class PiPManager {
    private(set) var isSupported = AVPictureInPictureController.isPictureInPictureSupported()
    private(set) var isPossible = false
    private(set) var isActive = false

    @ObservationIgnored private var pip: AVPictureInPictureController?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var sampleDelegate: SampleBufferPiPDelegate?
    @ObservationIgnored private weak var attachedLayer: CALayer?
    @ObservationIgnored let bridge = PiPPlaybackBridge()

    enum LayerKind: Equatable {
        case playerLayer
        case sampleBuffer
        case unsupported
    }

    static func kind(of layer: CALayer?) -> LayerKind {
        if layer is AVPlayerLayer { return .playerLayer }
        if layer is AVSampleBufferDisplayLayer { return .sampleBuffer }
        return .unsupported
    }

    /// (Re)creates the controller when the backend's layer changes, e.g. after an AVPlayer -> mpv fallback.
    func attach(layer: CALayer?, controller: CndPlayerController) {
        guard layer !== attachedLayer else { return }
        detach()
        attachedLayer = layer
        guard isSupported else { return }

        bridge.setHandlers(
            onSetPlaying: { [weak controller] playing in
                Task { @MainActor in playing ? controller?.play() : controller?.pause() }
            },
            onSkip: { [weak controller] seconds in
                Task { @MainActor in controller?.skip(bySeconds: Int(seconds.rounded())) }
            }
        )
        syncState(from: controller)

        switch Self.kind(of: layer) {
        case .playerLayer:
            if let playerLayer = layer as? AVPlayerLayer { pip = AVPictureInPictureController(playerLayer: playerLayer) }
        case .sampleBuffer:
            if let sampleLayer = layer as? AVSampleBufferDisplayLayer {
                let delegate = SampleBufferPiPDelegate(bridge: bridge)
                sampleDelegate = delegate
                let source = AVPictureInPictureController.ContentSource(
                    sampleBufferDisplayLayer: sampleLayer, playbackDelegate: delegate
                )
                pip = AVPictureInPictureController(contentSource: source)
            }
        case .unsupported:
            break
        }
        guard let pip else { return }
        #if os(iOS)
        // Leaving the app while playing hands the video over to PiP by itself.
        pip.canStartPictureInPictureAutomaticallyFromInline = true
        #endif
        observations = [
            pip.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
                let possible = controller.isPictureInPicturePossible
                Task { @MainActor in self?.isPossible = possible }
            },
            pip.observe(\.isPictureInPictureActive, options: [.initial, .new]) { [weak self] controller, _ in
                let active = controller.isPictureInPictureActive
                Task { @MainActor in self?.isActive = active }
            },
        ]
    }

    /// Keeps the system window's play/pause state and time range in step with the player.
    func syncState(from controller: CndPlayerController) {
        let playing = controller.state == .playing || controller.state == .buffering
        bridge.update(isPaused: !playing, isLive: controller.isLive, durationMs: controller.durationMs)
        pip?.invalidatePlaybackState()
    }

    func toggle() {
        guard let pip else { return }
        if pip.isPictureInPictureActive {
            pip.stopPictureInPicture()
        } else if pip.isPictureInPicturePossible {
            pip.startPictureInPicture()
        }
    }

    func detach() {
        observations.removeAll()
        if pip?.isPictureInPictureActive == true { pip?.stopPictureInPicture() }
        pip = nil
        sampleDelegate = nil
        attachedLayer = nil
        isPossible = false
        isActive = false
    }
}
