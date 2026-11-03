import Foundation
import Observation
#if os(macOS)
import AppKit
#endif

/// Owns the download folder.
///
/// macOS: a folder picked with `NSOpenPanel` is persisted as a security-scoped bookmark, and its
/// scope is opened at launch so the Rust engine (plain POSIX calls) may write `.part` and final
/// files there. The previous scope is always released when the folder changes.
/// iOS: `Documents/Downloads`, which the Files app shows.
@Observable
@MainActor
final class DownloadDirectoryManager {
    static let bookmarkKey = "downloads.directory.bookmark"

    private(set) var directory: URL
    private(set) var isCustom = false
    /// URL whose security scope this manager currently holds open (macOS).
    private(set) var accessedURL: URL?
    private(set) var lastError: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored let platformDefault: URL

    init(defaults: UserDefaults = .standard, platformDefault: URL = DownloadLocation.platformDefault) {
        self.defaults = defaults
        self.platformDefault = platformDefault
        directory = platformDefault
        restore()
    }

    /// Re-opens the saved folder. Called once at launch.
    private func restore() {
        #if os(macOS)
        if let data = defaults.data(forKey: Self.bookmarkKey) {
            var stale = false
            do {
                let url = try URL(
                    resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale
                )
                open(url)
                directory = url
                isCustom = true
                if stale { try? storeBookmark(for: url) }
                defaults.set(url.path, forKey: DownloadLocation.defaultsKey)
                ensureExists()
                return
            } catch {
                lastError = "Dossier de téléchargement inaccessible : \(error.localizedDescription)"
                defaults.removeObject(forKey: Self.bookmarkKey)
            }
        }
        #endif
        if let path = defaults.string(forKey: DownloadLocation.defaultsKey), !path.isEmpty {
            directory = URL(fileURLWithPath: path, isDirectory: true)
            isCustom = true
        }
        ensureExists()
    }

    /// Switches to `url`: persists it, releases the previous scope and opens the new one.
    func setDirectory(_ url: URL) throws {
        #if os(macOS)
        try storeBookmark(for: url)
        closeAccess()
        open(url)
        #else
        defaults.removeObject(forKey: Self.bookmarkKey)
        #endif
        directory = url
        isCustom = true
        lastError = nil
        defaults.set(url.path, forKey: DownloadLocation.defaultsKey)
        ensureExists()
    }

    func resetToDefault() {
        closeAccess()
        defaults.removeObject(forKey: Self.bookmarkKey)
        defaults.removeObject(forKey: DownloadLocation.defaultsKey)
        directory = platformDefault
        isCustom = false
        ensureExists()
    }

    /// Releases the scope held on the current folder.
    func closeAccess() {
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = nil
    }

    private func open(_ url: URL) {
        accessedURL = url.startAccessingSecurityScopedResource() ? url : nil
    }

    #if os(macOS)
    private func storeBookmark(for url: URL) throws {
        let data = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(data, forKey: Self.bookmarkKey)
    }

    func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choisir"
        panel.message = "Choisissez le dossier où enregistrer les téléchargements"
        panel.directoryURL = directory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try setDirectory(url)
        } catch {
            lastError = "Impossible d'utiliser ce dossier : \(error.localizedDescription)"
        }
    }
    #endif

    private func ensureExists() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            lastError = "Impossible de créer le dossier de téléchargement : \(error.localizedDescription)"
        }
    }
}
