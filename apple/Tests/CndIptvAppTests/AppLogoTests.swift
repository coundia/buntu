import XCTest
import SwiftUI
@testable import CndIptvKit

#if os(macOS)
import AppKit

@MainActor
final class AppLogoTests: XCTestCase {
    func testRendersAtEveryIconSize() throws {
        for pixels in [16.0, 32, 128, 512, 1024] {
            let image = try XCTUnwrap(AppLogoRenderer.nsImage(pixels: pixels))
            let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            XCTAssertEqual(CGFloat(rep.pixelsWide), pixels)
            XCTAssertEqual(CGFloat(rep.pixelsHigh), pixels)
        }
    }

    func testFramedIconKeepsATransparentMarginAndAnOpaqueCenter() throws {
        let image = try XCTUnwrap(AppLogoRenderer.nsImage(pixels: 512, framed: true))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let corner = try XCTUnwrap(rep.colorAt(x: 2, y: 2))
        let center = try XCTUnwrap(rep.colorAt(x: 256, y: 256))
        XCTAssertEqual(corner.alphaComponent, 0, accuracy: 0.01, "the margin around the tile is transparent")
        XCTAssertEqual(center.alphaComponent, 1, accuracy: 0.01)

        let flat = try XCTUnwrap(AppLogoRenderer.nsImage(pixels: 512, framed: false))
        let flatRep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(flat.tiffRepresentation)))
        XCTAssertEqual(try XCTUnwrap(flatRep.colorAt(x: 256, y: 256)).alphaComponent, 1, accuracy: 0.01)
    }

    /// `task icon` runs this with `CND_EXPORT_ICON=<dir>/AppIcon.iconset` to regenerate the icon files.
    func testExportIconsetWhenAsked() throws {
        guard let path = ProcessInfo.processInfo.environment["CND_EXPORT_ICON"], !path.isEmpty else {
            throw XCTSkip("Set CND_EXPORT_ICON to export the .iconset (see `task icon`).")
        }
        try AppLogoRenderer.writeIconset(to: URL(fileURLWithPath: path, isDirectory: true))
        let files = try FileManager.default.contentsOfDirectory(atPath: path)
        XCTAssertEqual(files.count, 10)
    }
}
#endif
