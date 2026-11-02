import SwiftUI
import CndCoreBridge

struct SettingsView: View {
    @Bindable var model: SettingsModel
    @Bindable var directory: DownloadDirectoryManager
    let stats: DbStats?

    @State private var showsOmdbKey = false

    var body: some View {
        Form {
            downloadsSection
            networkSection
            omdbSection
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
            LabeledContent("Application", value: SettingsModel.appVersion)
            LabeledContent("Moteur Rust", value: model.engineVersion)
            if let stats {
                LabeledContent("Base de données", value: ByteCountFormatter.string(fromByteCount: Int64(stats.dbSizeBytes), countStyle: .file))
                LabeledContent("Chaînes / Films / Séries", value: "\(stats.totalLiveChannels) / \(stats.totalMovies) / \(stats.totalSeries)")
            }
        }
    }
}
