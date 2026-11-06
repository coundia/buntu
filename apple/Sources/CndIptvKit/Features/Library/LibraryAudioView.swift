#if !os(tvOS)
import SwiftUI
import CndCoreBridge

public struct LibraryAudioView: View {
    @Bindable var model: LibraryModel

    public enum AudioSubTab: String, CaseIterable, Identifiable {
        case tracks = "Titres"
        case albums = "Albums"
        case artists = "Artistes"
        case genres = "Genres"
        case folders = "Dossiers"

        public var id: String { rawValue }
    }

    @State private var selectedSubTab: AudioSubTab = .tracks
    @State private var showingAddFolder = false
    @State private var showingSettingsSheet = false

    public init(model: LibraryModel) {
        self.model = model
    }

    public var body: some View {
        Group {
            if model.folders.isEmpty {
                emptyLibraryView
            } else if model.audioItems.isEmpty && model.searchQuery.isEmpty {
                emptyAudioView
            } else {
                mainContentView
            }
        }
        .navigationTitle("Musique")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Vue Audio", selection: $selectedSubTab) {
                    ForEach(AudioSubTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 380)
            }

            ToolbarItem(placement: .primaryAction) {
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
    }

    // MARK: - Main Content

    @ViewBuilder
    private var mainContentView: some View {
        switch selectedSubTab {
        case .tracks:
            tracksListView
        case .albums:
            albumsGridView
        case .artists:
            artistsListView
        case .genres:
            genresListView
        case .folders:
            LibraryFoldersView(model: model, filterKind: "audio")
        }
    }

    // MARK: - Tracks List

    private var tracksListView: some View {
        List {
            let tracks = model.searchQuery.isEmpty ? model.audioItems : model.searchResults.filter { $0.kind == "audio" }
            ForEach(tracks, id: \.id) { track in
                Button {
                    model.playAudio(item: track, inQueue: tracks)
                } label: {
                    HStack(spacing: 12) {
                        // Artwork
                        Group {
                            if let thumb = track.thumbnailPath,
                               let img = platformImage(path: thumb) {
                                img
                                    .resizable()
                                    .scaledToFill()
                            } else {
                                Image(systemName: "music.note")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 40, height: 40)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title ?? URL(fileURLWithPath: track.relPath).lastPathComponent)
                                .font(.body.weight(model.nowPlayingAudio?.id == track.id ? .bold : .regular))
                                .foregroundStyle(model.nowPlayingAudio?.id == track.id ? Color.accentColor : Color.primary)
                                .lineLimit(1)

                            HStack(spacing: 4) {
                                Text(track.artist ?? "Artiste inconnu")
                                if let album = track.album {
                                    Text("• \(album)")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        }

                        Spacer()

                        if let dur = track.durationMs {
                            Text(formatDurationMs(dur))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        if model.nowPlayingAudio?.id == track.id && model.isAudioPlaying {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.caption)
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Albums Grid

    private var albumsGridView: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 20)],
                spacing: 20
            ) {
                ForEach(model.albums, id: \.name) { album in
                    Button {
                        // Play first track of album
                        let albumTracks = model.audioItems.filter { $0.album == album.name }
                        if let first = albumTracks.first {
                            model.playAudio(item: first, inQueue: albumTracks)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.secondary.opacity(0.15))
                                    .aspectRatio(1, contentMode: .fit)

                                if let thumb = album.thumbnailPath,
                                   let img = platformImage(path: thumb) {
                                    img
                                        .resizable()
                                        .scaledToFill()
                                } else {
                                    Image(systemName: "square.stack")
                                        .font(.system(size: 36))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .aspectRatio(1, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 10))

                            Text(album.name)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                                .foregroundStyle(.primary)

                            Text(album.artist ?? "Artiste inconnu")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)

                            Text("\(album.trackCount) titre\(album.trackCount > 1 ? "s" : "")")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
    }

    // MARK: - Artists List

    private var artistsListView: some View {
        List {
            ForEach(model.artists, id: \.name) { artist in
                HStack(spacing: 14) {
                    Circle()
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: 44, height: 44)
                        .overlay {
                            Image(systemName: "person.fill")
                                .foregroundStyle(.secondary)
                        }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(artist.name)
                            .font(.body.weight(.medium))

                        Text("\(artist.albumCount) album\(artist.albumCount > 1 ? "s" : "") • \(artist.trackCount) titre\(artist.trackCount > 1 ? "s" : "")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Genres List

    private var genresListView: some View {
        List {
            ForEach(model.genres, id: \.name) { genre in
                HStack {
                    Image(systemName: "guitars.fill")
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 28)

                    Text(genre.name)
                        .font(.body.weight(.medium))

                    Spacer()

                    Text("\(genre.trackCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Empty States

    private var emptyLibraryView: some View {
        ContentUnavailableView {
            Label("Aucun dossier de musique", systemImage: "folder.badge.questionmark")
        } description: {
            Text("Ajoutez un dossier contenant votre musique (MP3, FLAC, AAC, ALAC, WAV) pour démarrer l'écoute.")
        } actions: {
            Button("Ajouter un dossier…") {
                showingAddFolder = true
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var emptyAudioView: some View {
        ContentUnavailableView {
            Label("Aucune piste audio", systemImage: "music.note")
        } description: {
            Text("Les dossiers autorisés ne contiennent aucun fichier musical pris en charge.")
        } actions: {
            Button("Actualiser") {
                model.scanAllFolders()
            }
        }
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
#endif
