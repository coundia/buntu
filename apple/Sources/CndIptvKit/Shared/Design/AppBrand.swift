import SwiftUI

/// The app's name and voice (`docs/BRANDING_BUNTU.md`). Every place that shows the name reads it from
/// here, so the next renaming is a one-line change. Bundle identifiers, the iCloud container, Keychain
/// keys and the downloads folder keep their original names on purpose: changing them would cost
/// existing users their data.
enum AppBrand {
    static let name = "Buntu"
    /// « Buntu : sa bunt ci lépp. » (Wolof, to be validated by native speakers.)
    static let sloganWolof = "Sa bunt ci lépp."
    static let sloganFrench = "La porte d'entrée de tous vos médias."
    /// What the app is, for the About screen. It plays the user's own sources; it supplies no content.
    static let descriptor = "Lecteur de médias pour Mac, iPhone, iPad, Apple TV et Vision Pro"

    /// `Partage Buntu.cndshare`: the visible name of an exported share; the extension is the format's.
    static func shareFileName(extension ext: String) -> String { "Partage \(name).\(ext)" }
    /// « Ce fichier n'est pas un partage Buntu. »
    static var notAShareFile: String { "Ce fichier n'est pas un partage \(name)." }
    static var notAShareLink: String { "Ce lien n'est pas un partage \(name)." }
    static var notAShareContent: String { "Le contenu reçu n'est pas un partage \(name)." }
}

/// The brand colours (§ 4.2 of the brand book). Hex values are the source; contrast ratios are tested.
enum BrandPalette {
    struct Swatch: Equatable, Sendable {
        let name: String
        let hex: UInt32

        var color: Color {
            Color(
                red: Double((hex >> 16) & 0xFF) / 255,
                green: Double((hex >> 8) & 0xFF) / 255,
                blue: Double(hex & 0xFF) / 255
            )
        }
    }

    static let midnight = Swatch(name: "Buntu Midnight", hex: 0x0B0E14)
    static let slate = Swatch(name: "Buntu Slate", hex: 0x161B26)
    static let gold = Swatch(name: "Teranga Gold", hex: 0xFF9F0A)
    static let cyan = Swatch(name: "Léer Cyan", hex: 0x00D2FF)
    static let white = Swatch(name: "Pure White", hex: 0xF5F7FA)
    static let silver = Swatch(name: "Muted Silver", hex: 0x8E95A5)

    static let all = [midnight, slate, gold, cyan, white, silver]
}

/// WCAG 2 contrast ratio between two colours.
enum Contrast {
    static func luminance(_ hex: UInt32) -> Double {
        func channel(_ value: UInt32) -> Double {
            let c = Double(value) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel((hex >> 16) & 0xFF) + 0.7152 * channel((hex >> 8) & 0xFF) + 0.0722 * channel(hex & 0xFF)
    }

    static func ratio(_ a: UInt32, _ b: UInt32) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// 4.5:1 is the AA threshold for normal text.
    static let aaText = 4.5
}
