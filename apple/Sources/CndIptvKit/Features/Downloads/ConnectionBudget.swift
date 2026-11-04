import Foundation
import CndCoreBridge

/// How many simultaneous connections the user's subscription allows, and how downloads share them with
/// playback. A provider that allows one connection answers 502 to anything beyond it, which breaks both the
/// stream and the download, so the default is one: downloads wait for the end of a playback.
struct ConnectionBudget: Equatable, Sendable {
    static let defaultsKey = "connections.assumedLimit"
    static let defaultLimit = 1
    static let range = 1...10

    let limit: Int

    init(limit: Int) {
        self.limit = min(max(limit, Self.range.lowerBound), Self.range.upperBound)
    }

    static func current(defaults: UserDefaults = .standard) -> ConnectionBudget {
        let stored = defaults.object(forKey: defaultsKey) as? Int
        return ConnectionBudget(limit: stored ?? defaultLimit)
    }

    /// Connections the downloads may use together. One is kept for watching as soon as the subscription
    /// has more than one; with a single connection the downloads wait for the end of the playback.
    var downloadConnections: Int { limit <= 1 ? 1 : limit - 1 }

    /// With one connection a download and a stream cannot run together.
    var pausesDuringPlayback: Bool { limit <= 1 }

    /// The user's segments per file and files at once, brought under `downloadConnections`
    /// (segments × files never exceeds it).
    func clamp(segments: Int, files: Int) -> (segments: Int, files: Int) {
        let cap = downloadConnections
        let s = min(max(segments, 1), cap)
        let f = min(max(files, 1), max(1, cap / s))
        return (s, f)
    }

    /// The limit that applies to a host: the one the provider reported for a matching source, never more
    /// than the user's own setting (which defaults to one).
    static func limit(forHost host: String?, sources: [IptvSourceRecord], assumed: Int) -> Int {
        let assumed = ConnectionBudget(limit: assumed).limit
        guard let host = host?.lowercased(),
              let reported = sources.first(where: { hostOf(source: $0) == host })?.maxConnections, reported > 0 else {
            return assumed
        }
        return min(assumed, Int(reported))
    }

    static func hostOf(source: IptvSourceRecord) -> String? {
        host(of: source.server) ?? host(of: source.url)
    }

    static func host(of urlString: String?) -> String? {
        guard let text = urlString?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        let withScheme = text.contains("://") ? text : "http://\(text)"
        return URL(string: withScheme)?.host?.lowercased()
    }
}
