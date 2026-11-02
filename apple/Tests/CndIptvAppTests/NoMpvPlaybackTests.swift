import XCTest
@testable import CndIptvApp

/// iPhone and iPad ship without libmpv: raw TS channels must go through their HLS address.
final class NoMpvPlaybackTests: XCTestCase {
    private func url(_ text: String) -> URL { URL(string: text)! }

    func testXtreamLiveTsHasAnHlsAlternative() {
        XCTAssertEqual(
            PlayerRouting.hlsAlternative(for: url("http://srv.example:80/live/bob/s3cret/469902.ts")),
            url("http://srv.example:80/live/bob/s3cret/469902.m3u8")
        )
        XCTAssertEqual(
            PlayerRouting.hlsAlternative(for: url("https://srv.example/live/bob/s3cret/12")),
            url("https://srv.example/live/bob/s3cret/12.m3u8")
        )
    }

    func testOtherAddressesHaveNoHlsAlternative() {
        XCTAssertNil(PlayerRouting.hlsAlternative(for: url("http://srv.example/movie/bob/pw/1.mkv")))
        XCTAssertNil(PlayerRouting.hlsAlternative(for: url("http://srv.example/stream/channel.ts")))
        XCTAssertNil(PlayerRouting.hlsAlternative(for: url("http://srv.example/live/bob/pw/1.m3u8")))
    }

    func testAVPlayerSupportedExtensions() {
        for ext in ["m3u8", "mp4", "m4v", "mov"] { XCTAssertTrue(PlayerRouting.avPlayerCanPlay(url("http://h/a.\(ext)")), ext) }
        for ext in ["ts", "mkv", "avi", "flv"] { XCTAssertFalse(PlayerRouting.avPlayerCanPlay(url("http://h/a.\(ext)")), ext) }
    }

    @MainActor
    private func controller(created: @escaping (MockBackend) -> Void) -> CndPlayerController {
        CndPlayerController(
            reachability: FakeReachability(),
            backendFactory: { kind in
                let backend = MockBackend(kind)
                created(backend)
                return backend
            },
            isEngineAvailable: { $0 == .avPlayer }
        )
    }

    @MainActor
    func testLiveTsIsLoadedAsHlsInAVPlayerWhenMpvIsMissing() {
        var backends: [MockBackend] = []
        let player = controller { backends.append($0) }
        let media = PlayableMedia(title: "RTS1", url: url("http://srv.example/live/bob/pw/9.ts"), headers: ["User-Agent": "UA"], kind: .live)

        player.open(media)

        XCTAssertEqual(backends.map(\.engineKind), [.avPlayer])
        XCTAssertEqual(backends.first?.loads.first?.media.url, url("http://srv.example/live/bob/pw/9.m3u8"))
        XCTAssertEqual(backends.first?.loads.first?.media.headers, ["User-Agent": "UA"])
        XCTAssertEqual(player.media?.url, media.url, "the catalog address stays the media's identity")
        XCTAssertEqual(player.state, .playing)
        player.close()
    }

    @MainActor
    func testMkvFailsAtOnceWithAClearMessageWhenMpvIsMissing() {
        var backends: [MockBackend] = []
        let player = controller { backends.append($0) }
        player.open(PlayableMedia(title: "Film", url: url("http://srv.example/movie/bob/pw/1.mkv"), kind: .movie))

        XCTAssertTrue(backends.isEmpty, "no engine is started for a format it cannot read")
        guard case .failed(let reason) = player.state else { return XCTFail("expected failure, got \(player.state)") }
        XCTAssertTrue(reason.contains(".mkv"))
        XCTAssertTrue(reason.contains("libmpv"))
        player.close()
    }

    @MainActor
    func testMp4StillGoesStraightToAVPlayer() {
        var backends: [MockBackend] = []
        let player = controller { backends.append($0) }
        let media = PlayableMedia(title: "Film", url: url("http://srv.example/movie/bob/pw/1.mp4"), kind: .movie)
        player.open(media)
        XCTAssertEqual(backends.first?.loads.first?.media.url, media.url)
        player.close()
    }
}
