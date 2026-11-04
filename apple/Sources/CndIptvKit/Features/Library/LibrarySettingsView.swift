import SwiftUI
import CndCoreBridge

public struct LibrarySettingsView: View {
    @Bindable var model: LibraryModel
    @State private var showingAddFolder = false
    @State private var folderToRemove: LibraryFolderRecord?

    public init(model: LibraryModel) {
        self.model = model
    }

    public var body: some View {
        Form {
            Section("Dossiers autorisés") {
                if model.folders.isEmpty {
                    Text("Aucun dossier configuré pour le moment.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.folders, id: \.id) { folder in
                        HStack(spacing: 12) {
                            Image(systemName: "folder.fill")
                                .font(.title3)
                                .foregroundStyle(folder.state == "ok" ? Color.accentColor : Color.secondary)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(folder.displayName)
                                        .font(.body.weight(.medium))

                                    if folder.state == "missing" {
                                        Text("Indisponible")
                                            .font(.caption2.bold())
                                            .foregroundStyle(.red)
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .background(Color.red.opacity(0.12))
                                            .clipShape(Capsule())
                                    }
                                }

                                Text(folder.path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            Text("\(folder.itemCount) éléments")
                                .font(.caption)
                                .foregroundStyle(.tertiary)

                            // Rescan button
                            Button {
                                model.scanFolder(id: folder.id)
                            } label: {
                                if model.scanningFolderIds.contains(folder.id) {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(model.scanningFolderIds.contains(folder.id))

                            // Remove button
                            Button(role: .destructive) {
                                folderToRemove = folder
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 4)
                    }
                }

                Button {
                    showingAddFolder = true
                } label: {
                    Label("Ajouter un dossier…", systemImage: "folder.badge.plus")
                }
            }

            Section("Maintenance & Cache") {
                Button("Tout réindexer maintenant") {
                    model.scanAllFolders()
                }

                Button("Vider le cache des miniatures") {
                    clearThumbnailCache()
                }
            }
        }
        .fileImporter(
            isPresented: $showingAddFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task {
                    _ = await model.addFolder(url: url)
                }
            }
        }
        .confirmationDialog(
            "Retirer le dossier ?",
            isPresented: Binding(
                get: { folderToRemove != nil },
                set: { if !$0 { folderToRemove = nil } }
            ),
            presenting: folderToRemove
        ) { folder in
            Button("Retirer de la bibliothèque", role: .destructive) {
                Task {
                    await model.removeFolder(id: folder.id)
                }
            }
            Button("Annuler", role: .cancel) {}
        } message: { folder in
            Text("Les fichiers de « \(folder.displayName) » ne seront plus indexés. Aucun fichier ne sera supprimé de votre disque.")
        }
    }

    private func clearThumbnailCache() {
        let baseCache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let cacheDir = baseCache.appendingPathComponent("CndLibraryThumbnails", isDirectory: true)
        try? FileManager.default.removeItem(at: cacheDir)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }
}
