import SwiftUI
import CndCoreBridge

enum SeriesLabels {
    @MainActor
    static func counts(_ series: SeriesRecord) -> String {
        let lang = AppLanguageStore.shared
        let seasons = series.seasonCount
        let episodes = series.episodeCount
        guard episodes > 0 else { return lang.t("series.counts.pending") }
        let seasonText = lang.t(seasons > 1 ? "series.counts.season.other" : "series.counts.season.one", Int(seasons))
        let episodeText = lang.t(episodes > 1 ? "series.counts.episode.other" : "series.counts.episode.one", Int(episodes))
        return "\(seasonText) · \(episodeText)"
    }
}

struct SeriesCatalogView: View {
    @State private var model: VodCatalogModel<SeriesRecord>
    let revision: Int
    let totalSeries: Int
    @Environment(VodContext.self) private var vod

    var onOpenAssistant: ((String) -> Void)?
    var forYou: ForYouModel?

    init(engine: CndEngine, revision: Int, totalSeries: Int, forYou: ForYouModel? = nil, onOpenAssistant: ((String) -> Void)? = nil) {
        self.onOpenAssistant = onOpenAssistant
        self.forYou = forYou
        _model = State(initialValue: VodCatalogModel(kind: "series", source: .series(engine: engine)))
        self.revision = revision
        self.totalSeries = totalSeries
    }

    var body: some View {
        let lang = AppLanguageStore.shared
        VodCatalogView(
            title: lang.t("series.title"),
            model: model,
            totalCount: totalSeries,
            revision: revision,
            viewModeKey: "series.viewMode",
            titles: VodSectionTitles(resume: lang.t("series.section.recents"), resumeIcon: "clock", all: lang.t("series.section.all")),
            sortOptions: [.name, .rating, .recentlyAdded, .group],
            searchPrompt: lang.t("series.searchPrompt"),
            emptyDescription: lang.t("series.empty.description"),
            assistantStarter: lang.t("series.assistantStarter"),
            onOpenAssistant: onOpenAssistant,
            forYou: forYou
        ) { series, style in
            SeriesCard(
                series: series,
                style: style,
                onToggleFavorite: { toggleFavorite(series) },
                onToggleBroken: { toggleBroken(series) }
            )
        }
    }

    private func toggleFavorite(_ series: SeriesRecord) {
        Task {
            if let value = await vod.toggleFavorite(stableHash: series.stableHash, kind: "series") {
                model.applyFavorite(value, to: series)
            }
        }
    }

    private func toggleBroken(_ series: SeriesRecord) {
        Task {
            if let value = await vod.toggleBroken(stableHash: series.stableHash, kind: "series") {
                model.applyBroken(value, to: series)
            }
        }
    }
}

struct SeriesCard: View {
    @Environment(\.uiMetrics) private var ui
    let series: SeriesRecord
    let style: VodCardStyle
    var onToggleFavorite: () -> Void
    var onToggleBroken: (() -> Void)? = nil

    var body: some View {
        VodCardLink(route: .series(series)) {
            switch style {
            case .poster: poster
            case .row: row
            }
        }
        .contextMenu {
            let lang = AppLanguageStore.shared
            Button(lang.t(series.isFavorite ? "series.favorite.remove" : "series.favorite.add"),
                   systemImage: series.isFavorite ? "star.slash" : "star", action: onToggleFavorite)
            if let onToggleBroken {
                Button(lang.t(series.isBroken ? "series.broken.restore" : "series.broken.report"),
                       systemImage: series.isBroken ? "checkmark.circle" : "exclamationmark.triangle",
                       action: onToggleBroken)
            }
        }
        .accessibilityLabel(series.title)
    }

    private var poster: some View {
        VStack(alignment: .leading, spacing: 6) {
            PosterArtwork(
                posterUrl: series.posterUrl, rating: series.imdbRating, progress: nil,
                isFavorite: series.isFavorite, isBroken: series.isBroken, placeholder: "play.tv", onToggleFavorite: onToggleFavorite
            )
            .hoverLift()
            Text(series.title).font(.subheadline.weight(.semibold)).lineLimit(2)
            Text(SeriesLabels.counts(series)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var row: some View {
        HStack(spacing: 12) {
            ThumbnailImageView(urlString: series.posterUrl, size: .poster, placeholderSystemImage: "play.tv", fills: true)
                .frame(width: ui.posterThumbWidth, height: ui.posterHeight(forWidth: ui.posterThumbWidth))
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(series.title).font(.body.weight(.semibold)).lineLimit(1)
                    if series.isBroken {
                        BrokenBadge(style: .compact)
                    }
                }
                Text(SeriesLabels.counts(series)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onToggleFavorite) {
                Image(systemName: series.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(series.isFavorite ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AppLanguageStore.shared.t(series.isFavorite ? "series.favorite.remove" : "series.favorite.add"))
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}
