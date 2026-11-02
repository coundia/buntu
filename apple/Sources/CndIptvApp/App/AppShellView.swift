import SwiftUI
import CndCoreBridge

enum AppTab: String, CaseIterable, Identifiable {
    case live
    case guide
    case movies
    case series
    case downloads
    case sources
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .live: return "Live TV"
        case .guide: return "Guide TV"
        case .movies: return "Films"
        case .series: return "Séries"
        case .downloads: return "Téléchargements"
        case .sources: return "Sources"
        case .settings: return "Réglages"
        }
    }

    var systemImage: String {
        switch self {
        case .live: return "tv"
        case .guide: return "calendar"
        case .movies: return "film"
        case .series: return "play.tv"
        case .downloads: return "arrow.down.circle"
        case .sources: return "antenna.radiowaves.left.and.right"
        case .settings: return "gearshape"
        }
    }
}

/// Root view: waits for the engine, then shows the adaptive navigation.
struct AppShellView: View {
    @Bindable var state: AppState
    var commands: AppCommandCenter = AppCommandCenter()

    var body: some View {
        if let engine = state.engine {
            LoadedShellView(state: state, engine: engine, commands: commands)
        } else if let error = state.errorMessage {
            ContentUnavailableView("Démarrage impossible", systemImage: "exclamationmark.triangle", description: Text(error))
        } else {
            ProgressView("Initialisation du moteur…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// macOS: `NavigationSplitView` (sidebar, then the screen with its own category column and the
/// docked player). iOS: `TabView` with a persistent mini-player above the tab bar. One navigation
/// container per platform, so there is a single title bar and a single toolbar.
private struct LoadedShellView: View {
    @Bindable var state: AppState
    let engine: CndEngine
    let commands: AppCommandCenter

    @AppStorage("shell.selectedTab") private var selectedTabRaw = AppTab.live.rawValue
    @State private var sourcesModel: SourcesModel
    @State private var toasts: ToastCenter
    @State private var vodContext: VodContext
    @State private var downloadsModel: DownloadsModel
    @State private var settingsModel: SettingsModel
    @State private var consoleModel: ConsoleModel
    @State private var pip = PiPManager()
    @State private var nowPlaying: NowPlayingCoordinator
    @State private var zapper = LiveZapper()
    @State private var epgFocus: IptvItemRecord?
    @State private var isPlayerExpanded = false
    @State private var isDropTargeted = false

    init(state: AppState, engine: CndEngine, commands: AppCommandCenter) {
        self.state = state
        self.engine = engine
        self.commands = commands
        _nowPlaying = State(initialValue: NowPlayingCoordinator(controller: state.player))
        _sourcesModel = State(initialValue: SourcesModel(engine: engine, onChange: { [weak state] in
            state?.reloadSnapshot()
        }))
        let toasts = ToastCenter()
        _toasts = State(initialValue: toasts)
        _vodContext = State(initialValue: VodContext(
            engine: engine,
            toasts: toasts,
            downloadBase: { [weak state] in state?.downloadDirectory.directory ?? DownloadLocation.baseDirectory },
            playMedia: { [weak state] media in state?.player.open(media) },
            playQueue: { [weak state] medias, index in state?.player.openQueue(medias, startIndex: index) },
            openDownloads: { UserDefaults.standard.set(AppTab.downloads.rawValue, forKey: "shell.selectedTab") },
            onFavoriteChanged: { [weak state] in state?.reloadSnapshot(notifyScreens: false) }
        ))
        _downloadsModel = State(initialValue: DownloadsModel(backend: engine))
        let settings = SettingsModel(engine: engine, directory: state.downloadDirectory)
        settings.onConsoleVisibilityChanged = { [weak state] visible in state?.showNetworkConsole = visible }
        _settingsModel = State(initialValue: settings)
        _consoleModel = State(initialValue: ConsoleModel(engine: engine))
    }

    private var selectedTab: AppTab { AppTab(rawValue: selectedTabRaw) ?? .live }
    private var player: CndPlayerController { state.player }
    private var hasMedia: Bool { player.media != nil }

    var body: some View {
        VStack(spacing: 0) {
            mainShell
            if state.showNetworkConsole {
                NetworkConsoleDrawer(model: consoleModel)
            }
        }
    }

    private var mainShell: some View {
        platformShell
            .environment(vodContext)
            .overlay(alignment: .bottom) {
                if let toast = toasts.current {
                    ToastView(toast: toast) { toasts.dismiss() }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.2), value: toasts.current?.id)
            .dropDestination(for: URL.self) { urls, _ in handleDrop(urls) } isTargeted: { isDropTargeted = $0 }
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10]))
                        .background(Color.accentColor.opacity(0.08))
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
            .alert(
                "Erreur",
                isPresented: Binding(get: { state.errorMessage != nil }, set: { if !$0 { state.errorMessage = nil } })
            ) {
                Button("OK") { state.errorMessage = nil }
            } message: {
                Text(state.errorMessage ?? "")
            }
            .onChange(of: hasMedia) { _, present in
                if !present { isPlayerExpanded = false }
                commands.hasMedia = present
                nowPlaying.refresh()
            }
            .onChange(of: player.state) { _, _ in
                nowPlaying.refresh()
                pip.syncState(from: player)
            }
            .onChange(of: player.media) { _, _ in nowPlaying.refresh() }
            .onChange(of: player.surfaceLayer.map(ObjectIdentifier.init)) { _, _ in
                pip.attach(layer: player.surfaceLayer, controller: player)
            }
            .onAppear { connectPlayerIntegrations() }
    }

    /// Hooks the system integrations (Now Playing, media keys, menu bar) to this shell.
    private func connectPlayerIntegrations() {
        nowPlaying.onZap = { zap($0) }
        nowPlaying.subtitleProvider = { media in
            media.kind == .live
                ? (zapper.nowTitle(forStreamUrl: media.url.absoluteString) ?? NowPlayingInfoBuilder.defaultSubtitle(for: media))
                : NowPlayingInfoBuilder.defaultSubtitle(for: media)
        }
        nowPlaying.activate()

        commands.addSource = { selectedTabRaw = AppTab.sources.rawValue; sourcesModel.request(.addSource) }
        commands.importPlaylist = { selectedTabRaw = AppTab.sources.rawValue; sourcesModel.request(.importPlaylist) }
        commands.refreshAllSources = { Task { await sourcesModel.syncAll(state.sources) } }
        commands.toggleNetworkConsole = { settingsModel.showNetworkConsole.toggle() }
        commands.zap = { zap($0) }
        commands.togglePlayPause = { player.togglePlayPause() }
        commands.toggleMute = { player.isMuted.toggle() }
        commands.togglePictureInPicture = { pip.toggle() }
        commands.hasMedia = hasMedia

        state.cloudSync?.onRemoteChange = { ids in
            state.reloadSnapshot()
            refreshImportedSources(ids)
        }
    }

    /// Sources that arrived from iCloud have no catalog yet: fetch M3U ones now; Xtream ones need
    /// their password, which lives in the Keychain of the device where it was typed.
    private func refreshImportedSources(_ ids: [Int64]) {
        guard !ids.isEmpty else { return }
        Task {
            let sources = (try? engine.listSources()) ?? []
            for source in sources where ids.contains(source.id) {
                if source.sourceType == "xtream" {
                    toasts.show("« \(source.name) » vient d'iCloud : saisissez son mot de passe pour la charger.")
                } else {
                    await sourcesModel.sync(source)
                }
            }
        }
    }

    /// Next / previous episode when a queue is playing, otherwise next / previous channel.
    private func zap(_ offset: Int) {
        if player.queue != nil {
            offset > 0 ? player.next() : player.previous()
            Haptics.light()
            return
        }
        guard player.media == nil || player.media?.kind == .live,
              let item = zapper.neighbor(of: player.media?.url.absoluteString, offset: offset) else { return }
        play(item)
        Haptics.light()
    }

    // MARK: Platform shells

    @ViewBuilder
    private var platformShell: some View {
        #if os(macOS)
        NavigationSplitView {
            List(AppTab.allCases, selection: Binding<AppTab?>(
                get: { selectedTab },
                set: { if let tab = $0 { selectedTabRaw = tab.rawValue } }
            )) { tab in
                Label(tab.title, systemImage: tab.systemImage)
                    .badge(badge(for: tab))
                    .tag(tab)
            }
            .navigationTitle("CND IPTV")
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } detail: {
            HStack(spacing: 0) {
                content(for: selectedTab)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if hasMedia && !isPlayerExpanded {
                    Divider()
                    dockedPlayer.frame(width: 360)
                }
            }
            .overlay {
                if isPlayerExpanded { expandedPlayer }
            }
        }
        #else
        TabView(selection: Binding(get: { selectedTab }, set: { selectedTabRaw = $0.rawValue })) {
            ForEach(AppTab.allCases) { tab in
                NavigationStack {
                    content(for: tab)
                        .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayerBar }
                }
                .tabItem { Label(tab.title, systemImage: tab.systemImage) }
                .badge(badge(for: tab))
                .tag(tab)
            }
        }
        .fullScreenCover(isPresented: $isPlayerExpanded) {
            expandedPlayer.ignoresSafeArea()
        }
        #endif
    }

    private func badge(for tab: AppTab) -> Int {
        guard let stats = state.stats else { return 0 }
        switch tab {
        case .live: return Int(stats.totalLiveChannels)
        case .movies: return Int(stats.totalMovies)
        case .series: return Int(stats.totalSeries)
        case .downloads: return Int(stats.totalDownloads)
        case .sources: return Int(stats.totalSources)
        case .guide, .settings: return 0
        }
    }

    // MARK: Screens

    @ViewBuilder
    private func content(for tab: AppTab) -> some View {
        Group {
            switch tab {
            case .live:
                LiveTvView(
                    engine: engine,
                    revision: state.catalogRevision,
                    totalChannels: Int(state.stats?.totalLiveChannels ?? 0),
                    playingURL: player.media?.url.absoluteString,
                    onPlay: play,
                    onShowGuide: showGuide,
                    onFavoriteChanged: { state.reloadSnapshot(notifyScreens: false) },
                    zapper: zapper
                )
            case .guide:
                EpgGuideView(
                    engine: engine,
                    focus: $epgFocus,
                    revision: state.catalogRevision,
                    playingURL: player.media?.url.absoluteString,
                    onPlay: play
                )
            case .sources:
                SourcesListView(engine: engine, sources: state.sources, model: sourcesModel)
            case .movies:
                vodScreen(MoviesCatalogView(
                    engine: engine, revision: state.catalogRevision, totalMovies: Int(state.stats?.totalMovies ?? 0)
                ))
            case .series:
                vodScreen(SeriesCatalogView(
                    engine: engine, revision: state.catalogRevision, totalSeries: Int(state.stats?.totalSeries ?? 0)
                ))
            case .downloads:
                DownloadsDashboardView(model: downloadsModel, directory: state.downloadDirectory, onPlay: playDownload)
            case .settings:
                SettingsView(model: settingsModel, directory: state.downloadDirectory, stats: state.stats, sync: state.cloudSync)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let banner = sourcesModel.banner {
                SourcesBannerView(banner: banner) { sourcesModel.dismissBanner() }
            }
        }
    }

    /// Movies and series push their details; macOS needs its own stack inside the split view's detail.
    @ViewBuilder
    private func vodScreen<Screen: View>(_ screen: Screen) -> some View {
        #if os(macOS)
        NavigationStack {
            screen.navigationDestination(for: VodRoute.self) { vodDestination($0) }
        }
        #else
        screen.navigationDestination(for: VodRoute.self) { vodDestination($0) }
        #endif
    }

    @ViewBuilder
    private func vodDestination(_ route: VodRoute) -> some View {
        switch route {
        case .movie(let item): MovieDetailsView(item: item, vod: vodContext)
        case .series(let series): SeriesDetailsView(series: series, vod: vodContext)
        }
    }

    // MARK: Player

    private func play(_ item: IptvItemRecord) {
        guard let media = PlayableMedia(item: item) else {
            state.errorMessage = "L'URL du flux de « \(item.name) » est invalide."
            return
        }
        player.open(media)
    }

    /// Opens a finished download straight from disk in the built-in player.
    private func playDownload(_ task: DownloadTaskRecord) {
        guard FileManager.default.fileExists(atPath: task.savePath) else {
            toasts.show("Le fichier « \(task.fileName) » est introuvable sur le disque.", isError: true)
            return
        }
        player.open(PlayableMedia(title: task.fileName, url: URL(fileURLWithPath: task.savePath), kind: .movie))
    }

    private func showGuide(_ item: IptvItemRecord) {
        epgFocus = item
        selectedTabRaw = AppTab.guide.rawValue
    }

    private func closePlayer() {
        player.close()
        state.cloudSync?.scheduleSync()
        isPlayerExpanded = false
    }

    /// Side panel (macOS): the channel list stays browsable while the live stream keeps playing.
    private var dockedPlayer: some View {
        VStack(spacing: 0) {
            CndVideoPlayerView(
                controller: player,
                onToggleFullscreen: { isPlayerExpanded = true },
                onClose: closePlayer,
                closesOnDisappear: false,
                pip: pip
            )
            .aspectRatio(16 / 9, contentMode: .fit)
            VStack(alignment: .leading, spacing: 6) {
                Text(player.media?.title ?? "").font(.headline).lineLimit(2)
                Text(player.isLive ? "Direct" : "Lecture").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            Spacer(minLength: 0)
        }
        .background(.background)
    }

    private var expandedPlayer: some View {
        CndVideoPlayerView(
            controller: player,
            onToggleFullscreen: { isPlayerExpanded = false },
            onClose: closePlayer,
            closesOnDisappear: false,
            pip: pip
        )
        .background(Color.black)
    }

    /// Persistent mini-player (iOS): tap to expand, controls stay one thumb away.
    @ViewBuilder
    private var miniPlayerBar: some View {
        if hasMedia {
            HStack(spacing: 12) {
                PlayerSurface(layer: isPlayerExpanded ? nil : player.surfaceLayer)
                    .frame(width: 112, height: 63)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.media?.title ?? "").font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(player.reconnectBanner ?? (player.isLive ? "Direct" : "Lecture"))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.state == .playing || player.state == .buffering ? "pause.fill" : "play.fill")
                }
                .accessibilityLabel("Lecture / Pause")
                Button(action: closePlayer) { Image(systemName: "xmark") }
                    .accessibilityLabel("Fermer le lecteur")
            }
            .buttonStyle(.plain)
            .font(.title3)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
            .contentShape(Rectangle())
            .onTapGesture { isPlayerExpanded = true }
        }
    }

    // MARK: Drag & drop

    private func handleDrop(_ urls: [URL]) -> Bool {
        let playlists = urls.filter(SourcesModel.isM3uFile)
        guard !playlists.isEmpty else { return false }
        Task { for url in playlists { await sourcesModel.importM3u(from: url) } }
        return true
    }
}
