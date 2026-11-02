import XCTest
@testable import CndIptvApp

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, [String: String]))?
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        do {
            let (status, headers) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data([0]))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

final class StreamDiagnosisTests: XCTestCase {
    private var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }

    func testMessagesAreClearAndNeverContainAnAddress() {
        let all: [StreamDiagnosis] = [.http(429), .http(403), .http(404), .http(458), .http(503), .http(206), .http(418),
                                      .timeout, .unknownHost, .offline, .secureConnection, .unreachable]
        for diagnosis in all {
            XCTAssertFalse(diagnosis.message.isEmpty)
            XCTAssertFalse(diagnosis.message.contains("http://"))
        }
        XCTAssertTrue(StreamDiagnosis.http(429).message.contains("connexions simultanées"))
        XCTAssertTrue(StreamDiagnosis.http(429).message.contains("429"))
        XCTAssertTrue(StreamDiagnosis.http(403).message.contains("Accès refusé"))
        XCTAssertTrue(StreamDiagnosis.http(404).message.contains("introuvable"))
    }

    func testOnlyHopelessCausesStopTheReconnection() {
        for code in [401, 403, 404, 410, 429, 458] { XCTAssertTrue(StreamDiagnosis.http(code).isFinal, "\(code)") }
        for code in [200, 206, 500, 502, 503] { XCTAssertFalse(StreamDiagnosis.http(code).isFinal, "\(code)") }
        XCTAssertTrue(StreamDiagnosis.unknownHost.isFinal)
        XCTAssertFalse(StreamDiagnosis.timeout.isFinal)
        XCTAssertFalse(StreamDiagnosis.offline.isFinal)
    }

    func testURLErrorsAreClassified() {
        XCTAssertEqual(StreamDiagnosis.classify(URLError(.timedOut)), .timeout)
        XCTAssertEqual(StreamDiagnosis.classify(URLError(.cannotFindHost)), .unknownHost)
        XCTAssertEqual(StreamDiagnosis.classify(URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(StreamDiagnosis.classify(URLError(.serverCertificateUntrusted)), .secureConnection)
        XCTAssertEqual(StreamDiagnosis.classify(URLError(.cannotConnectToHost)), .unreachable)
    }

    func testProbeReportsStatusAndSendsRangeAndHeaders() async {
        StubProtocol.handler = { _ in (429, [:]) }
        let result = await StreamDiagnosis.probe(url: URL(string: "http://cdn.test/movie.mp4")!, headers: ["User-Agent": "UA"], session: session)
        XCTAssertEqual(result, .http(429))
        XCTAssertEqual(StubProtocol.lastRequest?.value(forHTTPHeaderField: "Range"), "bytes=0-0")
        XCTAssertEqual(StubProtocol.lastRequest?.value(forHTTPHeaderField: "User-Agent"), "UA")
    }

    func testProbeMapsNetworkErrors() async {
        StubProtocol.handler = { _ in throw URLError(.timedOut) }
        let result = await StreamDiagnosis.probe(url: URL(string: "http://cdn.test/a")!, headers: [:], session: session)
        XCTAssertEqual(result, .timeout)
    }

    // MARK: Controller

    private func media(_ name: String) -> PlayableMedia {
        PlayableMedia(title: name, url: URL(string: "http://cdn.test/\(name)")!, headers: [:], kind: .movie, startPositionMs: 0, stableHash: nil)
    }

    @MainActor
    private func controller(diagnoser: (@Sendable (PlayableMedia) async -> StreamDiagnosis)?, created: @escaping (MockBackend) -> Void) -> CndPlayerController {
        var timings = PlayerTimings()
        timings.reconnectBackoff = [0.05, 0.05, 0.05]
        timings.recoveryProbe = 0.1
        timings.tick = 0.02
        let controller = CndPlayerController(
            reachability: FakeReachability(),
            timings: timings,
            backendFactory: { kind in
                let backend = MockBackend(kind)
                backend.behavior = .fail("loading failed")
                created(backend)
                return backend
            }
        )
        controller.streamDiagnoser = diagnoser
        return controller
    }

    @MainActor
    func testRefusedByServerStopsReconnectionAndShowsTheReason() async {
        var backends: [MockBackend] = []
        let player = controller(diagnoser: { _ in .http(429) }, created: { backends.append($0) })
        let before = AppLog.shared.entries(after: 0).last?.seqId ?? 0
        player.open(media("a.mp4"))
        try? await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertEqual(player.diagnosis, .http(429))
        XCTAssertEqual(player.state, .failed(StreamDiagnosis.http(429).message))
        XCTAssertLessThanOrEqual(backends.count, 2, "AVPlayer then mpv, no reconnection reloads")
        let logs = AppLog.shared.entries(after: before).map(\.message)
        XCTAssertTrue(logs.contains { $0.contains("HTTP 429") && $0.contains("pas de nouvelle tentative") }, "\(logs)")
        player.close()
    }

    @MainActor
    func testRetryableCauseKeepsReconnectingAndMentionsTheCauseAtTheEnd() async {
        var backends: [MockBackend] = []
        let player = controller(diagnoser: { _ in .timeout }, created: { backends.append($0) })
        player.open(media("b.mp4"))
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        XCTAssertGreaterThan(backends.count, 3, "reconnection still runs for a timeout")
        XCTAssertEqual(player.state, .failed(StreamDiagnosis.timeout.message))
        player.close()
    }

    @MainActor
    func testWithoutDiagnoserBehaviourIsUnchanged() async {
        var backends: [MockBackend] = []
        let player = controller(diagnoser: nil, created: { backends.append($0) })
        player.open(media("c.mp4"))
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertNil(player.diagnosis)
        if case .failed(let reason) = player.state { XCTAssertTrue(reason.contains("Stream unavailable")) } else { XCTFail("expected failure") }
        player.close()
    }
}
