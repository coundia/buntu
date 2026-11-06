import SwiftUI
import CndCoreBridge

enum VodCardStyle { case poster, row }

enum VodRoute: Hashable {
    case movie(IptvItemRecord)
    case series(SeriesRecord)
}

/// Tapping a card shows its details: in the side panel under the player on macOS, as a pushed page on iOS.
struct VodCardLink<Content: View>: View {
    let route: VodRoute
    @ViewBuilder let content: () -> Content
    @Environment(VodContext.self) private var vod

    var body: some View {
        #if os(macOS)
        content()
            .padding(4)
            .overlay {
                if vod.selection == route {
                    RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 3)
                }
            }
            .accessibleTap("Voir la fiche") { vod.selection = route }
            .accessibilityAddTraits(vod.selection == route ? .isSelected : [])
        #else
        NavigationLink(value: route, label: content).buttonStyle(.plain)
        #endif
    }
}

struct VodSectionTitles {
    var resume: String
    var resumeIcon: String
    var favorites = "Favoris"
    var all: String
}

/// Poster grid / list with categories, "resume" and "favorites" sections and infinite scroll,
/// shared by the Movies and Series tabs. The card is supplied by the caller.
struct VodCatalogView<Entry: CatalogEntry, Card: View>: View {
    @Environment(\.uiMetrics) private var ui
    let title: String
    let model: VodCatalogModel<Entry>
    let totalCount: Int
    let revision: Int
    let titles: VodSectionTitles
    let sortOptions: [SortField]
    let searchPrompt: String
    let emptyDescription: String
    /// Opens the assistant (PRD 33) with a starting phrase; the button shows only when an AI search is possible.
    var onOpenAssistant: ((String) -> Void)?
    /// What the assistant starts with when nothing is typed: "un film ", "une série ".
    let assistantStarter: String
    /// The « Pour vous » rows of this kind (PRD 34), above the catalog while nothing is searched.
    var forYou: ForYouModel?
    @ViewBuilder let card: (Entry, VodCardStyle) -> Card

    @AppStorage private var viewModeRaw: String

    init(
        title: String,
        model: VodCatalogModel<Entry>,
        totalCount: Int,
        revision: Int,
        viewModeKey: String,
        titles: VodSectionTitles,
        sortOptions: [SortField],
        searchPrompt: String,
        emptyDescription: String,
        assistantStarter: String = "",
        onOpenAssistant: ((String) -> Void)? = nil,
        forYou: ForYouModel? = nil,
        @ViewBuilder card: @escaping (Entry, VodCardStyle) -> Card
    ) {
        self.forYou = forYou
        self.assistantStarter = assistantStarter
        self.onOpenAssistant = onOpenAssistant
        self.title = title
        self.model = model
        self.totalCount = totalCount
        self.revision = revision
        self.titles = titles
        self.sortOptions = sortOptions
        self.searchPrompt = searchPrompt
        self.emptyDescription = emptyDescription
        self.card = card
        _viewModeRaw = AppStorage(wrappedValue: LiveViewMode.grid.rawValue, viewModeKey)
    }

    /// The question the assistant opens with: what is typed in the search field, else the starter.
    static func assistantPhrase(typed: String, starter: String) -> String {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? starter : text
    }

    private var viewMode: LiveViewMode { LiveViewMode(rawValue: viewModeRaw) ?? .grid }
    private var reloadKey: String { "\(model.filter.signature)#\(revision)" }

    var body: some View {
        @Bindable var filter = model.filter
        return CategoryNavigation(
            groups: model.groups,
            totalCount: totalCount,
            selection: $filter.group
        ) {
            content
        }
        .navigationTitle(title)
        .searchFilterToolbar(
            state: model.filter,
            hosts: model.hosts,
            sortOptions: sortOptions,
            prompt: searchPrompt
        )
        .toolbar {
            if let onOpenAssistant {
                ToolbarItem(placement: .automatic) {
                    Button {
                        // What is already typed in the search field becomes the question.
                        onOpenAssistant(Self.assistantPhrase(typed: model.filter.query, starter: assistantStarter))
                    } label: {
                        Label("Chercher avec l'assistant", systemImage: "sparkles")
                    }
                    .help("Trouver un titre en langage naturel : « un film avec Tom Cruise », « une série coréenne » (⌘K)")
                    .accessibilityLabel("Chercher avec l'assistant")
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
    }

    @ViewBuilder
    private var content: some View {
        if model.entries.isEmpty && !model.isLoading && model.resume.isEmpty && model.favorites.isEmpty {
            if model.filter.query.isEmpty && !model.filter.hasActiveFilter {
                ContentUnavailableView("Aucun contenu", systemImage: "film.stack", description: Text(emptyDescription))
            } else {
                ContentUnavailableView.search(text: model.filter.query)
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if let message = model.errorMessage {
                        Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                    if model.searchIgnoresCategory {
                        Label("Recherche dans toutes les catégories", systemImage: "magnifyingglass")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if model.showsSections {
                        if let forYou { ForYouShelves(model: forYou) }
                        shelf(titles.resume, icon: titles.resumeIcon, entries: model.resume)
                        shelf(titles.favorites, icon: "star.fill", entries: model.favorites)
                        if !model.resume.isEmpty || !model.favorites.isEmpty {
                            Text(titles.all).font(.title3.bold())
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
        }
    }

    private func paged(_ entry: Entry, style: VodCardStyle) -> some View {
        card(entry, style).onAppear { model.loadMoreIfNeeded(current: entry) }
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: ui.posterGridMinWidth, maximum: ui.posterGridMaxWidth), spacing: ui.spacingL)], spacing: ui.value(20)) {
            ForEach(model.entries, id: \.entryId) { paged($0, style: .poster) }
        }
    }

    private var list: some View {
        LazyVStack(spacing: 0) {
            ForEach(model.entries, id: \.entryId) { entry in
                paged(entry, style: .row)
                Divider()
            }
        }
    }

    @ViewBuilder
    private func shelf(_ title: String, icon: String, entries: [Entry]) -> some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: icon).font(.title3.bold())
                HorizontalShelf(items: entries, spacing: 16, alignment: .top) { entry in
                    card(entry, .poster).frame(width: ui.shelfPosterWidth)
                }
            }
        }
    }
}

/// Shared poster artwork: 2:3 frame, rating badge, broken indicator, resume bar and favorite star.
struct PosterArtwork: View {
    let posterUrl: String?
    let rating: Double?
    let progress: Double?
    let isFavorite: Bool
    var isBroken: Bool = false
    var placeholder = "film"
    var onToggleFavorite: () -> Void

    var body: some View {
        // The 2:3 frame comes from a flexible clear base, not from the image: inside a horizontal
        // shelf the parent proposes no height, and an image-driven frame collapsed to nothing.
        Color.clear
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .overlay {
                ThumbnailImageView(urlString: posterUrl, size: .poster, placeholderSystemImage: placeholder, fills: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .topLeading) {
                HStack(spacing: 4) {
                    if let rating, rating > 0 {
                        Text(String(format: "★ %.1f", rating))
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.black.opacity(0.7), in: Capsule())
                            .foregroundStyle(.yellow)
                    }
                    if isBroken {
                        BrokenBadge(style: .poster)
                    }
                }
                .padding(6)
            }
            .overlay(alignment: .topTrailing) {
                Button(action: onToggleFavorite) {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .foregroundStyle(isFavorite ? Color.yellow : Color.white)
                        .padding(6)
                        .background(.black.opacity(0.45), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(6)
                .accessibilityLabel(isFavorite ? "Retirer des favoris" : "Ajouter aux favoris")
            }
            .overlay(alignment: .bottom) {
                if let progress, progress > 0 {
                    ProgressView(value: min(progress, 1))
                        .progressViewStyle(.linear)
                        .tint(.red)
                        .padding(.horizontal, 6).padding(.bottom, 6)
                }
            }
    }
}

/// Hover highlight (macOS pointer; inert on touch).
struct HoverLift: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        #if os(tvOS)
        content
        #else
        content
            .scaleEffect(hovering ? 1.03 : 1)
            .shadow(color: .black.opacity(hovering ? 0.25 : 0), radius: 8, y: 4)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .onHover { hovering = $0 }
        #endif
    }
}

extension View {
    func hoverLift() -> some View { modifier(HoverLift()) }
}
