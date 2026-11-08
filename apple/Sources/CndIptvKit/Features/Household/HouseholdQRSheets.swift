import SwiftUI
#if os(iOS)
import VisionKit
#endif

// Not on Apple TV: the household key is never displayed on a TV screen, and a TV has no camera.
#if !os(tvOS)

/// « Ajouter un appareil » : shows the household QR code for another device to scan.
/// The key is read from the Keychain when the sheet opens and only lives in memory while it is shown.
struct HouseholdQRSheet: View {
    let keyHex: String
    var onClose: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                if let image = HouseholdInvite.qrImage(forKeyHex: keyHex) {
                    Image(decorative: image, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .padding(14)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
                        .frame(maxWidth: 320)
                        .accessibilityLabel("QR code pour ajouter un appareil au foyer")
                } else {
                    Label("Impossible de créer le QR code.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
                Text("Sur l'autre appareil : Appareils, puis « Scanner un QR code ».")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Label("Ce code donne accès à vos favoris et à vos comptes IPTV. Ne le montrez qu'à vos propres appareils, et fermez cet écran ensuite.", systemImage: "lock.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle("Ajouter un appareil")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fermer", action: onClose) }
            }
        }
        #if os(macOS)
        .frame(minWidth: 400, idealWidth: 440, minHeight: 520, idealHeight: 560)
        #endif
    }
}

#if os(iOS)
/// « Scanner un QR code » : reads the household QR code shown by another device and hands the key over.
struct HouseholdScanSheet: View {
    /// Called once with a valid household key; the caller joins and closes the sheet.
    var onKey: (String) -> Void
    var onClose: () -> Void
    @State private var notAHouseholdCode = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    PairQrScanner { text in
                        if let key = HouseholdInvite.keyHex(fromScanned: text) {
                            notAHouseholdCode = false
                            onKey(key)
                        } else {
                            notAHouseholdCode = true
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal)
                } else {
                    Label("La caméra n'est pas disponible (autorisation refusée dans Réglages, ou appareil sans caméra). Collez la clé du foyer à la place.", systemImage: "camera.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .padding(.horizontal)
                }
                Text("Sur un appareil déjà dans le foyer, ouvrez Appareils puis « Afficher le QR code », et visez-le avec la caméra.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                if notAHouseholdCode {
                    Label("Ce QR code n'est pas un code de foyer Buntu.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .padding(.horizontal)
                }
                Spacer(minLength: 0)
            }
            .padding(.top)
            .navigationTitle("Scanner un QR code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler", action: onClose) }
            }
        }
    }
}
#endif

#endif
