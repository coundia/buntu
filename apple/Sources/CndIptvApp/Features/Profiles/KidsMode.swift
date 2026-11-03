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

/// Shows the categories recognised as adult for 15 minutes once the parental PIN (or Face ID / Touch ID) is given.
/// Without a PIN the unlock is free, and the sheet says so.
struct AdultUnlockSheet: View {
    let parental: ParentalControlManager
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
                        Text("Aucun code PIN n'est défini : le contenu adulte se déverrouille sans contrôle. Définissez un PIN dans Profils pour le protéger.")
                            .foregroundStyle(.secondary)
                    }
                    if let errorMessage {
                        Label(errorMessage, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    }
                    Button("Déverrouiller pendant 15 minutes", action: unlock)
                        .disabled(parental.hasPin && pin.isEmpty)
                }
                if parental.hasPin, parental.isBiometricsAvailable {
                    Section {
                        Button {
                            Task {
                                if await parental.authenticateWithBiometrics() {
                                    parental.unlockAdultSession()
                                    onClose()
                                }
                            }
                        } label: {
                            Label("Face ID / Touch ID", systemImage: "faceid")
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Contenu adulte")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Annuler", action: onClose) } }
        }
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 260)
        #endif
    }

    private func unlock() {
        guard !parental.hasPin || parental.verifyPin(pin) else {
            pin = ""
            errorMessage = "Code PIN erroné"
            return
        }
        parental.unlockAdultSession()
        onClose()
    }
}

/// "Qui regarde ?": offered once at launch when there is more than one profile. Leaving the Kids profile
/// for a regular one asks for the parental PIN (when one is set), like the lock button does.
struct ProfilePickerSheet: View {
    let profiles: ProfilesModel
    @State private var parental = ParentalControlManager.shared
    var onClose: () -> Void

    @State private var pendingProfile: ProfileRecord?
    @State private var pin = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Qui regarde ?") {
                    ForEach(profiles.profiles, id: \.id) { profile in
                        Button { choose(profile) } label: {
                            HStack {
                                Image(systemName: profile.avatar.isEmpty ? "person.circle.fill" : profile.avatar)
                                    .foregroundStyle(profile.isKids ? .orange : Color.accentColor)
                                Text(profile.name)
                                if profile.isKids { Text("Enfants").font(.caption).foregroundStyle(.secondary) }
                                Spacer()
                                if profile.id == profiles.activeProfileId { Image(systemName: "checkmark") }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                if pendingProfile != nil {
                    Section("Code PIN parental") {
                        SecureField("Code PIN", text: $pin)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                            .onSubmit(confirm)
                        if let errorMessage {
                            Label(errorMessage, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                        }
                        Button("Valider", action: confirm).disabled(pin.isEmpty)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Profils")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Garder le profil actuel", action: onClose) } }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 300)
        #endif
    }

    private func choose(_ profile: ProfileRecord) {
        if profiles.isKidsModeActive, !profile.isKids, parental.hasPin {
            pendingProfile = profile
            return
        }
        profiles.forceSelectProfile(id: profile.id)
        onClose()
    }

    private func confirm() {
        guard let target = pendingProfile else { return }
        guard parental.verifyPin(pin) else {
            pin = ""
            errorMessage = "Code PIN erroné"
            return
        }
        profiles.forceSelectProfile(id: target.id)
        onClose()
    }
}
