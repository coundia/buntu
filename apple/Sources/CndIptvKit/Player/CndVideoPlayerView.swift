import SwiftUI
import QuartzCore
import CndCoreBridge
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Video surface

#if os(macOS)
final class PlayerSurfaceHostView: NSView {
    var hostedLayer: CALayer? {
        didSet {
            guard hostedLayer !== oldValue else { return }
            oldValue?.removeFromSuperlayer()
            if let hostedLayer {
                layer?.addSublayer(hostedLayer)
                needsLayout = true
            }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hostedLayer?.frame = bounds
        CATransaction.commit()
    }
}

struct PlayerSurface: NSViewRepresentable {
    let layer: CALayer?
    func makeNSView(context: Context) -> PlayerSurfaceHostView { PlayerSurfaceHostView() }
    func updateNSView(_ view: PlayerSurfaceHostView, context: Context) { view.hostedLayer = layer }
}
#else
final class PlayerSurfaceHostView: UIView {
    var hostedLayer: CALayer? {
        didSet {
            guard hostedLayer !== oldValue else { return }
            oldValue?.removeFromSuperlayer()
            if let hostedLayer {
                layer.addSublayer(hostedLayer)
                setNeedsLayout()
            }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hostedLayer?.frame = bounds
        CATransaction.commit()
    }
}

struct PlayerSurface: UIViewRepresentable {
    let layer: CALayer?
    func makeUIView(context: Context) -> PlayerSurfaceHostView { PlayerSurfaceHostView() }
    func updateUIView(_ view: PlayerSurfaceHostView, context: Context) { view.hostedLayer = layer }
}
#endif

// MARK: - Player view + HUD

public struct CndVideoPlayerView: View {
    @Environment(\.uiMetrics) private var ui
    @Bindable var controller: CndPlayerController
    var upNext: UpNextModel?
    var onToggleFullscreen: (() -> Void)?
    var onClose: (() -> Void)?
    /// Shrinks a large player back to its docked size; shown only when provided.
    var onCollapse: (() -> Void)?
    /// `false` when a host view owns the controller's lifetime (mini-player <-> expanded swap).
    var closesOnDisappear: Bool
    /// Shows the Picture-in-Picture button when provided and supported.
    var pip: PiPManager?
    /// Whether the host currently shows the player full screen (switches the button's icon).
    var isFullscreen: Bool
    /// Previous (-1) / next (+1) channel; on Apple TV the Siri Remote's up and down arrows call it on live streams.
    var onZap: ((Int) -> Void)?
    /// Builds the online subtitle search for the current media; the menu entry shows only when provided.
    var subtitleSearch: (() -> SubtitleSearchModel)?
    /// Goes back to the channel's live stream from a replay; the button shows only when provided.
    var onReturnToLive: (() -> Void)?
    /// Downloads the film or episode being played; the button shows only when provided and the media can be downloaded.
    var onDownload: (() -> Void)?
    /// "Lire sur…" (PRD-42): household devices that can play right now, and the action that sends the
    /// current media to one of them. The menu shows only when both are provided and the media can be sent.
    var remoteTargets: (() -> [DiscoveredPeer])?
    var onPlayOnDevice: ((DiscoveredPeer) -> Void)?
    /// macOS "Mode Cinéma": toggles full screen on a black stage with the cursor hidden along with the controls.
    var onToggleCinema: (() -> Void)?
    var isCinema: Bool
    /// PRD-46: Live TV player enhancements (zapping anti-429, recall, 0-9 entry, Start-Over, Mini-Guide).
    var livePendingChannelTitle: String? = nil
    var canRecallChannel: Bool = false
    var onRecallChannel: (() -> Void)? = nil
    var onStartOverCurrent: (() -> Void)? = nil
    var onSelectChannelNumber: ((Int) -> Void)? = nil
    var liveChannelsForOverlay: [IptvItemRecord] = []
    var liveProgramTitle: ((IptvItemRecord) -> String?)? = nil
    var onSelectOverlayChannel: ((IptvItemRecord) -> Void)? = nil
    @State private var subtitleSearchModel: SubtitleSearchModel?

    @State private var hudVisible = true
    @State private var showShelf = false
    @State private var showChannelDrawer = false
    @State private var channelNumberBuffer = ""
    @State private var channelNumberTask: Task<Void, Never>?
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubValue: Double = 0
    @State private var isScrubbing = false

    private static let speeds: [Float] = [0.5, 1.0, 1.25, 1.5, 2.0]
    private static let sleepTimerOptions: [Int] = [15, 30, 60, 90]

    init(
        controller: CndPlayerController,
        upNext: UpNextModel? = nil,
        onToggleFullscreen: (() -> Void)? = nil,
        onClose: (() -> Void)? = nil,
        onCollapse: (() -> Void)? = nil,
        closesOnDisappear: Bool = true,
        pip: PiPManager? = nil,
        isFullscreen: Bool = false,
        onZap: ((Int) -> Void)? = nil,
        subtitleSearch: (() -> SubtitleSearchModel)? = nil,
        onReturnToLive: (() -> Void)? = nil,
        onDownload: (() -> Void)? = nil,
        remoteTargets: (() -> [DiscoveredPeer])? = nil,
        onPlayOnDevice: ((DiscoveredPeer) -> Void)? = nil,
        onToggleCinema: (() -> Void)? = nil,
        isCinema: Bool = false,
        livePendingChannelTitle: String? = nil,
        canRecallChannel: Bool = false,
        onRecallChannel: (() -> Void)? = nil,
        onStartOverCurrent: (() -> Void)? = nil,
        onSelectChannelNumber: ((Int) -> Void)? = nil,
        liveChannelsForOverlay: [IptvItemRecord] = [],
        liveProgramTitle: ((IptvItemRecord) -> String?)? = nil,
        onSelectOverlayChannel: ((IptvItemRecord) -> Void)? = nil
    ) {
        self.remoteTargets = remoteTargets
        self.onPlayOnDevice = onPlayOnDevice
        self.upNext = upNext
        self.onToggleCinema = onToggleCinema
        self.onDownload = onDownload
        self.isCinema = isCinema
        self.livePendingChannelTitle = livePendingChannelTitle
        self.canRecallChannel = canRecallChannel
        self.onRecallChannel = onRecallChannel
        self.onStartOverCurrent = onStartOverCurrent
        self.onSelectChannelNumber = onSelectChannelNumber
        self.liveChannelsForOverlay = liveChannelsForOverlay
        self.liveProgramTitle = liveProgramTitle
        self.onSelectOverlayChannel = onSelectOverlayChannel
        self.controller = controller
        self.isFullscreen = isFullscreen
        self.closesOnDisappear = closesOnDisappear
        self.pip = pip
        #if os(macOS)
        self.onToggleFullscreen = onToggleFullscreen ?? { NSApp.keyWindow?.toggleFullScreen(nil) }
        #else
        self.onToggleFullscreen = onToggleFullscreen
        #endif
        self.onClose = onClose
        self.onCollapse = onCollapse
        self.onZap = onZap
        self.subtitleSearch = subtitleSearch
        self.onReturnToLive = onReturnToLive
    }

    public var body: some View {
        ZStack {
            // Video and gestures run edge to edge; the controls below stay inside the safe area.
            Color.black.ignoresSafeArea()
            PlayerSurface(layer: controller.surfaceLayer).ignoresSafeArea()

            #if os(iOS)
            PlayerGestureLayer(
                controller: controller,
                onSingleTap: { hudVisible ? scheduleHide() : showHUD() },
                onSkip: { controller.skip(bySeconds: $0); showHUD() }
            )
            .ignoresSafeArea()
            #endif

            SubtitleOverlayView(model: controller.subtitleOverlay)

            if controller.showHlsAudioEnhancementNotice {
                VStack {
                    HStack(spacing: 12) {
                        Image(systemName: "waveform.badge.exclamationmark")
                            .foregroundStyle(.yellow)
                        Text("Le Dialogue Boost nécessite mpv pour les flux HLS.")
                            .font(.caption.bold())
                        Button("Basculer sur mpv") {
                            controller.switchToMpvForAudioEnhancement()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        Button("Ignorer") {
                            controller.dismissHlsAudioEnhancementNotice()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(10)
                    .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.top, 50)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if let notice = controller.slowSourceNotice {
                VStack {
                    SlowSourceBanner(notice: notice, controller: controller)
                        .padding(.top, 50)
                        .padding(.horizontal, 16)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if case .failed(let message) = controller.state {
                errorOverlay(message)
            } else if controller.state == .loading {
                ProgressView().controlSize(.large).tint(.white)
            }

            if let upNext, !controller.isLive {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        NextUpCard(model: upNext)
                            .padding(.trailing, 24)
                            .padding(.bottom, hudVisible ? (showShelf ? 230 : 100) : 24)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: hudVisible)
                .animation(.easeInOut(duration: 0.2), value: showShelf)
            }

            VStack(spacing: 0) {
                topBar
                Spacer()
                if hudVisible {
                    if showShelf, !controller.isLive, let upNext, upNext.isUpNextShelfEnabled, !upNext.recommendations.isEmpty {
                        shelfOverlay(upNext)
                    }
                    bottomBar
                }
            }
            .opacity(hudVisible ? 1 : 0)
            .animation(.easeInOut(duration: 0.2), value: hudVisible)

            if !channelNumberBuffer.isEmpty {
                VStack {
                    HStack {
                        Spacer()
                        Text("CH \(channelNumberBuffer)")
                            .font(.title2.monospacedDigit().bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 10))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(.white.opacity(0.25), lineWidth: 1)
                            )
                            .padding(20)
                    }
                    Spacer()
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }

            if showChannelDrawer, controller.isLive, !liveChannelsForOverlay.isEmpty {
                channelDrawerOverlay
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .contentShape(Rectangle())
        #if os(macOS)
        .onContinuousHover { _ in showHUD() }
        .background(CinemaCursorHider(hidden: isCinema && !hudVisible))
        #endif
        #if os(macOS)
        // Double-click toggles full screen (declared first so it wins over the single click, which
        // shows or hides the controls).
        .onTapGesture(count: 2) { // lint:ui-ignore the same actions are buttons in the player bar
            if compactWindow { WindowLevelController.shared.exitCompact() } else { onToggleFullscreen?() }
        }
        .onTapGesture { hudVisible ? scheduleHide() : showHUD() } // lint:ui-ignore the HUD stays up with a screen reader
        #endif
        .sheet(isPresented: Binding(get: { subtitleSearchModel != nil }, set: { if !$0 { subtitleSearchModel = nil } })) {
            if let subtitleSearchModel {
                SubtitleSearchSheet(model: subtitleSearchModel) { self.subtitleSearchModel = nil }
            }
        }
        .onAppear { showHUD() }
        .onDisappear {
            hideTask?.cancel()
            channelNumberTask?.cancel()
            if closesOnDisappear { controller.close() }
        }
        #if os(macOS)
        .focusable()
        .onKeyPress(.space) { controller.togglePlayPause(); showHUD(); return .handled }
        .onKeyPress("m") { controller.isMuted.toggle(); showHUD(); return .handled }
        .onKeyPress("f") { onToggleFullscreen?(); return .handled }
        .onKeyPress("s") { controller.toggleFavorite(); showHUD(); return .handled }
        .onKeyPress("r") {
            guard controller.isLive, canRecallChannel, let onRecallChannel else { return .ignored }
            onRecallChannel()
            showHUD()
            return .handled
        }
        .onKeyPress("g") {
            guard controller.isLive, !liveChannelsForOverlay.isEmpty else { return .ignored }
            withAnimation(.easeInOut(duration: 0.2)) { showChannelDrawer.toggle() }
            showHUD()
            return .handled
        }
        .onKeyPress("a") {
            controller.cycleAspectRatio()
            showHUD()
            return .handled
        }
        .onKeyPress(characters: .decimalDigits) { press in
            guard controller.isLive, onSelectChannelNumber != nil,
                  let ch = press.characters.first, ch.isNumber else { return .ignored }
            appendChannelDigit(String(ch))
            return .handled
        }
        .onKeyPress(.return) {
            guard !channelNumberBuffer.isEmpty else { return .ignored }
            commitChannelNumber()
            return .handled
        }
        .onKeyPress(.escape) {
            if showChannelDrawer {
                withAnimation(.easeInOut(duration: 0.2)) { showChannelDrawer = false }
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.leftArrow) {
            guard !controller.isLive || controller.timeshiftDuration.isEnabled else { return .ignored }
            controller.skip(bySeconds: -10); showHUD(); return .handled
        }
        .onKeyPress(.rightArrow) {
            guard !controller.isLive || (controller.timeshiftDuration.isEnabled && controller.currentLiveDelaySeconds > 0) else { return .ignored }
            controller.skip(bySeconds: 10); showHUD(); return .handled
        }
        .onKeyPress(.upArrow) { controller.volume = min(controller.volume + 0.1, 1); showHUD(); return .handled }
        .onKeyPress(.downArrow) { controller.volume = max(controller.volume - 0.1, 0); showHUD(); return .handled }
        #elseif os(tvOS)
        .onPlayPauseCommand { controller.togglePlayPause(); showHUD() }
        .onExitCommand {
            if showShelf {
                withAnimation { showShelf = false }
            } else if hudVisible {
                hudVisible = false
            } else if let onClose {
                onClose()
            }
        }
        .onMoveCommand { direction in
            switch direction {
            case .left:
                guard !controller.isLive || controller.timeshiftDuration.isEnabled else { return }
                controller.skip(bySeconds: -10)
                showHUD()
            case .right:
                guard !controller.isLive || (controller.timeshiftDuration.isEnabled && controller.currentLiveDelaySeconds > 0) else { return }
                controller.skip(bySeconds: 10)
                showHUD()
            case .up:
                if showShelf {
                    withAnimation { showShelf = false }
                    return
                }
                guard controller.isLive, let onZap else { return }
                onZap(-1)
                showHUD()
            case .down:
                if let upNext, upNext.isUpNextShelfEnabled, !upNext.recommendations.isEmpty {
                    withAnimation { showShelf = true }
                    showHUD()
                    return
                }
                guard controller.isLive, let onZap else { return }
                onZap(1)
                showHUD()
            default:
                break
            }
        }
        #endif
    }

    // MARK: HUD pieces

    /// The compact player (PRD 29): a 16:9 window with only the essentials.
    private var compactWindow: Bool {
        #if os(macOS)
        WindowLevelController.shared.isCompact
        #else
        false
        #endif
    }

    #if os(macOS)
    private var compactBar: some View {
        HStack(spacing: 8) {
            hudButton("arrow.down.right.and.arrow.up.left", "Quitter le lecteur compact") {
                WindowLevelController.shared.exitCompact()
            }
            Text(controller.media?.title ?? "")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Spacer()
            pinButton
        }
    }
    #else
    private var compactBar: some View { EmptyView() }
    #endif

    #if os(macOS)
    /// Keeps the window above the other apps' windows (PRD 29).
    private var pinButton: some View {
        let floating = WindowLevelController.shared.isFloating
        return hudButton(
            floating ? "pin.fill" : "pin",
            floating ? "Ne plus garder au premier plan" : "Garder au premier plan"
        ) { WindowLevelController.shared.toggle() }
        .help(floating ? "Ne plus garder au premier plan (⌥⌘T)" : "Garder au premier plan (⌥⌘T)")
    }
    #endif

    private var topBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if compactWindow { compactBar } else {
            HStack(spacing: 8) {
                if let onClose {
                    Button(action: onClose) { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Fermer")
                }
                if let onCollapse {
                    hudButton("rectangle.compress.vertical", "Réduire le lecteur") { onCollapse() }
                }
                Text(controller.media?.title ?? "")
                    .font(.headline)
                    .lineLimit(1)
                if controller.media?.kind == .replay {
                    Text("REPLAY")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.orange, in: Capsule())
                        .foregroundStyle(.black)
                    if let onReturnToLive {
                        Button("Retour au direct", systemImage: "dot.radiowaves.left.and.right", action: onReturnToLive)
                            .font(.caption.bold())
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
                if controller.media != nil {
                    favoriteButton
                    brokenButton
                    if let onToggleCinema {
                        hudButton("theatermasks", isCinema ? "Quitter le mode Cinéma" : "Mode Cinéma") { onToggleCinema() }
                    }
                    hudButton("stop.fill", "Arrêter la lecture et couper la connexion au serveur") {
                        controller.close()
                    }
                }
                Spacer()
                if let format = DisplayRateMatcher.shared.currentFormat {
                    Text(format.summary)
                        .font(.caption2.monospaced())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.white.opacity(0.15), in: Capsule())
                }
                if let engine = controller.activeEngine {
                    Text(engine == .mpv ? "mpv" : "AVPlayer")
                        .font(.caption2.monospaced())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.white.opacity(0.15), in: Capsule())
                }
                if let sleepSeconds = controller.sleepTimerRemainingSeconds {
                    Label(Self.formatSeconds(Int64(sleepSeconds)), systemImage: "moon.zzz.fill")
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.indigo.opacity(0.75), in: Capsule())
                        .accessibilityLabel("Minuteur de veille \(Self.formatSeconds(Int64(sleepSeconds)))")
                }
                #if os(macOS)
                pinButton
                #endif
                // Top-right, never clipped: the bottom row is too crowded for the narrow docked player.
                if let onToggleFullscreen {
                    hudButton(
                        isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                        isFullscreen ? "Quitter le plein écran" : "Plein écran"
                    ) { onToggleFullscreen() }
                    .font(.title3)
                }
            }
            }
            if let pending = livePendingChannelTitle {
                Label("Zap → \(pending)…", systemImage: "tv")
                    .font(.caption.bold())
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(.blue.opacity(0.85), in: Capsule())
            } else if let banner = controller.reconnectBanner {
                Label(banner, systemImage: "wifi.exclamationmark")
                    .font(.caption)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(.orange.opacity(0.85), in: Capsule())
            } else if let banner = controller.failoverBanner {
                Label(banner, systemImage: "arrow.triangle.swap")
                    .font(.caption)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(.blue.opacity(0.85), in: Capsule())
            }
        }
        .font(ui.font(.body))
        .foregroundStyle(.white)
        .padding(12)
        .background(LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom))
        .opacity(hudVisible || controller.reconnectBanner != nil || controller.failoverBanner != nil || livePendingChannelTitle != nil ? 1 : 0)
    }

    private var favoriteButton: some View {
        Button {
            controller.toggleFavorite()
            scheduleHide()
        } label: {
            Image(systemName: controller.isFavorite ? "star.fill" : "star")
                .foregroundStyle(controller.isFavorite ? Color.yellow : Color.white)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(controller.isFavorite ? "Retirer des favoris" : "Ajouter aux favoris")
        .help(controller.isFavorite ? "Retirer des favoris" : "Ajouter aux favoris")
    }

    private var brokenButton: some View {
        Button {
            controller.toggleBroken()
            scheduleHide()
        } label: {
            Image(systemName: controller.isBroken ? "exclamationmark.triangle.fill" : "exclamationmark.triangle")
                .foregroundStyle(controller.isBroken ? Color.red : Color.white)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(controller.isBroken ? "Rétablir le flux" : "Signaler en panne")
        .help(controller.isBroken ? "Signalé en panne — cliquer pour rétablir" : "Signaler en panne")
    }

    @ViewBuilder
    private func shelfOverlay(_ upNext: UpNextModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(controller.isLive ? "En direct · Pour vous" : "À suivre")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showShelf = false
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Fermer la rangée À suivre")
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)

            UpNextShelf(model: upNext, orientation: .horizontal) { [weak controller] media in
                showShelf = false
                controller?.open(media)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            progressRow
            // One row when it fits (wide / full screen), two rows in the narrow docked player.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) {
                    transportControls
                    Spacer(minLength: 12)
                    secondaryControls
                }
                VStack(spacing: 10) {
                    transportControls
                    secondaryControls
                }
            }
        }
        .foregroundStyle(.white)
        .padding(12)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom))
    }

    private var transportControls: some View {
        HStack(spacing: 18) {
            if controller.isLive, let onZap {
                hudButton("chevron.backward.to.line", "Chaîne précédente") { onZap(-1) }
                    .help("Chaîne précédente")
            }
            if controller.isLive, canRecallChannel, let onRecallChannel {
                hudButton("arrow.uturn.backward.circle", "Dernière chaîne") { onRecallChannel() }
                    .help("Dernière chaîne (R)")
            }
            if controller.queue != nil {
                hudButton("backward.end.fill", "Épisode précédent", enabled: controller.hasPrevious) { controller.previous() }
            }
            if !controller.isLive || controller.timeshiftDuration.isEnabled {
                hudButton("gobackward.10", "Reculer de 10 secondes") { controller.skip(bySeconds: -10) }
            }
            hudButton(
                controller.state == .playing || controller.state == .buffering ? "pause.fill" : "play.fill",
                "Lecture / Pause"
            ) { controller.togglePlayPause() }
            .font(.title)
            if !controller.isLive || (controller.timeshiftDuration.isEnabled && controller.currentLiveDelaySeconds > 0) {
                hudButton("goforward.10", "Avancer de 10 secondes") { controller.skip(bySeconds: 10) }
            }
            if controller.queue != nil {
                hudButton("forward.end.fill", "Épisode suivant", enabled: controller.hasNext) { controller.next() }
            }
            if controller.isLive, let onZap {
                hudButton("chevron.forward.to.line", "Chaîne suivante") { onZap(1) }
                    .help("Chaîne suivante")
            }
        }
        .fixedSize()
    }

    private var secondaryControls: some View {
        HStack(spacing: 14) {
            if controller.isLive, !liveChannelsForOverlay.isEmpty {
                hudButton("list.bullet.rectangle", "Mini-Guide chaînes") {
                    withAnimation(.easeInOut(duration: 0.2)) { showChannelDrawer.toggle() }
                }
                .help("Mini-Guide des chaînes (G)")
            }
            if let upNext, upNext.isUpNextShelfEnabled, !upNext.recommendations.isEmpty {
                hudButton("rectangle.stack", "À suivre") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showShelf.toggle()
                    }
                }
            }
            if let onDownload, controller.media?.isDownloadable == true {
                hudButton("arrow.down.circle", "Télécharger", action: onDownload)
                    .help("Télécharger ce film ou cet épisode")
            }
            playOnDeviceMenu
            mirrorsMenu
            liveComfortMenu
            volumeControls
            if !controller.isLive {
                speedMenu
            }
            audioMenu
            subtitlesMenu
            AirPlayRoutePicker()
                .frame(width: 24, height: 24)
                .accessibilityLabel("AirPlay")
            if let pip, pip.isSupported {
                hudButton(pip.isActive ? "pip.exit" : "pip.enter", "Image dans l'image", enabled: pip.isPossible) { pip.toggle() }
            }
        }
        .fixedSize()
    }

    @ViewBuilder
    private var mirrorsMenu: some View {
        if controller.isLive, !controller.availableMirrors.isEmpty {
            Menu {
                Section("Qualité / Miroirs") {
                    ForEach(controller.availableMirrors, id: \.id) { mirror in
                        Button {
                            controller.failoverToMirror(mirror)
                        } label: {
                            let quality = ChannelQuality.detect(in: mirror.name)?.rawValue ?? "Flux"
                            let isCurrent = mirror.streamUrl == controller.media?.url.absoluteString
                            Text(isCurrent ? "✓ \(mirror.name) [\(quality)]" : "\(mirror.name) [\(quality)]")
                        }
                    }
                }
            } label: {
                Image(systemName: "rectangle.2.swap")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Qualité et miroirs")
        }
    }

    private var liveComfortMenu: some View {
        Menu {
            Section("Format vidéo") {
                ForEach(VideoAspectRatioMode.allCases, id: \.self) { mode in
                    Button {
                        controller.aspectRatioMode = mode
                    } label: {
                        Label(
                            controller.aspectRatioMode == mode ? "✓ \(mode.displayName)" : mode.displayName,
                            systemImage: mode.systemImage
                        )
                    }
                }
            }
            Section("Minuteur de veille") {
                Button {
                    controller.setSleepTimer(minutes: nil)
                } label: {
                    Text(controller.sleepTimerMinutes == nil ? "✓ Désactivé" : "Désactivé")
                }
                ForEach(Self.sleepTimerOptions, id: \.self) { minutes in
                    Button {
                        controller.setSleepTimer(minutes: minutes)
                    } label: {
                        Text(controller.sleepTimerMinutes == minutes ? "✓ \(minutes) min" : "\(minutes) min")
                    }
                }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Format vidéo et minuteur de veille")
    }

    /// "Lire sur…": the other device opens the content in its own Buntu and this one stops (no Cast).
    @ViewBuilder
    private var playOnDeviceMenu: some View {
        if let remoteTargets, let onPlayOnDevice,
           let media = controller.media, media.stableHash != nil,
           media.kind == .live || media.kind == .movie || media.kind == .episode {
            Menu {
                let targets = remoteTargets()
                if targets.isEmpty {
                    Text("Aucun autre appareil Buntu détecté")
                } else {
                    Section("Lire sur…") {
                        ForEach(targets) { peer in
                            Button {
                                onPlayOnDevice(peer)
                            } label: {
                                Label(
                                    peer.state == "playing" ? "\(peer.name) (en lecture)" : peer.name,
                                    systemImage: Self.deviceSymbol(peer.deviceType)
                                )
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "rectangle.on.rectangle.angled")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Lire sur un autre appareil")
        }
    }

    private static func deviceSymbol(_ type: String) -> String {
        switch type.lowercased() {
        case "tv": return "tv"
        case "desktop", "mac": return "laptopcomputer"
        default: return "iphone"
        }
    }

    private var audioMenu: some View {
        Menu {
            if !controller.audioTracks.isEmpty {
                Section("Pistes audio") {
                    ForEach(controller.audioTracks) { track in
                        Button(track.isSelected ? "✓ \(track.displayTitle)" : track.displayTitle) {
                            controller.selectAudioTrack(id: track.id)
                        }
                    }
                }
            }

            Section("Amélioration des voix") {
                Menu("Dialogue Boost") {
                    ForEach(DialogueBoostLevel.allCases) { level in
                        Button(controller.audioEnhancement.dialogueBoost == level ? "✓ \(level.displayName)" : level.displayName) {
                            controller.audioEnhancement.dialogueBoost = level
                        }
                    }
                }

                Button(controller.audioEnhancement.nightMode ? "✓ Mode nuit (activé)" : "Mode nuit (désactivé)") {
                    controller.audioEnhancement.nightMode.toggle()
                }
            }
        } label: {
            Image(systemName: controller.audioEnhancement.isActive ? "waveform.badge.magnifyingglass" : "speaker.wave.2")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Audio et Dialogue Boost")
    }

    private var subtitlesMenu: some View {
        Menu {
            Button("Désactivés") {
                controller.selectSubtitleTrack(id: nil)
                controller.subtitleOverlay.clear()
            }

            if !controller.subtitleTracks.isEmpty {
                Section("Pistes intégrées") {
                    ForEach(controller.subtitleTracks) { track in
                        Button(track.isSelected ? "✓ \(track.displayTitle)" : track.displayTitle) {
                            controller.selectSubtitleTrack(id: track.id)
                        }
                    }
                }
            }

            if let subtitleSearch, controller.media?.kind != .live {
                Button("Rechercher en ligne…", systemImage: "magnifyingglass") {
                    subtitleSearchModel = subtitleSearch()
                }
            }

            Section("Synchronisation") {
                let delay = controller.subtitleDelaySeconds
                Text(String(format: "Décalage : %+.2f s", delay))
                Button("+0,25 s (plus tard)") {
                    controller.setSubtitleDelay(delay + 0.25)
                }
                Button("-0,25 s (plus tôt)") {
                    controller.setSubtitleDelay(delay - 0.25)
                }
                if delay != 0 {
                    Button("Réinitialiser (0 s)") {
                        controller.setSubtitleDelay(0)
                    }
                }
            }
        } label: {
            Image(systemName: controller.subtitleOverlay.isLoaded ? "captions.bubble.fill" : "captions.bubble")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Sous-titres")
    }

    @ViewBuilder
    private var progressRow: some View {
        if controller.isLive {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if controller.currentLiveDelaySeconds > 0 {
                        Button {
                            controller.catchUpToLive()
                        } label: {
                            HStack(spacing: 4) {
                                Text("Direct")
                                Image(systemName: "forward.end.fill")
                            }
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.red, in: RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)

                        Text("−" + Self.formatSeconds(Int64(controller.currentLiveDelaySeconds)))
                            .font(.caption.monospacedDigit().bold())
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.orange.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                    } else {
                        Text("LIVE")
                            .font(.caption.bold())
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(.red, in: RoundedRectangle(cornerRadius: 4))
                    }

                    if let nowProg = controller.liveNowProgram {
                        Text(nowProg.title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        let remaining = max(0, nowProg.endTs - Int64(Date().timeIntervalSince1970))
                        if remaining > 0 {
                            Text("(\(remaining / 60 + (remaining % 60 > 0 ? 1 : 0)) min rest.)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.white.opacity(0.75))
                        }
                    }

                    Spacer()

                    if controller.canStartOverLive, let onStartOverCurrent {
                        Button {
                            onStartOverCurrent()
                            scheduleHide()
                        } label: {
                            Label("Revoir depuis le début", systemImage: "arrow.counterclockwise")
                                .font(.caption.bold())
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                if let nowProg = controller.liveNowProgram {
                    HStack(spacing: 10) {
                        ProgressView(value: EpgProgress.ratio(start: nowProg.startTs, end: nowProg.endTs))
                            .progressViewStyle(.linear)
                            .tint(.red)
                        if let nextProg = controller.liveNextProgram {
                            Text("À suivre : \(nextProg.title)")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.75))
                                .lineLimit(1)
                        }
                    }
                }
            }
        } else {
            HStack(spacing: 10) {
                Text(Self.format(isScrubbing ? Int64(scrubValue) : controller.positionMs)).monospacedDigit()
                #if os(tvOS)
                ProgressView(value: Double(controller.positionMs), total: Double(max(controller.durationMs, 1)))
                    .progressViewStyle(.linear)
                #else
                Slider(
                    value: Binding(
                        get: { isScrubbing ? scrubValue : Double(controller.positionMs) },
                        set: { scrubValue = $0 }
                    ),
                    in: 0...Double(max(controller.durationMs, 1)),
                    step: Self.progressStep(durationMs: controller.durationMs),
                    onEditingChanged: { editing in
                        if editing {
                            isScrubbing = true
                            scrubValue = Double(controller.positionMs)
                            hideTask?.cancel()
                        } else {
                            controller.seek(toMs: Int64(scrubValue))
                            isScrubbing = false
                            scheduleHide()
                        }
                    }
                )
                .disabled(controller.durationMs == 0)
                .accessibilityLabel("Position de lecture")
                .accessibilityValue(A11yText.position(milliseconds: controller.positionMs, durationMs: controller.durationMs))
                #endif
                Text(Self.format(controller.durationMs)).monospacedDigit()
            }
            .font(.caption)
        }
    }

    @ViewBuilder
    private var volumeControls: some View {
        hudButton(controller.isMuted ? "speaker.slash.fill" : "speaker.fill", controller.isMuted ? "Rétablir le son" : "Couper le son") { controller.isMuted.toggle() }
        #if os(macOS)
        Slider(value: Binding(get: { Double(controller.volume) }, set: { controller.volume = Float($0) }), in: 0...1, step: 0.1)
            .frame(width: 80)
            .accessibilityLabel("Volume")
            .accessibilityValue(A11yText.percent(Double(controller.volume)))
        #endif
    }

    private var speedMenu: some View {
        Menu {
            ForEach(Self.speeds, id: \.self) { speed in
                Button {
                    controller.rate = speed
                } label: {
                    Text(speed == controller.rate ? "✓ \(Self.speedLabel(speed))" : Self.speedLabel(speed))
                }
            }
        } label: {
            Text(Self.speedLabel(controller.rate)).font(.caption.monospacedDigit())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Vitesse de lecture")
        .accessibilityValue(A11yText.speed(controller.rate))
    }

    private func hudButton(_ symbol: String, _ label: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button {
            action()
            scheduleHide()
        } label: {
            Image(systemName: symbol)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(label)
    }

    private func errorOverlay(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle)
            Text("Lecture impossible").font(.headline)
            Text(message).font(.caption).multilineTextAlignment(.center)
            if let media = controller.media {
                HStack(spacing: 12) {
                    Button("Réessayer") { controller.open(media) }
                        .buttonStyle(.borderedProminent)
                    Button {
                        controller.toggleBroken()
                    } label: {
                        Label(controller.isBroken ? "Marqué en panne" : "Signaler en panne",
                              systemImage: controller.isBroken ? "checkmark.circle" : "exclamationmark.triangle")
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.top, 4)

                // The way out when this device cannot play the stream itself (MKV on iPhone, for one).
                Menu {
                    ForEach(ExternalPlayer.availableOnThisPlatform) { player in
                        Button(player.displayName) { Task { _ = await ExternalPlayerLauncher.launch(player, media: media) } }
                    }
                    Button("Copier l'URL du flux", systemImage: "link") { ExternalPlayerLauncher.copyStreamUrl(media) }
                } label: {
                    Label("Ouvrir dans une autre app", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.bordered)

                if !controller.availableMirrors.isEmpty {
                    VStack(spacing: 6) {
                        Text("Alternatives disponibles :")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(controller.availableMirrors.prefix(3), id: \.id) { mirror in
                            Button {
                                controller.failoverToMirror(mirror)
                            } label: {
                                Label(mirror.name, systemImage: "play.circle.fill")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
        .foregroundStyle(.white)
        .padding()
    }

    private var channelDrawerOverlay: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Chaînes en direct")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Spacer()
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { showChannelDrawer = false }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Fermer le Mini-Guide")
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)

                Divider().overlay(Color.white.opacity(0.15))

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(liveChannelsForOverlay, id: \.id) { channel in
                            let isCurrent = channel.streamUrl == controller.media?.url.absoluteString
                            Button {
                                showChannelDrawer = false
                                onSelectOverlayChannel?(channel)
                                scheduleHide()
                            } label: {
                                HStack(spacing: 10) {
                                    if let num = channel.chno {
                                        Text("\(num)")
                                            .font(.caption.monospacedDigit().bold())
                                            .foregroundStyle(.white.opacity(0.7))
                                            .frame(width: 30, alignment: .trailing)
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(channel.name)
                                            .font(.subheadline.weight(isCurrent ? .bold : .regular))
                                            .foregroundStyle(.white)
                                            .lineLimit(1)
                                        if let prog = liveProgramTitle?(channel), !prog.isEmpty {
                                            Text(prog)
                                                .font(.caption2)
                                                .foregroundStyle(.white.opacity(0.7))
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                    if isCurrent {
                                        Circle()
                                            .fill(Color.red)
                                            .frame(width: 8, height: 8)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    isCurrent ? Color.white.opacity(0.16) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
            }
            .frame(width: 320)
            .background(Color.black.opacity(0.86))

            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) { showChannelDrawer = false }
                }
        }
    }

    private func appendChannelDigit(_ digit: String) {
        channelNumberTask?.cancel()
        if channelNumberBuffer.count < 4 {
            channelNumberBuffer += digit
        }
        showHUD()
        channelNumberTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            commitChannelNumber()
        }
    }

    private func commitChannelNumber() {
        channelNumberTask?.cancel()
        channelNumberTask = nil
        let text = channelNumberBuffer
        channelNumberBuffer = ""
        if let number = Int(text), number > 0 {
            onSelectChannelNumber?(number)
        }
    }

    // MARK: Auto-hide (3 s)

    private func showHUD() {
        hudVisible = true
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        // With a screen reader the controls stay: they must not vanish under the user's focus (PRD 31).
        guard !isScrubbing, !showChannelDrawer, !ScreenReader.isRunning else { return }
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled, controller.state == .playing { hudVisible = false }
        }
    }

    /// Steps of 10 s for VoiceOver, but never larger than the range: SwiftUI traps on a stride longer
    /// than the slider (a duration of 0 or a very short clip).
    static func progressStep(durationMs: Int64) -> Double {
        durationMs >= 20_000 ? 10_000 : 1
    }

    static func speedLabel(_ speed: Float) -> String {
        speed == speed.rounded() ? "\(Int(speed))x" : String(format: "%gx", speed)
    }

    static func format(_ ms: Int64) -> String {
        let total = max(0, Int(ms / 1000))
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func formatSeconds(_ seconds: Int64) -> String {
        let (h, m, s) = (seconds / 3600, (seconds % 3600) / 60, seconds % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}


#if os(macOS)
/// Hides the pointer while the cinema stage has no controls on screen; always restores it.
private struct CinemaCursorHider: NSViewRepresentable {
    let hidden: Bool

    final class Coordinator { var isHidden = false }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let c = context.coordinator
        guard c.isHidden != hidden else { return }
        c.isHidden = hidden
        if hidden { NSCursor.hide() } else { NSCursor.unhide() }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if coordinator.isHidden { NSCursor.unhide(); coordinator.isHidden = false }
    }
}
#endif


/// « Ce film demande 5,9 Mbit/s, la connexion au serveur en donne 2,8 » with what can be done about it.
struct SlowSourceBanner: View {
    let notice: SlowSourceNotice
    let controller: CndPlayerController

    static func message(_ notice: SlowSourceNotice) -> String {
        let needed = notice.neededMbps.formatted(.number.precision(.fractionLength(1)))
        let available = notice.availableMbps.formatted(.number.precision(.fractionLength(1)))
        return "Ce fichier demande \(needed) Mbit/s, la connexion au serveur n'en donne que \(available) : la lecture va s'arrêter souvent."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(Self.message(notice), systemImage: "speedometer")
                .font(.callout)
                .foregroundStyle(.white)
            HStack(spacing: 8) {
                if !controller.otherVersions.isEmpty {
                    Menu("Autre version") {
                        ForEach(controller.otherVersions, id: \.id) { version in
                            Button(version.name) { controller.playVersion(version) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                if controller.downloadHandler != nil, controller.media?.itemId != nil {
                    Button("Télécharger puis regarder") { controller.downloadInstead() }
                        .buttonStyle(.borderedProminent)
                }
                Button("Continuer") { controller.dismissSlowSourceNotice() }
                    .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }
}
