import SwiftUI
import CndCoreBridge

struct LiveTvView: View {
    @State private var model: LiveTvModel
    let revision: Int
    let totalChannels: Int
    let playingURL: String?
    let onPlay: (IptvItemRecord) -> Void
    let onShowGuide: (IptvItemRecord) -> Void
    var zapper: LiveZapper?
    var onOpenAssistant: (() -> Void)?
    @Binding var searchRequest: String?

    @AppStorage("live.viewMode") private var viewModeRaw = LiveViewMode.grid.rawValue
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
        searchRequest: Binding<String?> = .constant(nil)
    ) {
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
            ToolbarItem(placement: .automatic) {
                Picker("Affichage", selection: $viewModeRaw) {
                    Label("Grille", systemImage: "square.grid.2x2").tag(LiveViewMode.grid.rawValue)
                    Label("Liste", systemImage: "list.bullet").tag(LiveViewMode.list.rawValue)
                }
                .pickerStyle(.segmented)
            }
        }
        .task(id: reloadKey) { await model.reload(revision: revision) }
        .onChange(of: model.channels.count) { _, _ in publishZapList() }
        .onChange(of: model.nowNext.count) { _, _ in publishZapList() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                model.refreshEpg()
            }
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
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 340), spacing: 12)], spacing: 12) {
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
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(items, id: \.id) { item in
                            card(item, style: .card).frame(width: 280)
                        }
                    }
                }
            }
        }
    }
}
