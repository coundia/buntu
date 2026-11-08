import Foundation
import CoreImage.CIFilterBuiltins

/// The QR code that adds a device to the household (PRD 41).
///
/// The code carries the household key itself, so whoever sees it can join the household: the app shows
/// it only on request and never stores or logs it. The payload is a link (`buntu://household?key=…`);
/// a bare 64-character hexadecimal key is accepted too, for codes made by hand.
enum HouseholdInvite {
    static let scheme = "buntu"
    static let host = "household"
    static let keyLength = 64

    /// The text to put in the QR code for `keyHex`, or nil when it is not a valid key.
    static func link(forKeyHex keyHex: String) -> String? {
        guard let key = normalized(keyHex) else { return nil }
        return "\(scheme)://\(host)?key=\(key)"
    }

    /// The household key found in what a scanner read, or nil when it is not a household code.
    static func keyHex(fromScanned text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let key = normalized(trimmed) { return key }
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == scheme,
              components.host?.lowercased() == host,
              let value = components.queryItems?.first(where: { $0.name == "key" })?.value
        else { return nil }
        return normalized(value)
    }

    /// Lowercased key when it is exactly 64 hexadecimal characters.
    static func normalized(_ candidate: String) -> String? {
        let key = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard key.utf8.count == keyLength, key.utf8.allSatisfy(isHexDigit) else { return nil }
        return key
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x66)
    }

    /// A crisp, black-on-white QR image for `keyHex`.
    static func qrImage(forKeyHex keyHex: String, scale: CGFloat = 8) -> CGImage? {
        guard let link = link(forKeyHex: keyHex) else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(link.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}
