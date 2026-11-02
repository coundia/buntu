import SwiftUI
import CndCoreBridge

/// Owns the form model so typing survives re-evaluation of the presenting view.
struct SourceFormSheet: View {
    @State private var model: SourceFormModel
    var onSaved: (Int64) -> Void
    var onCancel: () -> Void

    init(
        engine: CndEngine,
        keychain: KeychainStore,
        editing: IptvSourceRecord?,
        onSaved: @escaping (Int64) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _model = State(initialValue: SourceFormModel(engine: engine, keychain: keychain, editing: editing))
        self.onSaved = onSaved
        self.onCancel = onCancel
    }

    var body: some View {
        SourceFormContent(model: model, onSaved: onSaved, onCancel: onCancel)
    }
}

struct SourceFormContent: View {
    @Bindable var model: SourceFormModel
    var onSaved: (Int64) -> Void
    var onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $model.kind) {
                        ForEach(SourceKind.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.isEditing)
                    .labelsHidden()
                }

                Section("Informations") {
                    TextField("Nom", text: $model.name, prompt: Text("Mon IPTV"))
                    switch model.kind {
                    case .m3u: m3uFields
                    case .xtream: xtreamFields
                    }
                }

                if let message = model.validationMessage, showsValidation {
                    Section { Label(message, systemImage: "info.circle").foregroundStyle(.secondary) }
                }
                if let error = model.errorMessage {
                    Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(model.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(model.isEditing ? "Enregistrer" : "Ajouter") { save() }
                        .disabled(!model.canSave)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 380)
        #endif
    }

    /// Hides the hint on a pristine form so it does not open with an error-looking message.
    private var showsValidation: Bool {
        !model.name.isEmpty || !model.m3uUrl.isEmpty || !model.server.isEmpty
            || !model.username.isEmpty || !model.password.isEmpty
    }

    private var m3uFields: some View {
        Group {
            TextField("URL M3U / M3U8", text: $model.m3uUrl, prompt: Text("https://exemple.com/playlist.m3u"))
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
            TextField("URL EPG (optionnel)", text: $model.epgUrl, prompt: Text("https://exemple.com/epg.xml.gz"))
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
        }
    }

    private var xtreamFields: some View {
        Group {
            TextField("Serveur", text: $model.server, prompt: Text("http://serveur:8080"))
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
            TextField("Nom d'utilisateur", text: $model.username)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            SecureField("Mot de passe", text: $model.password)
            TextField("URL EPG (optionnel)", text: $model.epgUrl, prompt: Text("Par défaut : xmltv.php du serveur"))
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif

            HStack {
                Button {
                    Task { await model.testConnection() }
                } label: {
                    Label("Tester le compte", systemImage: "checkmark.shield")
                }
                .disabled(!model.canTest)
                if model.testState == .testing { ProgressView().controlSize(.small) }
            }
            testResult
        }
    }

    @ViewBuilder
    private var testResult: some View {
        switch model.testState {
        case .success(let info):
            Label(SourceFormModel.describe(info), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
        case .failure(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .font(.callout)
        case .idle, .testing:
            EmptyView()
        }
    }

    private func save() {
        model.errorMessage = nil
        Task {
            do {
                onSaved(try await model.save())
            } catch {
                model.errorMessage = userMessage(for: error)
            }
        }
    }
}
