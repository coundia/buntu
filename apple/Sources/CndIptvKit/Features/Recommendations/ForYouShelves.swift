import SwiftUI
import CndCoreBridge

/// The « Pour vous » rows of one screen (Films, Séries or Live TV, PRD 34). Each row holds cards of
/// that kind only; a ✨ beside the title says the AI re-ranked it.
struct ForYouShelves<ChannelCard: View>: View {
    @Environment(\.uiMetrics) private var ui
    let model: ForYouModel
    /// Reloads the sources (and with them the guide) when the guide is out of date.
    var onRefreshGuide: (() -> Void)?
    @ViewBuilder var channelCard: (RecoCard) -> ChannelCard

    var body: some View {
        if model.isEnabled {
            ForEach(model.shelves, id: \.id) { shelf in
                if shelf.shelf == .guideStale {
                    staleBanner(shelf)
                } else {
                    shelfView(shelf)
                }
            }
        }
    }

    // MARK: Rows

    private func shelfView(_ shelf: RecoShelf) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label(shelf.title, systemImage: Self.icon(for: shelf.shelf)).font(.title3.bold())
                if let by = shelf.refinedBy {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.tint)
                        .help("Affiné par \(by)")
                        .accessibilityLabel("Affiné par \(by)")
                }
            }
            if let note = shelf.note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            HorizontalShelf(items: shelf.items, spacing: 16, alignment: .top) { card in
                cardView(card)
                    .frame(width: model.kind == .live ? ui.shelfChannelCardWidth : ui.shelfPosterWidth)
            }
        }
    }

    private func staleBanner(_ shelf: RecoShelf) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "calendar.badge.exclamationmark").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(shelf.title).font(.headline)
                if let note = shelf.note { Text(note).font(.callout).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            if let onRefreshGuide {
                Button("Actualiser le guide", action: onRefreshGuide)
                    .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func cardView(_ card: RecoCard) -> some View {
        switch model.kind {
        case .movies: RecoMovieCard(card: card, model: model)
        case .series: RecoSeriesCard(card: card, model: model)
        case .live: channelCard(card)
        }
    }

    static func icon(for kind: RecoShelfKind) -> String {
        switch kind {
        case .resume: "play.circle"
        case .continue: "forward.end"
        case .forYou: "heart.text.square"
        case .popular: "flame"
        case .sagas: "film.stack"
        case .becauseYouWatched: "arrow.triangle.branch"
        case .newForYou: "sparkle"
        case .newSeason: "calendar.badge.plus"
        case .onNow: "dot.radiowaves.left.and.right"
        case .soon: "clock"
        case .usualChannels: "tv"
        case .guideStale: "calendar.badge.exclamationmark"
        }
    }
}

extension ForYouShelves where ChannelCard == EmptyView {
    init(model: ForYouModel, onRefreshGuide: (() -> Void)? = nil) {
        self.init(model: model, onRefreshGuide: onRefreshGuide) { _ in EmptyView() }
    }
}

/// « Pas intéressé » and « Moins de ce genre », on every card.
private struct RecoFeedbackMenu: View {
    let card: RecoCard
    let model: ForYouModel

    var body: some View {
        Divider()
        Button("Pas intéressé", systemImage: "hand.thumbsdown") { model.dismiss(card) }
        Button("Moins de ce genre", systemImage: "minus.circle") { model.lessLikeThis(card) }
    }
}

private struct RecoReason: View {
    let card: RecoCard

    var body: some View {
        HStack(spacing: 3) {
            if card.aiReason { Image(systemName: "sparkles").imageScale(.small) }
            Text(card.reasonText).lineLimit(2)
        }
        .font(.caption)
        .foregroundStyle(card.aiReason ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
    }
}

/// A film: opens its sheet like any film of the catalog.
struct RecoMovieCard: View {
    let card: RecoCard
    let model: ForYouModel
    @Environment(VodContext.self) private var vod

    var body: some View {
        if let item = card.item {
            let title = item.nameClean.isEmpty ? item.name : item.nameClean
            VodCardLink(route: .movie(item)) {
                VStack(alignment: .leading, spacing: 6) {
                    PosterArtwork(
                        posterUrl: item.logoUrl, rating: item.imdbRating, progress: Self.progress(item),
                        isFavorite: item.isFavorite,
                        onToggleFavorite: { Task { _ = await vod.toggleFavorite(stableHash: item.stableHash, kind: item.kind) } }
                    )
                    .hoverLift()
                    Text(title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    RecoReason(card: card)
                }
            }
            .contextMenu {
                Button("Lire", systemImage: "play.fill") { vod.play(item, resume: false) }
                PlayOnAnotherDeviceMenu(item: item, positionMs: UInt64(max(0, VodContext.resumePosition(for: item) ?? 0)))
                RecoFeedbackMenu(card: card, model: model)
            }
            .accessibilityLabel("\(title). \(card.reasonText)")
        }
    }

    private static func progress(_ item: IptvItemRecord) -> Double? {
        guard item.resumePositionMs > 0, item.durationMs > 0, !item.isCompleted else { return nil }
        return Double(item.resumePositionMs) / Double(item.durationMs)
    }
}

/// A series (never an episode of another one): with the episode to watch next when it has one.
struct RecoSeriesCard: View {
    let card: RecoCard
    let model: ForYouModel
    @Environment(VodContext.self) private var vod

    var body: some View {
        if let series = card.series {
            VodCardLink(route: .series(series)) {
                VStack(alignment: .leading, spacing: 6) {
                    PosterArtwork(
                        posterUrl: series.posterUrl, rating: series.imdbRating, progress: nil,
                        isFavorite: series.isFavorite, placeholder: "play.tv",
                        onToggleFavorite: { Task { _ = await vod.toggleFavorite(stableHash: series.stableHash, kind: "series") } }
                    )
                    .hoverLift()
                    Text(series.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    RecoReason(card: card)
                }
            }
            .contextMenu {
                if let episode = card.nextEpisode {
                    Button("Lire \(Self.label(episode))", systemImage: "play.fill") { vod.play(episode, resume: true) }
                    PlayOnAnotherDeviceMenu(item: episode, positionMs: UInt64(max(0, VodContext.resumePosition(for: episode) ?? 0)))
                }
                RecoFeedbackMenu(card: card, model: model)
            }
            .accessibilityLabel("\(series.title). \(card.reasonText)")
        }
    }

    static func label(_ episode: IptvItemRecord) -> String {
        "S\(episode.seasonNum ?? 1):E\(episode.episodeNum ?? 1)"
    }
}

/// The feedback entries of a channel card, for the Live TV screen's own card.
struct RecoChannelFeedback: View {
    let card: RecoCard
    let model: ForYouModel

    var body: some View { RecoFeedbackMenu(card: card, model: model) }
}

/// Live TV recommendations displayed directly below the docked player (PRD 34).
struct LivePlayerForYouView: View {
    @Environment(\.uiMetrics) private var ui
    let model: ForYouModel
    let playingURL: String?
    let onPlay: (IptvItemRecord) -> Void
    var onRefreshGuide: (() -> Void)?

    var body: some View {
        if model.isEnabled, !model.shelves.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(model.shelves, id: \.id) { shelf in
                    if shelf.shelf == .guideStale {
                        staleBanner(shelf)
                    } else if !shelf.items.isEmpty {
                        shelfSection(shelf)
                    }
                }
            }
        }
    }

    private func shelfSection(_ shelf: RecoShelf) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label(shelf.title, systemImage: ForYouShelves<EmptyView>.icon(for: shelf.shelf))
                    .font(.subheadline.weight(.bold))
                if let by = shelf.refinedBy {
                    Image(systemName: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.tint)
                        .help("Affiné par \(by)")
                        .accessibilityLabel("Affiné par \(by)")
                }
            }
            if let note = shelf.note {
                Text(note).font(.caption2).foregroundStyle(.secondary)
            }
            LazyVStack(spacing: 8) {
                ForEach(Array(shelf.items.enumerated()), id: \.offset) { _, card in
                    if let channel = card.item, channel.streamUrl != playingURL {
                        channelRow(card: card, channel: channel)
                    }
                }
            }
        }
    }

    private func channelRow(card: RecoCard, channel: IptvItemRecord) -> some View {
        Button {
            onPlay(channel)
        } label: {
            HStack(spacing: 10) {
                ThumbnailImageView(urlString: channel.logoUrl, size: .tvLogo)
                    .frame(width: ui.channelLogo, height: ui.channelLogo)
                    .padding(2)
                    .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(channel.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if channel.isBroken {
                            BrokenBadge(style: .compact)
                        }
                    }
                    if let program = card.program {
                        Text(program.title)
                            .font(.caption)
                            .foregroundStyle(.primary.opacity(0.85))
                            .lineLimit(1)
                    }
                    RecoReason(card: card)
                }
                Spacer(minLength: 0)
                Image(systemName: "play.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Lire", systemImage: "play.fill") { onPlay(channel) }
            PlayOnAnotherDeviceMenu(item: channel)
            RecoFeedbackMenu(card: card, model: model)
        }
    }

    private func staleBanner(_ shelf: RecoShelf) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "calendar.badge.exclamationmark").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(shelf.title).font(.subheadline.weight(.semibold))
                if let note = shelf.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                if let onRefreshGuide {
                    Button("Actualiser le guide", action: onRefreshGuide)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}
