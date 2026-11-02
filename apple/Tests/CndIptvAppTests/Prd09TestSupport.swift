import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CndCoreBridge
@testable import CndIptvApp

/// Thread-safe counter for `@Sendable` loader closures.
final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}

enum TestFixtures {
    static func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cnd-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func pngData(width: Int, height: Int) -> Data {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    static let groups = ["News", "Sport", "Kids"]

    /// `count` live channels; the last `withoutGuide` ones have no `tvg-id`.
    static func m3u(count: Int, withoutGuide: Int = 0) -> String {
        var lines = ["#EXTM3U"]
        for index in 1...count {
            let hasGuide = index <= count - withoutGuide
            let tvg = hasGuide ? " tvg-id=\"ch\(index).fr\"" : ""
            let name = String(format: "Chaine %03d", index) + (index == 1 ? " 4K" : "")
            lines.append(
                "#EXTINF:-1\(tvg) tvg-logo=\"http://logos.test/\(index).png\" tvg-chno=\"\(index)\" group-title=\"\(groups[index % 3])\",\(name)"
            )
            lines.append("http://srv.test/live/user/pass/\(index).ts")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func writeM3u(in directory: URL, name: String = "playlist.m3u", count: Int, withoutGuide: Int = 0) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try m3u(count: count, withoutGuide: withoutGuide).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func xmltvTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.string(from: date) + " +0000"
    }

    /// Three consecutive programmes per channel around `now`: current, next, later.
    static func xmltv(channels: [String], now: Date = Date()) -> String {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<tv>\n"
        for id in channels { xml += "<channel id=\"\(id)\"><display-name>\(id)</display-name></channel>\n" }
        let slots: [(TimeInterval, TimeInterval, String)] = [
            (-30 * 60, 30 * 60, "Journal"),
            (30 * 60, 90 * 60, "Film du soir"),
            (90 * 60, 150 * 60, "Magazine"),
        ]
        for id in channels {
            for (from, to, title) in slots {
                xml += "<programme start=\"\(xmltvTime(now.addingTimeInterval(from)))\" stop=\"\(xmltvTime(now.addingTimeInterval(to)))\" channel=\"\(id)\">"
                xml += "<title>\(title)</title><desc>Description \(title)</desc></programme>\n"
            }
        }
        return xml + "</tv>\n"
    }

    static let movieUserAgent = "CndTest/1.0"

    /// `movies` VOD films (with custom UA / referrer) plus two series:
    /// "Breaking Bad" (S1 x3 episodes, S2 x2) and "Dark" (S1 x2).
    static func vodM3u(movies: Int) -> String {
        var lines = ["#EXTM3U"]
        let genres = ["Action", "Drame"]
        for index in 1...movies {
            lines.append("#EXTINF:-1 tvg-logo=\"http://posters.test/\(index).jpg\" group-title=\"\(genres[index % 2])\",Film \(String(format: "%03d", index)) (2020)")
            lines.append("#EXTVLCOPT:http-user-agent=\(movieUserAgent)")
            lines.append("#EXTVLCOPT:http-referrer=http://portal.test/")
            lines.append("http://127.0.0.1:9/movie/u/p/\(index).mkv")
        }
        var number = 1000
        func episodes(_ series: String, season: Int, count: Int, titles: [String]) {
            for episode in 1...count {
                let tag = String(format: "S%02dE%02d", season, episode)
                lines.append("#EXTINF:-1 tvg-logo=\"http://posters.test/\(series).jpg\" group-title=\"Séries\",\(series) \(tag) \(titles[episode - 1])")
                lines.append("http://127.0.0.1:9/series/u/p/\(number).mkv")
                number += 1
            }
        }
        episodes("Breaking Bad", season: 1, count: 3, titles: ["Pilot", "Cat's in the Bag", "And the Bag's in the River"])
        episodes("Breaking Bad", season: 2, count: 2, titles: ["Seven Thirty-Seven", "Grilled"])
        episodes("Dark", season: 1, count: 2, titles: ["Secrets", "Lies"])
        return lines.joined(separator: "\n") + "\n"
    }

    @discardableResult
    static func importVod(into engine: CndEngine, directory: URL, movies: Int) async throws -> Int64 {
        let url = directory.appendingPathComponent("vod.m3u")
        try vodM3u(movies: movies).write(to: url, atomically: true, encoding: .utf8)
        return try await engine.importLocalM3u(name: "VOD", filePath: url.path).sourceId
    }

    /// Imports a playlist and attaches a local XMLTV file to the created source.
    @discardableResult
    static func importCatalog(
        into engine: CndEngine,
        directory: URL,
        count: Int,
        withoutGuide: Int = 0,
        withGuide: Bool = false
    ) async throws -> Int64 {
        let file = try writeM3u(in: directory, count: count, withoutGuide: withoutGuide)
        let summary = try await engine.importLocalM3u(name: "Test", filePath: file.path)
        if withGuide {
            let guided = (1...(count - withoutGuide)).map { "ch\($0).fr" }
            let epgFile = directory.appendingPathComponent("guide.xml")
            try xmltv(channels: guided).write(to: epgFile, atomically: true, encoding: .utf8)
            let source = try engine.listSources().first { $0.id == summary.sourceId }!
            try engine.updateSource(
                sourceId: source.id, name: source.name, url: source.url, epgUrl: "file://\(epgFile.path)"
            )
            _ = try await engine.refreshSourceEpg(sourceId: source.id, password: nil)
        }
        return summary.sourceId
    }
}

@MainActor
func eventually(timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}
