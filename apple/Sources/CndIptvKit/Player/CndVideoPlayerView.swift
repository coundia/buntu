import SwiftUI
import QuartzCore
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
    @Bindable var controller: CndPlayerController
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
    @State private var subtitleSearchModel: SubtitleSearchModel?

    @State private var hudVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubValue: Double = 0
    @State private var isScrubbing = false

    private static let speeds: [Float] = [0.5, 1.0, 1.25, 1.5, 2.0]

    init(
        controller: CndPlayerController,
        onToggleFullscreen: (() -> Void)? = nil,
        onClose: (() -> Void)? = nil,
        onCollapse: (() -> Void)? = nil,
        closesOnDisappear: Bool = true,
        pip: PiPManager? = nil,
        isFullscreen: Bool = false,
        onZap: ((Int) -> Void)? = nil,
        subtitleSearch: (() -> SubtitleSearchModel)? = nil,
        onReturnToLive: (() -> Void)? = nil
    ) {
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

            if case .failed(let message) = controller.state {
                errorOverlay(message)
            } else if controller.state == .loading {
                ProgressView().controlSize(.large).tint(.white)
            }

            VStack(spacing: 0) {
                topBar
                Spacer()
                if hudVisible { bottomBar }
            }
            .opacity(hudVisible ? 1 : 0)
            .animation(.easeInOut(duration: 0.2), value: hudVisible)
        }
        .contentShape(Rectangle())
        #if os(macOS)
        .onContinuousHover { _ in showHUD() }
        #endif
        #if os(macOS)
        // Double-click toggles full screen (declared first so it wins over the single click, which
        // shows or hides the controls).
        .onTapGesture(count: 2) { onToggleFullscreen?() }
        .onTapGesture { hudVisible ? scheduleHide() : showHUD() }
        #endif
        .sheet(isPresented: Binding(get: { subtitleSearchModel != nil }, set: { if !$0 { subtitleSearchModel = nil } })) {
            if let subtitleSearchModel {
                SubtitleSearchSheet(model: subtitleSearchModel) { self.subtitleSearchModel = nil }
            }
        }
        .onAppear { showHUD() }
        .onDisappear {
            hideTask?.cancel()
            if closesOnDisappear { controller.close() }
        }
        #if os(macOS)
        .focusable()
        .onKeyPress(.space) { controller.togglePlayPause(); showHUD(); return .handled }
        .onKeyPress("m") { controller.isMuted.toggle(); showHUD(); return .handled }
        .onKeyPress("f") { onToggleFullscreen?(); return .handled }
        .onKeyPress("s") { controller.toggleFavorite(); showHUD(); return .handled }
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
            if hudVisible {
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
                guard controller.isLive, let onZap else { return }
                onZap(-1)
                showHUD()
            case .down:
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

    private var topBar: some View {
        VStack(alignment: .leading, spacing: 6) {
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
                // Top-right, never clipped: the bottom row is too crowded for the narrow docked player.
                if let onToggleFullscreen {
                    hudButton(
                        isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                        isFullscreen ? "Quitter le plein écran" : "Plein écran"
                    ) { onToggleFullscreen() }
                    .font(.title3)
                }
            }
            if let banner = controller.reconnectBanner {
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
        .foregroundStyle(.white)
        .padding(12)
        .background(LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom))
        .opacity(hudVisible || controller.reconnectBanner != nil || controller.failoverBanner != nil ? 1 : 0)
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
        .accessibilityLabel(controller.isBroken ? "Marquer comme fonctionnel" : "Signaler comme non fonctionnel")
        .help(controller.isBroken ? "Marquer comme fonctionnel" : "Signaler comme non fonctionnel")
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
        }
        .fixedSize()
    }

    private var secondaryControls: some View {
        HStack(spacing: 14) {
            volumeControls
            speedMenu
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

    private var audioMenu: some View {
        Menu {
            if !controller.audioTracks.isEmpty {
                Section("Pistes audio") {
                    ForEach(controller.audioTracks) { track in
                        Button(track.isSelected ? "✓ \(track.title)" : track.title) {
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
                        Button(track.isSelected ? "✓ \(track.title)" : track.title) {
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
                Spacer()
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
                #endif
                Text(Self.format(controller.durationMs)).monospacedDigit()
            }
            .font(.caption)
        }
    }

    @ViewBuilder
    private var volumeControls: some View {
        hudButton(controller.isMuted ? "speaker.slash.fill" : "speaker.fill", "Muet") { controller.isMuted.toggle() }
        #if os(macOS)
        Slider(value: Binding(get: { Double(controller.volume) }, set: { controller.volume = Float($0) }), in: 0...1)
            .frame(width: 80)
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

    // MARK: Auto-hide (3 s)

    private func showHUD() {
        hudVisible = true
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard !isScrubbing else { return }
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled, controller.state == .playing { hudVisible = false }
        }
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
