import XCTest
@testable import CndIptvKit

/// The brand book (docs/BRANDING_BUNTU.md) in numbers: the name, and the contrast of its palette.
final class AppBrandTests: XCTestCase {
    private func ratio(_ fg: BrandPalette.Swatch, _ bg: BrandPalette.Swatch) -> Double { Contrast.ratio(fg.hex, bg.hex) }

    func testNameAndMessages() {
        XCTAssertEqual(AppBrand.name, "Buntu")
        XCTAssertEqual(AppBrand.shareFileName(extension: "cndshare"), "Partage Buntu.cndshare")
        XCTAssertTrue(AppBrand.notAShareFile.contains("Buntu"))
        XCTAssertFalse(AppBrand.descriptor.lowercased().contains("gratuit"), "the app promises no free content")
        XCTAssertFalse(AppBrand.descriptor.contains("IPTV"), "the brand does not lead with the protocol")
    }

    func testNoVisibleStringKeepsTheOldWorkingName() throws {
        // The old name only survives in identifiers that must not change (bundle id, folders), not in text.
        for text in [AppBrand.name, AppBrand.descriptor, AppBrand.sloganFrench, AppBrand.sloganWolof,
                     AppBrand.notAShareFile, AppBrand.notAShareLink, AppBrand.notAShareContent] {
            XCTAssertFalse(text.contains("CND"), text)
        }
    }

    func testBodyTextMeetsAAOnTheDarkSurfaces() {
        for fg in [BrandPalette.white, BrandPalette.silver, BrandPalette.gold, BrandPalette.cyan] {
            for bg in [BrandPalette.midnight, BrandPalette.slate] {
                XCTAssertGreaterThanOrEqual(ratio(fg, bg), Contrast.aaText, "\(fg.name) on \(bg.name)")
            }
        }
    }

    func testMutedSilverIsFineOnSlate() {
        // The brand book first feared this pair was borderline: it is 5.7:1.
        XCTAssertEqual(ratio(BrandPalette.silver, BrandPalette.slate), 5.74, accuracy: 0.05)
    }

    func testWhiteTextOnGoldFailsSoActionsUseMidnightText() {
        XCTAssertLessThan(ratio(BrandPalette.white, BrandPalette.gold), Contrast.aaText)
        XCTAssertGreaterThanOrEqual(ratio(BrandPalette.midnight, BrandPalette.gold), Contrast.aaText)
    }

    func testSwatchColorsMatchTheirHex() {
        XCTAssertEqual(BrandPalette.gold.hex, 0xFF9F0A)
        XCTAssertEqual(BrandPalette.midnight.hex, 0x0B0E14)
        XCTAssertEqual(BrandPalette.all.count, 6)
    }
}
