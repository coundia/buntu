import SwiftUI
import CndCoreBridge

struct SettingsView: View {
    @Bindable var model: SettingsModel
    @Bindable var directory: DownloadDirectoryManager
    let stats: DbStats?
    var sync: CloudKitSyncManager?
    var ai: AiProviderSettings?
    var assistant: AssistantModel?

    @State private var showsOmdbKey = false
    @State private var showsAiKey = false
    @State private var aiStatus: AiProviderStatus?
    @State private var isTestingAi = false

    var body: some View {
        Form {
            downloadsSection
            networkSection
            omdbSection
            if let ai, let assistant { assistantSection(ai, assistant) }
            if let sync { iCloudSection(sync) }
            diagnosticSection
            aboutSection
        }
        .formStyle(.grouped)
        .navigationTitle("Réglages")
        .onDisappear { model.flush() }
    }

    // MARK: Sections

    private var downloadsSection: some View {
        Section("Téléchargements") {
            Stepper(value: $model.segmentsPerFile, in: SettingsModel.segmentRange) {
                LabeledContent("Segments par fichier", value: "\(model.segmentsPerFile)")
            }
            Stepper(value: $model.partSizeMB, in: SettingsModel.partSizeRangeMB) {
                LabeledContent("Taille d'une partie", value: "\(model.partSizeMB) Mo")
            }
            Stepper(value: $model.maxActiveFiles, in: SettingsModel.activeFilesRange) {
                LabeledContent("Fichiers simultanés", value: "\(model.maxActiveFiles)")
            }
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Dossier") {
                    Text(directory.directory.path)
                        .font(.callout).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }
                #if os(macOS)
                HStack {
                    Button("Choisir…") {
                        directory.chooseDirectory()
                        model.downloadDirectoryChanged()
                    }
                    Button("Par défaut") {
                        directory.resetToDefault()
                        model.downloadDirectoryChanged()
                    }
                    .disabled(!directory.isCustom)
                }
                #else
                Text("Visible dans l'app Fichiers, dans « Sur mon iPhone ».")
                    .font(.caption).foregroundStyle(.secondary)
                #endif
                if let error = directory.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    private var networkSection: some View {
        Section("Réseau et en-têtes HTTP") {
            TextField("User-Agent", text: $model.userAgent)
                .autocorrectionDisabled()
            TextField("Referer (optionnel)", text: $model.referer)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
        }
    }

    private var omdbSection: some View {
        Section {
            HStack {
                Group {
                    if showsOmdbKey {
                        TextField("Clé API OMDb", text: $model.omdbKey)
                    } else {
                        SecureField("Clé API OMDb", text: $model.omdbKey)
                    }
                }
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                Button { showsOmdbKey.toggle() } label: {
                    Image(systemName: showsOmdbKey ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(showsOmdbKey ? "Masquer la clé" : "Afficher la clé")
            }
        } header: {
            Text("Métadonnées OMDb")
        } footer: {
            Text("Stockée dans le Trousseau, jamais dans la base de données. Utilisée pour enrichir les fiches films et séries.")
        }
    }

    // MARK: Assistant IA

    @ViewBuilder
    private func assistantSection(_ ai: AiProviderSettings, _ assistant: AssistantModel) -> some View {
        @Bindable var ai = ai
        Section {
            Picker("Fournisseur", selection: $ai.choice) {
                ForEach(AiChoice.allCases) { Text($0.title).tag($0) }
            }
            if ai.choice.isRemote {
                TextField("Modèle", text: $ai.model, prompt: Text("Modèle par défaut du fournisseur"))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                TextField("Adresse du serveur", text: $ai.baseURL, prompt: Text(ai.choice.baseURLPlaceholder))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                HStack {
                    Group {
                        if showsAiKey {
                            TextField(ai.choice.requiresKey ? "Clé API" : "Clé API (facultative)", text: $ai.apiKey)
                        } else {
                            SecureField(ai.choice.requiresKey ? "Clé API" : "Clé API (facultative)", text: $ai.apiKey)
                        }
                    }
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    Button { showsAiKey.toggle() } label: { Image(systemName: showsAiKey ? "eye.slash" : "eye") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(showsAiKey ? "Masquer la clé" : "Afficher la clé")
                }
                if ai.endpointIsLocal {
                    Label("Serveur sur cet appareil : rien ne le quitte.", systemImage: "lock.shield")
                        .font(.callout).foregroundStyle(.green)
                } else {
                    Toggle("J'accepte d'envoyer mes commandes à ce fournisseur", isOn: $ai.consent)
                }
                HStack {
                    Button("Tester") { Task { await runAiTest(assistant) } }
                        .disabled(isTestingAi || (ai.choice.requiresKey && !ai.hasKey))
                    if isTestingAi { ProgressView().controlSize(.small) }
                    if let status = aiStatus {
                        Label(
                            status.ok ? "\(status.message) (\(status.latencyMs) ms, \(status.model))" : status.message,
                            systemImage: status.ok ? "checkmark.circle.fill" : "xmark.octagon.fill"
                        )
                        .font(.callout)
                        .foregroundStyle(status.ok ? .green : .red)
                    }
                }
                if let blocker = ai.blocker {
                    Label("\(blocker) En attendant, la résolution reste locale.", systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let keychainError = ai.keychainError {
                    Label(keychainError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
                }
                DisclosureGroup("Ce qui est envoyé") { sentTable }
                    .font(.callout)
            }
        } header: {
            Text("Assistant IA")
        } footer: {
            Text(assistantFooter(ai))
        }
        .onChange(of: ai.choice) { _, _ in aiStatus = nil }
    }

    private func assistantFooter(_ ai: AiProviderSettings) -> String {
        switch ai.choice {
        case .disabled: return "L'assistant (⌘K, bouton ✨) est masqué."
        case .localOnly: return "Les commandes explicites (« France 2 », « chaîne 6 », « suivante ») sont résolues sur l'appareil, sans aucun envoi. Choisissez un fournisseur pour les demandes plus libres."
        default: return "La clé est conservée dans le Trousseau. Sans clé, sans consentement ou en cas d'erreur, l'assistant retombe sur la résolution locale."
        }
    }

    private var sentTable: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Envoyé").font(.caption.weight(.semibold))
            Text("• la phrase que vous tapez\n• pour 40 chaînes au plus : nom, catégorie, numéro, programme en cours et suivant\n• la langue de l'interface")
                .font(.caption)
            Text("Jamais envoyé").font(.caption.weight(.semibold)).padding(.top, 4)
            Text("• les adresses des flux et le serveur IPTV\n• identifiants, mots de passe, en-têtes\n• l'historique, les favoris hors propositions, les téléchargements")
                .font(.caption)
        }
        .foregroundStyle(.secondary)
        .padding(.top, 4)
    }

    private func runAiTest(_ assistant: AssistantModel) async {
        isTestingAi = true
        aiStatus = await assistant.testProvider()
        isTestingAi = false
    }

    private func iCloudSection(_ sync: CloudKitSyncManager) -> some View {
        Section {
            LabeledContent("État") {
                HStack(spacing: 6) {
                    if sync.status == .syncing { ProgressView().controlSize(.small) }
                    Text(sync.status.title)
                }
            }
            if let detail = sync.status.detail {
                Label(detail, systemImage: sync.isAvailable ? "exclamationmark.triangle.fill" : "icloud.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Synchroniser maintenant") { Task { await sync.syncNow() } }
                .disabled(!sync.isAvailable || sync.status == .syncing)
        } header: {
            Text("Synchronisation iCloud")
        } footer: {
            Text("Seuls les sources, les favoris et la progression de lecture sont synchronisés. Le catalogue et le guide sont reconstruits sur chaque appareil, et les mots de passe restent dans le Trousseau.")
        }
    }

    private var diagnosticSection: some View {
        Section("Diagnostic") {
            Toggle("Afficher la console réseau", isOn: $model.showNetworkConsole)
            HStack {
                Button("Vider le cache des images") { Task { await model.clearImageCache() } }
                if let date = model.cacheClearedAt {
                    Text("Vidé à \(date.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
        }
    }

    private var aboutSection: some View {
        Section("À propos") {
            HStack(spacing: 12) {
                AppLogoView(size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("CND IPTV").font(.headline)
                    Text("Lecteur IPTV natif pour Mac, iPhone et iPad").font(.caption).foregroundStyle(.secondary)
                }
            }
            LabeledContent("Application", value: SettingsModel.appVersion)
            LabeledContent("Moteur Rust", value: model.engineVersion)
            if let stats {
                LabeledContent("Base de données", value: ByteCountFormatter.string(fromByteCount: Int64(stats.dbSizeBytes), countStyle: .file))
                LabeledContent("Chaînes / Films / Séries", value: "\(stats.totalLiveChannels) / \(stats.totalMovies) / \(stats.totalSeries)")
            }
        }
    }
}
