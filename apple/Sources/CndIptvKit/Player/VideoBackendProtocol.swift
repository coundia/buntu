import Foundation
import QuartzCore

public enum VideoAspectRatioMode: String, CaseIterable, Sendable, Equatable {
    case fit
    case fill
    case stretch

    public var displayName: String {
        switch self {
        case .fit: return "Ajuster"
        case .fill: return "Remplir"
        case .stretch: return "16:9 étiré"
        }
    }

    public var systemImage: String {
        switch self {
        case .fit: return "rectangle.arrowtriangle.2.inward"
        case .fill: return "rectangle.arrowtriangle.2.outward"
        case .stretch: return "arrow.left.and.right.square"
        }
    }
}

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
    /// Subtitles for the deaf and hard of hearing (they also describe music and sounds).
    public let isHearingImpaired: Bool
    /// Audio that describes what is on screen (audio description).
    public let isAudioDescription: Bool

    public init(
        id: String, title: String, language: String?, isSelected: Bool,
        isHearingImpaired: Bool = false, isAudioDescription: Bool = false
    ) {
        self.id = id
        self.title = title
        self.language = language
        self.isSelected = isSelected
        self.isHearingImpaired = isHearingImpaired
        self.isAudioDescription = isAudioDescription
    }

    /// The menu title, with « (SDH) » / « (audiodescription) » when the track says so and the name does not.
    public var displayTitle: String {
        var text = title
        let lower = title.lowercased()
        if isHearingImpaired, !lower.contains("sdh"), !lower.contains("malentendant"), !lower.contains("hearing") { text += " (SDH)" }
        if isAudioDescription, !lower.contains("audiodescription"), !lower.contains("description") { text += " (audiodescription)" }
        return text
    }
}

/// What a backend measured on the video it is playing (for display frame-rate matching).
public struct VideoFormatReading: Equatable, Sendable {
    public var fps: Double
    /// mpv-style names: "pq", "hlg", "bt.1886"...
    public var gamma: String?
    public var primaries: String?
    /// Decoded picture size in pixels, when the engine knows it.
    public var width: Int?
    public var height: Int?

    public init(fps: Double, gamma: String? = nil, primaries: String? = nil, width: Int? = nil, height: Int? = nil) {
        self.width = width
        self.height = height
        self.fps = fps
        self.gamma = gamma
        self.primaries = primaries
    }
}

/// What the connection delivers and what the file needs (mpv only): for a film too heavy for it.
public struct NetworkReading: Equatable, Sendable {
    /// Download speed measured by the engine.
    public var downloadBytesPerSecond: Double
    /// Average bitrate of the file (size × 8 / duration), when both are known.
    public var fileBitsPerSecond: Double?
    /// The engine is still reading ahead (its cache is not full): the speed is meaningful.
    public var isDownloading: Bool

    public init(downloadBytesPerSecond: Double, fileBitsPerSecond: Double?, isDownloading: Bool) {
        self.downloadBytesPerSecond = downloadBytesPerSecond
        self.fileBitsPerSecond = fileBitsPerSecond
        self.isDownloading = isDownloading
    }
}

public enum SlowSourceStage: Equatable, Sendable {
    case continuing
    case atRisk
    case refilling
}

public struct SlowSourceNotice: Equatable, Sendable {
    public var neededMbps: Double
    public var availableMbps: Double
    public var stage: SlowSourceStage
    public var showsDownload: Bool
}

/// Assesses the active download and the playback reserve. Samples taken while cache is full
/// cannot be used as measurements of the connection.
public struct SlowSourceDetector: Sendable {
    private var speeds: [Double] = []
    private var weakSeconds: Double = 0
    private var healthySeconds: Double = 0
    private var bufferingSeconds: Double = 0
    private var stage: SlowSourceStage?
    private var previousReserve: Double?
    private var drainingSeconds: Double = 0
    private static let window = 20
    private static let minimumSamples = 8
    private static let margin = 0.95

    public init() {}

    public mutating func reset() { self = SlowSourceDetector() }

    public mutating func add(
        _ reading: NetworkReading?,
        bufferedAhead: Double?,
        isBuffering: Bool,
        interval: Double
    ) -> SlowSourceNotice? {
        let elapsed = min(max(interval, 0), 2)
        guard let reading, let needed = reading.fileBitsPerSecond, needed.isFinite, needed > 0 else {
            reset()
            return nil
        }
        if reading.isDownloading, reading.downloadBytesPerSecond.isFinite, reading.downloadBytesPerSecond > 0 {
            speeds.append(reading.downloadBytesPerSecond * 8)
            if speeds.count > Self.window { speeds.removeFirst() }
        }
        if let reserve = bufferedAhead, let previousReserve, reserve < previousReserve {
            drainingSeconds += elapsed
        } else {
            drainingSeconds = max(0, drainingSeconds - elapsed)
        }
        previousReserve = bufferedAhead
        guard speeds.count >= Self.minimumSamples else { return nil }
        let average = speeds.reduce(0, +) / Double(speeds.count)
        if reading.isDownloading, average < needed * Self.margin {
            weakSeconds += elapsed
            healthySeconds = 0
        } else if !isBuffering, reading.isDownloading || (bufferedAhead ?? 0) >= 25 {
            healthySeconds += elapsed
        }
        if healthySeconds >= 5 {
            reset()
            return nil
        }
        guard weakSeconds >= 3 else { return nil }
        if isBuffering {
            bufferingSeconds += elapsed
            stage = .refilling
        } else {
            // Leave extra headroom before downgrading the alert to avoid flickering around 12 s.
            let riskLimit: Double = stage == .atRisk || stage == .refilling ? 18 : 12
            let lowReserve = bufferedAhead.map { $0 <= riskLimit } ?? false
            let draining = drainingSeconds >= 3 || stage == .atRisk || stage == .refilling
            stage = lowReserve && draining ? .atRisk : .continuing
        }
        guard let stage else { return nil }
        return SlowSourceNotice(
            neededMbps: needed / 1_000_000,
            availableMbps: average / 1_000_000,
            stage: stage,
            showsDownload: weakSeconds >= 30 || bufferingSeconds >= 8
        )
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
    func setAspectRatio(_ mode: VideoAspectRatioMode)

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
    /// Download speed and the file's bitrate, `nil` when the engine cannot tell.
    func networkReading() -> NetworkReading?
    func bufferedAheadSeconds() -> Double?
}

extension VideoBackend {
    public func setAspectRatio(_ mode: VideoAspectRatioMode) {}
    public func currentVideoFormat() -> VideoFormatReading? { nil }
    public func networkReading() -> NetworkReading? { nil }
    public func bufferedAheadSeconds() -> Double? { nil }
    public func setAudioEnhancement(_ config: AudioEnhancementConfig) {}
    public func setSubtitleDelay(seconds: Double) {}
    public func addExternalSubtitle(fileUrl: URL) -> Bool { false }
    public func seekLiveRelative(seconds: Double) {}
    public func returnToLive() {}
}
