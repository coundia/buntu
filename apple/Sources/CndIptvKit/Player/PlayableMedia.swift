import Foundation
import CndCoreBridge

public enum PlayableKind: String, Sendable, Equatable {
    case live
    case movie
    case episode
    case recording
    /// A past programme played back from the provider's archive: seekable like a film, but it is not
    /// watch history (the channel's own entry must not move) and it can return to the live stream.
    case replay
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
    /// Whether the media is currently marked as favorite.
    public var isFavorite: Bool
    /// Whether the media is currently flagged as broken / non-functional.
    public var isBroken: Bool
    /// Original item kind ("live", "movie", "episode").
    public let itemKind: String?
    /// Catalog item id if created from a catalog row.
    public let itemId: Int64?
    /// Link to series catalog if this item is an episode.
    public let seriesId: Int64?
    /// Series stable hash if known.
    public let seriesStableHash: String?
    /// Series title if known.
    public let seriesTitle: String?
    /// IMDb identifier and episode numbers, when the catalog knows them (used to match subtitles exactly).
    public let imdbId: String?
    public let seasonNumber: UInt32?
    public let episodeNumber: UInt32?

    /// A film or an episode from the catalog that streams over the network: the player can offer to
    /// download it. Live channels and local files cannot be.
    public var isDownloadable: Bool {
        guard itemId != nil, itemKind == "movie" || itemKind == "episode" else { return false }
        return url.scheme == "http" || url.scheme == "https"
    }

    public init(
        title: String,
        url: URL,
        headers: [String: String] = [:],
        kind: PlayableKind,
        startPositionMs: Int64 = 0,
        stableHash: String? = nil,
        itemId: Int64? = nil,
        artworkUrl: String? = nil,
        isFavorite: Bool = false,
        isBroken: Bool = false,
        itemKind: String? = nil,
        seriesId: Int64? = nil,
        seriesStableHash: String? = nil,
        seriesTitle: String? = nil,
        imdbId: String? = nil,
        seasonNumber: UInt32? = nil,
        episodeNumber: UInt32? = nil
    ) {
        self.title = title
        self.url = url
        self.headers = headers
        self.kind = kind
        self.startPositionMs = max(0, startPositionMs)
        self.stableHash = stableHash
        self.itemId = itemId
        self.artworkUrl = artworkUrl
        self.isFavorite = isFavorite
        self.isBroken = isBroken
        self.itemKind = itemKind ?? kind.rawValue
        self.seriesId = seriesId
        self.seriesStableHash = seriesStableHash
        self.seriesTitle = seriesTitle
        self.imdbId = imdbId
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
    }

    /// The same media played from another address (headers, position and identity are kept).
    public func replacingURL(_ newURL: URL) -> PlayableMedia {
        PlayableMedia(
            title: title, url: newURL, headers: headers, kind: kind, startPositionMs: startPositionMs,
            stableHash: stableHash, itemId: itemId, artworkUrl: artworkUrl, isFavorite: isFavorite,
            isBroken: isBroken, itemKind: itemKind, seriesId: seriesId, seriesStableHash: seriesStableHash,
            seriesTitle: seriesTitle, imdbId: imdbId, seasonNumber: seasonNumber, episodeNumber: episodeNumber
        )
    }

    public func header(named name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public var userAgent: String? { header(named: "User-Agent") }
    public var referer: String? { header(named: "Referer") ?? header(named: "Referrer") }

    public var isHls: Bool {
        url.pathExtension.lowercased() == "m3u8" || url.absoluteString.lowercased().contains(".m3u8")
    }

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
    public init?(
        item: IptvItemRecord,
        overrideUrl: URL? = nil,
        customTitle: String? = nil,
        kind: PlayableKind? = nil,
        startPositionMs: Int64 = 0,
        series: SeriesRecord? = nil
    ) {
        guard let url = overrideUrl ?? URL(string: item.streamUrl) else { return nil }
        var headers: [String: String] = [:]
        if let raw = item.headersJson?.data(using: .utf8),
           let parsed = try? JSONDecoder().decode([String: String].self, from: raw) {
            headers = parsed
        }
        if let ua = item.userAgent, !ua.isEmpty { headers["User-Agent"] = ua }
        if let ref = item.referer, !ref.isEmpty { headers["Referer"] = ref }
        self.init(
            title: customTitle ?? item.name,
            url: url,
            headers: headers,
            kind: kind ?? PlayableKind(rawValue: item.kind) ?? .movie,
            startPositionMs: startPositionMs,
            stableHash: item.stableHash,
            itemId: item.id,
            artworkUrl: item.logoUrl,
            isFavorite: series?.isFavorite ?? item.isFavorite,
            isBroken: series?.isBroken ?? item.isBroken,
            itemKind: item.kind,
            seriesId: item.seriesId,
            seriesStableHash: series?.stableHash,
            seriesTitle: series?.title,
            imdbId: item.imdbId,
            seasonNumber: item.seasonNum,
            episodeNumber: item.episodeNum
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

    public mutating func updateCurrentFavorite(_ isFavorite: Bool) {
        guard items.indices.contains(currentIndex) else { return }
        items[currentIndex].isFavorite = isFavorite
    }
}

/// Engine selection: `AVPlayer` for HLS/MP4/MOV, `mpv` for raw TS/MKV/AVI/FLV and unknown containers.
public enum PlayerRouting {
    private static let avPlayerExtensions: Set<String> = ["m3u8", "mp4", "m4v", "mov"]

    /// `AVPlayer` plays HLS, MP4, M4V and MOV; raw MPEG-TS, MKV, AVI and FLV need `libmpv`.
    public static func avPlayerCanPlay(_ url: URL) -> Bool {
        avPlayerExtensions.contains(url.pathExtension.lowercased())
    }

    /// Xtream serves a live channel as `/live/<user>/<password>/<id>.ts` (raw TS) and, from the same
    /// path with `.m3u8`, as HLS. Devices without `libmpv` (iPhone, iPad) can only play the HLS form.
    public static func hlsAlternative(for url: URL) -> URL? {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 4, parts[0] == "live", ["ts", ""].contains(url.pathExtension.lowercased()),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let id = (parts[3] as NSString).deletingPathExtension
        components.path = "/live/\(parts[1])/\(parts[2])/\(id).m3u8"
        return components.url
    }

    public static func engine(for url: URL, preference: PlayerEnginePreference = .auto) -> PlayerEngineKind {
        if preference == .forceMpv { return .mpv }
        let ext = url.pathExtension.lowercased()
        return avPlayerExtensions.contains(ext) ? .avPlayer : .mpv
    }
}
