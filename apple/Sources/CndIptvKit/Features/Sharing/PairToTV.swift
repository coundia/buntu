import Foundation
import Observation
import Security
import CndCoreBridge

// PRD 39 — sending sources to a TV that shows a QR code. The protocol (keys, encryption, sessions) is
// the Rust one in `cnd-domain::pairing`, the same code the TV runs: this file only moves bytes.

enum PairingRandom {
    static func bytes(_ count: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &out)
        precondition(status == errSecSuccess, "no secure random bytes")
        return out
    }
}

/// Carries one sealed message to the TV and returns the TV's sealed answer. The answer comes only after
/// the user confirmed on the TV with the remote (minutes, not seconds).
protocol PairingTransporting: Sendable {
    func exchange(link: PairingLink, message: String, onDelivered: @escaping @Sendable () -> Void) async throws -> String
}

enum PairingTransportError: LocalizedError {
    case unsupported(String)
    case tvNotListening
    case unreachable(String)
    case timedOut
    case badAnswer

    var errorDescription: String? {
        switch self {
        case .unsupported(let t): return "Ce type de TV (\(t)) n'est pas encore pris en charge."
        case .tvNotListening: return "La TV n'écoute plus : rouvrez l'écran « Ajouter depuis le téléphone » sur la TV, puis scannez le nouveau code."
        case .unreachable: return "Votre téléphone ne voit pas la TV : vérifiez qu'ils sont sur le même Wi-Fi (pas un réseau invité)."
        case .timedOut: return "La TV n'a pas répondu à temps. Réessayez avec un nouveau code."
        case .badAnswer: return "Réponse illisible de la TV."
        }
    }
}

/// Samsung TV: the app listens on the TV's own channel (`ws://<tv>:8001/api/v2/channels/…`).
struct MsfPairingTransport: PairingTransporting {
    var timeout: TimeInterval = 330

    func exchange(link: PairingLink, message: String, onDelivered: @escaping @Sendable () -> Void) async throws -> String {
        guard let url = URL(string: "ws://\(link.host):\(link.port)/api/v2/channels/buntu.pair.\(link.session)") else {
            throw PairingTransportError.unreachable(link.host)
        }
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: url)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil); session.invalidateAndCancel() }
        let deadline = Date().addingTimeInterval(timeout)

        func next() async throws -> [String: Any] {
            while true {
                guard Date() < deadline else { throw PairingTransportError.timedOut }
                let received: URLSessionWebSocketTask.Message
                do {
                    received = try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
                        group.addTask { try await task.receive() }
                        group.addTask {
                            try await Task.sleep(nanoseconds: UInt64(max(0.1, deadline.timeIntervalSinceNow) * 1_000_000_000))
                            throw PairingTransportError.timedOut
                        }
                        let first = try await group.next()!
                        group.cancelAll()
                        return first
                    }
                } catch let error as PairingTransportError {
                    throw error
                } catch {
                    throw PairingTransportError.unreachable(link.host)
                }
                let text: String
                switch received {
                case .string(let s): text = s
                case .data(let d): text = String(decoding: d, as: UTF8.self)
                @unknown default: continue
                }
                if let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] { return object }
            }
        }

        // Welcome: the channel lists who is on it. The TV's app is one of them, or nobody would hear us.
        let welcome = try await next()
        guard welcome["event"] as? String == "ms.channel.connect" else { throw PairingTransportError.unreachable(link.host) }
        let clients = ((welcome["data"] as? [String: Any])?["clients"] as? [[String: Any]])?.count ?? 0
        guard clients >= 2 else { throw PairingTransportError.tvNotListening }

        let frame: [String: Any] = [
            "method": "ms.channel.emit",
            "params": ["event": "buntu.pair", "to": "broadcast", "data": message],
        ]
        let data = try JSONSerialization.data(withJSONObject: frame)
        do { try await task.send(.string(String(decoding: data, as: UTF8.self))) } catch { throw PairingTransportError.unreachable(link.host) }
        onDelivered()

        while true {
            let event = try await next()
            if event["event"] as? String == "buntu.pair.reply", let reply = event["data"] as? String { return reply }
        }
    }
}

/// Android TV: the TV answers a POST on its pairing address once the user has decided.
struct HttpPairingTransport: PairingTransporting {
    var timeout: TimeInterval = 330

    func exchange(link: PairingLink, message: String, onDelivered: @escaping @Sendable () -> Void) async throws -> String {
        guard let url = URL(string: "http://\(link.host):\(link.port)/pair") else { throw PairingTransportError.unreachable(link.host) }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(message.utf8)
        onDelivered()
        do {
            let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw PairingTransportError.badAnswer }
            return String(decoding: data, as: UTF8.self)
        } catch let error as PairingTransportError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw PairingTransportError.timedOut
        } catch {
            throw PairingTransportError.unreachable(link.host)
        }
    }
}

enum PairingTransports {
    static func make(for transport: String) throws -> PairingTransporting {
        switch transport {
        case "msf": return MsfPairingTransport()
        case "http": return HttpPairingTransport()
        default: throw PairingTransportError.unsupported(transport)
        }
    }
}

// MARK: - The sheet's model

@Observable
@MainActor
final class PairToTVModel {
    enum Stage: Equatable {
        case scanning
        case choosing
        case waitingForTV
        case done(Int)
        case refused
        case failed(String)
    }

    let share: ShareSourcesModel
    private(set) var stage: Stage = .scanning
    private(set) var link: PairingLink?
    private var linkText = ""
    private let makeTransport: (String) throws -> PairingTransporting
    private let now: () -> Int64
    private let randomBytes: (Int) -> [UInt8]
    private let phoneName: String

    init(
        share: ShareSourcesModel,
        phoneName: String = DeviceName.current,
        now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970) },
        randomBytes: @escaping (Int) -> [UInt8] = PairingRandom.bytes,
        makeTransport: @escaping (String) throws -> PairingTransporting = PairingTransports.make
    ) {
        self.share = share
        self.phoneName = phoneName
        self.now = now
        self.randomBytes = randomBytes
        self.makeTransport = makeTransport
        // The phone is the user's own device and so is the TV: passwords go along unless unticked.
        share.includeCredentials = Set(share.sources.filter { $0.sourceType == "xtream" }.map(\.id))
    }

    /// Reads a scanned (or pasted) link. Returns false when it is not a valid, current pairing link.
    @discardableResult
    func accept(scanned text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            link = try pairingParseLink(link: trimmed, now: now())
            linkText = trimmed
            stage = .choosing
            return true
        } catch {
            return false
        }
    }

    var sourcesAreEmpty: Bool { share.sources.isEmpty }

    func back() {
        stage = .scanning
        link = nil
    }

    func send() async {
        guard let link, !share.selected.isEmpty, stage == .choosing else { return }
        stage = .waitingForTV
        do {
            let document = try await share.exportDocument()
            let sealed = try pairingSeal(
                link: linkText, entropy: Data(randomBytes(44)), shareJson: document.json,
                phoneName: phoneName, now: now()
            )
            let transport = try makeTransport(link.transport)
            let answer = try await transport.exchange(link: link, message: sealed.message, onDelivered: {})
            let reply = try pairingOpenReply(replyKey: sealed.replyKey, session: link.session, reply: answer)
            switch reply.result {
            case "added": stage = .done(Int(reply.count))
            case "refused": stage = .refused
            default: stage = .failed("La TV n'a pas pu ajouter ces comptes.")
            }
        } catch let error as PairingTransportError {
            stage = .failed(error.errorDescription ?? "Envoi impossible")
        } catch {
            stage = .failed("Envoi impossible : \(error.localizedDescription)")
        }
    }
}
