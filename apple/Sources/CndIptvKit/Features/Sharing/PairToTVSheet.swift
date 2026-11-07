import SwiftUI
import CndCoreBridge
#if os(iOS)
import VisionKit
#endif

// Not on Apple TV: it is the receiving side there (a phone scans the TV's code), not a sender.
#if !os(tvOS)

/// « Envoyer vers une TV » (PRD 39): scan the QR code the TV shows, pick the accounts, send.
struct PairToTVSheet: View {
    @State var model: PairToTVModel
    var onClose: () -> Void
    @State private var pasted = ""
    @State private var scanError = false

    var body: some View {
        NavigationStack {
            Group {
                switch model.stage {
                case .scanning: scanning
                case .choosing: choosing
                case .waitingForTV: waiting
                case .done(let count): finished(
                    icon: "checkmark.circle.fill", tint: .green,
                    title: count > 0 ? "\(count) compte\(count > 1 ? "s" : "") ajouté\(count > 1 ? "s" : "") sur la TV" : "Rien n'a été ajouté",
                    detail: count > 0 ? "La TV synchronise vos comptes." : "Les comptes étaient peut-être déjà sur la TV."
                )
                case .refused: finished(icon: "xmark.circle.fill", tint: .orange, title: "Refusé sur la TV", detail: "Rien n'a été ajouté.")
                case .failed(let message): finished(icon: "exclamationmark.triangle.fill", tint: .red, title: "Envoi impossible", detail: message)
                }
            }
            .navigationTitle("Envoyer vers une TV")
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

    // MARK: Scan

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
            Text("Sur la TV, ouvrez « Ajouter depuis le téléphone », puis scannez le QR code affiché.")
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

    // MARK: Choose

    private var choosing: some View {
        Form {
            if let link = model.link {
                Section {
                    Label("TV : \(link.tvName.isEmpty ? link.host : link.tvName)", systemImage: "tv")
                }
            }
            ShareSourceChoices(model: model.share)
            Section {
                Button {
                    Task { await model.send() }
                } label: {
                    Label("Envoyer à la TV", systemImage: "paperplane.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.share.selected.isEmpty)
            } footer: {
                Text("Les comptes partent chiffrés de bout en bout : seul l'écran de cette TV peut les lire. Vous confirmerez l'ajout avec la télécommande.")
            }
        }
    }

    // MARK: Wait, finish

    private var waiting: some View {
        VStack(spacing: 18) {
            ProgressView().controlSize(.large)
            Text("Confirmez l'ajout sur la TV avec la télécommande…").font(.headline).multilineTextAlignment(.center)
            Text("Vous avez 5 minutes.").font(.callout).foregroundStyle(.secondary)
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

#if os(iOS)
/// The camera, reading QR codes only (VisionKit: the system asks for the camera on first use).
struct PairQrScanner: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        try? controller.startScanning()
        return controller
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        private var lastCode = ""
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems {
                if case .barcode(let code) = item, let text = code.payloadStringValue, text != lastCode {
                    lastCode = text
                    onCode(text)
                }
            }
        }
    }
}
#endif

#endif
