import SwiftUI
import CndCoreBridge
#if os(macOS)
import AppKit
#endif

struct AddUrlsSheet: View {
    let model: DownloadsModel
    let directory: DownloadDirectoryManager
    var onDone: () -> Void

    @State private var text = ""
    @State private var userAgent = ""
    @State private var referer = ""
    @State private var showsOptions = false
    @State private var folderOverride: URL?
    @State private var isSubmitting = false

    private var parsed: (valid: [URL], invalid: [String]) { AddUrlsParser.parse(text) }
    private var targetFolder: URL { folderOverride ?? directory.directory }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    #if os(tvOS)
                    TextField("Liens...", text: $text)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                    #else
                    TextEditor(text: $text)
                        .font(.body.monospaced())
                        .frame(minHeight: 140)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    #endif
                } header: {
                    Text("Liens (un par ligne)")
                } footer: {
                    summary
                }

                Section("Dossier cible") {
                    HStack {
                        Text(targetFolder.path).font(.callout).lineLimit(2).truncationMode(.middle)
                        Spacer()
                        #if os(macOS)
                        Button("Choisir…", action: chooseFolder)
                        #endif
                    }
                }

                #if os(tvOS)
                Section("En-têtes HTTP (optionnel)") {
                    TextField("User-Agent", text: $userAgent)
                    TextField("Referer", text: $referer)
                }
                #else
                Section {
                    DisclosureGroup("En-têtes HTTP (optionnel)", isExpanded: $showsOptions) {
                        TextField("User-Agent", text: $userAgent)
                        TextField("Referer", text: $referer)
                    }
                }
                #endif
            }
            .formStyle(.grouped)
            .navigationTitle("Ajouter des liens")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler", action: onDone) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Télécharger") { submit() }
                        .disabled(parsed.valid.isEmpty || isSubmitting)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 460)
        #endif
    }

    @ViewBuilder
    private var summary: some View {
        let result = parsed
        VStack(alignment: .leading, spacing: 2) {
            if !result.valid.isEmpty { Text("\(result.valid.count) lien(s) valide(s)") }
            if !result.invalid.isEmpty {
                Text("\(result.invalid.count) ligne(s) ignorée(s) : seules les URLs http:// et https:// sont acceptées.")
                    .foregroundStyle(.orange)
            }
        }
    }

    private func submit() {
        isSubmitting = true
        let agent = userAgent.trimmingCharacters(in: .whitespaces)
        let ref = referer.trimmingCharacters(in: .whitespaces)
        let requests = parsed.valid.map { url in
            NewDownloadRequest(
                url: url.absoluteString, fileName: nil, saveDir: targetFolder.path,
                userAgent: agent.isEmpty ? nil : agent, referer: ref.isEmpty ? nil : ref,
                headersJson: nil, autoStart: true
            )
        }
        Task {
            await model.enqueue(requests)
            isSubmitting = false
            onDone()
        }
    }

    #if os(macOS)
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = targetFolder
        panel.prompt = "Choisir"
        if panel.runModal() == .OK, let url = panel.url { folderOverride = url }
    }
    #endif
}
