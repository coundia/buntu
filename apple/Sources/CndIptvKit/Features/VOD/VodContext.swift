import Foundation
import Observation
import CndCoreBridge

/// Everything a VOD screen needs from the rest of the app: engine, playback, downloads, toasts.
/// Injected through the SwiftUI environment so pushed detail screens get it too.
@Observable
@MainActor
final class VodContext {
    let engine: CndEngine
    let keychain: KeychainStore
    let toasts: ToastCenter
    let downloadBase: () -> URL
    let openDownloads: () -> Void
    let onFavoriteChanged: () -> Void
    let aiConfigProvider: (() -> AiProviderConfig)?
    /// Keeps downloads inside the subscription's connection limit while something plays.
    let connections: DownloadConnectionCoordinator?
    /// The movie or series shown in the side panel (macOS), under the player. Never a separate page there.
    var selection: VodRoute?
    private let playMedia: (PlayableMedia) -> Void
    private let playQueue: ([PlayableMedia], Int) -> Void

    init(
        engine: CndEngine,
        keychain: KeychainStore = .shared,
        toasts: ToastCenter,
        downloadBase: @escaping () -> URL = { DownloadLocation.baseDirectory },
        playMedia: @escaping (PlayableMedia) -> Void,
        playQueue: @escaping ([PlayableMedia], Int) -> Void,
        openDownloads: @escaping () -> Void = {},
        onFavoriteChanged: @escaping () -> Void = {},
        aiConfigProvider: (() -> AiProviderConfig)? = nil,
        connections: DownloadConnectionCoordinator? = nil
    ) {
        self.connections = connections
        self.engine = engine
        self.keychain = keychain
        self.toasts = toasts
        self.downloadBase = downloadBase
        self.playMedia = playMedia
        self.playQueue = playQueue
        self.openDownloads = openDownloads
        self.onFavoriteChanged = onFavoriteChanged
        self.aiConfigProvider = aiConfigProvider
    }

    /// Reads the key on demand (never cached): changing it in Settings takes effect immediately.
    /// The user's own key, else the default one of this build (`ApiKeyResolver`).
    func omdbKey() -> String? {
        ApiKeyResolver(keychain: keychain).keyForCall(.omdb)
    }

    // MARK: Playback

    /// A saved position is only offered above 30 s and while the title is not finished.
    nonisolated static let resumeThresholdMs: Int64 = 30_000

    nonisolated static func resumePosition(for item: IptvItemRecord) -> Int64? {
        item.resumePositionMs > resumeThresholdMs && !item.isCompleted ? item.resumePositionMs : nil
    }

    func play(_ item: IptvItemRecord, resume: Bool) {
        let start = resume ? (Self.resumePosition(for: item) ?? 0) : 0
        guard let media = PlayableMedia(item: item, startPositionMs: start) else {
            toasts.show("L'URL du flux de « \(item.name) » est invalide.", isError: true)
            return
        }
        playMedia(media)
    }

    /// Plays `items` as a queue starting at `index`, so the next episode follows automatically.
    func playEpisodes(_ items: [IptvItemRecord], series: SeriesRecord? = nil, startingAt index: Int, resume: Bool = false) {
        var medias: [PlayableMedia] = []
        var startIndex = 0
        for (offset, item) in items.enumerated() {
            let start = (resume && offset == index) ? (Self.resumePosition(for: item) ?? 0) : 0
            guard let media = PlayableMedia(item: item, startPositionMs: start, series: series) else { continue }
            if offset == index { startIndex = medias.count }
            medias.append(media)
        }
        guard !medias.isEmpty else {
            toasts.show("Aucun épisode lisible.", isError: true)
            return
        }
        playQueue(medias, startIndex)
    }

    // MARK: Downloads

    /// Sends the requests to the Rust engine (never to an external browser) and confirms with a
    /// toast that links to the Downloads tab.
    @discardableResult
    func enqueue(_ requests: [NewDownloadRequest]) async -> Int {
        var queued = 0
        var waiting = 0
        var failure: String?
        for var request in requests {
            // With one connection, a download started during a playback would fight the stream (502 for both):
            // it is queued and starts when the playback is over.
            let waits = connections?.shouldHoldNewDownload(urlString: request.url) == true
            if waits { request.autoStart = false }
            do {
                let taskId = try await engine.enqueueDownload(req: request)
                queued += 1
                if waits {
                    connections?.hold(taskId: taskId)
                    waiting += 1
                }
            } catch {
                failure = userMessage(for: error)
            }
        }
        if queued > 0 {
            #if os(iOS) || os(tvOS) || os(visionOS)
            BackgroundDownloadCoordinator.shared.promoteNextQueuedTasks()
            #endif
            var text = queued == 1 ? "1 téléchargement ajouté" : "\(queued) téléchargements ajoutés"
            if waiting > 0 { text += " : démarrage à la fin de la lecture (votre abonnement n'autorise qu'une connexion)" }
            toasts.show(text, actionTitle: "Voir", action: openDownloads)
        }
        if let failure { toasts.show(failure, isError: true) }
        return queued
    }

    func downloadMovie(_ item: IptvItemRecord) {
        let request = DownloadPlanner.movieRequest(item, baseDirectory: downloadBase())
        Task { await enqueue([request]) }
    }

    func downloadEpisodes(_ episodes: [IptvItemRecord], seriesTitle: String) {
        let requests = DownloadPlanner.seasonRequests(
            seriesTitle: seriesTitle, episodes: episodes, baseDirectory: downloadBase()
        )
        guard !requests.isEmpty else {
            toasts.show("Aucun épisode à télécharger.", isError: true)
            return
        }
        Task { await enqueue(requests) }
    }

    // MARK: Favorites

    func toggleFavorite(stableHash: String, kind: String) async -> Bool? {
        let engine = self.engine
        do {
            let value = try await Task.detached(priority: .userInitiated) {
                try engine.toggleFavorite(stableHash: stableHash, itemKind: kind)
            }.value
            onFavoriteChanged()
            return value
        } catch {
            toasts.show(userMessage(for: error), isError: true)
            return nil
        }
    }

    // MARK: Broken flags

    func toggleBroken(stableHash: String, kind: String) async -> Bool? {
        let engine = self.engine
        do {
            let value = try await Task.detached(priority: .userInitiated) {
                try engine.toggleBroken(stableHash: stableHash, itemKind: kind)
            }.value
            return value
        } catch {
            toasts.show(userMessage(for: error), isError: true)
            return nil
        }
    }
}
