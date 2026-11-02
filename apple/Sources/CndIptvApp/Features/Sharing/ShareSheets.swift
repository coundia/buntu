import SwiftUI
import UniformTypeIdentifiers
import CndCoreBridge
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension Clipboard {
    @MainActor
    static func paste() -> String? {
        #if os(macOS)
        NSPasteboard.general.string(forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string
        #else
        nil
        #endif
    }
}

extension UTType {
    /// `.cndshare`; falls back to generic data when the app does not declare the type.
    static var cndShare: UTType { UTType(filenameExtension: ShareEnvelope.fileExtension) ?? .data }
}

// MARK: - Sender

struct ShareSourcesSheet: View {
    @State var model: ShareSourcesModel
    var onClose: () -> Void

    @State private var fileURL: URL?
    @State private var copied: String?

    var body: some View {
        NavigationStack {
            Group {
                if let package = model.package { result(package) } else { form }
            }
            .navigationTitle("Partager des sources")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fermer", action: onClose) }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 460, idealHeight: 560)
        #endif
    }

    // MARK: Choices

    private var form: some View {
        Form {
            Section("Sources à partager") {
                ForEach(model.sources, id: \.id) { source in
                    sourceRow(source)
                }
            }
            Section("Validité") {
                Picker("Le partage expire dans", selection: $model.validity) {
                    ForEach(ShareValidity.allCases) { Text($0.title).tag($0) }
                }
            }
            if model.sharesCredentials {
                Section {
                    Label(
                        "Partagez vos identifiants uniquement avec des personnes de confiance et si votre abonnement le permet. Le nombre de connexions simultanées est limité par votre fournisseur"
                            + (model.sharedConnectionLimit.map { " (\($0) autorisée(s))." } ?? "."),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.callout)
                    .foregroundStyle(.orange)
                }
            }
            if let message = model.errorMessage {
                Section { Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red) }
            }
            Section {
                Button {
                    Task { await model.prepare() }
                } label: {
                    HStack {
                        Text("Créer le partage")
                        if model.isPreparing { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(!model.canPrepare)
            } footer: {
                Text("Le partage est chiffré avec un code aléatoire. Sans identifiants, seules les adresses des serveurs sont incluses.")
            }
        }
        .formStyle(.grouped)
    }

    private func sourceRow(_ source: IptvSourceRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: binding(\.selected, source.id)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.name).font(.body.weight(.semibold))
                    Text(source.sourceType == "xtream" ? "Xtream · \(source.server ?? "")" : "M3U")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if model.selected.contains(source.id) {
                if ShareSourcesModel.isLocalPlaylist(source) {
                    Toggle("Inclure le contenu de la playlist locale", isOn: binding(\.includePlaylist, source.id))
                        .font(.callout)
                } else {
                    Toggle(
                        source.sourceType == "xtream" ? "Inclure le mot de passe (le nom d'utilisateur est toujours transmis)" : "Conserver les identifiants de l'adresse",
                        isOn: binding(\.includeCredentials, source.id)
                    )
                    .font(.callout)
                }
            }
        }
    }

    private func binding(_ keyPath: ReferenceWritableKeyPath<ShareSourcesModel, Set<Int64>>, _ id: Int64) -> Binding<Bool> {
        Binding(
            get: { model[keyPath: keyPath].contains(id) },
            set: { on in
                if on { model[keyPath: keyPath].insert(id) } else { model[keyPath: keyPath].remove(id) }
            }
        )
    }

    // MARK: Result

    private func result(_ package: SharePackage) -> some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    Text("Code de partage").font(.caption).foregroundStyle(.secondary)
                    #if os(tvOS)
                    Text(package.codeText)
                        .font(.system(.title2, design: .monospaced).weight(.semibold))
                        .multilineTextAlignment(.center)
                    #else
                    Text(package.codeText)
                        .font(.system(.title2, design: .monospaced).weight(.semibold))
                        .textSelection(.enabled)
                        .multilineTextAlignment(.center)
                    #endif
                    Text("Pour un fichier, communiquez ce code séparément.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                Button(copied == "code" ? "Code copié" : "Copier le code", systemImage: "doc.on.doc") {
                    Clipboard.copy(package.codeText)
                    copied = "code"
                }
            }
            Section("Envoyer") {
                #if !os(tvOS)
                if let fileURL {
                    ShareLink(item: fileURL) { Label("Partager le fichier .\(ShareEnvelope.fileExtension)…", systemImage: "square.and.arrow.up") }
                }
                #endif
                Button(copied == "link" ? "Lien copié" : "Copier le lien (contient le code)", systemImage: "link") {
                    Clipboard.copy(package.link)
                    copied = "link"
                }
            }
            if let qr = package.qrImage() {
                Section("QR code") {
                    Image(decorative: qr, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 260, maxHeight: 260)
                        .frame(maxWidth: .infinity)
                    Text("Le QR code et le lien contiennent aussi le code : ne les envoyez qu'à une personne de confiance.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Section {
                    Text("Ce partage est trop volumineux pour un QR code : utilisez le fichier ou le lien.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !package.warnings.isEmpty {
                Section("À savoir") {
                    ForEach(Array(package.warnings.enumerated()), id: \.offset) { _, warning in
                        Label("\(warning.sourceName) : \(warning.detail)", systemImage: "info.circle")
                            .font(.callout)
                    }
                }
            }
            Section {
                Text("\(package.sourceCount) source(s) · expire le \(package.expiresAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Refaire un partage") { model.reset(); fileURL = nil; copied = nil }
            }
        }
        .formStyle(.grouped)
        .onAppear { fileURL = try? package.writeFile() }
    }
}

// MARK: - Receiver

struct ImportShareSheet: View {
    @State var model: ShareImportModel
    var onClose: () -> Void

    @State private var showingFilePicker = false
    @State private var pasted = ""

    var body: some View {
        NavigationStack {
            Group {
                switch model.stage {
                case .input: input
                case .preview: preview
                case .done(let summary): done(summary)
                }
            }
            .navigationTitle("Importer un partage")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isDone ? "Terminer" : "Annuler", action: onClose)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 420, idealHeight: 520)
        #endif
        #if !os(tvOS)
        .fileImporter(isPresented: $showingFilePicker, allowedContentTypes: [.cndShare, .data]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) { model.load(envelope: data) }
        }
        #endif
    }

    private var isDone: Bool {
        if case .done = model.stage { return true }
        return false
    }

    private var errorRow: some View {
        Group {
            if let message = model.errorMessage {
                Section { Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red) }
            }
        }
    }

    private var input: some View {
        Form {
            if model.hasEnvelope, let header = model.header {
                Section("Partage reçu") {
                    Text("\(header.sourceCount) source(s)")
                    if let expires = model.expiresAt {
                        Text("Expire le \(expires.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Code de partage") {
                    TextField("XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XX", text: $model.codeText)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.characters)
                        #endif
                        .onSubmit { Task { await model.decrypt() } }
                    Button {
                        Task { await model.decrypt() }
                    } label: {
                        HStack {
                            Text("Déchiffrer et prévisualiser")
                            if model.isWorking { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(model.codeText.trimmingCharacters(in: .whitespaces).isEmpty || model.isWorking)
                }
            } else {
                Section("Choisir le partage") {
                    Button("Ouvrir un fichier .\(ShareEnvelope.fileExtension)…", systemImage: "doc") { showingFilePicker = true }
                    TextField("Coller un lien cndiptv://import#…", text: $pasted, axis: .vertical)
                        .lineLimit(1...3)
                        .autocorrectionDisabled()
                    HStack {
                        Button("Coller", systemImage: "doc.on.clipboard") { pasted = Clipboard.paste() ?? "" }
                        Spacer()
                        Button("Continuer") { model.load(pasted: pasted) }
                            .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            errorRow
        }
        .formStyle(.grouped)
    }

    private var preview: some View {
        Form {
            if let preview = model.preview {
                Section {
                    Text("De : \(preview.from.isEmpty ? "appareil inconnu" : preview.from)")
                    Text("Créé le \(Date(timeIntervalSince1970: TimeInterval(preview.createdAt)).formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                } footer: {
                    Text("Rien n'est ajouté avant votre confirmation.")
                }
                ForEach(preview.sources, id: \.index) { source in
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(source.name).font(.body.weight(.semibold))
                            Text(source.urlDisplay ?? source.server ?? "")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            if let user = source.username, !user.isEmpty {
                                Text("Utilisateur : \(user) · mot de passe \(source.hasPassword ? "inclus" : "absent")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if source.hasPlaylist { Text("Playlist incluse").font(.caption).foregroundStyle(.secondary) }
                            if source.needsCredentials {
                                Label("Identifiants à saisir après l'import", systemImage: "key")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                            if let name = source.duplicateName {
                                Label("Déjà présente : « \(name) »", systemImage: "exclamationmark.triangle")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                        Picker("Action", selection: decision(source.index)) {
                            Text("Ignorer").tag(ShareImportAction.skip)
                            if source.duplicateOf != nil {
                                Text("Remplacer l'existante").tag(ShareImportAction.replace)
                                Text("Ajouter quand même").tag(ShareImportAction.import)
                            } else {
                                Text("Importer").tag(ShareImportAction.import)
                            }
                        }
                    }
                }
            }
            errorRow
            Section {
                Button {
                    Task { await model.performImport() }
                } label: {
                    HStack {
                        Text("Importer \(model.chosenCount) source(s)")
                        if model.isWorking { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(model.chosenCount == 0 || model.isWorking)
            }
        }
        .formStyle(.grouped)
    }

    private func decision(_ index: UInt32) -> Binding<ShareImportAction> {
        Binding(get: { model.decisions[index] ?? .skip }, set: { model.decisions[index] = $0 })
    }

    private func done(_ summary: ShareImportSummary) -> some View {
        Form {
            Section {
                Label("\(summary.imported) ajoutée(s), \(summary.replaced) remplacée(s), \(summary.skipped) ignorée(s)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            if !summary.needingCredentials.isEmpty {
                Section("À compléter") {
                    ForEach(summary.needingCredentials, id: \.self) { name in
                        Label("\(name) : saisissez les identifiants via « Modifier… »", systemImage: "key")
                    }
                }
            }
            Section { Text("Les sources prêtes sont synchronisées en arrière-plan.").font(.caption).foregroundStyle(.secondary) }
        }
        .formStyle(.grouped)
    }
}
