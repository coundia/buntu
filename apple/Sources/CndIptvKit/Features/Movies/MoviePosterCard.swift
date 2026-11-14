import SwiftUI
import CndCoreBridge

/// Context / "more" menu shared by the poster card and the details screen.
struct MovieActionsMenu: View {
    let item: IptvItemRecord
    let vod: VodContext
    var onToggleFavorite: () -> Void = {}
    var onToggleBroken: (() -> Void)? = nil
    var onRefreshMetadata: (() -> Void)?

    var body: some View {
        let lang = AppLanguageStore.shared
        if let position = VodContext.resumePosition(for: item) {
            Button(lang.t("movies.action.resumeAt", TimeFormat.hms(milliseconds: position)), systemImage: "play.fill") {
                vod.play(item, resume: true)
            }
            Button(lang.t("movies.action.restart"), systemImage: "arrow.counterclockwise") {
                vod.play(item, resume: false)
            }
        } else {
            Button(lang.t("movies.action.play"), systemImage: "play.fill") { vod.play(item, resume: false) }
        }
        Button(lang.t(item.isFavorite ? "movies.favorite.remove" : "movies.favorite.add"),
               systemImage: item.isFavorite ? "star.slash" : "star", action: onToggleFavorite)
        if let onToggleBroken {
            Button(lang.t(item.isBroken ? "movies.broken.restore" : "movies.broken.report"),
                   systemImage: item.isBroken ? "checkmark.circle" : "exclamationmark.triangle",
                   action: onToggleBroken)
        }
        PlayOnAnotherDeviceMenu(item: item, positionMs: UInt64(max(0, VodContext.resumePosition(for: item) ?? 0)))
        Button(lang.t("movies.action.download"), systemImage: "arrow.down.circle") { vod.downloadMovie(item) }
        if let media = PlayableMedia(item: item) {
            Menu(lang.t("movies.action.openIn"), systemImage: "arrow.up.forward.app") {
                ForEach(ExternalPlayer.availableOnThisPlatform) { player in
                    Button(player.displayName) { Task { _ = await ExternalPlayerLauncher.launch(player, media: media) } }
                }
            }
            Divider()
            Button(lang.t("movies.action.copyUrl"), systemImage: "link") { ExternalPlayerLauncher.copyStreamUrl(media) }
            Button(lang.t("movies.action.copyFfmpeg"), systemImage: "terminal") { ExternalPlayerLauncher.copyFfmpegCommand(media) }
            Button(lang.t("movies.action.copyCurl"), systemImage: "terminal") { ExternalPlayerLauncher.copyCurlCommand(media) }
        }
        if let onRefreshMetadata {
            Divider()
            Button(lang.t("movies.action.refreshOmdb"), systemImage: "arrow.clockwise", action: onRefreshMetadata)
        }
    }
}

/// Poster tile (or list row). Tapping opens the details; play and download live in the menu and
/// on the details screen.
struct MoviePosterCard: View {
    @Environment(\.uiMetrics) private var ui
    let item: IptvItemRecord
    let style: VodCardStyle
    let vod: VodContext
    var onToggleFavorite: () -> Void
    var onToggleBroken: (() -> Void)? = nil

    private var progress: Double? {
        guard item.resumePositionMs > 0, item.durationMs > 0, !item.isCompleted else { return nil }
        return Double(item.resumePositionMs) / Double(item.durationMs)
    }

    private var displayTitle: String { item.nameClean.isEmpty ? item.name : item.nameClean }

    var body: some View {
        VodCardLink(route: .movie(item)) {
            switch style {
            case .poster: poster
            case .row: row
            }
        }
        .contextMenu {
            MovieActionsMenu(
                item: item,
                vod: vod,
                onToggleFavorite: onToggleFavorite,
                onToggleBroken: onToggleBroken
            )
        }
        .accessibilityLabel(displayTitle)
    }

    private var poster: some View {
        VStack(alignment: .leading, spacing: 6) {
            PosterArtwork(
                posterUrl: item.logoUrl, rating: item.imdbRating, progress: progress,
                isFavorite: item.isFavorite, isBroken: item.isBroken, onToggleFavorite: onToggleFavorite
            )
            .hoverLift()
            Text(displayTitle).font(.subheadline.weight(.semibold)).lineLimit(2)
            if let year = item.year {
                Text(String(year)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var row: some View {
        HStack(spacing: 12) {
            ThumbnailImageView(urlString: item.logoUrl, size: .poster, placeholderSystemImage: "film", fills: true)
                .frame(width: ui.posterThumbWidth, height: ui.posterHeight(forWidth: ui.posterThumbWidth))
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(displayTitle).font(.body.weight(.semibold)).lineLimit(1)
                    if item.isBroken {
                        BrokenBadge(style: .compact)
                    }
                }
                HStack(spacing: 6) {
                    if let year = item.year { Text(String(year)) }
                    if let group = item.groupTitle, !group.isEmpty { Text(group) }
                    if let rating = item.imdbRating, rating > 0 { Text(String(format: "★ %.1f", rating)).foregroundStyle(.yellow) }
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let progress {
                    ProgressView(value: min(progress, 1)).progressViewStyle(.linear).tint(.red).frame(maxWidth: 160)
                }
            }
            Spacer()
            Button(action: onToggleFavorite) {
                Image(systemName: item.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(item.isFavorite ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AppLanguageStore.shared.t(item.isFavorite ? "movies.favorite.remove" : "movies.favorite.add"))
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}
