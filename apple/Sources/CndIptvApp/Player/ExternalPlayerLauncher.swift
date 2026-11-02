import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

public enum ExternalPlayer: String, CaseIterable, Identifiable, Sendable {
    case iina
    case vlc
    case infuse
    case outplayer

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .iina: return "IINA"
        case .vlc: return "VLC"
        case .infuse: return "Infuse"
        case .outplayer: return "Outplayer"
        }
    }

    /// Players offered on the current platform.
    public static var availableOnThisPlatform: [ExternalPlayer] {
        #if os(macOS)
        return [.iina, .vlc, .infuse]
        #else
        return [.vlc, .infuse, .outplayer]
        #endif
    }
}

/// Opens streams in third-party players and builds copy-paste `ffmpeg` / `curl` commands.
/// URL schemes cannot carry HTTP headers; use the generated commands when headers matter.
public enum ExternalPlayerLauncher {

    // MARK: URL schemes

    /// Everything except unreserved characters, so `&`, `?`, `=` and `+` of the stream URL survive.
    static func encodeQueryValue(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    public static func schemeURL(for player: ExternalPlayer, media: PlayableMedia) -> URL? {
        let encoded = encodeQueryValue(media.url.absoluteString)
        switch player {
        case .iina: return URL(string: "iina://weblink?url=\(encoded)")
        case .vlc:
            #if os(macOS)
            return URL(string: "vlc://\(media.url.absoluteString)")
            #else
            return URL(string: "vlc-x-callback://x-callback-url/stream?url=\(encoded)")
            #endif
        case .infuse: return URL(string: "infuse://x-callback-url/play?url=\(encoded)")
        case .outplayer: return URL(string: "outplayer://\(media.url.absoluteString)")
        }
    }

    @MainActor
    public static func launch(_ player: ExternalPlayer, media: PlayableMedia) async -> Bool {
        #if os(macOS)
        if player == .vlc,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.videolan.vlc") {
            let config = NSWorkspace.OpenConfiguration()
            return await withCheckedContinuation { continuation in
                NSWorkspace.shared.open([media.url], withApplicationAt: appURL, configuration: config) { _, error in
                    continuation.resume(returning: error == nil)
                }
            }
        }
        guard let url = schemeURL(for: player, media: media) else { return false }
        return NSWorkspace.shared.open(url)
        #else
        guard let url = schemeURL(for: player, media: media) else { return false }
        return await UIApplication.shared.open(url)
        #endif
    }

    // MARK: Command generators

    public static func safeFileName(for title: String) -> String {
        let cleaned = String(title.map { "/\\:*?\"<>|".contains($0) || $0.isNewline ? "_" : $0 })
            .trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
        return cleaned.isEmpty ? "video" : cleaned
    }

    /// Escapes a value placed inside a shell double-quoted string.
    static func escapeDoubleQuoted(_ value: String) -> String {
        var out = ""
        for ch in value {
            if "\\\"$`".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    /// Escapes a value placed inside a bash `$'...'` string.
    static func escapeAnsiC(_ value: String) -> String {
        var out = ""
        for ch in value {
            switch ch {
            case "\\": out.append("\\\\")
            case "'": out.append("\\'")
            case "\n", "\r": out.append(" ")
            default: out.append(ch)
            }
        }
        return out
    }

    /// `ffmpeg -headers $'User-Agent: ...\r\nReferer: ...\r\n' -i "<url>" -c copy "<safe_title>.mp4"`
    public static func ffmpegCommand(for media: PlayableMedia) -> String {
        var parts = ["ffmpeg"]
        let headers = media.orderedHeaders
        if !headers.isEmpty {
            let block = headers.map { "\(escapeAnsiC($0.name)): \(escapeAnsiC($0.value))\\r\\n" }.joined()
            parts.append("-headers $'\(block)'")
        }
        parts.append("-i \"\(escapeDoubleQuoted(media.url.absoluteString))\"")
        parts.append("-c copy")
        parts.append("\"\(escapeDoubleQuoted(safeFileName(for: media.title))).mp4\"")
        return parts.joined(separator: " ")
    }

    /// `curl -L -H "User-Agent: ..." "<url>" -o "<safe_title>.mp4"`
    public static func curlCommand(for media: PlayableMedia) -> String {
        var parts = ["curl -L"]
        for header in media.orderedHeaders {
            parts.append("-H \"\(escapeDoubleQuoted("\(header.name): \(header.value)"))\"")
        }
        parts.append("\"\(escapeDoubleQuoted(media.url.absoluteString))\"")
        parts.append("-o \"\(escapeDoubleQuoted(safeFileName(for: media.title))).mp4\"")
        return parts.joined(separator: " ")
    }

    // MARK: Clipboard

    @MainActor
    private static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    @MainActor public static func copyStreamUrl(_ media: PlayableMedia) { copy(media.url.absoluteString) }
    @MainActor public static func copyFfmpegCommand(_ media: PlayableMedia) { copy(ffmpegCommand(for: media)) }
    @MainActor public static func copyCurlCommand(_ media: PlayableMedia) { copy(curlCommand(for: media)) }
}
