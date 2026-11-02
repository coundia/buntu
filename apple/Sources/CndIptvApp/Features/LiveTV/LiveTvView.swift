import SwiftUI
import CndCoreBridge

struct LiveTvView: View {
    @State private var model: LiveTvModel
    let revision: Int
    let totalChannels: Int
    let playingURL: String?
    let onPlay: (IptvItemRecord) -> Void
    let onShowGuide: (IptvItemRecord) -> Void

    @AppStorage("live.viewMode") private var viewModeRaw = LiveViewMode.grid.rawValue
    @State private var isWide = false
    @State private var showingCategories = false
    @State private var categoryQuery = ""

    /// Width from which the category column stays visible (macOS and iPad landscape).
    static let wideLayoutThreshold: CGFloat = 900

    init(
        engine: CndEngine,
        revision: Int,
        totalChannels: Int,
        playingURL: String?,
        onPlay: @escaping (IptvItemRecord) -> Void,
        onShowGuide: @escaping (IptvItemRecord) -> Void,
        onFavoriteChanged: @escaping () -> Void
    ) {
        let model = LiveTvModel(engine: engine)
        model.onFavoriteChanged = onFavoriteChanged
        _model = State(initialValue: model)
        self.revision = revision
        self.totalChannels = totalChannels
        self.playingURL = playingURL
        self.onPlay = onPlay
        self.onShowGuide = onShowGuide
    }

    private var viewMode: LiveViewMode { LiveViewMode(rawValue: viewModeRaw) ?? .grid }

    private var reloadKey: String { "\(model.filter.signature)#\(revision)" }

    private var actions: ChannelActions {
        ChannelActions(
            play: { item in
                model.markWatched(item)
                onPlay(item)
            },
            toggleFavorite: { item in Task { await model.toggleFavorite(item) } },
            showGuide: onShowGuide
        )
    }

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= Self.wideLayoutThreshold
            HStack(spacing: 0) {
                if wide {
                    categoryColumn.frame(width: 250)
                    Divider()
                }
                VStack(spacing: 0) {
                    if !wide { categoryChips }
                    channelContent
                }
            }
            .onChange(of: wide, initial: true) { _, newValue in isWide = newValue }
        }
        .navigationTitle("Live TV")
        .searchFilterToolbar(
            state: model.filter,
            groups: model.groups,
            hosts: model.hosts,
            sortOptions: [.channelNumber, .name, .group, .host],
            prompt: "Rechercher une chaîne"
        )
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Picker("Affichage", selection: $viewModeRaw) {
                    Label("Grille", systemImage: "square.grid.2x2").tag(LiveViewMode.grid.rawValue)
                    Label("Liste", systemImage: "list.bullet").tag(LiveViewMode.list.rawValue)
                }
                .pickerStyle(.segmented)
            }
            if !isWide {
                ToolbarItem(placement: .automatic) {
                    Button { showingCategories = true } label: { Label("Catégories", systemImage: "folder") }
                }
            }
        }
        .sheet(isPresented: $showingCategories) { categorySheet }
        .task(id: reloadKey) { await model.reload(revision: revision) }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                model.refreshEpg()
            }
        }
    }

    // MARK: Categories

    private var filteredGroups: [FacetCount] {
        let needle = categoryQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return model.groups }
        return model.groups.filter { $0.value.localizedCaseInsensitiveContains(needle) }
    }

    private var categoryColumn: some View {
        VStack(spacing: 0) {
            TextField("Filtrer les catégories", text: $categoryQuery)
                .textFieldStyle(.roundedBorder)
                .padding(8)
            categoryList
        }
    }

    private var categoryList: some View {
        @Bindable var filter = model.filter
        return List(selection: $filter.group) {
            Label("Toutes les chaînes", systemImage: "tv")
                .badge(totalChannels)
                .tag(String?.none)
            ForEach(filteredGroups, id: \.value) { group in
                Text(group.value)
                    .lineLimit(1)
                    .badge(Int(group.count))
                    .tag(String?.some(group.value))
            }
        }
        .listStyle(.sidebar)
    }

    private var categorySheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextField("Filtrer les catégories", text: $categoryQuery)
                    .textFieldStyle(.roundedBorder)
                    .padding(8)
                categoryList
                    .onChange(of: model.filter.group) { _, _ in showingCategories = false }
            }
            .navigationTitle("Catégories")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("OK") { showingCategories = false } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 320, minHeight: 420)
        #endif
        .presentationDetents([.medium, .large])
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("Toutes", selected: model.filter.group == nil) { model.filter.group = nil }
                ForEach(model.groups.prefix(40), id: \.value) { group in
                    chip("\(group.value) \(group.count)", selected: model.filter.group == group.value) {
                        model.filter.group = group.value
                    }
                }
                if model.groups.count > 40 {
                    chip("Plus…", selected: false) { showingCategories = true }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(selected ? Color.accentColor : Color.secondary.opacity(0.18), in: Capsule())
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
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
