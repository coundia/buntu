import Foundation
import Observation
import CndCoreBridge

struct SyncReport: Equatable {
    var summary: SyncSummary
    /// Programmes imported by the follow-up EPG refresh; `nil` while it runs or when it failed.
    var epgPrograms: UInt32?
    var epgPending: Bool
}

enum SyncState: Equatable {
    case idle
    case syncing
    case done(SyncReport)
    case failed(String)
}

struct SourcesBanner: Equatable, Identifiable {
    let id = UUID()
    let isError: Bool
    let text: String
}

enum SourcesAction: Equatable {
    case addSource
    case importPlaylist
    case importShare
}

enum SourcesError: LocalizedError {
    case missingPassword
    case unsupportedFile(String)

    var errorDescription: String? {
        switch self {
        case .missingPassword: return "Mot de passe Xtream introuvable dans le Trousseau. Modifiez la source pour le saisir à nouveau."
        case .unsupportedFile(let name): return "« \(name) » n'est pas une playlist .m3u / .m3u8."
        }
    }
}

enum SyncSummaryFormatter {
    private static func plural(_ n: UInt32, _ one: String, _ many: String) -> String {
        "\(n) \(n > 1 ? many : one)"
    }

    static func text(_ summary: SyncSummary) -> String {
        [
            plural(summary.liveCount, "chaîne", "chaînes"),
            plural(summary.movieCount, "film", "films"),
            plural(summary.seriesCount, "série", "séries"),
            "\(summary.durationMs) ms",
        ].joined(separator: " · ")
    }
}

func userMessage(for error: Error) -> String {
    switch error {
    case let CndError.Database(message), let CndError.Network(message), let CndError.Parse(message),
         let CndError.Io(message), let CndError.Internal(message):
        return message
    default:
        return error.localizedDescription
    }
}

/// Source operations (sync, delete, local import). Everything slow runs on the Rust side, so the
/// UI stays responsive and only reads `syncStates` / `banner`.
@Observable
@MainActor
final class SourcesModel {
    let engine: CndEngine
    let keychain: KeychainStore
    let importsDirectory: URL
    @ObservationIgnored var onChange: () -> Void

    private(set) var syncStates: [Int64: SyncState] = [:]
    private(set) var isSyncingAll = false
    private(set) var isImporting = false
    private(set) var banner: SourcesBanner?
    /// Set by the menu bar (File > Add a source / Import). The list consumes it when it appears or
    /// when it changes, so the request survives the tab switch that creates the list.
    var pendingAction: SourcesAction?
    /// A share received by link or file (opened from outside the list); the list shows the import sheet.
    var incomingShare: IncomingShare?

    init(
        engine: CndEngine,
        keychain: KeychainStore = .shared,
        importsDirectory: URL = SourcesModel.defaultImportsDirectory,
        onChange: @escaping () -> Void = {}
    ) {
        self.engine = engine
        self.keychain = keychain
        self.importsDirectory = importsDirectory
        self.onChange = onChange
    }

    nonisolated static var defaultImportsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("CndIptvNative/Imports", isDirectory: true)
    }

    static func isM3uFile(_ url: URL) -> Bool {
        ["m3u", "m3u8"].contains(url.pathExtension.lowercased())
    }

    func state(for source: IptvSourceRecord) -> SyncState {
        syncStates[source.id] ?? .idle
    }

    func dismissBanner() { banner = nil }
    func request(_ action: SourcesAction) { pendingAction = action }

    private func show(_ text: String, isError: Bool) {
        let banner = SourcesBanner(isError: isError, text: text)
        self.banner = banner
        guard !isError else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            if self?.banner?.id == banner.id { self?.banner = nil }
        }
    }

    func password(for source: IptvSourceRecord) -> String? {
        let key = source.passwordRef ?? KeychainStore.xtreamKey(forSourceUuid: source.uuid)
        return try? keychain.readSecret(forKey: key)
    }

    // MARK: Sync

    @discardableResult
    func sync(_ source: IptvSourceRecord) async -> Bool {
        if case .syncing = state(for: source) { return false }
        syncStates[source.id] = .syncing
        var password: String?
        do {
            let summary: SyncSummary
            if source.sourceType == "xtream" {
                guard let secret = self.password(for: source) else { throw SourcesError.missingPassword }
                password = secret
                summary = try await engine.refreshXtreamSource(sourceId: source.id, password: secret)
            } else {
                summary = try await engine.refreshSource(sourceId: source.id)
            }
            syncStates[source.id] = .done(SyncReport(summary: summary, epgPrograms: nil, epgPending: true))
            show("\(source.name) : \(SyncSummaryFormatter.text(summary))", isError: false)
            onChange()

            // The guide is best effort: a missing or broken XMLTV must not fail the sync.
            let epg = try? await engine.refreshSourceEpg(sourceId: source.id, password: password)
            syncStates[source.id] = .done(SyncReport(summary: summary, epgPrograms: epg, epgPending: false))
            return true
        } catch {
            let message = userMessage(for: error)
            syncStates[source.id] = .failed(message)
            show("\(source.name) : \(message)", isError: true)
            return false
        }
    }

    func syncSource(id: Int64) async {
        guard let source = (try? engine.listSources())?.first(where: { $0.id == id }) else { return }
        await sync(source)
    }

    func syncAll(_ sources: [IptvSourceRecord]) async {
        guard !isSyncingAll else { return }
        isSyncingAll = true
        defer { isSyncingAll = false }
        for source in sources { await sync(source) }
    }

    // MARK: Delete

    func delete(_ source: IptvSourceRecord) {
        do {
            try engine.deleteSource(sourceId: source.id)
            if source.sourceType == "xtream" {
                try? keychain.deleteSecret(forKey: source.passwordRef ?? KeychainStore.xtreamKey(forSourceUuid: source.uuid))
            }
            syncStates[source.id] = nil
            onChange()
        } catch {
            show(userMessage(for: error), isError: true)
        }
    }

    // MARK: Local import

    /// Imports a `.m3u` / `.m3u8` file (drag and drop or file picker). The file is copied into the
    /// app container first: a sandboxed picker URL is only readable while its scope is open, but
    /// later refreshes re-read the stored path.
    func importM3u(from fileURL: URL) async {
        guard Self.isM3uFile(fileURL) else {
            show(SourcesError.unsupportedFile(fileURL.lastPathComponent).localizedDescription, isError: true)
            return
        }
        isImporting = true
        defer { isImporting = false }
        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
        do {
            let stored = try copyIntoImports(fileURL)
            let name = fileURL.deletingPathExtension().lastPathComponent
            let summary = try await engine.importLocalM3u(name: name, filePath: stored.path)
            show("\(name) : \(SyncSummaryFormatter.text(summary))", isError: false)
            onChange()
        } catch {
            show(userMessage(for: error), isError: true)
        }
    }

    private func copyIntoImports(_ fileURL: URL) throws -> URL {
        try FileManager.default.createDirectory(at: importsDirectory, withIntermediateDirectories: true)
        let destination = importsDirectory.appendingPathComponent("\(UUID().uuidString)-\(fileURL.lastPathComponent)")
        try FileManager.default.copyItem(at: fileURL, to: destination)
        return destination
    }
}
