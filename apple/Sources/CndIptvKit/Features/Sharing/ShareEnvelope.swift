import Foundation
import CryptoKit
import Compression

/// Encrypted container for a share document.
///
/// Layout: `"CNDS1"` + header length (UInt32, big endian) + header (JSON, in clear) + AES-GCM
/// "combined" box (nonce + ciphertext + tag) of the zlib-compressed document. The header is
/// authenticated (GCM additional data), so changing it invalidates the envelope, but it holds nothing
/// sensitive: format, version, expiry, number of sources and the HKDF salt.
///
/// The key comes from a random 128-bit share code through HKDF-SHA256. A random code, not a password
/// chosen by the user, is why no slow key stretching is needed.
enum ShareEnvelope {
    static let magic = Data("CNDS1".utf8)
    static let linkScheme = "cndiptv"
    static let fileExtension = "cndshare"
    static let hkdfInfo = Data("cnd-source-share-v1".utf8)
    /// Practical QR capacity at the lowest error-correction level (binary mode).
    static let qrByteLimit = 2_900

    struct Header: Codable, Equatable {
        var format: String
        var version: Int
        var expiresAt: Int64
        var sourceCount: Int
        var salt: Data
    }

    enum Failure: LocalizedError, Equatable {
        case malformed
        case unsupportedVersion(Int)
        case expired
        case wrongCodeOrTampered
        case invalidCode
        case compression

        var errorDescription: String? {
            switch self {
            case .malformed: return AppBrand.notAShareFile
            case .unsupportedVersion(let v): return "Version de partage non prise en charge (\(v)). Mettez l'application à jour."
            case .expired: return "Ce partage a expiré."
            case .wrongCodeOrTampered: return "Code incorrect, ou fichier modifié."
            case .invalidCode: return "Le code de partage est invalide."
            case .compression: return "Contenu du partage illisible."
            }
        }
    }

    // MARK: Share code

    /// 16 random bytes (128 bits).
    static func makeCode() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<16).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }

    /// Crockford-style alphabet without I, L, O, U: no look-alike characters when read aloud.
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// 26 characters in groups of four: `K7QF-ABCD-EFGH-JKMN-PQRS-TV`.
    static func format(code: Data) -> String {
        var bits = 0
        var accumulator = 0
        var characters: [Character] = []
        for byte in code {
            accumulator = (accumulator << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                characters.append(alphabet[(accumulator >> (bits - 5)) & 31])
                bits -= 5
            }
            accumulator &= (1 << bits) - 1
        }
        if bits > 0 { characters.append(alphabet[(accumulator << (5 - bits)) & 31]) }
        return stride(from: 0, to: characters.count, by: 4)
            .map { String(characters[$0..<min($0 + 4, characters.count)]) }
            .joined(separator: "-")
    }

    /// Accepts spaces, dashes, lower case and the usual look-alikes (O -> 0, I/L -> 1).
    static func parse(code text: String) throws -> Data {
        let normalized = text.uppercased().filter { !$0.isWhitespace && $0 != "-" }
            .map { character -> Character in
                switch character {
                case "O": return "0"
                case "I", "L": return "1"
                default: return character
                }
            }
        guard normalized.count == 26 else { throw Failure.invalidCode }
        var accumulator = 0
        var bits = 0
        var bytes: [UInt8] = []
        for character in normalized {
            guard let value = alphabet.firstIndex(of: character) else { throw Failure.invalidCode }
            accumulator = (accumulator << 5) | value
            bits += 5
            if bits >= 8 {
                bytes.append(UInt8((accumulator >> (bits - 8)) & 0xFF))
                bits -= 8
                accumulator &= (1 << bits) - 1
            }
        }
        guard bytes.count == 16 else { throw Failure.invalidCode }
        return Data(bytes)
    }

    // MARK: Seal / open

    private static func key(code: Data, salt: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: code), salt: salt, info: hkdfInfo, outputByteCount: 32)
    }

    static func seal(
        document: Data,
        code: Data,
        sourceCount: Int,
        expiresAt: Int64
    ) throws -> Data {
        guard let compressed = try? (document as NSData).compressed(using: .zlib) as Data else { throw Failure.compression }
        var salt = Data(count: 16)
        salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let header = Header(format: "cnd-source-share", version: 1, expiresAt: expiresAt, sourceCount: sourceCount, salt: salt)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let headerData = try encoder.encode(header)
        let box = try AES.GCM.seal(compressed, using: key(code: code, salt: salt), authenticating: headerData)
        guard let combined = box.combined else { throw Failure.malformed }

        var out = magic
        var length = UInt32(headerData.count).bigEndian
        out.append(Data(bytes: &length, count: 4))
        out.append(headerData)
        out.append(combined)
        return out
    }

    /// The clear header, without needing the code (for the preview and the expiry check).
    static func header(of envelope: Data) throws -> (header: Header, headerData: Data, body: Data) {
        guard envelope.count > magic.count + 4, envelope.prefix(magic.count) == magic else { throw Failure.malformed }
        let lengthStart = envelope.startIndex + magic.count
        let length = envelope[lengthStart..<lengthStart + 4].reduce(0) { ($0 << 8) | Int($1) }
        let headerStart = lengthStart + 4
        guard length > 0, length < 4_096, envelope.count > headerStart + length else { throw Failure.malformed }
        let headerData = envelope[headerStart..<headerStart + length]
        guard let header = try? JSONDecoder().decode(Header.self, from: headerData) else { throw Failure.malformed }
        guard header.format == "cnd-source-share" else { throw Failure.malformed }
        guard header.version == 1 else { throw Failure.unsupportedVersion(header.version) }
        return (header, Data(headerData), Data(envelope[(headerStart + length)...]))
    }

    static func open(envelope: Data, code: Data, now: Date = Date()) throws -> Data {
        let parts = try header(of: envelope)
        guard parts.header.expiresAt > Int64(now.timeIntervalSince1970) else { throw Failure.expired }
        let box: AES.GCM.SealedBox
        let plain: Data
        do {
            box = try AES.GCM.SealedBox(combined: parts.body)
            plain = try AES.GCM.open(box, using: key(code: code, salt: parts.header.salt), authenticating: parts.headerData)
        } catch {
            throw Failure.wrongCodeOrTampered
        }
        guard let document = try? (plain as NSData).decompressed(using: .zlib) as Data else { throw Failure.compression }
        return document
    }

    // MARK: Links

    /// `cndiptv://import#<envelope base64url>.<code>`: carries everything, for someone you trust.
    static func link(envelope: Data, code: Data) -> String {
        "\(linkScheme)://import#\(base64URL(envelope)).\(format(code: code))"
    }

    struct Incoming: Equatable {
        var envelope: Data
        var code: String?
    }

    static func parse(link url: URL) -> Incoming? {
        guard url.scheme == linkScheme, url.host == "import", let fragment = url.fragment else { return nil }
        let parts = fragment.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let first = parts.first, let envelope = data(fromBase64URL: first) else { return nil }
        return Incoming(envelope: envelope, code: parts.count > 1 ? parts[1] : nil)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func data(fromBase64URL text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        return Data(base64Encoded: base64)
    }
}
