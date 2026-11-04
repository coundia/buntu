import Foundation

#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Handles security-scoped bookmarks and file access permissions on macOS, iOS and iPadOS.
public enum FolderAccess {

    /// Creates a persistent security-scoped bookmark for a user-selected folder URL.
    public static func createBookmark(for url: URL) -> Data? {
        #if os(macOS)
        let options: URL.BookmarkCreationOptions = [.withSecurityScope]
        #else
        let options: URL.BookmarkCreationOptions = []
        #endif

        do {
            return try url.bookmarkData(
                options: options,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            return nil
        }
    }

    /// Resolves a security-scoped bookmark data back to a URL.
    /// Returns the resolved URL, whether the bookmark is stale (needs renewal), and whether it exists.
    public static func resolveBookmark(data: Data) -> (url: URL, isStale: Bool, isAvailable: Bool)? {
        var isStale = false
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
        #else
        let options: URL.BookmarkResolutionOptions = []
        #endif

        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: options,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            let isAvailable = FileManager.default.fileExists(atPath: url.path)
            return (url, isStale, isAvailable)
        } catch {
            return nil
        }
    }

    /// Safely accesses a security-scoped resource, ensuring `stopAccessingSecurityScopedResource`
    /// is always called in a `defer` block.
    public static func withSecurityAccess<T>(for url: URL, block: () throws -> T) rethrows -> T {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try block()
    }

    /// Async version of `withSecurityAccess`.
    public static func withSecurityAccessAsync<T>(for url: URL, block: () async throws -> T) async rethrows -> T {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try await block()
    }

    /// Checks if a path is currently accessible on disk (e.g. disk plugged in).
    public static func isFolderAvailable(path: String) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return exists && isDir.boolValue
    }
}
