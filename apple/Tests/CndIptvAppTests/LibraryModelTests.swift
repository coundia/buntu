import XCTest
import CndCoreBridge
@testable import CndIptvKit

@MainActor
final class LibraryModelTests: XCTestCase {
    private var engine: CndEngine!
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try TestFixtures.makeTempDirectory()
        engine = try CndEngine.inMemory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testFolderAccessBookmarkAndSecurityAccess() throws {
        let subDir = tempDir.appendingPathComponent("TestMediaFolder")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)

        let bookmark = FolderAccess.createBookmark(for: subDir)
        XCTAssertNotNil(bookmark, "Security-scoped bookmark should be created")

        if let bookmark {
            let resolved = FolderAccess.resolveBookmark(data: bookmark)
            XCTAssertNotNil(resolved, "Bookmark should resolve successfully")
            if let resolved {
                XCTAssertTrue(resolved.isAvailable, "Resolved URL should be available on disk")
                XCTAssertEqual(resolved.url.standardizedFileURL.path, subDir.standardizedFileURL.path)
            }
        }

        var closureExecuted = false
        let result = FolderAccess.withSecurityAccess(for: subDir) {
            closureExecuted = true
            return 42
        }
        XCTAssertTrue(closureExecuted)
        XCTAssertEqual(result, 42)
    }

    func testLibraryScanAndMediaClassification() async throws {
        let mediaDir = tempDir.appendingPathComponent("MediaCollection")
        try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)

        // 1. Create a dummy video file and companion subtitle
        let videoFile = mediaDir.appendingPathComponent("Inception.2010.mp4")
        let subFile = mediaDir.appendingPathComponent("Inception.2010.srt")
        try "video dummy content 1234567890".write(to: videoFile, atomically: true, encoding: .utf8)
        try "1\n00:00:01,000 --> 00:00:04,000\nHello world\n".write(to: subFile, atomically: true, encoding: .utf8)

        // 2. Create a dummy audio file
        let audioFile = mediaDir.appendingPathComponent("Song.mp3")
        try "audio dummy mp3 bytes header".write(to: audioFile, atomically: true, encoding: .utf8)

        // 3. Create a dummy image file
        let imageFile = mediaDir.appendingPathComponent("Photo.jpg")
        try "fake image data".write(to: imageFile, atomically: true, encoding: .utf8)

        let model = LibraryModel(engine: engine)
        let folder = await model.addFolder(url: mediaDir, displayName: "Ma Collection")
        XCTAssertNotNil(folder)

        // Allow scan task to complete
        for _ in 0..<30 {
            if !model.isScanning && !model.videoItems.isEmpty {
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        model.reloadCurrentMedia()

        // Verify video items
        XCTAssertEqual(model.videoItems.count, 1)
        if let video = model.videoItems.first {
            XCTAssertEqual(video.relPath, "Inception.2010.mp4")
            XCTAssertEqual(video.subtitles.count, 1)
            XCTAssertEqual(video.subtitles.first, "Inception.2010.srt")

            let subUrls = model.companionSubtitleURLs(for: video)
            XCTAssertEqual(subUrls.count, 1)
            XCTAssertEqual(subUrls.first?.lastPathComponent, "Inception.2010.srt")
        }

        // Verify audio items
        XCTAssertEqual(model.audioItems.count, 1)
        XCTAssertEqual(model.audioItems.first?.relPath, "Song.mp3")

        // Verify image items
        XCTAssertEqual(model.imageItems.count, 1)
        XCTAssertEqual(model.imageItems.first?.relPath, "Photo.jpg")

        // Test FTS5 Search
        model.performSearch(query: "Inception")
        XCTAssertEqual(model.searchResults.count, 1)
        XCTAssertEqual(model.searchResults.first?.relPath, "Inception.2010.mp4")

        model.performSearch(query: "Song")
        XCTAssertEqual(model.searchResults.count, 1)
        XCTAssertEqual(model.searchResults.first?.relPath, "Song.mp3")

        model.performSearch(query: "NonExistentTerm")
        XCTAssertTrue(model.searchResults.isEmpty)
    }

    func testLibraryProgressRecordingAndRetrieval() async throws {
        let mediaDir = tempDir.appendingPathComponent("ProgressTestDir")
        try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)

        let videoFile = mediaDir.appendingPathComponent("Movie.mkv")
        try "mkv video content".write(to: videoFile, atomically: true, encoding: .utf8)

        let model = LibraryModel(engine: engine)
        _ = await model.addFolder(url: mediaDir)

        for _ in 0..<30 {
            if !model.isScanning && !model.videoItems.isEmpty { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        model.loadVideos()

        guard let video = model.videoItems.first else {
            XCTFail("Video item should have been indexed")
            return
        }

        // Record 50% watch progress
        model.recordProgress(fingerprint: video.fingerprint, positionMs: 60_000, durationMs: 120_000)
        let prog1 = model.getProgress(fingerprint: video.fingerprint)
        XCTAssertNotNil(prog1)
        XCTAssertEqual(prog1?.positionMs, 60_000)
        XCTAssertEqual(prog1?.durationMs, 120_000)
        XCTAssertFalse(prog1?.completed ?? true)

        // Record 95% watch progress (should be marked completed)
        model.recordProgress(fingerprint: video.fingerprint, positionMs: 115_000, durationMs: 120_000)
        let prog2 = model.getProgress(fingerprint: video.fingerprint)
        XCTAssertNotNil(prog2)
        XCTAssertEqual(prog2?.positionMs, 115_000)
        XCTAssertTrue(prog2?.completed ?? false)
    }

    func testLibraryAudioControls() async throws {
        let mediaDir = tempDir.appendingPathComponent("AudioTestDir")
        try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)

        let track1 = mediaDir.appendingPathComponent("01 Track One.mp3")
        let track2 = mediaDir.appendingPathComponent("02 Track Two.mp3")
        try "audio track 1".write(to: track1, atomically: true, encoding: .utf8)
        try "audio track 2".write(to: track2, atomically: true, encoding: .utf8)

        let model = LibraryModel(engine: engine)
        _ = await model.addFolder(url: mediaDir)

        for _ in 0..<30 {
            if !model.isScanning && model.audioItems.count >= 2 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        model.loadAudio()

        XCTAssertEqual(model.audioItems.count, 2)
        let items = model.audioItems

        // Play track 1
        model.playAudio(item: items[0], inQueue: items)
        XCTAssertEqual(model.nowPlayingAudio?.id, items[0].id)
        XCTAssertTrue(model.isAudioPlaying)

        // Toggle pause
        model.toggleAudioPlayPause()
        XCTAssertFalse(model.isAudioPlaying)

        // Next audio
        model.nextAudio()
        XCTAssertEqual(model.nowPlayingAudio?.id, items[1].id)

        // Previous audio
        model.previousAudio()
        XCTAssertEqual(model.nowPlayingAudio?.id, items[0].id)

        // Stop audio
        model.stopAudio()
        XCTAssertNil(model.nowPlayingAudio)
        XCTAssertFalse(model.isAudioPlaying)
    }

    func testDirectoryBrowser() async throws {
        let rootDir = tempDir.appendingPathComponent("BrowseDir")
        let subDir = rootDir.appendingPathComponent("SubFolder")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)

        let fileInRoot = rootDir.appendingPathComponent("root.mp4")
        let fileInSub = subDir.appendingPathComponent("sub.mp3")
        try "root video".write(to: fileInRoot, atomically: true, encoding: .utf8)
        try "sub audio".write(to: fileInSub, atomically: true, encoding: .utf8)

        let model = LibraryModel(engine: engine)
        guard let folder = await model.addFolder(url: rootDir) else {
            XCTFail("Failed to add folder")
            return
        }

        for _ in 0..<30 {
            if !model.isScanning && !model.videoItems.isEmpty { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        // Browse root
        model.browse(folderId: folder.id, relDir: "")
        XCTAssertTrue(model.browseEntries.contains(where: { $0.name == "SubFolder" && $0.isDirectory }))
        XCTAssertTrue(model.browseEntries.contains(where: { $0.name == "root.mp4" && !$0.isDirectory }))

        // Browse subfolder
        model.browse(folderId: folder.id, relDir: "SubFolder")
        XCTAssertTrue(model.browseEntries.contains(where: { $0.name == "sub.mp3" && !$0.isDirectory }))
    }

    func testMoveItemToTrashAndRemoveFolder() async throws {
        let mediaDir = tempDir.appendingPathComponent("TrashTestDir")
        try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)

        let videoFile = mediaDir.appendingPathComponent("TemporaryVideo.mp4")
        try "temporary".write(to: videoFile, atomically: true, encoding: .utf8)

        let model = LibraryModel(engine: engine)
        guard let folder = await model.addFolder(url: mediaDir) else {
            XCTFail("Failed to add folder")
            return
        }

        for _ in 0..<30 {
            if !model.isScanning && !model.videoItems.isEmpty { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        model.loadVideos()

        guard let item = model.videoItems.first else {
            XCTFail("Video item should exist")
            return
        }

        // Test trash
        let trashed = model.moveItemToTrash(item)
        XCTAssertTrue(trashed, "Moving item to trash should succeed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.fullPath))

        // Test folder removal
        await model.removeFolder(id: folder.id)
        XCTAssertTrue(model.folders.isEmpty)
        XCTAssertTrue(model.videoItems.isEmpty)
    }
}
