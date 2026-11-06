import SwiftUI
import CndCoreBridge

struct MoviesCatalogView: View {
    @State private var model: VodCatalogModel<IptvItemRecord>
    let revision: Int
    let totalMovies: Int
    var onOpenAssistant: ((String) -> Void)?
    var forYou: ForYouModel?
    @Environment(VodContext.self) private var vod

    init(engine: CndEngine, revision: Int, totalMovies: Int, forYou: ForYouModel? = nil, onOpenAssistant: ((String) -> Void)? = nil) {
        self.onOpenAssistant = onOpenAssistant
        self.forYou = forYou
        _model = State(initialValue: VodCatalogModel(kind: "movie", source: .movies(engine: engine)))
        self.revision = revision
        self.totalMovies = totalMovies
    }

    var body: some View {
        VodCatalogView(
            title: "Films",
            model: model,
            totalCount: totalMovies,
            revision: revision,
            viewModeKey: "movies.viewMode",
            titles: VodSectionTitles(resume: "Reprendre", resumeIcon: "play.circle", all: "Tous les films"),
            sortOptions: [.name, .rating, .recentlyAdded, .group, .host],
            searchPrompt: "Rechercher un film",
            emptyDescription: "Ajoutez une source dans l'onglet Sources pour importer des films.",
            assistantStarter: "un film ",
            onOpenAssistant: onOpenAssistant,
            forYou: forYou
        ) { item, style in
            MoviePosterCard(
                item: item,
                style: style,
                vod: vod,
                onToggleFavorite: { toggleFavorite(item) },
                onToggleBroken: { toggleBroken(item) }
            )
        }
    }

    private func toggleFavorite(_ item: IptvItemRecord) {
        Task {
            if let value = await vod.toggleFavorite(stableHash: item.stableHash, kind: item.kind) {
                model.applyFavorite(value, to: item)
            }
        }
    }

    private func toggleBroken(_ item: IptvItemRecord) {
        Task {
            if let value = await vod.toggleBroken(stableHash: item.stableHash, kind: item.kind) {
                model.applyBroken(value, to: item)
            }
        }
    }
}
