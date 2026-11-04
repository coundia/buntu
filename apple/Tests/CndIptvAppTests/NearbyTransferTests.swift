import XCTest
import Network
import CndCoreBridge
@testable import CndIptvKit

@MainActor
final class NearbyTransferTests: XCTestCase {
    private func listeningServer(duration: TimeInterval = 30) async throws -> (NearbyTransferServer, NWEndpoint) {
        let server = NearbyTransferServer(deviceName: "Test-\(UUID().uuidString.prefix(6))", listenDuration: duration)
        server.startListening()
        for _ in 0..<100 {
            if case .listening(let port) = server.state, port != 0 {
                return (server, .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!))
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("server did not start: \(server.state)")
        throw NearbyTransfer.Failure.timeout
    }

    func testPinIsSixRandomDigitsAndNeverAdvertised() {
        let pins = Set((0..<30).map { _ in NearbyTransfer.makePin() })
        XCTAssertGreaterThan(pins.count, 20)
        XCTAssertTrue(pins.allSatisfy { NearbyTransfer.isValid(pin: $0) })
        XCTAssertFalse(NearbyTransfer.isValid(pin: "12345"))
        XCTAssertFalse(NearbyTransfer.isValid(pin: "12345a"))
        let server = NearbyTransferServer(deviceName: "Salon")
        XCTAssertEqual(server.state, .idle)
        XCTAssertEqual(server.pairingCode.count, 6)
    }

    func testPayloadTravelsWithTheRightCode() async throws {
        let (server, endpoint) = try await listeningServer()
        var received: Data?
        server.onEnvelopeReceived = { received = $0 }
        let payload = Data("cndiptv://import#abc.DEF".utf8)

        try await NearbyTransferClient().send(payload, to: endpoint, pin: server.pairingCode)

        XCTAssertEqual(received, payload)
        XCTAssertEqual(server.state, .completed(sourceCount: 1))
    }

    func testWrongCodeIsRefusedAndNothingIsDelivered() async throws {
        let (server, endpoint) = try await listeningServer()
        var delivered = false
        server.onEnvelopeReceived = { _ in delivered = true }
        let wrong = server.pairingCode == "000000" ? "111111" : "000000"

        do {
            try await NearbyTransferClient().send(Data("secret".utf8), to: endpoint, pin: wrong)
            XCTFail("a wrong code must not be accepted")
        } catch {
            XCTAssertEqual(error as? NearbyTransfer.Failure, .wrongCode)
        }
        XCTAssertFalse(delivered)
        server.stop()
    }

    func testReceiverClosesAfterTooManyWrongCodes() async throws {
        let (server, endpoint) = try await listeningServer()
        let wrong = server.pairingCode == "000000" ? "111111" : "000000"
        for _ in 0..<NearbyTransfer.maxFailedAttempts {
            _ = try? await NearbyTransferClient().send(Data("x".utf8), to: endpoint, pin: wrong, timeout: 3)
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard case .failed = server.state else { return XCTFail("expected the receiver to close, got \(server.state)") }

        // Even the right code no longer works once it is closed.
        do {
            try await NearbyTransferClient().send(Data("x".utf8), to: endpoint, pin: server.pairingCode, timeout: 3)
            XCTFail("closed receiver must refuse")
        } catch {}
    }

    func testClientRejectsBadInputBeforeConnecting() async {
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 9)
        do {
            try await NearbyTransferClient().send(Data(), to: endpoint, pin: "12")
            XCTFail()
        } catch { XCTAssertEqual(error as? NearbyTransfer.Failure, .invalidPin) }
        do {
            let big = Data(count: NearbyTransfer.maxPayloadBytes + 1)
            try await NearbyTransferClient().send(big, to: endpoint, pin: "123456")
            XCTFail()
        } catch { XCTAssertEqual(error as? NearbyTransfer.Failure, .tooLarge) }
    }

    func testReceiverStopsListeningAfterItsDelay() async throws {
        let (server, _) = try await listeningServer(duration: 0.3)
        try await Task.sleep(nanoseconds: 800_000_000)
        guard case .failed = server.state else { return XCTFail("expected expiry, got \(server.state)") }
    }
}

@MainActor
final class NearbyModelsTests: XCTestCase {
    private var sender: CndEngine!
    private var keychain: KeychainStore!

    override func setUp() async throws {
        sender = try CndEngine.inMemory()
        keychain = KeychainStore(service: "com.cnd.iptv.tests.nearby.\(UUID().uuidString)")
    }

    private func peer(_ name: String) -> NearbyTransferClient.DiscoveredPeer {
        .init(id: name, name: name, endpoint: .service(name: name, type: NearbyTransfer.serviceType, domain: "local.", interface: nil))
    }

    private func makeModel(sources: Int = 1, deliver: @escaping NearbySendModel.Sender) throws -> NearbySendModel {
        for index in 0..<sources {
            _ = try sender.addSource(name: "Source \(index)", sourceType: "m3u", url: "http://example.com/list\(index).m3u", server: nil, username: nil, passwordRef: nil)
        }
        let records = try sender.listSources()
        let share = ShareSourcesModel(engine: sender, keychain: keychain, sources: records, preselected: Set(records.map(\.id)))
        let model = NearbySendModel(share: share, sender: deliver)
        model.client.discoveredPeers = [peer("iPhone de Papa")]
        return model
    }

    func testSendNeedsADeviceAndASixDigitCode() throws {
        let model = try makeModel { _, _, _ in }
        XCTAssertFalse(model.canSend)
        model.selectedPeerID = "iPhone de Papa"
        XCTAssertFalse(model.canSend)
        model.pin = "12345"
        XCTAssertFalse(model.canSend)
        model.pin = "123456"
        XCTAssertTrue(model.canSend)
    }

    func testSendDeliversAnEncryptedLinkThatTheReceiverCanImport() async throws {
        var delivered: (Data, String, String)?
        let model = try makeModel(sources: 2) { payload, peer, pin in delivered = (payload, peer.name, pin) }
        model.selectedPeerID = "iPhone de Papa"
        model.pin = "482913"

        await model.send()

        XCTAssertEqual(model.status, .sent)
        let (payload, name, pin) = try XCTUnwrap(delivered)
        XCTAssertEqual(name, "iPhone de Papa")
        XCTAssertEqual(pin, "482913")
        let link = try XCTUnwrap(String(data: payload, encoding: .utf8))
        XCTAssertTrue(link.hasPrefix("cndiptv://import#"))
        let incoming = try XCTUnwrap(IncomingShare.from(url: URL(string: link)!))
        XCTAssertNotNil(incoming.code, "the code travels inside the protected channel")
        XCTAssertNil(model.share.package, "the share is not kept after sending")

        // The receiving side opens it with the code it got.
        let receiver = ShareImportModel(engine: try CndEngine.inMemory(), keychain: keychain, importsDirectory: FileManager.default.temporaryDirectory, incoming: incoming)
        await receiver.decrypt()
        XCTAssertEqual(receiver.stage, .preview)
        XCTAssertEqual(receiver.preview?.sources.count, 2)
    }

    func testSendFailureIsReportedAndKeepsNothing() async throws {
        let model = try makeModel { _, _, _ in throw NearbyTransfer.Failure.wrongCode }
        model.selectedPeerID = "iPhone de Papa"
        model.pin = "000000"
        await model.send()
        XCTAssertEqual(model.status, .failed(NearbyTransfer.Failure.wrongCode.errorDescription!))
        XCTAssertNil(model.share.package)
        model.pin = "000001"
        XCTAssertEqual(model.status, .idle, "editing the code clears the error")
    }

    func testReceiverHandsAValidLinkToTheImportFlow() async throws {
        let code = ShareEnvelope.makeCode()
        let envelope = try ShareEnvelope.seal(document: Data("{}".utf8), code: code, sourceCount: 1, expiresAt: Int64(Date().addingTimeInterval(600).timeIntervalSince1970))
        let receiver = NearbyReceiveModel(server: NearbyTransferServer(deviceName: "x"))
        var got: IncomingShare?
        receiver.onReceived = { got = $0 }
        receiver.server.onEnvelopeReceived?(Data(ShareEnvelope.link(envelope: envelope, code: code).utf8))
        XCTAssertEqual(got?.envelope, envelope)
        XCTAssertEqual(got?.code, ShareEnvelope.format(code: code))
    }

    func testReceiverRejectsGarbage() {
        let receiver = NearbyReceiveModel(server: NearbyTransferServer(deviceName: "x"))
        var called = false
        receiver.onReceived = { _ in called = true }
        receiver.server.onEnvelopeReceived?(Data("not a share".utf8))
        XCTAssertFalse(called)
        XCTAssertEqual(receiver.status, .failed(AppBrand.notAShareContent))
    }
}
