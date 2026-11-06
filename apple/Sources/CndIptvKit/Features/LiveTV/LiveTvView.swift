import SwiftUI
import CndCoreBridge

struct LiveTvView: View {
    @Environment(\.uiMetrics) private var ui
    @State private var model: LiveTvModel
    let revision: Int
    let totalChannels: Int
    let playingURL: String?
    let onPlay: (IptvItemRecord) -> Void
    let onShowGuide: (IptvItemRecord) -> Void
    var zapper: LiveZapper?
    var onOpenAssistant: (() -> Void)?
    var onAddToMultiView: ((IptvItemRecord) -> Void)? = nil
    var onOpenMultiView: (() -> Void)? = nil
    var onStartOver: ((IptvItemRecord, EpgProgramRecord) -> Void)? = nil
    /// The « Pour vous » rows (programmes on the air, soon, usual channels) and the guide refresh (PRD 34).
    var forYou: ForYouModel?
    var onRefreshGuide: (() -> Void)?
    @Binding var searchRequest: String?

    @AppStorage("live.viewMode") private var viewModeRaw = LiveViewMode.grid.rawValue
    @State private var mirrorTarget: IptvItemRecord?
    @State private var mirrorList: [IptvItemRecord] = []
    init(
        engine: CndEngine,
        revision: Int,
        totalChannels: Int,
        playingURL: String?,
        onPlay: @escaping (IptvItemRecord) -> Void,
        onShowGuide: @escaping (IptvItemRecord) -> Void,
        onFavoriteChanged: @escaping () -> Void,
        zapper: LiveZapper? = nil,
        onOpenAssistant: (() -> Void)? = nil,
        onAddToMultiView: ((IptvItemRecord) -> Void)? = nil,
        onOpenMultiView: (() -> Void)? = nil,
        onStartOver: ((IptvItemRecord, EpgProgramRecord) -> Void)? = nil,
        forYou: ForYouModel? = nil,
        onRefreshGuide: (() -> Void)? = nil,
        searchRequest: Binding<String?> = .constant(nil)
    ) {
        self.forYou = forYou
        self.onRefreshGuide = onRefreshGuide
        let model = LiveTvModel(engine: engine)
        model.onFavoriteChanged = onFavoriteChanged
        _model = State(initialValue: model)
        self.revision = revision
        self.totalChannels = totalChannels
        self.playingURL = playingURL
        self.onPlay = onPlay
        self.onShowGuide = onShowGuide
        self.zapper = zapper
        self.onOpenAssistant = onOpenAssistant
        self.onAddToMultiView = onAddToMultiView
        self.onOpenMultiView = onOpenMultiView
        self.onStartOver = onStartOver
        _searchRequest = searchRequest
    }

    /// A "search" decided by the assistant: shown here, across every category.
    private func applySearchRequest() {
        guard let query = searchRequest else { return }
        searchRequest = nil
        model.filter.group = nil
        model.filter.text = query
        model.filter.commit()
    }

    private var viewMode: LiveViewMode { LiveViewMode(rawValue: viewModeRaw) ?? .grid }

    private var reloadKey: String { "\(model.filter.signature)#\(revision)" }

    /// Hands the browsed channel list to the zapper (next/previous channel from anywhere).
    private func publishZapList() {
        zapper?.update(channels: model.channels) { [model] item in model.program(for: item)?.now?.title }
    }

    private var actions: ChannelActions {
        ChannelActions(
            play: { item in
                model.markWatched(item)
                onPlay(item)
            },
            toggleFavorite: { item in
                Haptics.light()
                Task { await model.toggleFavorite(item) }
            },
            toggleBroken: { item in
                Haptics.light()
                Task { await model.toggleBroken(item) }
            },
            addToMultiView: onAddToMultiView,
            showMirrors: { item in
                Task {
                    let list = (try? model.engine.findMirrors(itemId: item.id)) ?? []
                    mirrorList = list
                    mirrorTarget = item
                }
            },
            startOver: onStartOver,
            showGuide: onShowGuide
        )
    }

    var body: some View {
        @Bindable var filter = model.filter
        return CategoryNavigation(
            groups: model.groups,
            totalCount: totalChannels,
            allTitle: "Toutes les chaînes",
            selection: $filter.group
        ) {
            channelContent
        }
        .navigationTitle("Live TV")
        .searchFilterToolbar(
            state: model.filter,
            groups: model.groups,
            hosts: model.hosts,
            sortOptions: [.channelNumber, .name, .group, .host],
            prompt: "Rechercher une chaîne"
        )
        .onAppear { applySearchRequest() }
        .onChange(of: searchRequest) { _, _ in applySearchRequest() }
        .toolbar {
            if let onOpenAssistant {
                ToolbarItem(placement: .automatic) {
                    Button(action: onOpenAssistant) { Label("Assistant", systemImage: "sparkles") }
                        .help("Changer de chaîne en langage naturel (⌘K)")
                }
            }
            if let onOpenMultiView {
                ToolbarItem(placement: .automatic) {
                    Button(action: onOpenMultiView) { Label("Mosaïque", systemImage: "square.grid.2x2") }
                        .help("Ouvrir la mosaïque de flux (Multi-View)")
                }
            }
            ToolbarItem(placement: .automatic) {
                Picker("Affichage", selection: $viewModeRaw) {
                    Label("Grille", systemImage: "square.grid.2x2").tag(LiveViewMode.grid.rawValue)
                    Label("Liste", systemImage: "list.bullet").tag(LiveViewMode.list.rawValue)
                }
                .pickerStyle(.segmented)
            }
        }
        .task(id: reloadKey) { await model.reload(revision: revision) }
        .task(id: revision) { await forYou?.reload(revision: revision) }
        .onChange(of: model.channels.count) { _, _ in publishZapList() }
        .onChange(of: model.nowNext.count) { _, _ in publishZapList() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                model.refreshEpg()
            }
        }
        .sheet(item: Binding(
            get: { mirrorTarget.map { IdentifiableLiveItem(item: $0) } },
            set: { mirrorTarget = $0?.item }
        )) { wrapper in
            MirrorSheetView(
                target: wrapper.item,
                mirrors: mirrorList,
                onPlay: { mirror in
                    model.markWatched(mirror)
                    onPlay(mirror)
                }
            )
        }
    }

    // MARK: Channels

    @ViewBuilder
    private var channelContent: some View {
        if model.channels.isEmpty && !model.isLoading && model.recents.isEmpty && model.favorites.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if let message = model.errorMessage {
                        Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                    if model.searchIgnoresCategory {
                        Label("Recherche dans toutes les catégories", systemImage: "magnifyingglass")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if model.showsSections {
                        horizontalSection("Récemment consultés", icon: "clock", items: model.recents)
                        horizontalSection("Favoris", icon: "star.fill", items: model.favorites)
                        #if !os(macOS)
                        if playingURL == nil, let forYou {
                            ForYouShelves(model: forYou, onRefreshGuide: onRefreshGuide) { recoCard in
                                recommendedChannel(recoCard, forYou: forYou)
                            }
                        }
                        #endif
                        if !model.recents.isEmpty || !model.favorites.isEmpty {
                            Text("Toutes les chaînes").font(.title3.bold())
                        }
                    }
                    switch viewMode {
                    case .grid: grid
                    case .list: list
                    }
                    if model.hasMore {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding()
                            .onAppear { Task { await model.loadNextPage() } }
                    }
                }
                .padding(16)
            }
            .overlay(alignment: .topTrailing) {
                if model.isLoadingEpg {
                    ProgressView().controlSize(.small).padding(10)
                }
            }
        }
    }

    private var emptyState: some View {
        Group {
            if model.filter.query.isEmpty && !model.filter.hasActiveFilter {
                ContentUnavailableView(
                    "Aucune chaîne",
                    systemImage: "tv.slash",
                    description: Text("Ajoutez une source dans l'onglet Sources pour importer des chaînes.")
                )
            } else {
                ContentUnavailableView.search(text: model.filter.query)
            }
        }
    }

    /// A channel of a « Pour vous » row: the usual channel card, with the programme the engine chose and why.
    @ViewBuilder
    private func recommendedChannel(_ recoCard: RecoCard, forYou: ForYouModel) -> some View {
        if let item = recoCard.item {
            VStack(alignment: .leading, spacing: 4) {
                ChannelCardView(
                    item: item,
                    nowNext: ChannelNowNext(channelTvgId: item.tvgId ?? "", now: recoCard.program, next: nil),
                    isPlaying: item.streamUrl == playingURL,
                    style: .card,
                    actions: actions
                )
                HStack(spacing: 3) {
                    if recoCard.aiReason { Image(systemName: "sparkles").imageScale(.small) }
                    Text(recoCard.reasonText).lineLimit(2)
                }
                .font(.caption)
                .foregroundStyle(recoCard.aiReason ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            .contextMenu { RecoChannelFeedback(card: recoCard, model: forYou) }
        }
    }

    private func card(_ item: IptvItemRecord, style: ChannelCardView.Style) -> some View {
        ChannelCardView(
            item: item,
            nowNext: model.program(for: item),
            isPlaying: item.streamUrl == playingURL,
            style: style,
            actions: actions
        )
        .onAppear {
            model.cardAppeared(item)
            model.loadMoreIfNeeded(current: item)
        }
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: ui.channelCardMinWidth, maximum: ui.channelCardMaxWidth), spacing: ui.spacingM)], spacing: ui.spacingM) {
            ForEach(model.channels, id: \.id) { card($0, style: .card) }
        }
    }

    private var list: some View {
        LazyVStack(spacing: 0) {
            ForEach(model.channels, id: \.id) { item in
                card(item, style: .row)
                Divider()
            }
        }
    }

    @ViewBuilder
    private func horizontalSection(_ title: String, icon: String, items: [IptvItemRecord]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: icon).font(.title3.bold())
                HorizontalShelf(items: items, spacing: 12) { item in
                    card(item, style: .card).frame(width: ui.shelfChannelCardWidth)
                }
            }
        }
    }
}

private struct IdentifiableLiveItem: Identifiable {
    let item: IptvItemRecord
    var id: Int64 { item.id }
}

private struct MirrorSheetView: View {
    let target: IptvItemRecord
    let mirrors: [IptvItemRecord]
    let onPlay: (IptvItemRecord) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(target.name).font(.headline)
                            if let group = target.groupTitle {
                                Text(group).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text("Actuel")
                            .font(.caption.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.2), in: Capsule())
                    }
                } header: {
                    Text("Chaîne sélectionnée")
                }

                Section {
                    if mirrors.isEmpty {
                        Text("Aucun flux miroir trouvé pour cette chaîne.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(mirrors, id: \.id) { mirror in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Text(mirror.name).font(.subheadline.bold())
                                        if let q = ChannelQuality.detect(in: mirror.name) {
                                            Text(q.rawValue)
                                                .font(.caption2.bold())
                                                .padding(.horizontal, 4).padding(.vertical, 1)
                                                .background(Color.secondary.opacity(0.2), in: RoundedRectangle(cornerRadius: 3))
                                        }
                                    }
                                    Text(mirror.host).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Lire") {
                                    dismiss()
                                    onPlay(mirror)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                        }
                    }
                } header: {
                    Text("Flux alternatifs (\(mirrors.count))")
                }
            }
            .navigationTitle("Flux Miroirs")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
    }
}
