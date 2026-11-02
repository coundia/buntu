import Foundation
import CoreGraphics
import CryptoKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Pixel budget of a thumbnail, matched to the size it is displayed at.
public enum ThumbnailSize: Sendable {
    case tvLogo
    case poster

    public var maxPixel: Int {
        switch self {
        case .tvLogo: return 120
        case .poster: return 360
        }
    }
}

/// Memory + disk cache of downsampled images. `AsyncImage` is deliberately avoided: it has no
/// persistent cache and decodes full-size bitmaps, which saturates RAM on a grid of thousands of logos.
///
/// The actor only does bookkeeping (memory lookup, de-duplication of in-flight loads); fetching,
/// decoding and disk I/O run in detached tasks so several images decode in parallel and never on
/// the main thread.
public actor ImageThumbnailCache {
    public typealias Loader = @Sendable (URL) async throws -> Data

    public static let shared = ImageThumbnailCache()

    public static let defaultMemoryLimitBytes = 150 * 1024 * 1024
    public static let defaultDiskLimitBytes = 300 * 1024 * 1024

    private let memory = NSCache<NSString, CGImage>()
    private let directory: URL?
    private let loader: Loader
    private let diskLimitBytes: Int
    private var inflight: [String: Task<CGImage?, Never>] = [:]
    private var diskTrimmed = false

    public init(
        directory: URL? = ImageThumbnailCache.defaultDirectory,
        memoryLimitBytes: Int = ImageThumbnailCache.defaultMemoryLimitBytes,
        diskLimitBytes: Int = ImageThumbnailCache.defaultDiskLimitBytes,
        loader: @escaping Loader = ImageThumbnailCache.networkLoader
    ) {
        self.directory = directory
        self.loader = loader
        self.diskLimitBytes = diskLimitBytes
        memory.totalCostLimit = memoryLimitBytes
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    public static var defaultDirectory: URL? {
        FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("CndThumbnails", isDirectory: true)
    }

    public static let networkLoader: Loader = { url in
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .returnCacheDataElseLoad
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        guard data.count <= 20 * 1024 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
        return data
    }

    public func image(for url: URL, maxPixel: Int) async -> CGImage? {
        let key = Self.cacheKey(url: url, maxPixel: maxPixel)
        if let hit = memory.object(forKey: key as NSString) { return hit }
        if let running = inflight[key] { return await running.value }

        let directory = self.directory
        let loader = self.loader
        let task = Task.detached(priority: .utility) { () -> CGImage? in
            if let directory, let cached = Self.readDisk(directory: directory, key: key) {
                return cached
            }
            guard let data = try? await loader(url),
                  let image = Self.downsample(data, maxPixel: maxPixel) else { return nil }
            if let directory { Self.writeDisk(image, directory: directory, key: key) }
            return image
        }
        inflight[key] = task
        let image = await task.value
        inflight[key] = nil
        if let image {
            memory.setObject(image, forKey: key as NSString, cost: image.bytesPerRow * image.height)
        }
        trimDiskIfNeeded()
        return image
    }

    public func image(for urlString: String, size: ThumbnailSize) async -> CGImage? {
        guard let url = URL(string: urlString), ["http", "https", "file"].contains(url.scheme?.lowercased()) else {
            return nil
        }
        return await image(for: url, maxPixel: size.maxPixel)
    }

    public func clearMemory() {
        memory.removeAllObjects()
    }

    // MARK: Disk

    private func trimDiskIfNeeded() {
        guard !diskTrimmed, let directory else { return }
        diskTrimmed = true
        let limit = diskLimitBytes
        Task.detached(priority: .background) { Self.trimDisk(directory: directory, limitBytes: limit) }
    }

    nonisolated static func cacheKey(url: URL, maxPixel: Int) -> String {
        let digest = SHA256.hash(data: Data("\(url.absoluteString)|\(maxPixel)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func fileURL(directory: URL, key: String) -> URL {
        directory.appendingPathComponent("\(key).png")
    }

    nonisolated static func readDisk(directory: URL, key: String) -> CGImage? {
        let url = fileURL(directory: directory, key: key)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
        return CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
    }

    nonisolated static func writeDisk(_ image: CGImage, directory: URL, key: String) {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return }
        try? (data as Data).write(to: fileURL(directory: directory, key: key), options: .atomic)
    }

    /// Removes the least recently modified files until the directory fits in `limitBytes`.
    nonisolated static func trimDisk(directory: URL, limitBytes: Int) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: .skipsHiddenFiles
        ) else { return }
        var entries: [(url: URL, date: Date, size: Int)] = files.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        guard total > limitBytes else { return }
        entries.sort { $0.date < $1.date }
        for entry in entries where total > limitBytes {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    // MARK: Decoding

    /// Decodes straight to a thumbnail whose longest side is at most `maxPixel`, never materialising
    /// the full-size bitmap.
    nonisolated static func downsample(_ data: Data, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// Drop-in replacement for `AsyncImage` backed by `ImageThumbnailCache`.
struct ThumbnailImageView: View {
    let urlString: String?
    var size: ThumbnailSize = .tvLogo
    var placeholderSystemImage = "tv"
    /// Fills and crops the frame (posters) instead of fitting inside it (logos).
    var fills = false

    @State private var image: CGImage?

    var body: some View {
        ZStack {
            if let image {
                if fills {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                } else {
                    Image(decorative: image, scale: 1).resizable().scaledToFit()
                }
            } else {
                Image(systemName: placeholderSystemImage)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: urlString) {
            image = nil
            guard let urlString, !urlString.isEmpty else { return }
            image = await ImageThumbnailCache.shared.image(for: urlString, size: size)
        }
    }
}
