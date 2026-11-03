import Foundation
import CndCoreBridge

/// Where downloads are written by default.
enum DownloadLocation {
    static let defaultsKey = "downloads.directory"

    /// Visible in the Files app on iOS (`Documents/Downloads`), `~/Downloads/CndIPTV` on macOS.
    static var platformDefault: URL {
        #if os(macOS)
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        return downloads.appendingPathComponent("CndIPTV", isDirectory: true)
        #else
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return documents.appendingPathComponent("Downloads", isDirectory: true)
        #endif
    }

    /// The folder chosen in Settings (kept in `UserDefaults` by `DownloadDirectoryManager`), else the default.
    static var baseDirectory: URL {
        if let path = UserDefaults.standard.string(forKey: defaultsKey), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return platformDefault
    }
}

/// Builds the requests sent to the Rust download engine. Every title that ends up in a path is
/// sanitised here, so a hostile or messy playlist entry cannot escape the target folder.
enum DownloadPlanner {
    static func sanitize(_ raw: String, fallback: String = "video", maxLength: Int = 120) -> String {
        let mapped = String(raw.map { character -> Character in
            if character.isWhitespace { return " " }
            if "/\\:*?\"<>|".contains(character) { return "_" }
            if character.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) { return "_" }
            return character
        })
        let collapsed = mapped.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        var trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
        if trimmed.count > maxLength { trimmed = String(trimmed.prefix(maxLength)).trimmingCharacters(in: .whitespaces) }
        return trimmed.isEmpty ? fallback : trimmed
    }

    static func fileExtension(for item: IptvItemRecord) -> String {
        func clean(_ value: String?) -> String? {
            guard let value else { return nil }
            let lowered = value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            guard (1...5).contains(lowered.count), lowered.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
            return lowered
        }
        if let ext = clean(item.containerExt) { return ext }
        if let url = URL(string: item.streamUrl), let ext = clean(url.pathExtension), !["php", "html", "m3u8"].contains(ext) {
            return ext
        }
        return "mp4"
    }

    private static func request(_ item: IptvItemRecord, fileName: String, saveDir: URL) -> NewDownloadRequest {
        NewDownloadRequest(
            url: item.streamUrl,
            fileName: fileName,
            saveDir: saveDir.path,
            userAgent: item.userAgent,
            referer: item.referer,
            headersJson: item.headersJson,
            autoStart: true
        )
    }

    // MARK: Movies

    static func movieFileName(_ item: IptvItemRecord) -> String {
        let title = sanitize(item.nameClean.isEmpty ? item.name : item.nameClean)
        let year = item.year.map { " (\($0))" } ?? ""
        return "\(title)\(year).\(fileExtension(for: item))"
    }

    static func movieRequest(_ item: IptvItemRecord, baseDirectory: URL) -> NewDownloadRequest {
        request(item, fileName: movieFileName(item), saveDir: baseDirectory)
    }

    // MARK: Series

    static func seasonDirectory(base: URL, seriesTitle: String, season: UInt32) -> URL {
        base
            .appendingPathComponent(sanitize(seriesTitle, fallback: "Series"), isDirectory: true)
            .appendingPathComponent(String(format: "Season %02d", season), isDirectory: true)
    }

    /// `S01E02 - Title.mkv`. The series name and the `SxxEyy` marker are stripped from the title
    /// first, since playlists usually repeat them in every episode name.
    static func episodeFileName(_ item: IptvItemRecord, seriesTitle: String) -> String {
        let ext = fileExtension(for: item)
        let season = item.seasonNum ?? 1
        guard let episode = item.episodeNum else {
            return "\(sanitize(item.nameClean.isEmpty ? item.name : item.nameClean)).\(ext)"
        }
        let tag = String(format: "S%02dE%02d", season, episode)
        let remainder = episodeTitle(item.nameClean.isEmpty ? item.name : item.nameClean, seriesTitle: seriesTitle)
        return remainder.isEmpty ? "\(tag).\(ext)" : "\(tag) - \(sanitize(remainder)).\(ext)"
    }

    static func episodeTitle(_ name: String, seriesTitle: String) -> String {
        var text = name
        if let range = text.range(of: seriesTitle, options: [.caseInsensitive, .anchored, .diacriticInsensitive]) {
            text.removeSubrange(range)
        }
        let markers = [
            #"(?i)\bS\d{1,2}\s*E\d{1,3}\b"#,
            #"(?i)\b(?:Season|Saison)\s*\d{1,2}\D*?(?:Ep|Episode|Épisode|E)\s*\d{1,3}\b"#,
        ]
        for pattern in markers {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        return text.trimmingCharacters(in: CharacterSet(charactersIn: " -_.:").union(.whitespaces))
    }

    static func episodeRequest(_ item: IptvItemRecord, seriesTitle: String, baseDirectory: URL) -> NewDownloadRequest {
        let directory = seasonDirectory(base: baseDirectory, seriesTitle: seriesTitle, season: item.seasonNum ?? 1)
        return request(item, fileName: episodeFileName(item, seriesTitle: seriesTitle), saveDir: directory)
    }

    static func seasonRequests(
        seriesTitle: String,
        episodes: [IptvItemRecord],
        baseDirectory: URL
    ) -> [NewDownloadRequest] {
        episodes.map { episodeRequest($0, seriesTitle: seriesTitle, baseDirectory: baseDirectory) }
    }
}

enum TimeFormat {
    /// `1:02:03` or `42:15`.
    static func hms(milliseconds: Int64) -> String {
        let total = max(0, Int(milliseconds / 1000))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}
