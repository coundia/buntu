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
        if let position = VodContext.resumePosition(for: item) {
            Button("Reprendre (\(TimeFormat.hms(milliseconds: position)))", systemImage: "play.fill") {
                vod.play(item, resume: true)
            }
            Button("Recommencer depuis le début", systemImage: "arrow.counterclockwise") {
                vod.play(item, resume: false)
            }
        } else {
            Button("Lire", systemImage: "play.fill") { vod.play(item, resume: false) }
        }
        Button(item.isFavorite ? "Retirer des favoris" : "Ajouter aux favoris",
               systemImage: item.isFavorite ? "star.slash" : "star", action: onToggleFavorite)
        if let onToggleBroken {
            Button(item.isBroken ? "Marquer comme fonctionnel" : "Signaler comme non fonctionnel",
                   systemImage: item.isBroken ? "checkmark.circle" : "exclamationmark.triangle",
                   action: onToggleBroken)
        }
        Button("Télécharger", systemImage: "arrow.down.circle") { vod.downloadMovie(item) }
        if let media = PlayableMedia(item: item) {
            Menu("Ouvrir dans…", systemImage: "arrow.up.forward.app") {
                ForEach(ExternalPlayer.availableOnThisPlatform) { player in
                    Button(player.displayName) { Task { _ = await ExternalPlayerLauncher.launch(player, media: media) } }
                }
            }
            Divider()
            Button("Copier l'URL", systemImage: "link") { ExternalPlayerLauncher.copyStreamUrl(media) }
            Button("Copier la commande FFmpeg", systemImage: "terminal") { ExternalPlayerLauncher.copyFfmpegCommand(media) }
            Button("Copier la commande cURL", systemImage: "terminal") { ExternalPlayerLauncher.copyCurlCommand(media) }
        }
        if let onRefreshMetadata {
            Divider()
            Button("Rafraîchir les métadonnées OMDb", systemImage: "arrow.clockwise", action: onRefreshMetadata)
        }
    }
}

/// Poster tile (or list row). Tapping opens the details; play and download live in the menu and
/// on the details screen.
struct MoviePosterCard: View {
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
                isFavorite: item.isFavorite, onToggleFavorite: onToggleFavorite
            )
            .hoverLift()
            Text(displayTitle).font(.subheadline.weight(.semibold)).lineLimit(2)
            if item.isBroken {
                Label("En panne", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Color.red.opacity(0.2), in: RoundedRectangle(cornerRadius: 3))
                    .foregroundStyle(Color.red)
            }
            if let year = item.year {
                Text(String(year)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var row: some View {
        HStack(spacing: 12) {
            ThumbnailImageView(urlString: item.logoUrl, size: .poster, placeholderSystemImage: "film", fills: true)
                .frame(width: 44, height: 66)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                Text(displayTitle).font(.body.weight(.semibold)).lineLimit(1)
                if item.isBroken {
                    Label("En panne", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.red)
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
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}
