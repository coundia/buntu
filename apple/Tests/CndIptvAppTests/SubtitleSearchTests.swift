import XCTest
import CndCoreBridge
@testable import CndIptvApp

private final class FakeSubtitleBackend: SubtitleBackend, @unchecked Sendable {
    var results: [SubtitleSearchResult] = []
    /// Results per kind of query, for tests that need a fallback: "hash", "imdb" or "title".
    var resultsByKind: [String: [SubtitleSearchResult]]?
    var hash: String?
    private(set) var hashRequests: [Int64] = []
    var searchError: Error?
    var downloadError: Error?
    private(set) var queries: [(SubtitleSearchQuery, String?)] = []
    private(set) var downloads: [(Int64, String, String?)] = []

    func searchSubtitles(query: SubtitleSearchQuery, apiKey: String?) async throws -> [SubtitleSearchResult] {
        queries.append((query, apiKey))
        if let searchError { throw searchError }
        if let resultsByKind {
            let kind = query.moviehash != nil ? "hash" : (query.imdbId != nil ? "imdb" : (query.parentImdbId != nil ? "series" : "title"))
            return resultsByKind[kind] ?? []
        }
        return results
    }

    func computeStreamMoviehash(itemId: Int64) async throws -> String? {
        hashRequests.append(itemId)
        return hash
    }

    func downloadSubtitle(fileId: Int64, targetDir: String, apiKey: String?) async throws -> String {
        downloads.append((fileId, targetDir, apiKey))
        if let downloadError { throw downloadError }
        return targetDir + "/\(fileId).srt"
    }
}

@MainActor
final class SubtitleSearchTests: XCTestCase {
    private var keychain: KeychainStore!
    private var defaults: UserDefaults!
    private var suite = ""
    private var directory: URL!

    override func setUp() async throws {
        keychain = KeychainStore(service: "com.cnd.iptv.tests.subs.\(UUID().uuidString)")
        suite = "cnd.tests.subs.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        directory = try TestFixtures.makeTempDirectory()
    }

    override func tearDown() async throws {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? keychain.deleteSecret(forKey: OpenSubtitlesCredentials.keychainKey)
        try? FileManager.default.removeItem(at: directory)
    }

    private func result(_ fileId: Int64, language: String = "fr", release: String = "Film.2025.1080p") -> SubtitleSearchResult {
        SubtitleSearchResult(id: "\(fileId)", fileId: fileId, fileName: "\(fileId).srt", language: language, release: release, downloadCount: 120, rating: 8.5)
    }

    private func model(_ backend: SubtitleBackend, title: String = "EN  - Now You See Me: Now You Don't (2025) [1080p]") -> SubtitleSearchModel {
        SubtitleSearchModel(backend: backend, mediaTitle: title, keychain: keychain, defaults: defaults, cacheDirectory: directory)
    }

    func testCleansTheCatalogTitle() {
        XCTAssertEqual(SubtitleSearchModel.cleanTitle("EN  - Now You See Me: Now You Don't (2025) [1080p]"), "Now You See Me: Now You Don't 2025")
        XCTAssertEqual(SubtitleSearchModel.cleanTitle("#JeSuisLà (2020)"), "#JeSuisLà 2020")
        XCTAssertEqual(SubtitleSearchModel.cleanTitle("FR - Spider-Man [4K] [HDR]"), "Spider-Man")
        XCTAssertEqual(SubtitleSearchModel.cleanTitle("  Matrix  "), "Matrix")
    }

    func testWithoutAKeyThePersonIsToldWhereToAddIt() async {
        let backend = FakeSubtitleBackend()
        let search = model(backend)
        await search.search()
        guard case .failed(let message) = search.state else { return XCTFail("\(search.state)") }
        XCTAssertTrue(message.contains("Réglages"))
        XCTAssertTrue(backend.queries.isEmpty, "nothing is sent without a key")
    }

    func testSearchSendsOnlyTheCleanedTitleAndTheLanguages() async throws {
        try keychain.saveSecret("  my-key  ", forKey: OpenSubtitlesCredentials.keychainKey)
        defaults.set("fr", forKey: OpenSubtitlesCredentials.languagesDefaultsKey)
        let backend = FakeSubtitleBackend()
        backend.results = [result(1), result(2, language: "en")]
        let search = model(backend)

        await search.search()

        let (query, key) = try XCTUnwrap(backend.queries.first)
        XCTAssertEqual(query.query, "Now You See Me: Now You Don't 2025")
        XCTAssertEqual(query.languages, "fr")
        XCTAssertNil(query.moviehash)
        XCTAssertEqual(key, "my-key", "trimmed, and passed as a parameter only")
        guard case .results(let rows, _) = search.state else { return XCTFail("\(search.state)") }
        XCTAssertEqual(rows.map(\.fileId), [1, 2])
        XCTAssertEqual(rows.first?.release, "Film.2025.1080p")
    }

    func testDefaultLanguagesAreFrenchThenEnglish() {
        XCTAssertEqual(model(FakeSubtitleBackend()).languages, "fr,en")
    }

    private func movieModel(_ backend: FakeSubtitleBackend, imdb: String? = "tt1234567", seriesImdb: String? = nil, season: UInt32? = nil, episode: UInt32? = nil) -> SubtitleSearchModel {
        SubtitleSearchModel(
            backend: backend, mediaTitle: "FR - Matrix (1999) [1080p]", itemId: 42, imdbId: imdb, seriesImdbId: seriesImdb,
            seasonNumber: season, episodeNumber: episode,
            keychain: keychain, defaults: defaults, cacheDirectory: directory
        )
    }

    func testTheExactFileIsTriedFirstAndWinsWhenItMatches() async throws {
        try keychain.saveSecret("k", forKey: OpenSubtitlesCredentials.keychainKey)
        let backend = FakeSubtitleBackend()
        backend.hash = "8e245d9679d31e12"
        backend.resultsByKind = ["hash": [result(1)], "imdb": [result(2)], "title": [result(3)]]
        let search = movieModel(backend)
        await search.search()
        XCTAssertEqual(backend.hashRequests, [42])
        XCTAssertEqual(backend.queries.count, 1, "no need to try anything else")
        XCTAssertEqual(backend.queries.first?.0.moviehash, "8e245d9679d31e12")
        guard case .results(let rows, let match) = search.state else { return XCTFail("\(search.state)") }
        XCTAssertEqual(rows.map(\.fileId), [1])
        XCTAssertEqual(match, .file)
    }

    func testFallsBackToImdbThenToTheTitle() async throws {
        try keychain.saveSecret("k", forKey: OpenSubtitlesCredentials.keychainKey)
        let backend = FakeSubtitleBackend()
        backend.hash = nil // skipped: the subscription has no spare connection
        backend.resultsByKind = ["imdb": [result(2)], "title": [result(3)]]
        var search = movieModel(backend)
        await search.search()
        guard case .results(let rows, let match) = search.state else { return XCTFail() }
        XCTAssertEqual(rows.map(\.fileId), [2])
        XCTAssertEqual(match, .imdb)
        XCTAssertEqual(backend.queries.first?.0.imdbId, "tt1234567")
        XCTAssertNil(backend.queries.first?.0.query, "an exact id is not mixed with a title")

        backend.resultsByKind = ["title": [result(3)]]
        search = movieModel(backend)
        await search.search()
        guard case .results(_, let titleMatch) = search.state else { return XCTFail() }
        XCTAssertEqual(titleMatch, .title)
    }

    func testAnEpisodeSearchesTheTitleWithItsSeasonAndEpisode() async throws {
        try keychain.saveSecret("k", forKey: OpenSubtitlesCredentials.keychainKey)
        let backend = FakeSubtitleBackend()
        backend.resultsByKind = ["title": [result(5)]]
        let search = movieModel(backend, imdb: "tt999", season: 2, episode: 7)
        await search.search()
        let query = try XCTUnwrap(backend.queries.last?.0)
        XCTAssertEqual(query.seasonNumber, 2)
        XCTAssertEqual(query.episodeNumber, 7)
        XCTAssertNil(query.imdbId, "an episode's own id is not sent as the series id")
    }

    func testAnEpisodeIsMatchedThroughItsSeriesBeforeTheTitle() async throws {
        try keychain.saveSecret("k", forKey: OpenSubtitlesCredentials.keychainKey)
        let backend = FakeSubtitleBackend()
        backend.resultsByKind = ["series": [result(8)], "title": [result(9)]]
        var search = movieModel(backend, imdb: nil, seriesImdb: "tt0944947", season: 2, episode: 7)
        await search.search()
        guard case .results(let rows, let match) = search.state else { return XCTFail("\(search.state)") }
        XCTAssertEqual(rows.map(\.fileId), [8])
        XCTAssertEqual(match, .series)
        let query = try XCTUnwrap(backend.queries.first?.0)
        XCTAssertEqual(query.parentImdbId, "tt0944947")
        XCTAssertEqual(query.seasonNumber, 2)
        XCTAssertEqual(query.episodeNumber, 7)
        XCTAssertNil(query.imdbId)

        // Without a known series id (not enriched yet) it falls back to the title.
        backend.resultsByKind = ["title": [result(9)]]
        search = movieModel(backend, imdb: nil, seriesImdb: nil, season: 2, episode: 7)
        await search.search()
        guard case .results(_, let fallback) = search.state else { return XCTFail() }
        XCTAssertEqual(fallback, .title)
    }

    func testNoResultAndErrorsAreExplained() async throws {
        try keychain.saveSecret("k", forKey: OpenSubtitlesCredentials.keychainKey)
        let backend = FakeSubtitleBackend()
        let search = model(backend)
        await search.search()
        guard case .failed(let none) = search.state else { return XCTFail() }
        XCTAssertTrue(none.contains("Aucun sous-titre"))

        backend.searchError = CndError.Network(message: "quota dépassé")
        await search.search()
        XCTAssertEqual(search.state, .failed("quota dépassé"))
    }

    func testDownloadHandsTheFileToThePlayer() async throws {
        try keychain.saveSecret("k", forKey: OpenSubtitlesCredentials.keychainKey)
        let backend = FakeSubtitleBackend()
        backend.results = [result(7)]
        let search = model(backend)
        var received: URL?
        search.onDownloaded = { received = $0 }
        await search.search()
        guard case .results(let rows, _) = search.state else { return XCTFail() }

        await search.download(rows[0])

        XCTAssertEqual(backend.downloads.first?.0, 7)
        XCTAssertEqual(backend.downloads.first?.1, directory.path, "files are cached in the app's own folder")
        XCTAssertEqual(received?.lastPathComponent, "7.srt")
        XCTAssertNil(search.downloadingId)
    }

    func testAFailedDownloadIsReported() async throws {
        try keychain.saveSecret("k", forKey: OpenSubtitlesCredentials.keychainKey)
        let backend = FakeSubtitleBackend()
        backend.results = [result(7)]
        backend.downloadError = CndError.Network(message: "limite de téléchargements")
        let search = model(backend)
        var called = false
        search.onDownloaded = { _ in called = true }
        await search.search()
        guard case .results(let rows, _) = search.state else { return XCTFail() }
        await search.download(rows[0])
        XCTAssertFalse(called)
        XCTAssertEqual(search.state, .failed("limite de téléchargements"))
    }

    func testTheOldPreferencesKeyMovesToTheKeychain() throws {
        defaults.set("legacy-key", forKey: OpenSubtitlesCredentials.legacyDefaultsKey)
        OpenSubtitlesCredentials.migrateLegacyKey(keychain: keychain, defaults: defaults)
        XCTAssertEqual(OpenSubtitlesCredentials.apiKey(keychain: keychain), "legacy-key")
        XCTAssertNil(defaults.string(forKey: OpenSubtitlesCredentials.legacyDefaultsKey), "no copy stays in preferences")

        // An existing Keychain key is never overwritten by an old preference.
        defaults.set("other", forKey: OpenSubtitlesCredentials.legacyDefaultsKey)
        OpenSubtitlesCredentials.migrateLegacyKey(keychain: keychain, defaults: defaults)
        XCTAssertEqual(OpenSubtitlesCredentials.apiKey(keychain: keychain), "legacy-key")
        XCTAssertNil(defaults.string(forKey: OpenSubtitlesCredentials.legacyDefaultsKey))
    }
}
