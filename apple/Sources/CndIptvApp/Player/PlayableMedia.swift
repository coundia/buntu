import Foundation
import CndCoreBridge

public enum PlayableKind: String, Sendable, Equatable {
    case live
    case movie
    case episode
}

public enum PlayerEngineKind: String, Sendable, Equatable {
    case avPlayer
    case mpv
}

public enum PlayerEnginePreference: String, Sendable, Equatable, CaseIterable {
    case auto
    case forceMpv
}

/// Unified description of anything the player can open (live channel, movie, episode).
public struct PlayableMedia: Equatable, Identifiable, Sendable {
    public var id: String { url.absoluteString }
    public let title: String
    public let url: URL
    public let headers: [String: String]
    public let kind: PlayableKind
    public let startPositionMs: Int64
    /// `iptv_items.stable_hash`, used to persist watch progress (VOD only).
    public let stableHash: String?
    /// Logo or poster shown by the system Now Playing UI.
    public let artworkUrl: String?

    public init(
        title: String,
        url: URL,
        headers: [String: String] = [:],
        kind: PlayableKind,
        startPositionMs: Int64 = 0,
        stableHash: String? = nil,
        artworkUrl: String? = nil
    ) {
        self.title = title
        self.url = url
        self.headers = headers
        self.kind = kind
        self.startPositionMs = max(0, startPositionMs)
        self.stableHash = stableHash
        self.artworkUrl = artworkUrl
    }

    public func header(named name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public var userAgent: String? { header(named: "User-Agent") }
    public var referer: String? { header(named: "Referer") ?? header(named: "Referrer") }

    /// Headers in a stable order: User-Agent, Referer, then the rest sorted by name.
    public var orderedHeaders: [(name: String, value: String)] {
        var result: [(name: String, value: String)] = []
        if let ua = userAgent { result.append(("User-Agent", ua)) }
        if let ref = referer { result.append(("Referer", ref)) }
        let rest = headers
            .filter { key, _ in
                ["user-agent", "referer", "referrer"].contains(key.lowercased()) == false
            }
            .sorted { $0.key.lowercased() < $1.key.lowercased() }
        result.append(contentsOf: rest.map { ($0.key, $0.value) })
        return result
    }

    /// Builds a playable from a catalog row, merging `user_agent`, `referer` and `headers_json`.
    public init?(item: IptvItemRecord, startPositionMs: Int64 = 0) {
        guard let url = URL(string: item.streamUrl) else { return nil }
        var headers: [String: String] = [:]
        if let raw = item.headersJson?.data(using: .utf8),
           let parsed = try? JSONDecoder().decode([String: String].self, from: raw) {
            headers = parsed
        }
        if let ua = item.userAgent, !ua.isEmpty { headers["User-Agent"] = ua }
        if let ref = item.referer, !ref.isEmpty { headers["Referer"] = ref }
        self.init(
            title: item.name,
            url: url,
            headers: headers,
            kind: PlayableKind(rawValue: item.kind) ?? .movie,
            startPositionMs: startPositionMs,
            stableHash: item.stableHash,
            artworkUrl: item.logoUrl
        )
    }
}

/// Ordered list of media (season / series) with a current index.
public struct PlaylistQueue: Equatable, Sendable {
    public private(set) var items: [PlayableMedia]
    public private(set) var currentIndex: Int

    public init(items: [PlayableMedia], currentIndex: Int = 0) {
        self.items = items
        self.currentIndex = items.isEmpty ? 0 : min(max(0, currentIndex), items.count - 1)
    }

    public var current: PlayableMedia? {
        items.indices.contains(currentIndex) ? items[currentIndex] : nil
    }
    public var hasNext: Bool { currentIndex + 1 < items.count }
    public var hasPrevious: Bool { currentIndex > 0 }

    @discardableResult
    public mutating func next() -> PlayableMedia? {
        guard hasNext else { return nil }
        currentIndex += 1
        return current
    }

    @discardableResult
    public mutating func previous() -> PlayableMedia? {
        guard hasPrevious else { return nil }
        currentIndex -= 1
        return current
    }
}

/// Engine selection: `AVPlayer` for HLS/MP4/MOV, `mpv` for raw TS/MKV/AVI/FLV and unknown containers.
public enum PlayerRouting {
    private static let avPlayerExtensions: Set<String> = ["m3u8", "mp4", "m4v", "mov"]

    public static func engine(for url: URL, preference: PlayerEnginePreference = .auto) -> PlayerEngineKind {
        if preference == .forceMpv { return .mpv }
        let ext = url.pathExtension.lowercased()
        return avPlayerExtensions.contains(ext) ? .avPlayer : .mpv
    }
}
