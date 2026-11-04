import SwiftUI
import Observation
import CndCoreBridge

/// Details of one movie. The SQLite row is shown at once; the OMDb enrichment runs afterwards and
/// only here (or on explicit refresh), never while scrolling the grid.
@Observable
@MainActor
final class MovieDetailsModel {
    let vod: VodContext
    private(set) var item: IptvItemRecord
    private(set) var metadata: MediaMetadata?
    private(set) var recommendations: [Recommendation] = []
    private(set) var sagaInfo: SagaInfo?
    private(set) var isLoadingMetadata = false
    private(set) var metadataMessage: String?

    init(item: IptvItemRecord, vod: VodContext) {
        self.item = item
        self.vod = vod
    }

    var resumePosition: Int64? { VodContext.resumePosition(for: item) }

    func load() async {
        await reloadItem()
        await refreshMetadata(force: false)
        await loadRecommendations()
    }

    private func loadRecommendations() async {
        let engine = vod.engine
        let id = item.id
        let recs = (try? await Task.detached(priority: .userInitiated) {
            try engine.recommendationsFor(itemId: id, context: .playing, limit: 10)
        }.value) ?? []
        let saga = try? await Task.detached(priority: .userInitiated) {
            try engine.sagaFor(itemId: id)
        }.value
        self.recommendations = recs
        self.sagaInfo = saga
    }

    private func reloadItem() async {
        let engine = vod.engine
        let id = item.id
        if let fresh = try? await Task.detached(priority: .userInitiated, operation: {
            try engine.getItemById(itemId: id)
        }).value {
            item = fresh
        }
    }

    func refreshMetadata(force: Bool) async {
        guard let key = vod.omdbKey() else {
            metadataMessage = "Ajoutez une clé OMDb dans les Réglages pour enrichir la fiche."
            return
        }
        guard !isLoadingMetadata else { return }
        isLoadingMetadata = true
        metadataMessage = nil
        defer { isLoadingMetadata = false }
        do {
            let result = try await vod.engine.fetchItemMetadata(itemId: item.id, apiKey: key, forceRefresh: force)
            metadata = result
            if result == nil { metadataMessage = "Aucune fiche OMDb trouvée pour ce titre." }
            await reloadItem()
        } catch {
            metadataMessage = userMessage(for: error)
        }
    }

    func toggleFavorite() async {
        if let value = await vod.toggleFavorite(stableHash: item.stableHash, kind: item.kind) {
            item.isFavorite = value
        }
    }

    func toggleBroken() async {
        if let value = await vod.toggleBroken(stableHash: item.stableHash, kind: item.kind) {
            item.isBroken = value
        }
    }
}

struct MovieDetailsView: View {
    @Environment(\.uiMetrics) private var ui
    @State private var model: MovieDetailsModel
    @State private var showsDebug = false
    /// Narrow layout for the side panel (under the player) instead of a full page.
    let compact: Bool
    let onClose: (() -> Void)?

    init(item: IptvItemRecord, vod: VodContext, compact: Bool = false, onClose: (() -> Void)? = nil) {
        _model = State(initialValue: MovieDetailsModel(item: item, vod: vod))
        self.compact = compact
        self.onClose = onClose
    }

    private var item: IptvItemRecord { model.item }
    private var title: String { item.nameClean.isEmpty ? item.name : item.nameClean }
    private var rating: Double? { item.imdbRating ?? model.metadata?.imdbRating }
    private var plot: String? { model.metadata?.plot ?? item.plot }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: compact ? 12 : 20) {
                if compact { compactHeader } else { hero }
                VStack(alignment: .leading, spacing: compact ? 12 : 16) {
                    actions
                    if model.isLoadingMetadata {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Enrichissement OMDb…").foregroundStyle(.secondary) }
                            .font(.callout)
                    } else if let message = model.metadataMessage {
                        Label(message, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                    }
                    if let genres = genres, !genres.isEmpty {
                        FlowLayout { ForEach(genres, id: \.self) { PillView(text: $0) } }
                    }
                    if let plot, !plot.isEmpty {
                        Text(plot).font(.body)
                    }
                    credits
                    if !model.recommendations.isEmpty {
                        recommendationsSection
                    }
                    debugPanel
                }
                .padding(.horizontal, compact ? 14 : 20)
                .padding(.bottom, 24)
            }
        }
        #if os(iOS)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await model.load() }
    }

    private var genres: [String]? {
        model.metadata?.genres?
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // MARK: Hero

    /// Poster, title and rating side by side, plus a close button: fits a ~380 pt panel.
    private var compactHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            ThumbnailImageView(urlString: item.logoUrl, size: .poster, placeholderSystemImage: "film", fills: true)
                .frame(width: ui.posterCompactWidth, height: ui.posterHeight(forWidth: ui.posterCompactWidth))
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline).lineLimit(3)
                if item.isBroken {
                    Label("Signalé en panne", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.red.opacity(0.25), in: Capsule())
                        .foregroundStyle(Color.red)
                }
                Text(metaLine).font(.caption).foregroundStyle(.secondary)
                ratingRow
            }
            Spacer(minLength: 0)
            if let onClose {
                Button(action: onClose) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Fermer la fiche")
            }
        }
        .padding([.horizontal, .top], 14)
    }

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            ThumbnailImageView(urlString: item.logoUrl, size: .poster, placeholderSystemImage: "film", fills: true)
                .frame(maxWidth: .infinity)
                .frame(height: 320)
                .blur(radius: 40)
                .clipped()
                .overlay(LinearGradient(colors: [.clear, Color.black.opacity(0.65)], startPoint: .top, endPoint: .bottom))
            HStack(alignment: .bottom, spacing: 20) {
                ThumbnailImageView(urlString: item.logoUrl, size: .poster, placeholderSystemImage: "film", fills: true)
                    .frame(width: ui.posterDetailWidth, height: ui.posterHeight(forWidth: ui.posterDetailWidth))
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(radius: 10)
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).font(.title.bold()).lineLimit(3)
                    if item.isBroken {
                        Label("Signalé en panne", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.red.opacity(0.3), in: Capsule())
                            .foregroundStyle(Color.red)
                    }
                    Text(metaLine).font(.callout)
                    ratingRow
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(20)
        }
        .frame(height: 320)
    }

    private var metaLine: String {
        var parts: [String] = []
        if let year = item.year { parts.append(String(year)) } else if let year = model.metadata?.year { parts.append(year) }
        if let rated = model.metadata?.rated, rated != "N/A" { parts.append(rated) }
        if let runtime = model.metadata?.runtime, runtime != "N/A" { parts.append(runtime) }
        if let group = item.groupTitle, !group.isEmpty { parts.append(group) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var ratingRow: some View {
        HStack(spacing: 12) {
            if let rating, rating > 0 {
                Label(String(format: "%.1f", rating), systemImage: "star.fill").foregroundStyle(.yellow)
                if let votes = model.metadata?.imdbVotes, votes != "N/A" {
                    Text("\(votes) votes").font(.caption).opacity(0.8)
                }
            }
            if let meta = model.metadata?.metascore, meta != "N/A" {
                Text("Metascore \(meta)").font(.caption.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.green.opacity(0.8), in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .font(.headline)
    }

    // MARK: Actions

    @ViewBuilder
    private var actions: some View {
        if compact {
            FlowLayout(spacing: 8) { primaryButtons }.controlSize(.small)
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { primaryButtons }
                VStack(alignment: .leading, spacing: 10) { primaryButtons }
            }
        }
    }

    @ViewBuilder
    private var primaryButtons: some View {
        if let position = model.resumePosition {
            Button { model.vod.play(item, resume: true) } label: {
                Label("Reprendre (\(TimeFormat.hms(milliseconds: position)))", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            Button { model.vod.play(item, resume: false) } label: {
                Label("Recommencer depuis le début", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.bordered)
        } else {
            Button { model.vod.play(item, resume: false) } label: { Label("Lire", systemImage: "play.fill") }
                .buttonStyle(.borderedProminent)
        }
        Button { model.vod.downloadMovie(item) } label: { Label("Télécharger", systemImage: "arrow.down.circle") }
            .buttonStyle(.bordered)
        Button { Task { await model.toggleFavorite() } } label: {
            Label(item.isFavorite ? "Favori" : "Ajouter aux favoris", systemImage: item.isFavorite ? "star.fill" : "star")
        }
        .buttonStyle(.bordered)
        Button { Task { await model.toggleBroken() } } label: {
            Label(item.isBroken ? "En panne" : "Signaler en panne",
                  systemImage: item.isBroken ? "exclamationmark.triangle.fill" : "exclamationmark.triangle")
        }
        .buttonStyle(.bordered)
        .tint(item.isBroken ? .red : .secondary)
        Menu {
            MovieActionsMenu(
                item: item, vod: model.vod,
                onToggleFavorite: { Task { await model.toggleFavorite() } },
                onToggleBroken: { Task { await model.toggleBroken() } },
                onRefreshMetadata: { Task { await model.refreshMetadata(force: true) } }
            )
        } label: {
            Label("Plus", systemImage: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: Credits and debug

    @ViewBuilder
    private var recommendationsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().padding(.vertical, 4)
            HStack {
                let title = if let saga = model.sagaInfo {
                    "Dans la saga \(saga.name)"
                } else {
                    "Titres recommandés"
                }
                Text(title)
                    .font(.headline)
                Spacer()
                if let saga = model.sagaInfo, !saga.missingTitles.isEmpty {
                    Text("\(saga.missingTitles.count) absent(s)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(model.recommendations, id: \.item.stableHash) { rec in
                Button {
                    model.vod.play(rec.item, resume: false)
                } label: {
                    HStack(spacing: 10) {
                        ThumbnailImageView(urlString: rec.item.logoUrl, size: .poster, placeholderSystemImage: "film", fills: true)
                            .frame(width: ui.posterThumbWidth, height: ui.posterHeight(forWidth: ui.posterThumbWidth))
                            .background(.quaternary)
                            .clipShape(RoundedRectangle(cornerRadius: 6))

                        VStack(alignment: .leading, spacing: 3) {
                            Text(rec.reasonText)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                                .lineLimit(1)

                            Text(rec.item.name)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)

                            if let year = rec.item.year {
                                Text(String(year))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(6)
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var credits: some View {
        VStack(alignment: .leading, spacing: 8) {
            creditRow("Réalisateur", model.metadata?.director)
            creditRow("Acteurs", model.metadata?.actors)
        }
    }

    @ViewBuilder
    private func creditRow(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty, value != "N/A" {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.callout)
            }
        }
    }

    private var debugPanel: some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: 4) {
            Text("Informations techniques").font(.headline)
            debugRow("IMDb", model.metadata?.imdbId ?? item.imdbId)
            debugRow("Source", model.metadata.map { $0.fromCache ? "cache SQLite" : "réseau" })
            debugRow("Hôte du flux", item.host)
            debugRow("Conteneur", item.containerExt)
            debugRow("Hash", item.stableHash)
        }
        .font(.caption)
        .padding(.top, 6)
        #else
        DisclosureGroup("Informations techniques OMDb", isExpanded: $showsDebug) {
            VStack(alignment: .leading, spacing: 4) {
                debugRow("IMDb", model.metadata?.imdbId ?? item.imdbId)
                debugRow("Source", model.metadata.map { $0.fromCache ? "cache SQLite" : "réseau" })
                debugRow("Hôte du flux", item.host)
                debugRow("Conteneur", item.containerExt)
                debugRow("Hash", item.stableHash)
            }
            .font(.caption.monospaced())
            .padding(.top, 6)
        }
        .font(.callout)
        #endif
    }

    private func debugRow(_ label: String, _ value: String?) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
            #if os(tvOS)
            Text(value ?? "—")
            #else
            Text(value ?? "—").textSelection(.enabled)
            #endif
        }
    }
}
