import XCTest
@testable import CndIptvApp

/// PRD 15: a replay behaves like a film in the player but never becomes watch history.
@MainActor
final class ReplayTests: XCTestCase {
    private func player(recorder: FakeRecorder) -> CndPlayerController {
        CndPlayerController(
            recorder: recorder,
            reachability: FakeReachability(),
            backendFactory: { MockBackend($0) },
            isEngineAvailable: { _ in true }
        )
    }

    private func media(kind: PlayableKind) -> PlayableMedia {
        PlayableMedia(
            title: "TF1 — Journal [Replay]", url: URL(string: "http://h/timeshift/u/p/60/2026-11-02:20-00/1.ts")!,
            kind: kind, stableHash: "channel-hash", itemId: 7
        )
    }

    func testReplayIsNotLiveAndKeepsTheSeekBarOfAFilm() async throws {
        let recorder = FakeRecorder()
        let p = player(recorder: recorder)
        p.open(media(kind: .replay))
        try await Task.sleep(nanoseconds: 400_000_000) // the controller mirrors the engine on its tick
        XCTAssertFalse(p.isLive)
        XCTAssertEqual(p.durationMs, 600_000, "a bounded duration, like a film")
        p.close()
    }

    func testReplayProgressIsNeverRecordedInWatchHistory() async throws {
        let recorder = FakeRecorder()
        let p = player(recorder: recorder)
        p.open(media(kind: .replay))
        try await Task.sleep(nanoseconds: 300_000_000)
        p.saveProgress()
        p.close()
        XCTAssertTrue(recorder.calls.isEmpty, "the channel's own history entry must not move")
    }

    func testAFilmWithTheSameIdentityIsStillRecorded() async throws {
        let recorder = FakeRecorder()
        let p = player(recorder: recorder)
        p.open(media(kind: .movie))
        try await Task.sleep(nanoseconds: 300_000_000)
        p.saveProgress()
        p.close()
        XCTAssertFalse(recorder.calls.isEmpty, "the guard is specific to replays")
    }

    func testNowPlayingCallsItReplay() {
        XCTAssertEqual(NowPlayingInfoBuilder.defaultSubtitle(for: media(kind: .replay)), "Replay")
    }
}
