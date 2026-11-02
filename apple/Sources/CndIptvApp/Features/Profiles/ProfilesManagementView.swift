import SwiftUI
import CndCoreBridge

public struct ProfilesManagementView: View {
    let engine: CndEngine
    @State private var profilesModel: ProfilesModel?
    @State private var parental = ParentalControlManager.shared
    @State private var showingAddProfile = false
    @State private var showingPinSetup = false
    @State private var showingPinVerify = false
    @State private var pinInput = ""
    @State private var targetProfileToSwitch: ProfileRecord?
    @State private var pinErrorMessage: String?
    @State private var showingBouquetEditor = false

    public init(engine: CndEngine) {
        self.engine = engine
    }

    public var body: some View {
        Form {
            Section("Profils disponibles") {
                if let model = profilesModel {
                    ForEach(model.profiles, id: \.id) { profile in
                        HStack {
                            Image(systemName: profile.avatar.isEmpty ? "person.crop.circle" : profile.avatar)
                                .font(.title2)
                                .foregroundColor(profile.isKids ? .orange : .accentColor)
                                .frame(width: 36, height: 36)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(profile.name)
                                        .font(.headline)
                                    if profile.isKids {
                                        Text("Enfants")
                                            .font(.caption2.bold())
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.orange.opacity(0.2))
                                            .foregroundColor(.orange)
                                            .cornerRadius(4)
                                    }
                                    if profile.id == model.activeProfileId {
                                        Text("Actif")
                                            .font(.caption2.bold())
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.accentColor.opacity(0.2))
                                            .foregroundColor(.accentColor)
                                            .cornerRadius(4)
                                    }
                                }
                            }

                            Spacer()

                            if profile.id != model.activeProfileId {
                                Button("Basculer") {
                                    handleSwitch(to: profile, model: model)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }

                            if profile.id != 1 {
                                Button(role: .destructive) {
                                    _ = model.deleteProfile(id: profile.id)
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    Button {
                        showingAddProfile = true
                    } label: {
                        Label("Créer un profil", systemImage: "plus.circle")
                    }
                } else {
                    ProgressView()
                }
            }

            Section("Éditeur de bouquets") {
                Button {
                    showingBouquetEditor = true
                } label: {
                    Label("Organiser les catégories & dossiers", systemImage: "slider.horizontal.3")
                }
            }

            Section("Contrôle parental & Sécurité") {
                HStack {
                    Text("Code PIN parental")
                    Spacer()
                    if parental.hasPin {
                        Text("Configuré")
                            .foregroundColor(.secondary)
                        Button("Supprimer", role: .destructive) {
                            _ = parental.removePin()
                        }
                    } else {
                        Button("Définir un PIN") {
                            showingPinSetup = true
                        }
                    }
                }

                if parental.hasPin {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Déverrouillage +18 (Session 15 min)")
                            Text(parental.isAdultUnlocked ? "Déverrouillé" : "Verrouillé")
                                .font(.caption)
                                .foregroundColor(parental.isAdultUnlocked ? .green : .secondary)
                        }
                        Spacer()
                        if parental.isAdultUnlocked {
                            Button("Verrouiller") {
                                parental.lockAdultSession()
                            }
                        } else {
                            Button("Déverrouiller") {
                                showingPinVerify = true
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Profils & Contrôle parental")
        .sheet(isPresented: $showingAddProfile) {
            if let model = profilesModel {
                AddProfileSheet(model: model)
            }
        }
        .sheet(isPresented: $showingBouquetEditor) {
            BouquetEditorView(engine: engine)
        }
        .sheet(isPresented: $showingPinSetup) {
            PinSetupSheet(parental: parental)
        }
        .sheet(isPresented: $showingPinVerify) {
            PinVerifySheet(parental: parental, onSuccess: {
                parental.unlockAdultSession()
            })
        }
        .alert("Code PIN requis", isPresented: Binding(get: { targetProfileToSwitch != nil }, set: { if !$0 { targetProfileToSwitch = nil } })) {
            SecureField("Code PIN parental", text: $pinInput)
            Button("Valider") {
                if parental.verifyPin(pinInput) {
                    if let target = targetProfileToSwitch, let model = profilesModel {
                        model.forceSelectProfile(id: target.id)
                    }
                    pinInput = ""
                    targetProfileToSwitch = nil
                } else {
                    pinInput = ""
                    pinErrorMessage = "Code PIN erroné"
                }
            }
            Button("Annuler", role: .cancel) {
                pinInput = ""
                targetProfileToSwitch = nil
            }
        }
        .task {
            profilesModel = ProfilesModel(engine: engine)
        }
    }

    private func handleSwitch(to profile: ProfileRecord, model: ProfilesModel) {
        if model.isKidsModeActive && !profile.isKids && parental.hasPin {
            targetProfileToSwitch = profile
        } else {
            Task {
                _ = await model.selectProfile(profile, parental: parental)
            }
        }
    }
}

private struct AddProfileSheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: ProfilesModel
    @State private var name = ""
    @State private var isKids = false
    @State private var selectedAvatar = "person.crop.circle"

    let avatars = [
        "person.crop.circle", "figure.child", "star.fill", "tv.fill",
        "heart.fill", "sparkles", "gamecontroller.fill", "crown.fill"
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Identité") {
                    TextField("Nom du profil", text: $name)
                    Toggle("Profil Enfants (sécurisé)", isOn: $isKids)
                }

                Section("Avatar") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 12) {
                        ForEach(avatars, id: \.self) { av in
                            Image(systemName: av)
                                .font(.title)
                                .padding()
                                .background(selectedAvatar == av ? Color.accentColor.opacity(0.2) : Color.clear)
                                .clipShape(Circle())
                                .onTapGesture {
                                    selectedAvatar = av
                                }
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
            .navigationTitle("Nouveau profil")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Créer") {
                        if !name.trimmingCharacters(in: .whitespaces).isEmpty {
                            _ = model.createProfile(name: name, avatar: selectedAvatar, isKids: isKids)
                            dismiss()
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .frame(minWidth: 400, minHeight: 350)
    }
}

private struct PinSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    let parental: ParentalControlManager
    @State private var pin = ""
    @State private var confirmPin = ""
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Nouveau code PIN (4-6 chiffres)", text: $pin)
                    SecureField("Confirmer le code PIN", text: $confirmPin)
                    if let errorText {
                        Text(errorText)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                } footer: {
                    Text("Ce code PIN protège les catégories adultes et la sortie du profil Enfants.")
                }
            }
            .navigationTitle("Définir le PIN parental")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") {
                        if pin.count < 4 {
                            errorText = "Le code PIN doit comporter au moins 4 chiffres."
                        } else if pin != confirmPin {
                            errorText = "Les deux codes ne correspondent pas."
                        } else {
                            if parental.setPin(pin) {
                                dismiss()
                            } else {
                                errorText = "Impossible d'enregistrer le PIN dans le Trousseau."
                            }
                        }
                    }
                    .disabled(pin.isEmpty || confirmPin.isEmpty)
                }
            }
        }
        .frame(minWidth: 350, minHeight: 250)
    }
}

private struct PinVerifySheet: View {
    @Environment(\.dismiss) private var dismiss
    let parental: ParentalControlManager
    let onSuccess: () -> Void
    @State private var pin = ""
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Code PIN parental", text: $pin)
                    if let errorText {
                        Text(errorText)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }

                if parental.isBiometricsAvailable {
                    Section {
                        Button {
                            Task {
                                if await parental.authenticateWithBiometrics() {
                                    onSuccess()
                                    dismiss()
                                }
                            }
                        } label: {
                            Label("Déverrouiller avec Touch ID / Face ID", systemImage: "faceid")
                        }
                    }
                }
            }
            .navigationTitle("Contrôle parental")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Valider") {
                        if parental.verifyPin(pin) {
                            onSuccess()
                            dismiss()
                        } else {
                            errorText = "Code PIN incorrect."
                            pin = ""
                        }
                    }
                }
            }
        }
        .frame(minWidth: 350, minHeight: 220)
    }
}

