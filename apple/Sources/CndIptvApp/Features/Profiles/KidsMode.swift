import SwiftUI
import CndCoreBridge

/// What the Kids profile may not reach (PRD 20, lot 20.3): the sources, the settings (where accounts and
/// profiles are changed) and the AI assistant (which sends commands to a remote provider).
enum KidsModePolicy {
    static func allowedTabs(isKids: Bool) -> [AppTab] {
        isKids ? AppTab.allCases.filter { $0 != .sources && $0 != .settings } : AppTab.allCases
    }

    static func canUseAssistant(isKids: Bool) -> Bool { !isKids }
}

/// Leaves the Kids profile: asks for the parental PIN when one is set, then goes back to a regular profile.
struct KidsExitSheet: View {
    let profiles: ProfilesModel
    @State private var parental = ParentalControlManager.shared
    var onClose: () -> Void

    @State private var pin = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if parental.hasPin {
                        SecureField("Code PIN parental", text: $pin)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                            .onSubmit(unlock)
                    } else {
                        Text("Aucun code PIN n'est défini : n'importe qui peut quitter ce profil.")
                            .foregroundStyle(.secondary)
                    }
                    if let errorMessage {
                        Label(errorMessage, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    }
                    Button("Quitter le profil Enfants", action: unlock)
                        .disabled(parental.hasPin && pin.isEmpty)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Profil Enfants")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Annuler", action: onClose) } }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 220)
        #endif
    }

    private func unlock() {
        guard !parental.hasPin || parental.verifyPin(pin) else {
            pin = ""
            errorMessage = "Code PIN erroné"
            return
        }
        let regular = profiles.profiles.first { !$0.isKids }
        profiles.forceSelectProfile(id: regular?.id ?? 1)
        onClose()
    }
}
