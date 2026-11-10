import SwiftUI
import CndCoreBridge
#if os(iOS)
import VisionKit
#endif

// Not on Apple TV: it is a receiving screen, it has no camera to scan another TV.
#if !os(tvOS)

/// « Ajouter une TV Samsung » (PRD-45, PRD-43 sens B): any member of the household, whoever created it,
/// scans the pairing QR code the TV shows (Appareils > « Rejoindre (QR) ») and sends it the household.
/// The household key leaves only sealed by the PRD-39 pairing protocol: only that TV screen can open it.
@Observable
@MainActor
final class HouseholdAddTVModel {
    enum Stage: Equatable {
        case scanning
        case confirming
        case waitingForTV
        case done
        case refused
        case failed(String)
    }

    struct Credentials {
        let householdId: String
        let keyHex: String
        let deviceId: String
        let deviceName: String
    }

    private(set) var stage: Stage = .scanning
    private(set) var link: PairingLink?
    private var linkText = ""
    /// Read only when sending, never kept: the key is not held by the screen.
    private let credentials: () -> Credentials?
    private let makeTransport: (String) throws -> PairingTransporting
    private let now: () -> Int64
    private let randomBytes: (Int) -> [UInt8]

    init(
        credentials: @escaping () -> Credentials? = HouseholdAddTVModel.currentCredentials,
        now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970) },
        randomBytes: @escaping (Int) -> [UInt8] = PairingRandom.bytes,
        makeTransport: @escaping (String) throws -> PairingTransporting = PairingTransports.make
    ) {
        self.credentials = credentials
        self.now = now
        self.randomBytes = randomBytes
        self.makeTransport = makeTransport
    }

    /// This device's household: any member may add a device, not only the one that created it.
    static func currentCredentials() -> Credentials? {
        let store = HouseholdStore.shared
        guard store.isJoined, let id = store.householdId, let key = store.currentHouseholdKeyHex() else { return nil }
        return Credentials(householdId: id, keyHex: key, deviceId: store.deviceId, deviceName: store.deviceName)
    }

    @discardableResult
    func accept(scanned text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = try? pairingParseLink(link: trimmed, now: now()) else { return false }
        link = parsed
        linkText = trimmed
        stage = .confirming
        return true
    }

    func back() {
        stage = .scanning
        link = nil
    }

    /// The message the TV's `PairingService` understands (`type: household-join`).
    static func joinJson(_ c: Credentials) -> String? {
        let payload: [String: Any] = [
            "type": "household-join",
            "household_id": c.householdId,
            "household_key": c.keyHex,
            "household_name": "Foyer \(c.householdId.prefix(8))",
            "sender_device_id": c.deviceId,
            "sender_device_name": c.deviceName,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func send() async {
        guard let link, stage == .confirming else { return }
        guard let creds = credentials(), let json = Self.joinJson(creds) else {
            stage = .failed("Cet appareil n'est dans aucun foyer.")
            return
        }
        stage = .waitingForTV
        do {
            let sealed = try pairingSeal(
                link: linkText, entropy: Data(randomBytes(44)), shareJson: json,
                phoneName: creds.deviceName, now: now()
            )
            let transport = try makeTransport(link.transport)
            let answer = try await transport.exchange(link: link, message: sealed.message, onDelivered: {})
            let reply = try pairingOpenReply(replyKey: sealed.replyKey, session: link.session, reply: answer)
            switch reply.result {
            case "added": stage = .done
            case "refused": stage = .refused
            default: stage = .failed("La TV n'a pas pu rejoindre le foyer.")
            }
        } catch let error as PairingTransportError {
            stage = .failed(error.errorDescription ?? "Envoi impossible")
        } catch {
            stage = .failed("Envoi impossible : \(error.localizedDescription)")
        }
    }
}

struct HouseholdAddTVSheet: View {
    @State var model = HouseholdAddTVModel()
    var onClose: () -> Void
    @State private var pasted = ""
    @State private var scanError = false

    var body: some View {
        NavigationStack {
            Group {
                switch model.stage {
                case .scanning: scanning
                case .confirming: confirming
                case .waitingForTV: waiting
                case .done: finished(
                    icon: "checkmark.circle.fill", tint: .green, title: "La TV a rejoint le foyer",
                    detail: "Laissez Buntu ouvert sur la TV : elle apparaît dans « Appareils » sous quelques secondes."
                )
                case .refused: finished(icon: "xmark.circle.fill", tint: .orange, title: "Refusé sur la TV", detail: "La TV n'a pas rejoint le foyer.")
                case .failed(let message): finished(icon: "exclamationmark.triangle.fill", tint: .red, title: "Ajout impossible", detail: message)
                }
            }
            .navigationTitle("Ajouter une TV Samsung")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fermer", action: onClose) }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 420, idealHeight: 520)
        #endif
    }

    private var scanning: some View {
        VStack(spacing: 16) {
            #if os(iOS)
            if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                PairQrScanner { code in
                    if !model.accept(scanned: code) { scanError = true }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal)
            }
            #endif
            Text("Sur la TV, ouvrez « Appareils » puis « Rejoindre (QR) », et scannez le QR code affiché. Une TV déjà dans un autre foyer doit d'abord le quitter.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal)
            if scanError {
                Label("Ce code n'est pas valide ou a expiré : demandez-en un nouveau sur la TV.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange).padding(.horizontal)
            }
            DisclosureGroup("Saisir le lien à la main") {
                HStack {
                    TextField("buntu://pair?…", text: $pasted)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                    Button("Coller") { pasted = Clipboard.paste() ?? pasted }
                    Button("Valider") { scanError = !model.accept(scanned: pasted) }
                        .disabled(pasted.isEmpty)
                }
            }
            .padding(.horizontal)
            Spacer(minLength: 0)
        }
        .padding(.top)
    }

    private var confirming: some View {
        Form {
            if let link = model.link {
                Section {
                    Label("TV : \(link.tvName.isEmpty ? link.host : link.tvName)", systemImage: "tv")
                }
            }
            Section {
                Button {
                    Task { await model.send() }
                } label: {
                    Label("Ajouter cette TV au foyer", systemImage: "house.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button("Scanner un autre code") { model.back() }
            } footer: {
                Text("La clé du foyer part chiffrée de bout en bout : seul l'écran de cette TV peut la lire. La TV pourra lire vos favoris, reprises et comptes du foyer, et recevoir « Lire sur… ».")
            }
        }
    }

    private var waiting: some View {
        VStack(spacing: 18) {
            ProgressView().controlSize(.large)
            Text("Envoi à la TV…").font(.headline)
            Text("Gardez Buntu ouvert sur la TV.").font(.callout).foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func finished(icon: String, tint: Color, title: String, detail: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 54)).foregroundStyle(tint)
            Text(title).font(.title3.bold()).multilineTextAlignment(.center)
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Terminé", action: onClose).buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#endif
