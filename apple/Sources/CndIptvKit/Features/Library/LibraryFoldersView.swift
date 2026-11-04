import SwiftUI
import CndCoreBridge

public struct LibraryFoldersView: View {
    @Bindable var model: LibraryModel
    var filterKind: String?
    var onPlayVideo: ((LibraryItemRecord) -> Void)?

    @State private var selectedFolderId: Int64?
    @State private var pathComponents: [String] = []

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
                Button {
                    openFolder(folder.id)
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "folder.fill")
                            .font(.title2)
                            .foregroundStyle(Color.accentColor)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(folder.displayName)
                                .font(.body.weight(.medium))
                                .foregroundStyle(.primary)

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
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Subfolder Browser

    private var folderBrowserView: some View {
        VStack(spacing: 0) {
            // Breadcrumbs / Back button
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
        }
    }
}
