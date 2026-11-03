import XCTest
import CndCoreBridge
@testable import CndIptvKit

final class AudioAndSubtitleTests: XCTestCase {

    // MARK: - Lot 18.1 : Audio Enhancement & Dialogue Boost Tests

    func testAudioEnhancementConfigFilterStrings() {
        let offConfig = AudioEnhancementConfig(dialogueBoost: .off, nightMode: false)
        XCTAssertFalse(offConfig.isActive)
        XCTAssertEqual(offConfig.mpvFilterString, "")

        let lowConfig = AudioEnhancementConfig(dialogueBoost: .low, nightMode: false)
        XCTAssertTrue(lowConfig.isActive)
        XCTAssertTrue(lowConfig.mpvFilterString.contains("equalizer=f=2500:t=q:w=1.2:g=3"))
        XCTAssertTrue(lowConfig.mpvFilterString.contains("dynaudnorm"))
        XCTAssertFalse(lowConfig.mpvFilterString.contains("acompressor"))

        let medConfig = AudioEnhancementConfig(dialogueBoost: .medium, nightMode: false)
        XCTAssertTrue(medConfig.mpvFilterString.contains("g=6"))

        let highConfig = AudioEnhancementConfig(dialogueBoost: .high, nightMode: false)
        XCTAssertTrue(highConfig.mpvFilterString.contains("g=9"))

        let nightConfig = AudioEnhancementConfig(dialogueBoost: .off, nightMode: true)
        XCTAssertTrue(nightConfig.isActive)
        XCTAssertTrue(nightConfig.mpvFilterString.contains("acompressor=threshold=-24dB"))
        XCTAssertTrue(nightConfig.mpvFilterString.contains("loudnorm=I=-23:TP=-2"))
        XCTAssertFalse(nightConfig.mpvFilterString.contains("equalizer"))

        let combined = AudioEnhancementConfig(dialogueBoost: .high, nightMode: true)
        XCTAssertTrue(combined.isActive)
        XCTAssertTrue(combined.mpvFilterString.contains("g=9"))
        XCTAssertTrue(combined.mpvFilterString.contains("acompressor"))
    }

    // MARK: - Lot 18.2 : Subtitle Overlay & Delay Tests

    @MainActor
    func testSubtitleOverlayMatchingAndDelay() {
        let model = SubtitleOverlayModel()
        XCTAssertFalse(model.isLoaded)
        XCTAssertEqual(model.currentText, "")

        let cues = [
            SubtitleCue(index: 1, startMs: 5000, endMs: 9000, text: "Premier dialogue"),
            SubtitleCue(index: 2, startMs: 12000, endMs: 16000, text: "Deuxième réplique")
        ]
        model.load(cues: cues)
        XCTAssertTrue(model.isLoaded)

        // Before first cue
        model.update(positionMs: 2000)
        XCTAssertEqual(model.currentText, "")

        // Inside first cue
        model.update(positionMs: 6000)
        XCTAssertEqual(model.currentText, "Premier dialogue")

        // Between cues
        model.update(positionMs: 10500)
        XCTAssertEqual(model.currentText, "")

        // Inside second cue
        model.update(positionMs: 14000)
        XCTAssertEqual(model.currentText, "Deuxième réplique")

        // Positive delay (+1.0 s -> subtitle appears 1 s later)
        model.delaySeconds = 1.0
        // At 6000ms: effective is 5000ms -> cue 1 is visible
        model.update(positionMs: 6000)
        XCTAssertEqual(model.currentText, "Premier dialogue")
        // At 5500ms: effective is 4500ms -> not visible yet!
        model.update(positionMs: 5500)
        XCTAssertEqual(model.currentText, "")

        // Negative delay (-1.0 s -> subtitle appears 1 s earlier)
        model.delaySeconds = -1.0
        // At 4500ms: effective is 5500ms -> already visible!
        model.update(positionMs: 4500)
        XCTAssertEqual(model.currentText, "Premier dialogue")

        // Clear
        model.clear()
        XCTAssertFalse(model.isLoaded)
        XCTAssertEqual(model.currentText, "")
    }

    @MainActor
    func testPlayerControllerAudioEnhancementAndHlsNotice() {
        var appliedFilter: AudioEnhancementConfig?
        let mockBackend = MockVideoBackend()
        mockBackend.onSetAudioEnhancement = { config in
            appliedFilter = config
        }

        let controller = CndPlayerController(
            backendFactory: { _ in mockBackend }
        )

        let hlsUrl = URL(string: "http://example.com/live/stream.m3u8")!
        let hlsMedia = PlayableMedia(title: "Channel HLS", url: hlsUrl, kind: .live)

        // Open media (defaults to AVPlayer for .m3u8)
        controller.open(hlsMedia)
        XCTAssertEqual(controller.activeEngine, .avPlayer)

        // Enabling Dialogue Boost while on AVPlayer HLS stream triggers notice
        controller.setAudioEnhancement(AudioEnhancementConfig(dialogueBoost: .medium, nightMode: false))
        XCTAssertTrue(controller.showHlsAudioEnhancementNotice)
        XCTAssertEqual(appliedFilter?.dialogueBoost, .medium)

        // Switching to mpv dismisses notice and forces mpv
        controller.switchToMpvForAudioEnhancement()
        XCTAssertFalse(controller.showHlsAudioEnhancementNotice)
        XCTAssertEqual(controller.enginePreference, .forceMpv)

        // Setting subtitle delay
        controller.setSubtitleDelay(1.5)
        XCTAssertEqual(controller.subtitleDelaySeconds, 1.5)
        XCTAssertEqual(controller.subtitleOverlay.delaySeconds, 1.5)
    }
}

// MARK: - Mock Backend for Tests

private final class MockVideoBackend: VideoBackend {
    let engineKind: PlayerEngineKind = .avPlayer
    let displayLayer: CALayer = CALayer()
    var state: PlaybackState = .idle
    var positionMs: Int64 = 0
    var durationMs: Int64 = 0

    var onStateChange: ((PlaybackState) -> Void)?
    var onTracksChange: (() -> Void)?
    var onSetAudioEnhancement: ((AudioEnhancementConfig) -> Void)?

    func load(_ media: PlayableMedia, startPositionMs: Int64) {
        state = .playing
        onStateChange?(.playing)
    }
    func play() { state = .playing }
    func pause() { state = .paused }
    func seek(toMs positionMs: Int64) { self.positionMs = positionMs }
    func setRate(_ rate: Float) {}
    func setVolume(_ volume: Float) {}
    func setMuted(_ muted: Bool) {}

    func audioTracks() -> [MediaTrack] { [] }
    func subtitleTracks() -> [MediaTrack] { [] }
    func selectAudioTrack(id: String) {}
    func selectSubtitleTrack(id: String?) {}

    func setAudioEnhancement(_ config: AudioEnhancementConfig) {
        onSetAudioEnhancement?(config)
    }
    func setSubtitleDelay(seconds: Double) {}
    func addExternalSubtitle(fileUrl: URL) -> Bool { true }

    func teardown() {}
}
