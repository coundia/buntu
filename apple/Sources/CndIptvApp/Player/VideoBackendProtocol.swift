import Foundation
import QuartzCore

public enum PlaybackState: Equatable, Sendable {
    case idle
    case loading
    case playing
    case paused
    case buffering
    case ended
    case failed(String)
}

public struct MediaTrack: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let language: String?
    public let isSelected: Bool

    public init(id: String, title: String, language: String?, isSelected: Bool) {
        self.id = id
        self.title = title
        self.language = language
        self.isSelected = isSelected
    }
}

/// What a backend measured on the video it is playing (for display frame-rate matching).
public struct VideoFormatReading: Equatable, Sendable {
    public var fps: Double
    /// mpv-style names: "pq", "hlg", "bt.1886"...
    public var gamma: String?
    public var primaries: String?

    public init(fps: Double, gamma: String? = nil, primaries: String? = nil) {
        self.fps = fps
        self.gamma = gamma
        self.primaries = primaries
    }
}

/// Common contract of the two playback engines. Every call happens on the main actor.
@MainActor
public protocol VideoBackend: AnyObject {
    var engineKind: PlayerEngineKind { get }
    /// Layer showing the video; hosted by `CndVideoPlayerView` (and reusable for PiP / AirPlay).
    var displayLayer: CALayer { get }
    var state: PlaybackState { get }
    var positionMs: Int64 { get }
    /// `0` for live streams or while the duration is unknown.
    var durationMs: Int64 { get }

    var onStateChange: ((PlaybackState) -> Void)? { get set }
    var onTracksChange: (() -> Void)? { get set }

    func load(_ media: PlayableMedia, startPositionMs: Int64)
    func play()
    func pause()
    func seek(toMs positionMs: Int64)
    func setRate(_ rate: Float)
    /// `0...1`
    func setVolume(_ volume: Float)
    func setMuted(_ muted: Bool)

    func audioTracks() -> [MediaTrack]
    func subtitleTracks() -> [MediaTrack]
    func selectAudioTrack(id: String)
    /// `nil` disables subtitles.
    func selectSubtitleTrack(id: String?)

    /// Releases the player, its observers and background tasks. Idempotent.
    func teardown()

    func setAudioEnhancement(_ config: AudioEnhancementConfig)
    func setSubtitleDelay(seconds: Double)
    func addExternalSubtitle(fileUrl: URL) -> Bool
    func seekLiveRelative(seconds: Double)
    func returnToLive()
    /// Frame rate and dynamic range of the video being played, `nil` while not known yet.
    func currentVideoFormat() -> VideoFormatReading?
}

extension VideoBackend {
    public func currentVideoFormat() -> VideoFormatReading? { nil }
    public func setAudioEnhancement(_ config: AudioEnhancementConfig) {}
    public func setSubtitleDelay(seconds: Double) {}
    public func addExternalSubtitle(fileUrl: URL) -> Bool { false }
    public func seekLiveRelative(seconds: Double) {}
    public func returnToLive() {}
}
