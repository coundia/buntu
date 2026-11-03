import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The app's logo: a television with a play button and an antenna on a blue-violet tile.
/// Drawn in code so the sidebar, the Dock icon and the exported `.icns` share one source.
struct AppLogoView: View {
    var size: CGFloat
    /// `true` adds the transparent margin and soft shadow of a macOS app icon (the tile fills 80 %).
    var framed = false

    static let tileTop = Color(red: 0.07, green: 0.55, blue: 1.00)
    static let tileBottom = Color(red: 0.43, green: 0.20, blue: 0.93)

    var body: some View {
        let tile = framed ? size * 0.8 : size
        Canvas { context, canvas in
            let t = canvas.width
            let radius = t * 0.2237
            let tileRect = CGRect(origin: .zero, size: canvas)
            context.fill(
                Path(roundedRect: tileRect, cornerRadius: radius, style: .continuous),
                with: .linearGradient(
                    Gradient(colors: [Self.tileTop, Self.tileBottom]),
                    startPoint: CGPoint(x: t * 0.15, y: 0), endPoint: CGPoint(x: t * 0.85, y: t)
                )
            )

            func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * t, y: y * t) }
            let white = GraphicsContext.Shading.color(.white.opacity(0.96))
            let stroke = StrokeStyle(lineWidth: t * 0.04, lineCap: .round)

            // Antenna.
            var antenna = Path()
            antenna.move(to: point(0.50, 0.33))
            antenna.addLine(to: point(0.37, 0.17))
            antenna.move(to: point(0.50, 0.33))
            antenna.addLine(to: point(0.63, 0.17))
            context.stroke(antenna, with: white, style: stroke)

            // Screen.
            let screen = CGRect(x: 0.17 * t, y: 0.33 * t, width: 0.66 * t, height: 0.44 * t)
            context.fill(Path(roundedRect: screen, cornerRadius: t * 0.09, style: .continuous), with: white)

            // Play triangle, optically centred in the screen.
            var play = Path()
            play.move(to: point(0.44, 0.43))
            play.addLine(to: point(0.44, 0.67))
            play.addLine(to: point(0.63, 0.55))
            play.closeSubpath()
            context.fill(
                play,
                with: .linearGradient(
                    Gradient(colors: [Self.tileTop, Self.tileBottom]),
                    startPoint: point(0.44, 0.43), endPoint: point(0.63, 0.67)
                )
            )

            // Stand.
            let stand = CGRect(x: 0.36 * t, y: 0.82 * t, width: 0.28 * t, height: 0.04 * t)
            context.fill(Path(roundedRect: stand, cornerRadius: t * 0.02), with: .color(.white.opacity(0.85)))
        }
        .frame(width: tile, height: tile)
        .shadow(color: .black.opacity(framed ? 0.28 : 0), radius: size * 0.02, y: size * 0.012)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

#if os(macOS)
enum AppLogoRenderer {
    /// A bitmap of the logo (used for the Dock icon when the app does not run from a `.app` bundle).
    @MainActor
    static func nsImage(pixels: CGFloat, framed: Bool = true) -> NSImage? {
        let renderer = ImageRenderer(content: AppLogoView(size: pixels, framed: framed))
        renderer.scale = 1
        return renderer.nsImage
    }

    /// Writes the ten sizes of a macOS `.iconset` into `directory`.
    @MainActor
    static func writeIconset(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let entries: [(name: String, pixels: CGFloat)] = [
            ("icon_16x16", 16), ("icon_16x16@2x", 32),
            ("icon_32x32", 32), ("icon_32x32@2x", 64),
            ("icon_128x128", 128), ("icon_128x128@2x", 256),
            ("icon_256x256", 256), ("icon_256x256@2x", 512),
            ("icon_512x512", 512), ("icon_512x512@2x", 1024),
        ]
        for entry in entries {
            guard let image = nsImage(pixels: entry.pixels),
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try png.write(to: directory.appendingPathComponent("\(entry.name).png"))
        }
    }
}
#endif
