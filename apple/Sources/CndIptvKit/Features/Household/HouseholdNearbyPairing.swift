import Foundation
import Network
import CryptoKit
import Observation

/// PRD-43 Mode C: Automatic local network pairing over Bonjour without camera and without typing a 64-character key.
/// Uses ephemeral Curve25519 key agreement, a 6-digit confirmation code (SAS), human authorization, and AES-256-GCM encryption.

public enum HouseholdSAS {
    public static let hkdfInfo = Data("buntu-pair-v1".utf8)

    /// Computes the 6-digit SAS code identical to Rust `cnd_domain::pairing::compute_sas`.
    public static func compute(sharedSecret: SymmetricKey, sessionId: String) -> String {
        var info = hkdfInfo
        info.append(contentsOf: sessionId.utf8)
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: sharedSecret,
            info: info,
            outputByteCount: 32
        )
        let bytes = derived.withUnsafeBytes { Array($0) }
        guard bytes.count >= 4 else { return "000000" }
        let u32Val = (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16) | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
        let num = (u32Val & 0x7FFF_FFFF) % 1_000_000
        return String(format: "%06d", num)
    }
}

// MARK: - Wire DTOs

struct HouseholdJoinRequestDTO: Codable {
    let type: String
    let sessionId: String
    let deviceName: String
    let deviceId: String
    let deviceType: String
    let clientEphemeralKeyB64: String
}

struct HouseholdJoinOfferDTO: Codable {
    let type: String
    let sessionId: String
    let hostDeviceName: String
    let householdName: String
    let hostEphemeralKeyB64: String
}

struct HouseholdJoinDecisionDTO: Codable {
    let type: String
    let sessionId: String
    let approved: Bool
    let encryptedPayloadB64: String?
    let nonceB64: String?
}

struct HouseholdCredentialsPayloadDTO: Codable {
    let householdId: String
    let householdKeyHex: String
    let householdName: String
}

// MARK: - Host (Inviter: already in household)

@Observable
@MainActor
public final class HouseholdNearbyPairingHost {
    public static let serviceType = "_buntu-pair._tcp"

    @MainActor
    public struct PendingRequest: Identifiable {
        public let id = UUID()
        public let deviceName: String
        public let deviceType: String
        public let sasCode: String
        fileprivate let approveAction: @MainActor () -> Void
        fileprivate let rejectAction: @MainActor () -> Void

        public func approve() { approveAction() }
        public func reject() { rejectAction() }
    }

    public enum State: Equatable {
        case idle
        case listening
        case requestReceived(deviceName: String, sasCode: String)
        case success(deviceName: String)
        case failed(String)
    }

    public private(set) var state: State = .idle
    public private(set) var pendingRequest: PendingRequest?

    @ObservationIgnored private let store: HouseholdStore
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var activeConnection: NWConnection?
    @ObservationIgnored private var timeoutWorkItem: DispatchWorkItem?
    @ObservationIgnored private let queue = DispatchQueue(label: "com.pcoundia.buntu.pairing.host", qos: .userInitiated)

    public init(store: HouseholdStore = .shared) {
        self.store = store
    }

    public func startListening() {
        stop()
        guard let keyHex = store.currentHouseholdKeyHex(), keyHex.count == 64 else {
            state = .failed("Aucun foyer actif à partager.")
            return
        }

        do {
            let params = NWParameters.tcp
            params.includePeerToPeer = true
            let l = try NWListener(using: params)
            l.service = NWListener.Service(name: store.deviceName, type: Self.serviceType)

            l.stateUpdateHandler = { [weak self] s in
                Task { @MainActor in
                    switch s {
                    case .ready:
                        self?.state = .listening
                    case .failed(let err):
                        self?.state = .failed("Écoute impossible : \(err.localizedDescription)")
                        self?.stop()
                    default:
                        break
                    }
                }
            }

            l.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in
                    self?.handleIncomingConnection(conn)
                }
            }

            l.start(queue: queue)
            self.listener = l

            // 2 minutes auto-timeout (PRD-43 § 2.1)
            let item = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    if case .listening = self?.state {
                        self?.state = .failed("Délai d'attente dépassé (2 minutes).")
                        self?.stop()
                    }
                }
            }
            queue.asyncAfter(deadline: .now() + 120, execute: item)
            self.timeoutWorkItem = item
        } catch {
            state = .failed("Erreur démarrage réseau : \(error.localizedDescription)")
        }
    }

    public func stop() {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        listener?.cancel()
        listener = nil
        activeConnection?.cancel()
        activeConnection = nil
        pendingRequest = nil
        if case .listening = state {
            state = .idle
        }
    }

    private func handleIncomingConnection(_ connection: NWConnection) {
        guard activeConnection == nil else {
            // Only one connection at a time (PRD-43 § 4.3)
            connection.cancel()
            return
        }
        self.activeConnection = connection
        connection.start(queue: queue)
        receiveFrame(from: connection) { [weak self] data in
            guard let self, let data else {
                connection.cancel()
                self?.activeConnection = nil
                return
            }
            self.processRequest(data, on: connection)
        }
    }

    private func processRequest(_ data: Data, on connection: NWConnection) {
        guard let req = try? JSONDecoder().decode(HouseholdJoinRequestDTO.self, from: data),
              req.type == "join_request",
              let clientKeyData = Data(base64Encoded: req.clientEphemeralKeyB64),
              let clientPublicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: clientKeyData)
        else {
            connection.cancel()
            activeConnection = nil
            return
        }

        // Host generates its ephemeral key
        let hostPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        guard let sharedSecret = try? hostPrivateKey.sharedSecretFromKeyAgreement(with: clientPublicKey) else {
            connection.cancel()
            activeConnection = nil
            return
        }

        let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: Data(),
            outputByteCount: 32
        )
        let sas = HouseholdSAS.compute(sharedSecret: symmetricKey, sessionId: req.sessionId)

        // Send JoinOfferDTO to client so it has host's public key
        let offer = HouseholdJoinOfferDTO(
            type: "join_offer",
            sessionId: req.sessionId,
            hostDeviceName: store.deviceName,
            householdName: "Foyer \(store.householdId?.prefix(8) ?? "")",
            hostEphemeralKeyB64: hostPrivateKey.publicKey.rawRepresentation.base64EncodedString()
        )
        if let offerData = try? JSONEncoder().encode(offer) {
            sendFrame(offerData, on: connection)
        }

        self.state = .requestReceived(deviceName: req.deviceName, sasCode: sas)
        self.pendingRequest = PendingRequest(
            deviceName: req.deviceName,
            deviceType: req.deviceType,
            sasCode: sas,
            approveAction: { [weak self] in
                self?.respondToRequest(approved: true, sessionId: req.sessionId, symmetricKey: symmetricKey, deviceName: req.deviceName)
            },
            rejectAction: { [weak self] in
                self?.respondToRequest(approved: false, sessionId: req.sessionId, symmetricKey: symmetricKey, deviceName: req.deviceName)
            }
        )
    }

    private func respondToRequest(approved: Bool, sessionId: String, symmetricKey: SymmetricKey, deviceName: String) {
        guard let conn = activeConnection else { return }

        if approved, let keyHex = store.currentHouseholdKeyHex() {
            let creds = HouseholdCredentialsPayloadDTO(
                householdId: store.householdId ?? "",
                householdKeyHex: keyHex,
                householdName: "Foyer \(store.householdId?.prefix(8) ?? "")"
            )
            do {
                let credsData = try JSONEncoder().encode(creds)
                let sealed = try AES.GCM.seal(credsData, using: symmetricKey)
                let decision = HouseholdJoinDecisionDTO(
                    type: "join_decision",
                    sessionId: sessionId,
                    approved: true,
                    encryptedPayloadB64: sealed.ciphertext.base64EncodedString(),
                    nonceB64: Data(sealed.nonce).base64EncodedString()
                )
                if let decisionData = try? JSONEncoder().encode(decision) {
                    sendFrame(decisionData, on: conn)
                }
                state = .success(deviceName: deviceName)
            } catch {
                state = .failed("Échec du chiffrement des identifiants.")
            }
        } else {
            let decision = HouseholdJoinDecisionDTO(
                type: "join_decision",
                sessionId: sessionId,
                approved: false,
                encryptedPayloadB64: nil,
                nonceB64: nil
            )
            if let decisionData = try? JSONEncoder().encode(decision) {
                sendFrame(decisionData, on: conn)
            }
            state = .idle
        }

        // Clean up
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.stop()
        }
    }

    private func sendFrame(_ payload: Data, on connection: NWConnection) {
        var length = UInt32(payload.count).bigEndian
        let packet = Data(bytes: &length, count: 4) + payload
        connection.send(content: packet, completion: .contentProcessed({ _ in }))
    }

    private func receiveFrame(from connection: NWConnection, completion: @escaping @MainActor (Data?) -> Void) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { lengthData, _, isComplete, err in
            guard let lengthData, lengthData.count == 4, err == nil else {
                Task { @MainActor in completion(nil) }
                return
            }
            let length = lengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            guard length > 0 && length < 100_000 else {
                Task { @MainActor in completion(nil) }
                return
            }
            connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { data, _, _, err in
                Task { @MainActor in
                    guard let data, data.count == Int(length), err == nil else {
                        completion(nil)
                        return
                    }
                    completion(data)
                }
            }
        }
    }
}

// MARK: - Client (Joiner: wants to join a household)

@Observable
@MainActor
public final class HouseholdNearbyPairingClient {
    public struct DiscoveredHost: Identifiable, Hashable {
        public let id: String
        public let name: String
        public let endpoint: NWEndpoint

        public static func == (lhs: DiscoveredHost, rhs: DiscoveredHost) -> Bool {
            lhs.id == rhs.id
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }
    }

    public enum State: Equatable {
        case idle
        case browsing
        case connecting(hostName: String)
        case waitingForAuthorization(hostName: String, sasCode: String)
        case success(householdId: String)
        case refused
        case failed(String)
    }

    public private(set) var state: State = .idle
    public private(set) var discoveredHosts: [DiscoveredHost] = []

    @ObservationIgnored private let store: HouseholdStore
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var activeConnection: NWConnection?
    @ObservationIgnored private let queue = DispatchQueue(label: "com.pcoundia.buntu.pairing.client", qos: .userInitiated)

    public init(store: HouseholdStore = .shared) {
        self.store = store
    }

    public func startBrowsing() {
        stop()
        discoveredHosts = []
        state = .browsing

        let params = NWParameters()
        params.includePeerToPeer = true
        let b = NWBrowser(for: .bonjour(type: HouseholdNearbyPairingHost.serviceType, domain: nil), using: params)

        b.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                var hosts: [DiscoveredHost] = []
                for res in results {
                    guard case .service(let name, _, _, _) = res.endpoint else { continue }
                    hosts.append(DiscoveredHost(id: name, name: name, endpoint: res.endpoint))
                }
                self?.discoveredHosts = hosts
            }
        }

        b.stateUpdateHandler = { [weak self] s in
            Task { @MainActor in
                if case .failed(let err) = s {
                    self?.state = .failed("Recherche interrompue : \(err.localizedDescription)")
                }
            }
        }

        b.start(queue: queue)
        self.browser = b
    }

    public func connectToHost(_ host: DiscoveredHost) {
        guard browser != nil else { return }
        state = .connecting(hostName: host.name)

        let conn = NWConnection(to: host.endpoint, using: .tcp)
        self.activeConnection = conn

        let sessionId = UUID().uuidString.prefix(8).lowercased()
        let clientPrivateKey = Curve25519.KeyAgreement.PrivateKey()

        conn.stateUpdateHandler = { [weak self] s in
            Task { @MainActor in
                switch s {
                case .ready:
                    self?.sendJoinRequest(on: conn, sessionId: String(sessionId), privateKey: clientPrivateKey, hostName: host.name)
                case .failed(let err):
                    self?.state = .failed("Connexion impossible : \(err.localizedDescription)")
                    self?.activeConnection?.cancel()
                    self?.activeConnection = nil
                default:
                    break
                }
            }
        }

        conn.start(queue: queue)
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        activeConnection?.cancel()
        activeConnection = nil
        if case .browsing = state {
            state = .idle
        }
    }

    private func sendJoinRequest(on conn: NWConnection, sessionId: String, privateKey: Curve25519.KeyAgreement.PrivateKey, hostName: String) {
        let req = HouseholdJoinRequestDTO(
            type: "join_request",
            sessionId: sessionId,
            deviceName: store.deviceName,
            deviceId: store.deviceId,
            deviceType: store.deviceType,
            clientEphemeralKeyB64: privateKey.publicKey.rawRepresentation.base64EncodedString()
        )
        guard let data = try? JSONEncoder().encode(req) else { return }
        sendFrame(data, on: conn)

        // Wait for JoinOfferDTO
        receiveFrame(from: conn) { [weak self] offerData in
            guard let self, let offerData,
                  let offer = try? JSONDecoder().decode(HouseholdJoinOfferDTO.self, from: offerData),
                  offer.type == "join_offer",
                  let hostKeyData = Data(base64Encoded: offer.hostEphemeralKeyB64),
                  let hostPublicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: hostKeyData),
                  let sharedSecret = try? privateKey.sharedSecretFromKeyAgreement(with: hostPublicKey)
            else {
                self?.state = .failed("Réponse invalide de l'hôte.")
                conn.cancel()
                return
            }

            let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: Data(),
                sharedInfo: Data(),
                outputByteCount: 32
            )
            let sas = HouseholdSAS.compute(sharedSecret: symmetricKey, sessionId: sessionId)

            self.state = .waitingForAuthorization(hostName: offer.hostDeviceName, sasCode: sas)

            // Wait for Decision
            self.receiveFrame(from: conn) { [weak self] decisionData in
                guard let self, let decisionData,
                      let decision = try? JSONDecoder().decode(HouseholdJoinDecisionDTO.self, from: decisionData)
                else {
                    self?.state = .failed("Décision d'adhésion illisible.")
                    conn.cancel()
                    return
                }

                if decision.approved,
                   let ctB64 = decision.encryptedPayloadB64,
                   let nonceB64 = decision.nonceB64,
                   let ctData = Data(base64Encoded: ctB64),
                   let nonceData = Data(base64Encoded: nonceB64),
                   let nonce = try? AES.GCM.Nonce(data: nonceData),
                   let sealedBox = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: ctData, tag: Data()),
                   let decrypted = try? self.decryptPayload(box: sealedBox, ct: ctData, nonce: nonce, key: symmetricKey)
                {
                    do {
                        let creds = try JSONDecoder().decode(HouseholdCredentialsPayloadDTO.self, from: decrypted)
                        let joinedId = try self.store.joinHousehold(keyHex: creds.householdKeyHex)
                        self.state = .success(householdId: joinedId)
                    } catch {
                        self.state = .failed("Erreur enregistrement de la clé : \(error.localizedDescription)")
                    }
                } else if decision.approved {
                    self.state = .failed("Paquet de clé incomplet.")
                } else {
                    self.state = .refused
                }
                conn.cancel()
            }
        }
    }

    private func decryptPayload(box: AES.GCM.SealedBox, ct: Data, nonce: AES.GCM.Nonce, key: SymmetricKey) throws -> Data {
        if let combinedBox = try? AES.GCM.SealedBox(combined: nonce.withUnsafeBytes { Data($0) } + ct) {
            if let data = try? AES.GCM.open(combinedBox, using: key) {
                return data
            }
        }
        return try AES.GCM.open(box, using: key)
    }

    private func sendFrame(_ payload: Data, on connection: NWConnection) {
        var length = UInt32(payload.count).bigEndian
        let packet = Data(bytes: &length, count: 4) + payload
        connection.send(content: packet, completion: .contentProcessed({ _ in }))
    }

    private func receiveFrame(from connection: NWConnection, completion: @escaping @MainActor (Data?) -> Void) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { lengthData, _, _, err in
            guard let lengthData, lengthData.count == 4, err == nil else {
                Task { @MainActor in completion(nil) }
                return
            }
            let length = lengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            guard length > 0 && length < 100_000 else {
                Task { @MainActor in completion(nil) }
                return
            }
            connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { data, _, _, err in
                Task { @MainActor in
                    guard let data, data.count == Int(length), err == nil else {
                        completion(nil)
                        return
                    }
                    completion(data)
                }
            }
        }
    }
}
