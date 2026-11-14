import SwiftUI
import Observation
import CndCoreBridge

@Observable
@MainActor
final class SeriesDetailsModel {
    let vod: VodContext
    private(set) var series: SeriesRecord
    private(set) var seasons: [SeasonSummary] = []
    private(set) var selectedSeason: UInt32?
    private(set) var episodes: [IptvItemRecord] = []
    private(set) var isHydrating = false
    private(set) var hydrationError: String?
    private(set) var metadata: MediaMetadata?
    private(set) var isLoadingMetadata = false
    private(set) var metadataMessage: String?

    init(series: SeriesRecord, vod: VodContext) {
        self.series = series
        self.vod = vod
    }

    func load() async {
        await reloadStructure()
        await hydrateIfNeeded()
        if selectedSeason == nil { selectedSeason = seasons.first?.seasonNum }
        await reloadEpisodes()
        await refreshMetadata(force: false)
    }

    private func reloadStructure() async {
        let engine = vod.engine
        let id = series.id
        let snapshot = try? await Task.detached(priority: .userInitiated) {
            (series: try engine.getSeriesById(seriesId: id), seasons: try engine.getSeriesSeasons(seriesId: id))
        }.value
        if let fresh = snapshot?.series { series = fresh }
        if let found = snapshot?.seasons { seasons = found }
    }

    /// An Xtream series is imported without episodes; they are fetched on first open.
    func hydrateIfNeeded() async {
        guard series.episodeCount == 0 else { return }
        let engine = vod.engine
        guard let source = (try? engine.listSources())?.first(where: { $0.id == series.sourceId }),
              source.sourceType == "xtream" else { return }
        let key = source.passwordRef ?? KeychainStore.xtreamKey(forSourceUuid: source.uuid)
        guard let password = try? vod.keychain.readSecret(forKey: key) else {
            hydrationError = SourcesError.missingPassword.localizedDescription
            return
        }
        isHydrating = true
        hydrationError = nil
        defer { isHydrating = false }
        do {
            _ = try await engine.ensureXtreamSeriesEpisodes(seriesDbId: series.id, password: password)
            await reloadStructure()
        } catch {
            hydrationError = userMessage(for: error)
        }
    }

    func retryHydration() async {
        await hydrateIfNeeded()
        if selectedSeason == nil { selectedSeason = seasons.first?.seasonNum }
        await reloadEpisodes()
    }

    func select(season: UInt32) async {
        selectedSeason = season
        await reloadEpisodes()
    }

    func reloadEpisodes() async {
        let engine = vod.engine
        let id = series.id
        let season = selectedSeason
        episodes = (try? await Task.detached(priority: .userInitiated) {
            try engine.getSeriesEpisodes(seriesId: id, seasonNum: season)
        }.value) ?? []
    }

    // MARK: Playback

    func playEpisode(at index: Int) {
        vod.playEpisodes(episodes, series: series, startingAt: index, resume: true)
    }

    func playSeason() {
        vod.playEpisodes(episodes, series: series, startingAt: 0)
    }

    func playWholeSeries() async {
        let engine = vod.engine
        let id = series.id
        let all = (try? await Task.detached(priority: .userInitiated) {
            try engine.getSeriesEpisodes(seriesId: id, seasonNum: nil)
        }.value) ?? []
        vod.playEpisodes(all, series: series, startingAt: 0)
    }

    // MARK: Downloads

    func downloadEpisode(_ episode: IptvItemRecord) {
        vod.downloadEpisodes([episode], seriesTitle: series.title)
    }

    func downloadSeason() {
        vod.downloadEpisodes(episodes, seriesTitle: series.title)
    }

    // MARK: Metadata and favorite

    func refreshMetadata(force: Bool) async {
        guard let key = vod.omdbKey() else {
            metadataMessage = AppLanguageStore.shared.t("series.omdb.missingKey")
            return
        }
        guard !isLoadingMetadata else { return }
        isLoadingMetadata = true
        metadataMessage = nil
        defer { isLoadingMetadata = false }
        do {
            metadata = try await vod.engine.fetchSeriesMetadata(seriesId: series.id, apiKey: key, forceRefresh: force)
            if metadata == nil { metadataMessage = AppLanguageStore.shared.t("series.omdb.notFound") }
            await reloadStructure()
        } catch {
            metadataMessage = userMessage(for: error)
        }
    }

    func toggleFavorite() async {
        if let value = await vod.toggleFavorite(stableHash: series.stableHash, kind: "series") {
            series.isFavorite = value
        }
    }

    func toggleBroken() async {
        if let value = await vod.toggleBroken(stableHash: series.stableHash, kind: "series") {
            series.isBroken = value
        }
    }

    func toggleEpisodeBroken(_ episode: IptvItemRecord) async {
        if let value = await vod.toggleBroken(stableHash: episode.stableHash, kind: episode.kind) {
            for index in episodes.indices where episodes[index].stableHash == episode.stableHash {
                episodes[index].isBroken = value
            }
        }
    }
}

struct SeriesDetailsView: View {
    @Environment(\.uiMetrics) private var ui
    @State private var model: SeriesDetailsModel
    /// Narrow layout for the side panel (under the player) instead of a full page.
    let compact: Bool
    let onClose: (() -> Void)?

    init(series: SeriesRecord, vod: VodContext, compact: Bool = false, onClose: (() -> Void)? = nil) {
        _model = State(initialValue: SeriesDetailsModel(series: series, vod: vod))
        self.compact = compact
        self.onClose = onClose
    }

    private var series: SeriesRecord { model.series }
    private var plot: String? { model.metadata?.plot ?? series.plot }
    private var rating: Double? { series.imdbRating ?? model.metadata?.imdbRating }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: compact ? 12 : 20) {
                if compact { compactHeader } else { header }
                VStack(alignment: .leading, spacing: compact ? 12 : 16) {
                    actions
                    status
                    if let genres = genres, !genres.isEmpty {
                        FlowLayout { ForEach(genres, id: \.self) { PillView(text: $0) } }
                    }
                    if let plot, !plot.isEmpty { Text(plot) }
                    seasonPicker
                    episodeList
                }
                .padding(.horizontal, compact ? 14 : 20)
                .padding(.bottom, 24)
            }
        }
        #if os(iOS)
        .navigationTitle(series.title)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await model.load() }
    }

    private var genres: [String]? {
        model.metadata?.genres?
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // MARK: Header

    private var compactHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            ThumbnailImageView(urlString: series.posterUrl, size: .poster, placeholderSystemImage: "play.tv", fills: true)
                .frame(width: ui.posterCompactWidth, height: ui.posterHeight(forWidth: ui.posterCompactWidth))
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 6) {
                Text(series.title).font(.headline).lineLimit(3)
                Text(SeriesLabels.counts(series)).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    if series.isBroken {
                        BrokenBadge(style: .compact)
                    }
                    if let rating, rating > 0 {
                        Label(String(format: "%.1f", rating), systemImage: "star.fill").foregroundStyle(.yellow).font(.subheadline)
                    }
                }
            }
            Spacer(minLength: 0)
            if let onClose {
                Button(action: onClose) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(AppLanguageStore.shared.t("series.a11y.closeDetails"))
            }
        }
        .padding([.horizontal, .top], 14)
    }

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            ThumbnailImageView(urlString: series.backdropUrl ?? series.posterUrl, size: .poster, placeholderSystemImage: "play.tv", fills: true)
                .frame(maxWidth: .infinity).frame(height: 300)
                .blur(radius: 40).clipped()
                .overlay(LinearGradient(colors: [.clear, Color.black.opacity(0.65)], startPoint: .top, endPoint: .bottom))
            HStack(alignment: .bottom, spacing: 20) {
                ThumbnailImageView(urlString: series.posterUrl, size: .poster, placeholderSystemImage: "play.tv", fills: true)
                    .frame(width: ui.value(140), height: ui.posterHeight(forWidth: ui.value(140)))
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(radius: 10)
                VStack(alignment: .leading, spacing: 8) {
                    Text(series.title).font(.title.bold()).lineLimit(3)
                    Text(SeriesLabels.counts(series)).font(.callout)
                    HStack(spacing: 10) {
                        if series.isBroken {
                            BrokenBadge(style: .compact)
                        }
                        if let rating, rating > 0 {
                            Label(String(format: "%.1f", rating), systemImage: "star.fill").foregroundStyle(.yellow).font(.headline)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(20)
        }
        .frame(height: 300)
    }

    // MARK: Actions

    @ViewBuilder
    private var actions: some View {
        if compact {
            FlowLayout(spacing: 8) { actionButtons }.controlSize(.small)
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { actionButtons }
                VStack(alignment: .leading, spacing: 10) { actionButtons }
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        let lang = AppLanguageStore.shared
        Button { model.playSeason() } label: {
            Label(model.selectedSeason.map { lang.t("series.action.playSeason", Int($0)) } ?? lang.t("series.action.play"), systemImage: "play.fill")
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.episodes.isEmpty)
        Button { model.downloadSeason() } label: {
            Label(model.selectedSeason.map { lang.t("series.action.downloadSeason", Int($0)) } ?? lang.t("series.action.download"), systemImage: "arrow.down.circle")
        }
        .buttonStyle(.bordered)
        .disabled(model.episodes.isEmpty)
        Button { Task { await model.toggleFavorite() } } label: {
            Label(lang.t("series.action.favorite"), systemImage: series.isFavorite ? "star.fill" : "star")
        }
        .buttonStyle(.bordered)
        .help(lang.t(series.isFavorite ? "series.favorite.remove" : "series.favorite.add"))
        .accessibilityLabel(lang.t(series.isFavorite ? "series.favorite.remove" : "series.favorite.add"))
        Button { Task { await model.toggleBroken() } } label: {
            if series.isBroken {
                Label(lang.t("series.broken.badge"), systemImage: "exclamationmark.triangle.fill")
            } else {
                Image(systemName: "exclamationmark.triangle")
            }
        }
        .buttonStyle(.bordered)
        .tint(series.isBroken ? .red : .secondary)
        .help(lang.t(series.isBroken ? "series.broken.restoreHelp" : "series.broken.reportHelp"))
        .accessibilityLabel(lang.t(series.isBroken ? "series.broken.restore" : "series.broken.report"))
        Menu {
            Button(lang.t("series.action.playWholeSeries"), systemImage: "play.rectangle.on.rectangle") { Task { await model.playWholeSeries() } }
            Button(lang.t("series.action.refreshOmdb"), systemImage: "arrow.clockwise") {
                Task { await model.refreshMetadata(force: true) }
            }
        } label: {
            Label(lang.t("series.action.more"), systemImage: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    @ViewBuilder
    private var status: some View {
        let lang = AppLanguageStore.shared
        if model.isHydrating {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(lang.t("series.status.hydrating")) }
                .font(.callout).foregroundStyle(.secondary)
        } else if let error = model.hydrationError {
            HStack {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Button(lang.t("series.action.retry")) { Task { await model.retryHydration() } }
            }
            .font(.callout)
        } else if model.isLoadingMetadata {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(lang.t("series.omdb.loading")) }
                .font(.callout).foregroundStyle(.secondary)
        } else if let message = model.metadataMessage {
            Label(message, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: Seasons and episodes

    @ViewBuilder
    private var seasonPicker: some View {
        if model.seasons.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.seasons, id: \.seasonNum) { season in
                        let selected = model.selectedSeason == season.seasonNum
                        Button { Task { await model.select(season: season.seasonNum) } } label: {
                            Text(AppLanguageStore.shared.t("series.seasonNumber", Int(season.seasonNum)))
                                .font(.subheadline.weight(selected ? .semibold : .regular))
                                .padding(.horizontal, 14).padding(.vertical, 6)
                                .background(selected ? Color.accentColor : Color.secondary.opacity(0.18), in: Capsule())
                                .foregroundStyle(selected ? Color.white : Color.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var episodeList: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(model.episodes.enumerated()), id: \.element.id) { index, episode in
                EpisodeRow(
                    episode: episode,
                    seriesTitle: series.title,
                    onPlay: { model.playEpisode(at: index) },
                    onDownload: { model.downloadEpisode(episode) },
                    onToggleBroken: { Task { await model.toggleEpisodeBroken(episode) } }
                )
                Divider()
            }
        }
    }
}

struct EpisodeRow: View {
    let episode: IptvItemRecord
    let seriesTitle: String
    var onPlay: () -> Void
    var onDownload: () -> Void
    var onToggleBroken: (() -> Void)? = nil

    @MainActor
    private var title: String {
        let text = DownloadPlanner.episodeTitle(episode.nameClean.isEmpty ? episode.name : episode.nameClean, seriesTitle: seriesTitle)
        return text.isEmpty ? AppLanguageStore.shared.t("series.episode.fallbackTitle", Int(episode.episodeNum ?? 0)) : text
    }

    private var progress: Double? {
        guard episode.resumePositionMs > 0, episode.durationMs > 0, !episode.isCompleted else { return nil }
        return Double(episode.resumePositionMs) / Double(episode.durationMs)
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(episode.episodeNum.map { String(format: "E%02d", $0) } ?? "—")
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title).font(.body).lineLimit(2)
                    if episode.isCompleted { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                    if episode.isBroken {
                        BrokenBadge(style: .compact)
                    }
                }
                if let position = VodContext.resumePosition(for: episode) {
                    Text(AppLanguageStore.shared.t("series.episode.resumeAt", TimeFormat.hms(milliseconds: position))).font(.caption).foregroundStyle(.secondary)
                }
                if let progress {
                    ProgressView(value: min(progress, 1)).progressViewStyle(.linear).tint(.red).frame(maxWidth: 220)
                }
            }
            Spacer()
            let lang = AppLanguageStore.shared
            Button(action: onPlay) { Image(systemName: "play.fill") }
                .buttonStyle(.borderless)
                .accessibilityLabel(lang.t("series.episode.playA11y"))
            Button(action: onDownload) { Image(systemName: "arrow.down.circle") }
                .buttonStyle(.borderless)
                .accessibilityLabel(lang.t("series.episode.downloadA11y"))
            Menu {
                if let media = PlayableMedia(item: episode) {
                    Menu(lang.t("series.action.openIn")) {
                        ForEach(ExternalPlayer.availableOnThisPlatform) { player in
                            Button(player.displayName) { Task { _ = await ExternalPlayerLauncher.launch(player, media: media) } }
                        }
                    }
                    Button(lang.t("series.action.copyUrl")) { ExternalPlayerLauncher.copyStreamUrl(media) }
                    Button(lang.t("series.action.copyFfmpeg")) { ExternalPlayerLauncher.copyFfmpegCommand(media) }
                }
                if let onToggleBroken {
                    Button(lang.t(episode.isBroken ? "series.broken.restore" : "series.broken.report"),
                           systemImage: episode.isBroken ? "checkmark.circle" : "exclamationmark.triangle",
                           action: onToggleBroken)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel(lang.t("series.episode.moreA11y"))
        }
        .padding(.vertical, 8)
        .accessibleTap(perform: onPlay)
    }
}
