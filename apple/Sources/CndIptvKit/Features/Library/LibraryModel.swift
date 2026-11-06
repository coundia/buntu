#if !os(tvOS)
import Foundation
import Observation
import CndCoreBridge
import AVFoundation

#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

@Observable
@MainActor
public final class LibraryModel {

    public let engine: CndEngine
    public let extractor: MetadataExtractor

    // MARK: - State
    public var folders: [LibraryFolderRecord] = []
    public var scanningFolderIds: Set<Int64> = []
    public var isScanning: Bool { !scanningFolderIds.isEmpty }

    // Media datasets
    public var videoItems: [LibraryItemRecord] = []
    public var recentVideos: [LibraryItemRecord] = []
    public var recentlyAddedVideos: [LibraryItemRecord] = []

    public var audioItems: [LibraryItemRecord] = []
    public var albums: [LibraryAlbumRecord] = []
    public var artists: [LibraryArtistRecord] = []
    public var genres: [LibraryGenreRecord] = []

    public var imageItems: [LibraryItemRecord] = []

    // Directory Browser
    public var browseEntries: [LibraryBrowseEntry] = []
    public var currentBrowseDir: String = ""
    public var currentBrowseFolderId: Int64?

    // Search
    public var searchQuery: String = "" {
        didSet {
            performSearch(query: searchQuery)
        }
    }
    public var searchResults: [LibraryItemRecord] = []

    // Filters and Sorting
    public var selectedSort: String = "title" {
        didSet { reloadCurrentMedia() }
    }
    public var isSortAscending: Bool = true {
        didSet { reloadCurrentMedia() }
    }
    public var filterUnwatchedOnly: Bool = false {
        didSet { reloadCurrentMedia() }
    }

    // Audio Playback
    public var nowPlayingAudio: LibraryItemRecord?
    public var isAudioPlaying: Bool = false
    public var audioCurrentTime: Double = 0
    public var audioDuration: Double = 0
    public var audioQueue: [LibraryItemRecord] = []
    public var audioQueueIndex: Int = 0
    public var isShuffleEnabled: Bool = false
    public var isRepeatEnabled: Bool = false

    private var audioPlayer: AVPlayer?
    private var timeObserverToken: Any?

    // Subtitle companion cache
    public var activeVideoCompanionSubtitles: [URL] = []

    // Background scan task
    private var scanTasks: [Int64: Task<Void, Never>] = [:]

    public init(engine: CndEngine) {
        self.engine = engine
        self.extractor = MetadataExtractor(engine: engine)
        loadFolders()
    }

    // MARK: - Folder Management

    public func loadFolders() {
        if let list = try? engine.libraryListFolders() {
            self.folders = list
            // Verify availability
            for folder in list {
                let available = FolderAccess.isFolderAvailable(path: folder.path)
                let expectedState = available ? "ok" : "missing"
                if folder.state != expectedState {
                    try? engine.libraryUpdateFolderState(id: folder.id, state: expectedState)
                }
            }
        }
    }

    public func addFolder(url: URL, displayName: String? = nil) async -> LibraryFolderRecord? {
        let name = displayName ?? url.lastPathComponent
        let path = url.path
        let bookmark = FolderAccess.createBookmark(for: url)

        guard let record = try? engine.libraryAddFolder(
            displayName: name,
            path: path,
            bookmark: bookmark,
            includeSubfolders: true,
            kinds: "video,audio,image"
        ) else {
            return nil
        }

        loadFolders()
        scanFolder(id: record.id)
        return record
    }

    public func removeFolder(id: Int64) async {
        try? engine.libraryRemoveFolder(id: id)
        loadFolders()
        reloadCurrentMedia()
    }

    public func autoRegisterDownloadsFolder(url: URL) {
        guard !folders.contains(where: { $0.path == url.path }) else { return }
        Task {
            _ = await addFolder(url: url, displayName: "Téléchargements")
        }
    }

    // MARK: - Scanning

    public func scanFolder(id: Int64) {
        guard let folder = folders.first(where: { $0.id == id }) else { return }
        guard !scanningFolderIds.contains(id) else { return }

        scanningFolderIds.insert(id)

        let task = Task.detached(priority: .userInitiated) { [weak self, engine, extractor] in
            let folderURL = URL(fileURLWithPath: folder.path)

            let scanResult = FolderAccess.withSecurityAccess(for: folderURL) {
                try? engine.libraryScan(folderId: id, rootPath: folder.path)
            }

            if scanResult != nil {
                // Extract metadata in background
                await extractor.processPendingBatch(limit: 50)
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.scanningFolderIds.remove(id)
                self.loadFolders()
                self.reloadCurrentMedia()
            }
        }

        scanTasks[id] = task
    }

    public func scanAllFolders() {
        for folder in folders where folder.state == "ok" {
            scanFolder(id: folder.id)
        }
    }

    public func cancelScan(id: Int64) {
        engine.libraryCancelScan(folderId: id)
        scanTasks[id]?.cancel()
        scanTasks.removeValue(forKey: id)
        scanningFolderIds.remove(id)
    }

    // MARK: - Media Loading

    public func reloadCurrentMedia() {
        loadVideos()
        loadAudio()
        loadImages()
        if let fid = currentBrowseFolderId {
            browse(folderId: fid, relDir: currentBrowseDir)
        }
    }

    public func loadVideos() {
        videoItems = (try? engine.libraryListItems(
            kind: "video",
            folderId: nil,
            sortBy: selectedSort,
            sortAsc: isSortAscending,
            offset: 0,
            limit: 1000
        )) ?? []

        recentVideos = (try? engine.libraryRecent(kind: "video", limit: 20)) ?? []
        recentlyAddedVideos = (try? engine.libraryRecentlyAdded(kind: "video", limit: 20)) ?? []
    }

    public func loadAudio() {
        audioItems = (try? engine.libraryListItems(
            kind: "audio",
            folderId: nil,
            sortBy: selectedSort,
            sortAsc: isSortAscending,
            offset: 0,
            limit: 1000
        )) ?? []

        albums = (try? engine.libraryAlbums(limit: 500, offset: 0)) ?? []
        artists = (try? engine.libraryArtists(limit: 500, offset: 0)) ?? []
        genres = (try? engine.libraryGenres()) ?? []
    }

    public func loadImages() {
        imageItems = (try? engine.libraryListItems(
            kind: "image",
            folderId: nil,
            sortBy: "date",
            sortAsc: false,
            offset: 0,
            limit: 2000
        )) ?? []
    }

    public func browse(folderId: Int64, relDir: String) {
        currentBrowseFolderId = folderId
        currentBrowseDir = relDir
        browseEntries = (try? engine.libraryBrowse(folderId: folderId, relDir: relDir)) ?? []
    }

    public func performSearch(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            searchResults = []
            return
        }
        searchResults = (try? engine.librarySearch(query: trimmed, kind: nil, limit: 100)) ?? []
    }

    // MARK: - Progress Tracking

    public func recordProgress(fingerprint: String, positionMs: Int64, durationMs: Int64) {
        try? engine.libraryRecordProgress(
            fingerprint: fingerprint,
            positionMs: positionMs,
            durationMs: durationMs
        )
    }

    public func getProgress(fingerprint: String) -> LibraryProgressRecord? {
        try? engine.libraryGetProgress(fingerprint: fingerprint)
    }

    // MARK: - Audio Playback Engine

    public private(set) var audioLaunchCount: Int = 0

    public func playAudio(item: LibraryItemRecord, inQueue: [LibraryItemRecord] = [], presentUI: Bool = true) {
        let queue = inQueue.isEmpty ? [item] : inQueue
        self.audioQueue = queue
        self.audioQueueIndex = queue.firstIndex(where: { $0.id == item.id }) ?? 0
        self.nowPlayingAudio = item
        if presentUI {
            self.audioLaunchCount &+= 1
        }

        let fileURL = URL(fileURLWithPath: item.fullPath)
        let playerItem = AVPlayerItem(url: fileURL)

        if audioPlayer == nil {
            audioPlayer = AVPlayer(playerItem: playerItem)
            setupTimeObserver()
        } else {
            audioPlayer?.replaceCurrentItem(with: playerItem)
        }

        audioPlayer?.play()
        isAudioPlaying = true

        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: nil)
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.onAudioTrackFinished()
            }
        }
    }

    public func toggleAudioPlayPause() {
        guard let player = audioPlayer else { return }
        if isAudioPlaying {
            player.pause()
            isAudioPlaying = false
        } else {
            player.play()
            isAudioPlaying = true
        }
    }

    public func nextAudio() {
        guard !audioQueue.isEmpty else { return }
        if isShuffleEnabled {
            audioQueueIndex = Int.random(in: 0..<audioQueue.count)
        } else {
            audioQueueIndex = (audioQueueIndex + 1) % audioQueue.count
        }
        let nextItem = audioQueue[audioQueueIndex]
        playAudio(item: nextItem, inQueue: audioQueue, presentUI: false)
    }

    public func previousAudio() {
        guard !audioQueue.isEmpty else { return }
        if audioCurrentTime > 3.0 {
            seekAudio(toFraction: 0)
            return
        }
        audioQueueIndex = (audioQueueIndex - 1 + audioQueue.count) % audioQueue.count
        let prevItem = audioQueue[audioQueueIndex]
        playAudio(item: prevItem, inQueue: audioQueue, presentUI: false)
    }

    public func seekAudio(toFraction fraction: Double) {
        guard let player = audioPlayer, audioDuration > 0 else { return }
        let targetSec = audioDuration * min(1.0, max(0.0, fraction))
        let cmTime = CMTime(seconds: targetSec, preferredTimescale: 600)
        player.seek(to: cmTime)
    }

    public func stopAudio() {
        if let token = timeObserverToken {
            audioPlayer?.removeTimeObserver(token)
            timeObserverToken = nil
        }
        audioPlayer?.pause()
        audioPlayer = nil
        isAudioPlaying = false
        nowPlayingAudio = nil
    }

    private func setupTimeObserver() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserverToken = audioPlayer?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, let currentItem = self.audioPlayer?.currentItem else { return }
                let duration = currentItem.duration.seconds
                let current = time.seconds
                if !duration.isNaN && !duration.isInfinite && duration > 0 {
                    self.audioDuration = duration
                    self.audioCurrentTime = current
                    if let fp = self.nowPlayingAudio?.fingerprint {
                        self.recordProgress(
                            fingerprint: fp,
                            positionMs: Int64(current * 1000),
                            durationMs: Int64(duration * 1000)
                        )
                    }
                }
            }
        }
    }

    private func onAudioTrackFinished() {
        if isRepeatEnabled {
            seekAudio(toFraction: 0)
            audioPlayer?.play()
        } else if audioQueueIndex + 1 < audioQueue.count {
            nextAudio()
        } else {
            stopAudio()
        }
    }

    // MARK: - Companion Subtitles

    public func companionSubtitleURLs(for video: LibraryItemRecord) -> [URL] {
        guard let folder = folders.first(where: { $0.id == video.folderId }) else { return [] }
        return video.subtitles.map { subRel in
            URL(fileURLWithPath: "\(folder.path)/\(subRel)")
        }
    }

    // MARK: - Trash item (Safe user action)

    public func moveItemToTrash(_ item: LibraryItemRecord) -> Bool {
        let url = URL(fileURLWithPath: item.fullPath)
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            reloadCurrentMedia()
            return true
        } catch {
            return false
        }
    }
}

extension LibraryItemRecord: @retroactive Identifiable {}
extension LibraryFolderRecord: @retroactive Identifiable {}
extension LibraryAlbumRecord: @retroactive Identifiable {
    public var id: String { "\(artist ?? "")_\(name)" }
}
extension LibraryArtistRecord: @retroactive Identifiable {
    public var id: String { name }
}
extension LibraryGenreRecord: @retroactive Identifiable {
    public var id: String { name }
}
extension LibraryBrowseEntry: @retroactive Identifiable {
    public var id: String { relPath }
}
#endif
