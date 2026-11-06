#if !os(tvOS)
import SwiftUI
import CndCoreBridge

public struct LibraryImagesView: View {
    @Bindable var model: LibraryModel

    @State private var columnCount: Int = 4
    @State private var selectedIndex: Int?
    @State private var showingAddFolder = false
    @State private var showingSettingsSheet = false

    public init(model: LibraryModel) {
        self.model = model
    }

    public var body: some View {
        Group {
            if model.folders.isEmpty {
                emptyLibraryView
            } else if model.imageItems.isEmpty && model.searchQuery.isEmpty {
                emptyImagesView
            } else {
                mainGalleryView
            }
        }
        .navigationTitle("Photos & Images")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 12) {
                    // Zoom slider (3 to 8 columns)
                    #if os(macOS)
                    HStack {
                        Image(systemName: "photo")
                            .font(.caption2)
                        Slider(value: Binding(
                            get: { Double(columnCount) },
                            set: { columnCount = Int($0) }
                        ), in: 3...8, step: 1)
                        .frame(width: 100)
                        Image(systemName: "photo.fill")
                            .font(.caption)
                    }
                    #endif

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
        #if os(macOS)
        .sheet(item: Binding(
            get: { selectedIndex.map { ImageSelection(index: $0) } },
            set: { selectedIndex = $0?.index }
        )) { selection in
            ImageViewer(
                items: displayedImages,
                initialIndex: selection.index
            )
            .frame(minWidth: 800, minHeight: 600)
        }
        #else
        .fullScreenCover(item: Binding(
            get: { selectedIndex.map { ImageSelection(index: $0) } },
            set: { selectedIndex = $0?.index }
        )) { selection in
            ImageViewer(
                items: displayedImages,
                initialIndex: selection.index
            )
        }
        #endif
    }

    private var displayedImages: [LibraryItemRecord] {
        model.searchQuery.isEmpty ? model.imageItems : model.searchResults.filter { $0.kind == "image" }
    }

    private var mainGalleryView: some View {
        ScrollView {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: columnCount),
                spacing: 4
            ) {
                ForEach(Array(displayedImages.enumerated()), id: \.element.id) { index, item in
                    Button {
                        selectedIndex = index
                    } label: {
                        ZStack {
                            Rectangle()
                                .fill(Color.secondary.opacity(0.12))
                                .aspectRatio(1, contentMode: .fit)

                            if let thumb = item.thumbnailPath,
                               let img = platformImage(path: thumb) {
                                img
                                    .resizable()
                                    .scaledToFill()
                            } else {
                                Image(systemName: "photo")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .aspectRatio(1, contentMode: .fit)
                        .clipped()
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var emptyLibraryView: some View {
        ContentUnavailableView {
            Label("Aucun dossier d'images", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("Ajoutez un dossier contenant vos photos pour les explorer dans une galerie fluide.")
        } actions: {
            Button("Ajouter un dossier…") {
                showingAddFolder = true
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var emptyImagesView: some View {
        ContentUnavailableView {
            Label("Aucune photo trouvée", systemImage: "photo")
        } description: {
            Text("Les dossiers autorisés ne contiennent aucune image prise en charge (JPEG, PNG, HEIC, WebP, etc.).")
        } actions: {
            Button("Actualiser") {
                model.scanAllFolders()
            }
        }
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

private struct ImageSelection: Identifiable {
    let index: Int
    var id: Int { index }
}

/// Fullscreen photo viewer with pan, zoom, slideshow and EXIF details.
public struct ImageViewer: View {
    @Environment(\.dismiss) private var dismiss
    let items: [LibraryItemRecord]
    @State private var currentIndex: Int
    @State private var isSlideshowRunning = false
    @State private var slideshowTimer: Timer?
    @State private var showingInfo = false
    @State private var scale: CGFloat = 1.0

    public init(items: [LibraryItemRecord], initialIndex: Int) {
        self.items = items
        self._currentIndex = State(initialValue: initialIndex)
    }

    private var currentItem: LibraryItemRecord? {
        guard items.indices.contains(currentIndex) else { return nil }
        return items[currentIndex]
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let item = currentItem {
                // Image display
                Group {
                    if let img = fullImage(path: item.fullPath) ?? platformImage(path: item.thumbnailPath ?? "") {
                        img
                            .resizable()
                            .scaledToFit()
                            .scaleEffect(scale)
                            .gesture(
                                MagnificationGesture()
                                    .onChanged { val in scale = max(1.0, min(val, 4.0)) }
                                    .onEnded { _ in withAnimation { scale = max(1.0, scale) } }
                            )
                            .onTapGesture(count: 2) {
                                withAnimation {
                                    scale = scale > 1.0 ? 1.0 : 2.5
                                }
                            }
                    } else {
                        ProgressView()
                            .tint(.white)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            }

            // Top Bar
            VStack {
                HStack {
                    Button {
                        stopSlideshow()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Text("\(currentIndex + 1) / \(items.count)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.8))

                    Spacer()

                    // Slideshow Toggle
                    Button {
                        toggleSlideshow()
                    } label: {
                        Image(systemName: isSlideshowRunning ? "pause.circle.fill" : "play.circle")
                            .font(.title2)
                            .foregroundStyle(isSlideshowRunning ? Color.accentColor : Color.white.opacity(0.8))
                    }
                    .buttonStyle(.plain)

                    // Info
                    Button {
                        showingInfo.toggle()
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.title2)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }
                .padding()
                .background(
                    LinearGradient(
                        colors: [.black.opacity(0.7), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                Spacer()

                // Bottom arrows / navigation
                HStack {
                    Button {
                        navigate(delta: -1)
                    } label: {
                        Image(systemName: "chevron.left.circle.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .disabled(currentIndex == 0)

                    Spacer()

                    Button {
                        navigate(delta: 1)
                    } label: {
                        Image(systemName: "chevron.right.circle.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .disabled(currentIndex >= items.count - 1)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .sheet(isPresented: $showingInfo) {
            if let item = currentItem {
                ImageInfoSheet(item: item)
            }
        }
        .onDisappear {
            stopSlideshow()
        }
        #if !os(tvOS)
        .onKeyPress(.leftArrow) { navigate(delta: -1); return .handled }
        .onKeyPress(.rightArrow) { navigate(delta: 1); return .handled }
        .onKeyPress(.escape) { dismiss(); return .handled }
        #endif
    }

    private func navigate(delta: Int) {
        let newIndex = currentIndex + delta
        guard items.indices.contains(newIndex) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            currentIndex = newIndex
            scale = 1.0
        }
    }

    private func toggleSlideshow() {
        if isSlideshowRunning {
            stopSlideshow()
        } else {
            isSlideshowRunning = true
            slideshowTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { _ in
                Task { @MainActor in
                    if currentIndex + 1 < items.count {
                        navigate(delta: 1)
                    } else {
                        currentIndex = 0
                    }
                }
            }
        }
    }

    private func stopSlideshow() {
        isSlideshowRunning = false
        slideshowTimer?.invalidate()
        slideshowTimer = nil
    }

    private func fullImage(path: String) -> Image? {
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

struct ImageInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    let item: LibraryItemRecord

    var body: some View {
        NavigationStack {
            List {
                Section("Fichier") {
                    LabeledContent("Nom", value: URL(fileURLWithPath: item.relPath).lastPathComponent)
                    LabeledContent("Chemin", value: item.fullPath)
                    LabeledContent("Taille", value: ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file))
                }

                Section("Détails de l'image") {
                    if let w = item.width, let h = item.height {
                        LabeledContent("Dimensions", value: "\(w) × \(h)")
                    }
                    if let taken = item.takenAt {
                        let d = Date(timeIntervalSince1970: TimeInterval(taken))
                        LabeledContent("Prise de vue", value: d.formatted(date: .abbreviated, time: .shortened))
                    }
                }
            }
            .navigationTitle("Infos photo")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
    }
}
#endif
