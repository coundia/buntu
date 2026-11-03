import Foundation
import Observation
import CndCoreBridge

/// The slice of `CndEngine` the subtitle search uses; scripted in tests.
protocol SubtitleBackend: AnyObject, Sendable {
    func searchSubtitles(query: SubtitleSearchQuery, apiKey: String?) async throws -> [SubtitleSearchResult]
    func downloadSubtitle(fileId: Int64, targetDir: String, apiKey: String?) async throws -> String
    func subtitlesSignIn(username: String, password: String, apiKey: String?) async throws -> SubtitleAccount
    func subtitlesSignedIn() -> Bool
    /// OpenSubtitles hash of the item's stream; `nil` when skipped (see the engine: only with a spare connection).
    func computeStreamMoviehash(itemId: Int64) async throws -> String?
}

extension CndEngine: SubtitleBackend {}

/// The OpenSubtitles API key lives in the Keychain, never in preferences or the database.
enum OpenSubtitlesCredentials {
    static let keychainKey = "cnd.opensubtitles.apikey"
    static let userKey = "cnd.opensubtitles.user"
    static let passwordKey = "cnd.opensubtitles.password"
    static let autoSearchDefaultsKey = "openSubtitlesAutoSearch"
    static let legacyDefaultsKey = "openSubtitlesApiKey"
    static let languagesDefaultsKey = "openSubtitlesLanguages"

    static func apiKey(keychain: KeychainStore = .shared) -> String? {
        guard let key = try? keychain.readSecret(forKey: keychainKey) else { return nil }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The optional account (lifts the daily download quota). Both parts or nothing.
    static func account(keychain: KeychainStore = .shared) -> (username: String, password: String)? {
        guard let user = try? keychain.readSecret(forKey: userKey)?.trimmingCharacters(in: .whitespacesAndNewlines), !user.isEmpty,
              let password = try? keychain.readSecret(forKey: passwordKey), !password.isEmpty else { return nil }
        return (user, password)
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

    /// How the results were found, best first: the exact file, the IMDb title, or the plain title.
    enum Match: Equatable {
        case file
        case imdb
        case series
        case title

        var description: String {
            switch self {
            case .file: return "Correspondance exacte avec ce fichier"
            case .imdb: return "Trouvés par identifiant IMDb"
            case .series: return "Trouvés par la série (IMDb), saison et épisode"
            case .title: return "Trouvés par titre : la synchronisation peut demander un réglage"
            }
        }
    }

    enum State: Equatable {
        case idle
        case searching
        case results([Row], Match)
        case failed(String)
    }

    let backend: SubtitleBackend
    let mediaTitle: String
    private let itemId: Int64?
    private let imdbId: String?
    private let seriesImdbId: String?
    private let seasonNumber: UInt32?
    private let episodeNumber: UInt32?
    private let keychain: KeychainStore
    private let defaults: UserDefaults
    private let cacheDirectory: URL
    @ObservationIgnored var onDownloaded: (URL) -> Void = { _ in }

    private(set) var state: State = .idle
    private(set) var accountNote: String?
    private(set) var downloadingId: Int64?
    private(set) var downloadedName: String?

    init(
        backend: SubtitleBackend,
        mediaTitle: String,
        itemId: Int64? = nil,
        imdbId: String? = nil,
        seriesImdbId: String? = nil,
        seasonNumber: UInt32? = nil,
        episodeNumber: UInt32? = nil,
        keychain: KeychainStore = .shared,
        defaults: UserDefaults = .standard,
        cacheDirectory: URL? = nil
    ) {
        self.backend = backend
        self.mediaTitle = mediaTitle
        self.itemId = itemId
        self.imdbId = imdbId
        self.seriesImdbId = seriesImdbId
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
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

    /// Signs in with the stored account, when there is one and no session yet. A refusal is reported but never
    /// blocks the search: the anonymous quota still works.
    private func ensureSignedIn(apiKey: String) async {
        guard let account = OpenSubtitlesCredentials.account(keychain: keychain), !backend.subtitlesSignedIn() else { return }
        do {
            _ = try await backend.subtitlesSignIn(username: account.username, password: account.password, apiKey: apiKey)
            accountNote = nil
        } catch {
            accountNote = "Connexion OpenSubtitles impossible (\(userMessage(for: error))) : la recherche continue sans compte."
        }
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
        await ensureSignedIn(apiKey: apiKey)
        let isEpisode = seasonNumber != nil && episodeNumber != nil
        let languages = self.languages
        let title = cleanedTitle
        // Best match first: the exact file (hash), then the IMDb title, then the plain title.
        var attempts: [(Match, SubtitleSearchQuery)] = []
        if let itemId, let hash = try? await backend.computeStreamMoviehash(itemId: itemId), !hash.isEmpty {
            attempts.append((.file, SubtitleSearchQuery(
                query: nil, imdbId: nil, parentImdbId: nil, moviehash: hash, seasonNumber: nil, episodeNumber: nil, languages: languages
            )))
        }
        if let imdb = imdbId?.trimmingCharacters(in: .whitespaces), !imdb.isEmpty, !isEpisode {
            attempts.append((.imdb, SubtitleSearchQuery(
                query: nil, imdbId: imdb, parentImdbId: nil, moviehash: nil, seasonNumber: nil, episodeNumber: nil, languages: languages
            )))
        }
        if isEpisode, let series = seriesImdbId?.trimmingCharacters(in: .whitespaces), !series.isEmpty {
            attempts.append((.series, SubtitleSearchQuery(
                query: nil, imdbId: nil, parentImdbId: series, moviehash: nil,
                seasonNumber: seasonNumber, episodeNumber: episodeNumber, languages: languages
            )))
        }
        attempts.append((.title, SubtitleSearchQuery(
            query: title, imdbId: nil, parentImdbId: nil, moviehash: nil, seasonNumber: seasonNumber, episodeNumber: episodeNumber, languages: languages
        )))

        var lastError: Error?
        for (match, query) in attempts {
            do {
                let found = try await backend.searchSubtitles(query: query, apiKey: apiKey)
                let rows = found.map {
                    Row(fileId: $0.fileId, language: $0.language, release: $0.release.isEmpty ? $0.fileName : $0.release,
                        downloads: $0.downloadCount, rating: $0.rating)
                }
                if !rows.isEmpty {
                    state = .results(rows, match)
                    return
                }
            } catch {
                lastError = error
            }
        }
        if let lastError {
            state = .failed(userMessage(for: lastError))
        } else {
            state = .failed("Aucun sous-titre trouvé pour « \(title) ».")
        }
    }

    func download(_ row: Row) async {
        guard downloadingId == nil, let apiKey = OpenSubtitlesCredentials.apiKey(keychain: keychain) else { return }
        downloadingId = row.fileId
        defer { downloadingId = nil }
        await ensureSignedIn(apiKey: apiKey)
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


/// Automatic subtitle search (off by default): when a film or episode starts without a subtitle track in the
/// preferred language, search and load the best online match.
enum AutoSubtitlePolicy {
    private static let aliases: [String: String] = [
        "fra": "fr", "fre": "fr", "french": "fr", "français": "fr", "francais": "fr",
        "eng": "en", "english": "en", "anglais": "en",
        "spa": "es", "spanish": "es", "deu": "de", "ger": "de", "german": "de",
        "ita": "it", "italian": "it", "por": "pt", "portuguese": "pt", "ara": "ar", "arabic": "ar",
        "nld": "nl", "dut": "nl", "dutch": "nl",
    ]

    /// "fr,en" -> ["fr", "en"], normalised to two letters.
    static func preferred(_ languages: String) -> [String] {
        languages.split(separator: ",").map { normalize(String($0)) }.filter { !$0.isEmpty }
    }

    static func normalize(_ language: String) -> String {
        let value = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let mapped = aliases[value] { return mapped }
        // "fr-FR", "pt_BR" -> the first two letters.
        let head = value.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? value
        return aliases[head] ?? String(head.prefix(2))
    }

    static func hasTrack(_ tracks: [MediaTrack], in languages: [String]) -> Bool {
        tracks.contains { track in
            guard let language = track.language else { return false }
            return languages.contains(normalize(language))
        }
    }

    static func shouldSearch(media: PlayableMedia, tracks: [MediaTrack], overlayLoaded: Bool, languages: String, enabled: Bool, hasKey: Bool) -> Bool {
        guard enabled, hasKey, media.kind != .live, !overlayLoaded else { return false }
        let wanted = preferred(languages)
        guard !wanted.isEmpty else { return false }
        return !hasTrack(tracks, in: wanted)
    }

    /// The first preferred language wins, then the most downloaded file.
    static func best(of rows: [SubtitleSearchModel.Row], languages: String) -> SubtitleSearchModel.Row? {
        let wanted = preferred(languages)
        func rank(_ row: SubtitleSearchModel.Row) -> Int { wanted.firstIndex(of: normalize(row.language)) ?? wanted.count }
        return rows.min { a, b in
            let (ra, rb) = (rank(a), rank(b))
            return ra != rb ? ra < rb : a.downloads > b.downloads
        }
    }
}
