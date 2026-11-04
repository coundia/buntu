import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The app's logo (brand book, § 4.1): a "B" drawn as two stacked arches, a door ajar, with a thread of
/// warm light (*leer*) coming through the opening, on a deep night tile. Drawn in code so the sidebar, the
/// Dock icon and the exported `.icns` share one source.
struct AppLogoView: View {
    var size: CGFloat
    /// `true` adds the transparent margin and soft shadow of a macOS app icon (the tile fills 80 %).
    var framed = false

    static let tileTop = BrandPalette.slate.color
    static let tileBottom = BrandPalette.midnight.color

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
                    startPoint: CGPoint(x: t * 0.2, y: 0), endPoint: CGPoint(x: t * 0.8, y: t)
                )
            )

            func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * t, y: y * t) }
            let gold = BrandPalette.gold.color

            // The glow behind the opening.
            context.fill(
                Path(ellipseIn: CGRect(x: 0.14 * t, y: 0.22 * t, width: 0.62 * t, height: 0.56 * t)),
                with: .radialGradient(
                    Gradient(colors: [gold.opacity(0.42), gold.opacity(0)]),
                    center: point(0.45, 0.5), startRadius: 0, endRadius: 0.32 * t
                )
            )

            // The "B": a stem and two arches, the lower one a little wider (a door ajar).
            var letter = Path()
            letter.move(to: point(0.31, 0.24))
            letter.addLine(to: point(0.31, 0.76))
            letter.move(to: point(0.31, 0.24))
            letter.addLine(to: point(0.50, 0.24))
            letter.addArc(center: point(0.50, 0.37), radius: 0.13 * t, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
            letter.addLine(to: point(0.31, 0.50))
            letter.move(to: point(0.31, 0.50))
            letter.addLine(to: point(0.53, 0.50))
            letter.addArc(center: point(0.53, 0.63), radius: 0.13 * t, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
            letter.addLine(to: point(0.31, 0.76))
            context.stroke(
                letter,
                with: .color(BrandPalette.white.color),
                style: StrokeStyle(lineWidth: t * 0.085, lineCap: .round, lineJoin: .round)
            )

            // The thread of light through the opening, in the two arches (never over the letter).
            for (top, bottom) in [(0.31, 0.445), (0.555, 0.69)] {
                let beam = CGRect(x: 0.426 * t, y: top * t, width: 0.034 * t, height: (bottom - top) * t)
                context.fill(
                    Path(roundedRect: beam, cornerRadius: t * 0.017),
                    with: .linearGradient(
                        Gradient(colors: [gold.opacity(0.55), gold]),
                        startPoint: point(0.44, top), endPoint: point(0.44, bottom)
                    )
                )
            }
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
