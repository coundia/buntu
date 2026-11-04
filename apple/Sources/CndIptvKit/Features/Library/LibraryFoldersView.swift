import SwiftUI
import CndCoreBridge
#if canImport(AppKit)
import AppKit
#endif

public struct LibraryFoldersView: View {
    @Bindable var model: LibraryModel
    var filterKind: String?
    var onPlayVideo: ((LibraryItemRecord) -> Void)?

    @State private var selectedFolderId: Int64?
    @State private var pathComponents: [String] = []
    @State private var showingAddFolder = false
    @State private var folderToRemove: LibraryFolderRecord?
    @State private var showingSettingsSheet = false

    public init(
        model: LibraryModel,
        filterKind: String? = nil,
        onPlayVideo: ((LibraryItemRecord) -> Void)? = nil
    ) {
        self.model = model
        self.filterKind = filterKind
        self.onPlayVideo = onPlayVideo
    }

    public var body: some View {
        Group {
            if model.folders.isEmpty {
                emptyFoldersView
            } else if selectedFolderId == nil {
                rootFoldersList
            } else {
                folderBrowserView
            }
        }
        .navigationTitle(currentTitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showingAddFolder = true
                } label: {
                    Label("Ajouter un dossier", systemImage: "folder.badge.plus")
                }

                Button {
                    showingSettingsSheet = true
                } label: {
                    Label("Gérer les dossiers", systemImage: "gearshape")
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
                    if selectedFolderId == folder.id {
                        selectedFolderId = nil
                        pathComponents = []
                    }
                }
            }
            Button("Annuler", role: .cancel) {}
        } message: { folder in
            Text("Les fichiers de « \(folder.displayName) » ne seront plus indexés dans Buntu. Aucun fichier ne sera supprimé de votre disque.")
        }
        .sheet(isPresented: $showingSettingsSheet) {
            NavigationStack {
                LibrarySettingsView(model: model)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Fermer") {
                                showingSettingsSheet = false
                            }
                        }
                    }
            }
            #if os(macOS)
            .frame(minWidth: 500, minHeight: 400)
            #endif
        }
    }

    private var currentTitle: String {
        if let fid = selectedFolderId, let folder = model.folders.first(where: { $0.id == fid }) {
            if pathComponents.isEmpty {
                return folder.displayName
            } else {
                return pathComponents.last ?? folder.displayName
            }
        }
        return "Dossiers"
    }

    // MARK: - Root Folders List

    private var rootFoldersList: some View {
        List {
            ForEach(model.folders, id: \.id) { folder in
                HStack(spacing: 14) {
                    Button {
                        openFolder(folder.id)
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "folder.fill")
                                .font(.title2)
                                .foregroundStyle(folder.state == "ok" ? Color.accentColor : Color.secondary)

                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(folder.displayName)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(.primary)

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

                            Text("\(folder.itemCount) élément\(folder.itemCount > 1 ? "s" : "")")
                                .font(.caption)
                                .foregroundStyle(.tertiary)

                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)

                    // Quick Remove Button
                    Button(role: .destructive) {
                        folderToRemove = folder
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .help("Retirer ce dossier de la bibliothèque")
                    .accessibilityLabel("Retirer « \(folder.displayName) »")
                }
                .padding(.vertical, 4)
                .contextMenu {
                    Button {
                        model.scanFolder(id: folder.id)
                    } label: {
                        Label("Réindexer le dossier", systemImage: "arrow.clockwise")
                    }

                    #if os(macOS)
                    Button {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
                    } label: {
                        Label("Afficher dans le Finder", systemImage: "folder")
                    }
                    #endif

                    Divider()

                    Button(role: .destructive) {
                        folderToRemove = folder
                    } label: {
                        Label("Retirer de la bibliothèque", systemImage: "trash")
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        folderToRemove = folder
                    } label: {
                        Label("Retirer", systemImage: "trash")
                    }
                }
            }
        }
    }

    // MARK: - Subfolder Browser

    private var folderBrowserView: some View {
        VStack(spacing: 0) {
            // Breadcrumbs / Back button / Folder Menu
            HStack {
                Button {
                    goUp()
                } label: {
                    Label(pathComponents.isEmpty ? "Tous les dossiers" : "Dossier parent", systemImage: "chevron.left")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                if !pathComponents.isEmpty {
                    Text(pathComponents.joined(separator: " / "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let fid = selectedFolderId, let folder = model.folders.first(where: { $0.id == fid }) {
                    Menu {
                        Button {
                            model.scanFolder(id: folder.id)
                        } label: {
                            Label("Réindexer ce dossier", systemImage: "arrow.clockwise")
                        }

                        #if os(macOS)
                        Button {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
                        } label: {
                            Label("Afficher dans le Finder", systemImage: "folder")
                        }
                        #endif

                        Divider()

                        Button(role: .destructive) {
                            folderToRemove = folder
                        } label: {
                            Label("Retirer ce dossier de la bibliothèque", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.body)
                    }
                    .menuStyle(.borderlessButton)
                    .accessibilityLabel("Options du dossier")
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color.secondary.opacity(0.08))

            // Entries List
            List {
                let displayedEntries = filterEntries(model.browseEntries)

                if displayedEntries.isEmpty {
                    Text("Ce dossier est vide.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding()
                } else {
                    ForEach(displayedEntries, id: \.relPath) { entry in
                        if entry.isDirectory {
                            Button {
                                enterSubdir(entry.name)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "folder.fill")
                                        .foregroundStyle(Color.accentColor)
                                    Text(entry.name)
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 2)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Button {
                                handleFileClick(entry: entry)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: iconForKind(entry.kind))
                                        .foregroundStyle(.secondary)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.name)
                                            .font(.body)
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)

                                        if let size = entry.size {
                                            Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }

                                    Spacer()

                                    if let dur = entry.durationMs {
                                        Text(formatDurationMs(dur))
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func filterEntries(_ entries: [LibraryBrowseEntry]) -> [LibraryBrowseEntry] {
        guard let k = filterKind else { return entries }
        return entries.filter { e in
            e.isDirectory || e.kind == k
        }
    }

    private func openFolder(_ id: Int64) {
        selectedFolderId = id
        pathComponents = []
        model.browse(folderId: id, relDir: "")
    }

    private func enterSubdir(_ name: String) {
        guard let fid = selectedFolderId else { return }
        pathComponents.append(name)
        let relDir = pathComponents.joined(separator: "/")
        model.browse(folderId: fid, relDir: relDir)
    }

    private func goUp() {
        guard let fid = selectedFolderId else { return }
        if pathComponents.isEmpty {
            selectedFolderId = nil
            model.loadFolders()
        } else {
            pathComponents.removeLast()
            let relDir = pathComponents.joined(separator: "/")
            model.browse(folderId: fid, relDir: relDir)
        }
    }

    private func handleFileClick(entry: LibraryBrowseEntry) {
        guard let itemId = entry.itemId,
              let item = try? model.engine.libraryGetItem(id: itemId) else { return }

        if item.kind == "audio" {
            model.playAudio(item: item)
        } else if item.kind == "video" {
            onPlayVideo?(item)
        }
    }

    private func iconForKind(_ kind: String?) -> String {
        switch kind {
        case "video": return "film"
        case "audio": return "music.note"
        case "image": return "photo"
        default: return "doc"
        }
    }

    private func formatDurationMs(_ ms: UInt32) -> String {
        let total = ms / 1000
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    private var emptyFoldersView: some View {
        ContentUnavailableView {
            Label("Aucun dossier configuré", systemImage: "folder")
        } description: {
            Text("Ajoutez un dossier pour parcourir vos fichiers sur votre disque ou support externe.")
        } actions: {
            Button {
                showingAddFolder = true
            } label: {
                Label("Ajouter un dossier…", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
