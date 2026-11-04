import SwiftUI
import CndCoreBridge

public struct MultiViewScreen: View {
    @Bindable var controller: MultiViewController
    let engine: CndEngine
    let sources: [IptvSourceRecord]
    let onExitToSinglePlayer: (IptvItemRecord) -> Void
    let onClose: () -> Void

    @State private var isAddSheetPresented = false
    @State private var hoveredIndex: Int? = nil

    public init(
        controller: MultiViewController,
        engine: CndEngine,
        sources: [IptvSourceRecord],
        onExitToSinglePlayer: @escaping (IptvItemRecord) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.controller = controller
        self.engine = engine
        self.sources = sources
        self.onExitToSinglePlayer = onExitToSinglePlayer
        self.onClose = onClose
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if controller.slots.isEmpty {
                emptyMosaicView
            } else {
                GeometryReader { geo in
                    let frames = MultiViewLayout.calculateFrames(
                        count: controller.count,
                        in: geo.size,
                        layout: controller.layoutKind,
                        activeTileIndex: controller.activeIndex
                    )

                    ForEach(Array(controller.slots.enumerated()), id: \.element.id) { index, slot in
                        if frames.indices.contains(index) {
                            let frame = frames[index]
                            tileView(slot: slot, index: index)
                                .frame(width: frame.width, height: frame.height)
                                .position(x: frame.midX, y: frame.midY)
                        }
                    }
                }
                .padding(4)
            }

            // Top Header Bar
            VStack {
                headerBar
                if let err = controller.errorMessage {
                    Text(err)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.red.opacity(0.85), in: Capsule())
                        .shadow(radius: 4)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .accessibleTap("\(err). Appuyer pour fermer") { controller.errorMessage = nil }
                }
                Spacer()
            }
            .padding()
        }
        .sheet(isPresented: $isAddSheetPresented) {
            MultiViewChannelPickerSheet(
                engine: engine,
                onSelect: { channel in
                    isAddSheetPresented = false
                    controller.addChannel(channel, sources: sources)
                },
                onCancel: { isAddSheetPresented = false }
            )
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 12) {
            Button {
                if let active = controller.popActiveToSinglePlayer() {
                    onExitToSinglePlayer(active)
                } else {
                    onClose()
                }
            } label: {
                Label("Plein écran", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.bordered)

            Spacer()

            // Layout Picker
            Picker("Disposition", selection: $controller.layoutKind) {
                ForEach(MultiViewLayoutKind.allCases) { layout in
                    Label(layout.title, systemImage: layout.iconName).tag(layout)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)

            // Stream Count Badge
            Text("\(controller.count)/\(controller.maxAllowedSlots) flux")
                .font(.caption.monospacedDigit().weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())

            // Add Channel Button
            if controller.count < controller.maxAllowedSlots {
                Button {
                    isAddSheetPresented = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .help("Ajouter une chaîne à la mosaïque")
            }

            // Close Mosaic Button
            Button(role: .cancel) {
                controller.closeAll()
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Fermer la mosaïque")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 8)
    }

    // MARK: - Tile View

    private func tileView(slot: MultiViewSlot, index: Int) -> some View {
        let isActive = (index == controller.activeIndex)
        return ZStack {
            CndVideoPlayerView(controller: slot.controller, closesOnDisappear: false)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            // Mini HUD Overlay
            VStack {
                HStack(spacing: 8) {
                    ThumbnailImageView(urlString: slot.channel.logoUrl, size: .tvLogo)
                        .frame(width: 24, height: 24)
                    Text(slot.channel.name)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                        .lineLimit(1)

                    Spacer()

                    // Audio indicator
                    Image(systemName: isActive ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .font(.caption)
                        .foregroundStyle(isActive ? Color.green : Color.white.opacity(0.6))
                        .padding(4)
                        .background(.black.opacity(0.5), in: Circle())

                    // Fullscreen Button
                    Button {
                        controller.setActiveIndex(index)
                        if let active = controller.popActiveToSinglePlayer() {
                            onExitToSinglePlayer(active)
                        }
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.caption)
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(.black.opacity(0.5), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Passer cette chaîne en plein lecteur")

                    // Close Button
                    Button {
                        controller.removeSlot(at: index)
                        if controller.slots.isEmpty {
                            onClose()
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption)
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(.black.opacity(0.5), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Retirer cette chaîne de la mosaïque")
                }
                .padding(8)
                .background(
                    LinearGradient(
                        colors: [.black.opacity(0.75), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                Spacer()
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isActive ? Color.accentColor : Color.white.opacity(0.2), lineWidth: isActive ? 3 : 1)
        )
        .accessibleTap("Rendre le son de cette chaîne actif") {
            controller.setActiveIndex(index)
        }
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    // MARK: - Empty State

    private var emptyMosaicView: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Mosaïque Multi-View")
                .font(.title2.bold())
            Text("Ajoutez jusqu'à \(controller.maxAllowedSlots) chaînes en direct simultanées.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Ajouter une chaîne", systemImage: "plus") {
                isAddSheetPresented = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }
}

// MARK: - Channel Picker Sheet

private struct MultiViewChannelPickerSheet: View {
    let engine: CndEngine
    let onSelect: (IptvItemRecord) -> Void
    let onCancel: () -> Void

    @State private var searchText = ""
    @State private var channels: [IptvItemRecord] = []
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            List(channels, id: \.id) { channel in
                Button {
                    onSelect(channel)
                } label: {
                    HStack(spacing: 12) {
                        ThumbnailImageView(urlString: channel.logoUrl, size: .tvLogo)
                            .frame(width: 36, height: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(channel.name).font(.headline).foregroundStyle(.primary)
                            if let group = channel.groupTitle {
                                Text(group).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Image(systemName: "plus.circle")
                            .font(.title3)
                            .foregroundStyle(.tint)
                    }
                }
                .buttonStyle(.plain)
            }
            .searchable(text: $searchText, prompt: "Rechercher une chaîne…")
            .navigationTitle("Ajouter à la mosaïque")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler", action: onCancel)
                }
            }
            .task(id: searchText) {
                await loadChannels()
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 480)
        #endif
    }

    private func loadChannels() async {
        isLoading = true
        let filter = CatalogFilter(
            kind: "live",
            sourceId: nil,
            query: searchText.trimmingCharacters(in: .whitespaces),
            groupTitle: nil,
            host: nil,
            favoritesOnly: false,
            includeBroken: false,
            includeHidden: false,
            sortBy: .channelNumber,
            sortAsc: true,
            limit: 40,
            offset: 0
        )
        let results = (try? await Task.detached(priority: .userInitiated) {
            try engine.queryCatalog(filter: filter)
        }.value) ?? []
        channels = results
        isLoading = false
    }
}
