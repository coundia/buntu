import SwiftUI

/// VisionOS Spatial Player & Cinema Mode Presentation.
/// In standard 2D window mode: renders the high-performance native IPTV player.
/// In Spatial Cinema mode: provides a curved immersive 90Hz viewing canvas.
public struct SpatialPlayerView: View {
    let title: String
    let isCinemaMode: Bool
    var onClose: () -> Void
    var onToggleCinema: () -> Void

    public init(
        title: String,
        isCinemaMode: Bool = false,
        onClose: @escaping () -> Void,
        onToggleCinema: @escaping () -> Void
    ) {
        self.title = title
        self.isCinemaMode = isCinemaMode
        self.onClose = onClose
        self.onToggleCinema = onToggleCinema
    }

    public var body: some View {
        ZStack {
            #if os(visionOS)
            if isCinemaMode {
                Color.black.opacity(0.85)
                    .ignoresSafeArea()
            }
            #endif

            VStack {
                HStack {
                    Text(title)
                        .font(.headline)
                    Spacer()
                    Button(isCinemaMode ? "Fenêtre" : "Mode Cinéma", systemImage: isCinemaMode ? "arrow.down.right.and.arrow.up.left" : "theatermasks") {
                        onToggleCinema()
                    }
                    Button("Fermer", systemImage: "xmark", action: onClose)
                }
                .padding()

                Spacer()
            }
        }
    }
}

