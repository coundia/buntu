#if !os(tvOS)
import SwiftUI
import CndCoreBridge

public struct LibraryVideoView: View {
    @Bindable var model: LibraryModel
    var onPlay: (LibraryItemRecord) -> Void

    @State private var isListView = false
    @State private var showingInfoItem: LibraryItemRecord?
    @State private var itemToTrash: LibraryItemRecord?
    @State private var showingAddFolder = false
    @State private var showingSettingsSheet = false

    public init(model: LibraryModel, onPlay: @escaping (LibraryItemRecord) -> Void) {
        self.model = model
        self.onPlay = onPlay
    }

    public var body: some View {
        Group {
            if model.folders.isEmpty {
                emptyLibraryView
            } else if model.videoItems.isEmpty && model.searchQuery.isEmpty {
                emptyVideosView
            } else {
                mainContent
            }
        }
        .navigationTitle("Vidéos")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("Affichage", selection: $isListView) {
                    Image(systemName: "square.grid.2x2").tag(false)
                    Image(systemName: "list.bullet").tag(true)
                }
                .pickerStyle(.segmented)

                Menu {
                    Picker("Trier par", selection: $model.selectedSort) {
                        Text("Nom").tag("title")
                        Text("Date de modification").tag("date")
                        Text("Date d'ajout").tag("added")
                        Text("Durée").tag("duration")
                        Text("Taille").tag("size")
                    }

                    Toggle("Ordre croissant", isOn: $model.isSortAscending)
                    Toggle("Non vus uniquement", isOn: $model.filterUnwatchedOnly)
                } label: {
                    Label("Trier & Filtrer", systemImage: "arrow.up.arrow.down")
                }

                Menu {
                    Button {
                        showingAddFolder = true
                    } label: {
                        Label("Ajouter un dossier…", systemImage: "folder.badge.plus")
                    }

                    Button {
                        showingSettingsSheet = true
                    } label: {
                        Label("Gérer les dossiers…", systemImage: "gearshape")
                    }
                } label: {
                    Label("Dossiers", systemImage: "folder")
                }
            }
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
        .sheet(item: $showingInfoItem) { item in
            VideoInfoSheet(item: item)
        }
        .confirmationDialog(
            "Mettre à la corbeille ?",
            isPresented: Binding(
                get: { itemToTrash != nil },
                set: { if !$0 { itemToTrash = nil } }
            ),
            presenting: itemToTrash
        ) { item in
            Button("Mettre à la corbeille", role: .destructive) {
                _ = model.moveItemToTrash(item)
            }
            Button("Annuler", role: .cancel) {}
        } message: { item in
            Text("Le fichier « \(item.title ?? item.relPath) » sera déplacé dans la corbeille de votre système.")
        }
    }

    // MARK: - Main Content

    private var displayedVideos: [LibraryItemRecord] {
        let items = model.searchQuery.isEmpty ? model.videoItems : model.searchResults.filter { $0.kind == "video" }
        if model.filterUnwatchedOnly {
            return items.filter { item in
                let prog = model.getProgress(fingerprint: item.fingerprint)
                return prog == nil || prog?.completed == false
            }
        }
        return items
    }

    private var mainContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                // Shelf: Reprendre la lecture
                if model.searchQuery.isEmpty && !model.recentVideos.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Reprendre la lecture")
                            .font(.headline)
                            .padding(.horizontal)

                        HorizontalShelf(items: model.recentVideos, spacing: 14) { item in
                            VideoCard(item: item, model: model) {
                                onPlay(item)
                            }
                            .frame(width: 220)
                        }
                        .padding(.horizontal)
                    }
                }

                // Shelf: Ajoutés récemment
                if model.searchQuery.isEmpty && !model.recentlyAddedVideos.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Ajoutés récemment")
                            .font(.headline)
                            .padding(.horizontal)

                        HorizontalShelf(items: model.recentlyAddedVideos, spacing: 14) { item in
                            VideoCard(item: item, model: model) {
                                onPlay(item)
                            }
                            .frame(width: 220)
                        }
                        .padding(.horizontal)
                    }
                }

                // All Videos Section
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(model.searchQuery.isEmpty ? "Toutes les vidéos (\(displayedVideos.count))" : "Résultats (\(displayedVideos.count))")
                            .font(.headline)

                        Spacer()

                        if !model.scanningFolderIds.isEmpty {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .scaleEffect(0.7)
                                Text("Indexation…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal)

                    if isListView {
                        LazyVStack(spacing: 8) {
                            ForEach(displayedVideos, id: \.id) { item in
                                VideoListRow(item: item, model: model) {
                                    onPlay(item)
                                }
                                .contextMenu {
                                    videoContextMenu(for: item)
                                }
                            }
                        }
                        .padding(.horizontal)
                    } else {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 16)],
                            spacing: 16
                        ) {
                            ForEach(displayedVideos, id: \.id) { item in
                                VideoCard(item: item, model: model) {
                                    onPlay(item)
                                }
                                .contextMenu {
                                    videoContextMenu(for: item)
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }
            .padding(.vertical)
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func videoContextMenu(for item: LibraryItemRecord) -> some View {
        Button {
            onPlay(item)
        } label: {
            Label("Lire", systemImage: "play.fill")
        }

        #if os(macOS)
        Button {
            let url = URL(fileURLWithPath: item.fullPath)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } label: {
            Label("Afficher dans le Finder", systemImage: "folder")
        }
        #endif

        Button {
            showingInfoItem = item
        } label: {
            Label("Informations", systemImage: "info.circle")
        }

        Divider()

        Button(role: .destructive) {
            itemToTrash = item
        } label: {
            Label("Mettre à la corbeille", systemImage: "trash")
        }
    }

    // MARK: - Empty States

    private var emptyLibraryView: some View {
        ContentUnavailableView {
            Label("Aucun dossier autorisé", systemImage: "folder.badge.questionmark")
        } description: {
            Text("Ajoutez un dossier de votre disque, d'iCloud Drive ou d'un support externe pour retrouver vos films et vidéos.")
        } actions: {
            Button("Ajouter un dossier…") {
                showingAddFolder = true
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var emptyVideosView: some View {
        ContentUnavailableView {
            Label("Aucune vidéo trouvée", systemImage: "film.stack")
        } description: {
            Text("Les dossiers autorisés ne contiennent aucune vidéo pour l'instant.")
        } actions: {
            Button("Actualiser") {
                model.scanAllFolders()
            }
        }
    }
}

// MARK: - Video Card & List Row

struct VideoCard: View {
    let item: LibraryItemRecord
    let model: LibraryModel
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                // 16:9 Thumbnail
                ZStack(alignment: .bottomTrailing) {
                    ZStack {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.15))
                            .aspectRatio(16/9, contentMode: .fit)

                        if let thumb = item.thumbnailPath,
                           let image = platformImage(path: thumb) {
                            image
                                .resizable()
                                .scaledToFill()
                        } else {
                            Image(systemName: "film")
                                .font(.system(size: 32))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .aspectRatio(16/9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                    // Quality Badge (4K, 1080p, 720p)
                    if let quality = qualityBadge(width: item.width, height: item.height) {
                        Text(quality)
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.75))
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .padding(6)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }

                    // Duration badge
                    if let dur = item.durationMs {
                        Text(formatDurationMs(dur))
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.8))
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .padding(6)
                    }

                    // Subtitle badge if companions exist
                    if !item.subtitles.isEmpty {
                        Image(systemName: "captions.bubble.fill")
                            .font(.system(size: 11))
                            .padding(4)
                            .background(.black.opacity(0.8))
                            .foregroundStyle(.white)
                            .clipShape(Circle())
                            .padding(6)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    }

                    // Progress bar
                    if let prog = model.getProgress(fingerprint: item.fingerprint),
                       prog.durationMs > 0, !prog.completed {
                        GeometryReader { geo in
                            let fraction = CGFloat(prog.positionMs) / CGFloat(prog.durationMs)
                            Rectangle()
                                .fill(Color.accentColor)
                                .frame(width: geo.size.width * min(1.0, fraction), height: 3)
                        }
                        .frame(height: 3)
                        .background(Color.white.opacity(0.2))
                    }
                }

                // Title & Details
                Text(item.title ?? URL(fileURLWithPath: item.relPath).lastPathComponent)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .foregroundStyle(.primary)

                HStack {
                    if let codec = item.codec {
                        Text(codec.uppercased())
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(formatFileSize(item.size))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func qualityBadge(width: UInt32?, height: UInt32?) -> String? {
        guard let w = width, let h = height else { return nil }
        let maxDim = max(w, h)
        if maxDim >= 3800 { return "4K" }
        if maxDim >= 1900 { return "1080p" }
        if maxDim >= 1200 { return "720p" }
        return nil
    }

    private func formatDurationMs(_ ms: UInt32) -> String {
        let total = ms / 1000
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%d:%02d", m, s)
        }
    }

    private func formatFileSize(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func platformImage(path: String) -> Image? {
        #if canImport(AppKit)
        if let nsImage = NSImage(contentsOfFile: path) {
            return Image(nsImage: nsImage)
        }
        #elseif canImport(UIKit)
        if let uiImage = UIImage(contentsOfFile: path) {
            return Image(uiImage: uiImage)
        }
        #endif
        return nil
    }
}

struct VideoListRow: View {
    let item: LibraryItemRecord
    let model: LibraryModel
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                // Thumbnail
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.15))
                        .frame(width: 80, height: 45)

                    if let thumb = item.thumbnailPath,
                       let image = platformImage(path: thumb) {
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(width: 80, height: 45)
                            .clipped()
                            .cornerRadius(6)
                    } else {
                        Image(systemName: "film")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                    }
                }

                // Info
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title ?? URL(fileURLWithPath: item.relPath).lastPathComponent)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .foregroundStyle(.primary)

                    HStack(spacing: 8) {
                        if let dur = item.durationMs {
                            Text(formatDurationMs(dur))
                        }
                        if let codec = item.codec {
                            Text("• \(codec.uppercased())")
                        }
                        Text("• \(ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file))")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "play.circle")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(Color.secondary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func formatDurationMs(_ ms: UInt32) -> String {
        let total = ms / 1000
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    private func platformImage(path: String) -> Image? {
        #if canImport(AppKit)
        if let nsImage = NSImage(contentsOfFile: path) {
            return Image(nsImage: nsImage)
        }
        #elseif canImport(UIKit)
        if let uiImage = UIImage(contentsOfFile: path) {
            return Image(uiImage: uiImage)
        }
        #endif
        return nil
    }
}

struct VideoInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    let item: LibraryItemRecord

    var body: some View {
        NavigationStack {
            List {
                Section("Fichier") {
                    LabeledContent("Titre", value: item.title ?? "—")
                    LabeledContent("Nom", value: URL(fileURLWithPath: item.relPath).lastPathComponent)
                    LabeledContent("Chemin", value: item.fullPath)
                    LabeledContent("Taille", value: ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file))
                }

                Section("Vidéo & Audio") {
                    if let dur = item.durationMs {
                        let sec = dur / 1000
                        LabeledContent("Durée", value: "\(sec / 60) min \(sec % 60) s")
                    }
                    if let w = item.width, let h = item.height {
                        LabeledContent("Résolution", value: "\(w) × \(h)")
                    }
                    if let codec = item.codec {
                        LabeledContent("Codec", value: codec.uppercased())
                    }
                    if !item.subtitles.isEmpty {
                        LabeledContent("Sous-titres associés", value: item.subtitles.joined(separator: ", "))
                    }
                }
            }
            .navigationTitle("Détails de la vidéo")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
    }
}
#endif
