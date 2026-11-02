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
    /// `false` when a host view owns the controller's lifetime (mini-player <-> expanded swap).
    var closesOnDisappear: Bool
    /// Shows the Picture-in-Picture button when provided and supported.
    var pip: PiPManager?

    @State private var hudVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubValue: Double = 0
    @State private var isScrubbing = false

    private static let speeds: [Float] = [0.5, 1.0, 1.25, 1.5, 2.0]

    init(
        controller: CndPlayerController,
        onToggleFullscreen: (() -> Void)? = nil,
        onClose: (() -> Void)? = nil,
        closesOnDisappear: Bool = true,
        pip: PiPManager? = nil
    ) {
        self.controller = controller
        self.closesOnDisappear = closesOnDisappear
        self.pip = pip
        #if os(macOS)
        self.onToggleFullscreen = onToggleFullscreen ?? { NSApp.keyWindow?.toggleFullScreen(nil) }
        #else
        self.onToggleFullscreen = onToggleFullscreen
        #endif
        self.onClose = onClose
    }

    public var body: some View {
        ZStack {
            Color.black
            PlayerSurface(layer: controller.surfaceLayer)

            #if os(iOS)
            PlayerGestureLayer(
                controller: controller,
                onSingleTap: { hudVisible ? scheduleHide() : showHUD() },
                onSkip: { controller.skip(bySeconds: $0); showHUD() }
            )
            #endif

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
        .onTapGesture { hudVisible ? scheduleHide() : showHUD() }
        #endif
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
        .onKeyPress(.leftArrow) { guard !controller.isLive else { return .ignored }; controller.skip(bySeconds: -10); showHUD(); return .handled }
        .onKeyPress(.rightArrow) { guard !controller.isLive else { return .ignored }; controller.skip(bySeconds: 10); showHUD(); return .handled }
        .onKeyPress(.upArrow) { controller.volume = min(controller.volume + 0.1, 1); showHUD(); return .handled }
        .onKeyPress(.downArrow) { controller.volume = max(controller.volume - 0.1, 0); showHUD(); return .handled }
        #endif
    }

    // MARK: HUD pieces

    private var topBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let onClose {
                    Button(action: onClose) { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Fermer")
                }
                Text(controller.media?.title ?? "")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                if let engine = controller.activeEngine {
                    Text(engine == .mpv ? "mpv" : "AVPlayer")
                        .font(.caption2.monospaced())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.white.opacity(0.15), in: Capsule())
                }
            }
            if let banner = controller.reconnectBanner {
                Label(banner, systemImage: "wifi.exclamationmark")
                    .font(.caption)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(.orange.opacity(0.85), in: Capsule())
            }
        }
        .foregroundStyle(.white)
        .padding(12)
        .background(LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom))
        .opacity(hudVisible || controller.reconnectBanner != nil ? 1 : 0)
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            progressRow
            HStack(spacing: 18) {
                if controller.queue != nil {
                    hudButton("backward.end.fill", "Épisode précédent", enabled: controller.hasPrevious) { controller.previous() }
                }
                if !controller.isLive {
                    hudButton("gobackward.10", "Reculer de 10 secondes") { controller.skip(bySeconds: -10) }
                }
                hudButton(
                    controller.state == .playing || controller.state == .buffering ? "pause.fill" : "play.fill",
                    "Lecture / Pause"
                ) { controller.togglePlayPause() }
                .font(.title)
                if !controller.isLive {
                    hudButton("goforward.10", "Avancer de 10 secondes") { controller.skip(bySeconds: 10) }
                }
                if controller.queue != nil {
                    hudButton("forward.end.fill", "Épisode suivant", enabled: controller.hasNext) { controller.next() }
                }
                Spacer()
                volumeControls
                speedMenu
                trackMenu(title: "Audio", systemImage: "speaker.wave.2", tracks: controller.audioTracks, allowsNone: false)
                trackMenu(title: "Sous-titres", systemImage: "captions.bubble", tracks: controller.subtitleTracks, allowsNone: true)
                AirPlayRoutePicker()
                    .frame(width: 24, height: 24)
                    .accessibilityLabel("AirPlay")
                if let pip, pip.isSupported {
                    hudButton(pip.isActive ? "pip.exit" : "pip.enter", "Image dans l'image", enabled: pip.isPossible) { pip.toggle() }
                }
                if let onToggleFullscreen {
                    hudButton("arrow.up.left.and.arrow.down.right", "Plein écran") { onToggleFullscreen() }
                }
            }
        }
        .foregroundStyle(.white)
        .padding(12)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom))
    }

    @ViewBuilder
    private var progressRow: some View {
        if controller.isLive {
            HStack {
                Text("LIVE")
                    .font(.caption.bold())
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(.red, in: RoundedRectangle(cornerRadius: 4))
                Spacer()
            }
        } else {
            HStack(spacing: 10) {
                Text(Self.format(isScrubbing ? Int64(scrubValue) : controller.positionMs)).monospacedDigit()
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

    private func trackMenu(title: String, systemImage: String, tracks: [MediaTrack], allowsNone: Bool) -> some View {
        Menu {
            if allowsNone {
                Button("Désactivés") { controller.selectSubtitleTrack(id: nil) }
            }
            ForEach(tracks) { track in
                Button(track.isSelected ? "✓ \(track.title)" : track.title) {
                    if allowsNone {
                        controller.selectSubtitleTrack(id: track.id)
                    } else {
                        controller.selectAudioTrack(id: track.id)
                    }
                }
            }
        } label: {
            Image(systemName: systemImage)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(tracks.isEmpty)
        .accessibilityLabel(title)
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
                Button("Réessayer") { controller.open(media) }
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
}
