import XCTest
@testable import CndCoreBridge

final class CndCoreBridgeTests: XCTestCase {
    func testRustEngineInitAndStats() throws {
        let engine = try CndEngine.inMemory()
        XCTAssertEqual(engine.version(), "1.0.0-native-rust")
        
        let stats = try engine.getStats()
        XCTAssertEqual(stats.totalSources, 0)
        XCTAssertEqual(stats.totalLiveChannels, 0)
        
        let srcId = try engine.addSource(
            name: "Test Swift Source",
            sourceType: "m3u",
            url: "http://example.com/stream.m3u?password=mySecretPassword",
            server: nil,
            username: nil,
            passwordRef: nil
        )
        XCTAssertGreaterThan(srcId, 0)
        
        let sources = try engine.listSources()
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources[0].name, "Test Swift Source")
    }

    func testRuntimeSettingsAndTelemetryBridge() throws {
        let engine = try CndEngine.inMemory()
        var settings = engine.getSettings()
        XCTAssertEqual(settings.segmentsPerFile, 4)
        XCTAssertEqual(settings.defaultUserAgent, "VLC/3.0.21 LibVLC/3.0.21")

        settings.segmentsPerFile = 8
        settings.showNetworkConsole = true
        try engine.updateSettings(settings: settings)

        let updated = engine.getSettings()
        XCTAssertEqual(updated.segmentsPerFile, 8)
        XCTAssertTrue(updated.showNetworkConsole)

        _ = try engine.addSource(
            name: "Secret Source",
            sourceType: "m3u",
            url: "http://srv:8080/get.php?username=bob&password=secret123&apikey=abcd",
            server: nil,
            username: nil,
            passwordRef: nil
        )

        let logs = engine.getLogsSince(afterSeqId: 0, limit: 50)
        XCTAssertGreaterThanOrEqual(logs.count, 2)
        for entry in logs {
            if let redacted = entry.urlRedacted {
                XCTAssertFalse(redacted.contains("secret123"))
                XCTAssertFalse(redacted.contains("abcd"))
            }
        }

        engine.clearLogs()
        XCTAssertEqual(engine.getLogsSince(afterSeqId: 0, limit: 50).count, 0)
    }

    func testImportLocalM3uAndSeriesGrouping() async throws {
        let engine = try CndEngine.inMemory()
        let tempUrl = FileManager.default.temporaryDirectory
            .appendingPathComponent("cnd_bridge_test_\(UUID().uuidString).m3u")
        let m3uContent = """
        #EXTM3U x-tvg-url="http://epg.example.com/tv.xml.gz"
        #EXTINF:-1 tvg-id="arte.fr" group-title="France",|FR| ARTE FHD
        http://live.example.com/arte.m3u8
        #EXTINF:-1 group-title="Films",Dune: Part Two (2024) 4K HDR
        http://vod.example.com/movie/dune2.mkv
        #EXTINF:-1 group-title="Séries",|FR| Silo S01E01 VOSTFR
        http://vod.example.com/series/silo_s01e01.mkv
        #EXTINF:-1 group-title="Séries",|FR| Silo S02E01 VOSTFR
        http://vod.example.com/series/silo_s02e01.mkv
        """
        try m3uContent.write(to: tempUrl, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempUrl) }

        let summary = try await engine.importLocalM3u(
            name: "Local M3U Test",
            filePath: tempUrl.path
        )
        XCTAssertEqual(summary.totalItems, 4)
        XCTAssertEqual(summary.liveCount, 1)
        XCTAssertEqual(summary.movieCount, 1)
        XCTAssertEqual(summary.seriesCount, 1)
        XCTAssertEqual(summary.episodeCount, 2)

        try engine.updateSource(
            sourceId: summary.sourceId,
            name: "Renamed Local M3U",
            url: "file://\(tempUrl.path)",
            epgUrl: "http://epg.example.com/custom.xml"
        )
        let sources = try engine.listSources()
        XCTAssertEqual(sources.first?.name, "Renamed Local M3U")

        try engine.deleteSource(sourceId: summary.sourceId)
        XCTAssertEqual(try engine.listSources().count, 0)
    }

    func testStreamingXmltvEpgBridge() async throws {
        let engine = try CndEngine.inMemory()
        let m3uUrl = FileManager.default.temporaryDirectory
            .appendingPathComponent("cnd_epg_m3u_\(UUID().uuidString).m3u")
        let epgUrl = FileManager.default.temporaryDirectory
            .appendingPathComponent("cnd_epg_xml_\(UUID().uuidString).xml")
        defer {
            try? FileManager.default.removeItem(at: m3uUrl)
            try? FileManager.default.removeItem(at: epgUrl)
        }

        let now = Int64(Date().timeIntervalSince1970)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let startStr = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(now - 900)))
        let midStr = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(now + 900)))
        let endStr = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(now + 4500)))

        let m3u = """
        #EXTM3U x-tvg-url="file://\(epgUrl.path)"
        #EXTINF:-1 tvg-id="f2.fr" group-title="France",France 2 HD
        http://live.example.com/f2.m3u8
        """
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tv>
          <programme start="\(startStr) +0000" stop="\(midStr) +0000" channel="f2.fr">
            <title>Télématin</title>
          </programme>
          <programme start="\(midStr) +0000" stop="\(endStr) +0000" channel="f2.fr">
            <title>Journal de 13h</title>
          </programme>
        </tv>
        """
        try m3u.write(to: m3uUrl, atomically: true, encoding: .utf8)
        try xml.write(to: epgUrl, atomically: true, encoding: .utf8)

        let summary = try await engine.importLocalM3u(name: "EPG Test Source", filePath: m3uUrl.path)
        let importedCount = try await engine.refreshSourceEpg(sourceId: summary.sourceId, password: nil)
        XCTAssertEqual(importedCount, 2)

        let nowNext = try engine.getEpgNowNext(tvgIds: ["f2.fr"])
        XCTAssertEqual(nowNext.count, 1)
        XCTAssertEqual(nowNext[0].now?.title, "Télématin")
        XCTAssertEqual(nowNext[0].next?.title, "Journal de 13h")
        if let ratio = nowNext[0].now?.progressRatio {
            XCTAssertGreaterThan(ratio, 0.4)
            XCTAssertLessThan(ratio, 0.7)
        } else {
            XCTFail("Expected progressRatio on active EPG program")
        }

        let timeline = try engine.getChannelEpg(tvgId: "f2.fr", fromTs: now - 3600, toTs: now + 7200)
        XCTAssertEqual(timeline.count, 2)
    }

    func testCatalogFacetsFavoritesSeriesAndWatchHistoryBridge() async throws {
        let engine = try CndEngine.inMemory()
        let tempUrl = FileManager.default.temporaryDirectory
            .appendingPathComponent("cnd_catalog_test_\(UUID().uuidString).m3u")
        let m3uContent = """
        #EXTM3U
        #EXTINF:-1 group-title="Marvel",Spider-Man: No Way Home (2021)
        http://vod.example.com/movie/spidey.mkv
        #EXTINF:-1 group-title="Sci-Fi",|FR| Severance S01E01 VOSTFR
        http://vod.example.com/series/sev_101.mkv
        #EXTINF:-1 group-title="Sci-Fi",|FR| Severance S01E02 VOSTFR
        http://vod.example.com/series/sev_102.mkv
        """
        try m3uContent.write(to: tempUrl, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempUrl) }

        _ = try await engine.importLocalM3u(name: "Catalog Bridge", filePath: tempUrl.path)

        let movieGroups = try engine.getGroups(kind: "movie", sourceId: nil)
        XCTAssertEqual(movieGroups.count, 1)
        XCTAssertEqual(movieGroups[0].value, "Marvel")

        let movies = try engine.queryCatalog(
            filter: CatalogFilter(
                kind: "movie",
                sourceId: nil,
                query: "Spider-Man: No Way (2021)",
                groupTitle: nil,
                host: nil,
                favoritesOnly: false,
                includeBroken: false,
                includeHidden: false,
                sortBy: .name,
                sortAsc: true,
                limit: 20,
                offset: 0
            )
        )
        XCTAssertEqual(movies.count, 1)
        let spidey = movies[0]

        _ = try engine.toggleFavorite(stableHash: spidey.stableHash, itemKind: "movie")
        XCTAssertEqual(try engine.listFavoriteItems(kind: "movie").count, 1)

        try engine.recordWatchProgress(stableHash: spidey.stableHash, positionMs: 95_000, durationMs: 100_000)
        let recentMovies = try engine.listRecentItems(kind: "movie", limit: 10)
        XCTAssertEqual(recentMovies.count, 1)
        XCTAssertTrue(recentMovies[0].isCompleted)

        let seriesList = try engine.querySeries(
            filter: CatalogFilter(
                kind: "series",
                sourceId: nil,
                query: "Severance",
                groupTitle: nil,
                host: nil,
                favoritesOnly: false,
                includeBroken: false,
                includeHidden: false,
                sortBy: .name,
                sortAsc: true,
                limit: 20,
                offset: 0
            )
        )
        XCTAssertEqual(seriesList.count, 1)
        let sev = seriesList[0]
        XCTAssertFalse(sev.stableHash.isEmpty)

        _ = try engine.toggleFavorite(stableHash: sev.stableHash, itemKind: "series")
        XCTAssertEqual(try engine.listFavoriteSeries().count, 1)

        // Broken flag tests
        XCTAssertFalse(try engine.isBroken(stableHash: spidey.stableHash))
        XCTAssertTrue(try engine.toggleBroken(stableHash: spidey.stableHash, itemKind: "movie"))
        XCTAssertTrue(try engine.isBroken(stableHash: spidey.stableHash))
        XCTAssertEqual(try engine.listBrokenItems(kind: "movie").count, 1)

        // With includeBroken = false, Spider-Man must not be returned
        let hiddenMovies = try engine.queryCatalog(
            filter: CatalogFilter(
                kind: "movie",
                sourceId: nil,
                query: "Spider-Man",
                groupTitle: nil,
                host: nil,
                favoritesOnly: false,
                includeBroken: false,
                includeHidden: false,
                sortBy: .name,
                sortAsc: true,
                limit: 20,
                offset: 0
            )
        )
        XCTAssertEqual(hiddenMovies.count, 0)

        // With includeBroken = true, it is returned and marked isBroken
        let visibleMovies = try engine.queryCatalog(
            filter: CatalogFilter(
                kind: "movie",
                sourceId: nil,
                query: "Spider-Man",
                groupTitle: nil,
                host: nil,
                favoritesOnly: false,
                includeBroken: true,
                includeHidden: false,
                sortBy: .name,
                sortAsc: true,
                limit: 20,
                offset: 0
            )
        )
        XCTAssertEqual(visibleMovies.count, 1)
        XCTAssertTrue(visibleMovies[0].isBroken)

        // Unflag
        XCTAssertFalse(try engine.toggleBroken(stableHash: spidey.stableHash, itemKind: "movie"))
        XCTAssertFalse(try engine.isBroken(stableHash: spidey.stableHash))

        let seasons = try engine.getSeriesSeasons(seriesId: sev.id)
        XCTAssertEqual(seasons.count, 1)
        let episodes = try engine.getSeriesEpisodes(seriesId: sev.id, seasonNum: 1)
        XCTAssertEqual(episodes.count, 2)

        try engine.recordWatchProgress(stableHash: episodes[0].stableHash, positionMs: 300_000, durationMs: 2_400_000)
        XCTAssertEqual(try engine.listRecentSeries(limit: 10).count, 1)

        // PRD-06: empty OMDb API key must return nil cleanly with zero errors
        let emptyMeta = try await engine.fetchItemMetadata(itemId: spidey.id, apiKey: "", forceRefresh: false)
        XCTAssertNil(emptyMeta)
        let emptySeriesMeta = try await engine.fetchSeriesMetadata(seriesId: sev.id, apiKey: "   ", forceRefresh: false)
        XCTAssertNil(emptySeriesMeta)
    }
}
