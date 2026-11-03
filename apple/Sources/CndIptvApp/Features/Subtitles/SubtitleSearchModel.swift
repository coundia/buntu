import Foundation
import Observation
import CndCoreBridge

/// The slice of `CndEngine` the subtitle search uses; scripted in tests.
protocol SubtitleBackend: AnyObject, Sendable {
    func searchSubtitles(query: SubtitleSearchQuery, apiKey: String?) async throws -> [SubtitleSearchResult]
    func downloadSubtitle(fileId: Int64, targetDir: String, apiKey: String?) async throws -> String
}

extension CndEngine: SubtitleBackend {}

/// The OpenSubtitles API key lives in the Keychain, never in preferences or the database.
enum OpenSubtitlesCredentials {
    static let keychainKey = "cnd.opensubtitles.apikey"
    static let legacyDefaultsKey = "openSubtitlesApiKey"
    static let languagesDefaultsKey = "openSubtitlesLanguages"

    static func apiKey(keychain: KeychainStore = .shared) -> String? {
        guard let key = try? keychain.readSecret(forKey: keychainKey) else { return nil }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// An earlier version kept the key in `UserDefaults`: it moves to the Keychain and is erased.
    static func migrateLegacyKey(keychain: KeychainStore = .shared, defaults: UserDefaults = .standard) {
        guard let legacy = defaults.string(forKey: legacyDefaultsKey) else { return }
        defer { defaults.removeObject(forKey: legacyDefaultsKey) }
        let trimmed = legacy.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, (try? keychain.readSecret(forKey: keychainKey)) == nil else { return }
        try? keychain.saveSecret(trimmed, forKey: keychainKey)
    }
}

/// Searches OpenSubtitles for the media being played and downloads the chosen file. Only the cleaned
/// title and the languages are sent: never the stream address.
@Observable
@MainActor
final class SubtitleSearchModel {
    struct Row: Identifiable, Equatable {
        let fileId: Int64
        let language: String
        let release: String
        let downloads: UInt32
        let rating: Double
        var id: Int64 { fileId }
    }

    enum State: Equatable {
        case idle
        case searching
        case results([Row])
        case failed(String)
    }

    let backend: SubtitleBackend
    let mediaTitle: String
    private let keychain: KeychainStore
    private let defaults: UserDefaults
    private let cacheDirectory: URL
    @ObservationIgnored var onDownloaded: (URL) -> Void = { _ in }

    private(set) var state: State = .idle
    private(set) var downloadingId: Int64?
    private(set) var downloadedName: String?

    init(
        backend: SubtitleBackend,
        mediaTitle: String,
        keychain: KeychainStore = .shared,
        defaults: UserDefaults = .standard,
        cacheDirectory: URL? = nil
    ) {
        self.backend = backend
        self.mediaTitle = mediaTitle
        self.keychain = keychain
        self.defaults = defaults
        self.cacheDirectory = cacheDirectory ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CndSubtitles", isDirectory: true)
    }

    var languages: String {
        let value = defaults.string(forKey: OpenSubtitlesCredentials.languagesDefaultsKey) ?? ""
        return value.trimmingCharacters(in: .whitespaces).isEmpty ? "fr,en" : value
    }

    var cleanedTitle: String { Self.cleanTitle(mediaTitle) }

    /// "EN  - Now You See Me: Now You Don't (2025) [1080p]" -> "Now You See Me: Now You Don't 2025".
    nonisolated static func cleanTitle(_ raw: String) -> String {
        var text = raw
        text = text.replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"^\s*[A-Za-z]{2,3}\s+-\s+"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\((\d{4})\)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func search() async {
        guard let apiKey = OpenSubtitlesCredentials.apiKey(keychain: keychain) else {
            state = .failed("Ajoutez votre clé API OpenSubtitles dans Réglages > Sous-titres en ligne.")
            return
        }
        guard !cleanedTitle.isEmpty else {
            state = .failed("Titre introuvable pour la recherche.")
            return
        }
        state = .searching
        let query = SubtitleSearchQuery(
            query: cleanedTitle, imdbId: nil, moviehash: nil, seasonNumber: nil, episodeNumber: nil, languages: languages
        )
        do {
            let found = try await backend.searchSubtitles(query: query, apiKey: apiKey)
            let rows = found.map {
                Row(fileId: $0.fileId, language: $0.language, release: $0.release.isEmpty ? $0.fileName : $0.release,
                    downloads: $0.downloadCount, rating: $0.rating)
            }
            state = rows.isEmpty ? .failed("Aucun sous-titre trouvé pour « \(cleanedTitle) ».") : .results(rows)
        } catch {
            state = .failed(userMessage(for: error))
        }
    }

    func download(_ row: Row) async {
        guard downloadingId == nil, let apiKey = OpenSubtitlesCredentials.apiKey(keychain: keychain) else { return }
        downloadingId = row.fileId
        defer { downloadingId = nil }
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            let path = try await backend.downloadSubtitle(fileId: row.fileId, targetDir: cacheDirectory.path, apiKey: apiKey)
            let url = URL(fileURLWithPath: path)
            downloadedName = row.release
            onDownloaded(url)
        } catch {
            state = .failed(userMessage(for: error))
        }
    }
}
