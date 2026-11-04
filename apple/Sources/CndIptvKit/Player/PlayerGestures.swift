import SwiftUI
#if os(iOS)
import UIKit
#endif

enum PlayerGestureMath {
    enum Side: Equatable {
        case left
        case right
    }

    static func side(forX x: CGFloat, width: CGFloat) -> Side {
        x < width / 2 ? .left : .right
    }

    /// A drag across the full height of the screen moves the value by `fullRange`; dragging up raises it.
    static func adjusted(_ start: Float, translationY: CGFloat, height: CGFloat, fullRange: Float = 1) -> Float {
        guard height > 0 else { return start }
        let delta = Float(-translationY / height) * fullRange
        return min(max(start + delta, 0), 1)
    }

    /// Double-tap target: left rewinds, right fast-forwards.
    static func skipSeconds(for side: Side, interval: Int = 10) -> Int {
        side == .left ? -interval : interval
    }
}

/// Light haptic tick on touch devices (zapping, adding a favorite); nothing on the Mac.
enum Haptics {
    @MainActor
    static func light() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }
}

#if os(iOS)
/// Full-screen touch gestures: double-tap left/right to skip, vertical drag on the left half for
/// brightness and on the right half for volume.
struct PlayerGestureLayer: View {
    let controller: CndPlayerController
    var onSingleTap: () -> Void
    var onSkip: (Int) -> Void

    @State private var brightnessStart: Float?
    @State private var volumeStart: Float?
    @State private var hud: (symbol: String, value: Float)?
    @State private var hudTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geo in
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2, coordinateSpace: .local) { point in // lint:ui-ignore seek buttons exist in the player bar
                    let side = PlayerGestureMath.side(forX: point.x, width: geo.size.width)
                    guard !controller.isLive else { return }
                    onSkip(PlayerGestureMath.skipSeconds(for: side))
                    Haptics.light()
                }
                .onTapGesture { onSingleTap() } // lint:ui-ignore the HUD stays up with a screen reader
                .gesture(
                    DragGesture(minimumDistance: 12)
                        .onChanged { drag in
                            let side = PlayerGestureMath.side(forX: drag.startLocation.x, width: geo.size.width)
                            switch side {
                            case .left:
                                let start = brightnessStart ?? Self.currentBrightness
                                brightnessStart = start
                                let value = PlayerGestureMath.adjusted(start, translationY: drag.translation.height, height: geo.size.height)
                                Self.setBrightness(value)
                                show("sun.max.fill", value)
                            case .right:
                                let start = volumeStart ?? controller.volume
                                volumeStart = start
                                let value = PlayerGestureMath.adjusted(start, translationY: drag.translation.height, height: geo.size.height)
                                controller.volume = value
                                show("speaker.wave.2.fill", value)
                            }
                        }
                        .onEnded { _ in
                            brightnessStart = nil
                            volumeStart = nil
                        }
                )
                .overlay {
                    if let hud {
                        VStack(spacing: 6) {
                            Image(systemName: hud.symbol).font(.title)
                            ProgressView(value: Double(hud.value)).frame(width: 120)
                        }
                        .padding(16)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.white)
                        .allowsHitTesting(false)
                    }
                }
        }
    }

    private func show(_ symbol: String, _ value: Float) {
        hud = (symbol, value)
        hudTask?.cancel()
        hudTask = Task {
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { hud = nil }
        }
    }

    private static var screen: UIScreen? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.screen
    }

    private static var currentBrightness: Float { Float(screen?.brightness ?? 0.5) }

    private static func setBrightness(_ value: Float) {
        screen?.brightness = CGFloat(value)
    }
}
#endif
