#if !os(tvOS)
import Foundation
import AVFoundation
import ImageIO
import CndCoreBridge
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Background service extracting metadata (dimensions, duration, ID3/EXIF tags)
/// and generating downsampled thumbnails into the disk cache.
public actor MetadataExtractor {

    private let engine: CndEngine
    private let cacheDir: URL
    private var isPaused = false

    public init(engine: CndEngine) {
        self.engine = engine
        let baseCache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.cacheDir = baseCache.appendingPathComponent("CndLibraryThumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    /// Pause extraction during live TV / movie playback to avoid contention.
    public func setPaused(_ paused: Bool) {
        self.isPaused = paused
    }

    /// Process a batch of pending items.
    public func processPendingBatch(limit: UInt32 = 10) async {
        guard !isPaused else { return }

        guard let items = try? engine.libraryPendingMetadata(limit: limit), !items.isEmpty else {
            return
        }

        for item in items {
            if isPaused { break }
            await extractMetadata(for: item)
        }
    }

    private func extractMetadata(for item: LibraryItemRecord) async {
        let fileURL = URL(fileURLWithPath: item.fullPath)
        guard FileManager.default.fileExists(atPath: item.fullPath) else {
            return
        }

        switch item.kind {
        case "video":
            await extractVideoMetadata(item: item, url: fileURL)
        case "audio":
            await extractAudioMetadata(item: item, url: fileURL)
        case "image":
            await extractImageMetadata(item: item, url: fileURL)
        default:
            break
        }
    }

    // MARK: - Video Metadata

    private func extractVideoMetadata(item: LibraryItemRecord, url: URL) async {
        let asset = AVURLAsset(url: url)
        var durationMs: UInt32?
        var width: UInt32?
        var height: UInt32?
        var codec: String?

        if let duration = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(duration)
            if seconds > 0 && !seconds.isNaN && !seconds.isInfinite {
                durationMs = UInt32(seconds * 1000)
            }
        }

        if let tracks = try? await asset.loadTracks(withMediaType: .video), let track = tracks.first {
            if let naturalSize = try? await track.load(.naturalSize) {
                width = UInt32(max(0, naturalSize.width))
                height = UInt32(max(0, naturalSize.height))
            }
            if let formats = try? await track.load(.formatDescriptions) {
                if let firstDesc = formats.first {
                    let subType = CMFormatDescriptionGetMediaSubType(firstDesc)
                    codec = fourCCToString(subType)
                }
            }
        }

        // Generate thumbnail at 10%
        let thumbPath = await generateVideoThumbnail(asset: asset, fingerprint: item.fingerprint, durationMs: durationMs)

        let meta = LibraryItemMetadataInput(
            title: item.title,
            durationMs: durationMs,
            width: width,
            height: height,
            codec: codec,
            artist: nil,
            album: nil,
            albumArtist: nil,
            trackNo: nil,
            discNo: nil,
            genre: nil,
            year: nil,
            takenAt: nil,
            thumbnailPath: thumbPath
        )

        try? engine.libraryStoreMetadata(itemId: item.id, metadata: meta)
    }

    private func generateVideoThumbnail(asset: AVAsset, fingerprint: String, durationMs: UInt32?) async -> String? {
        let targetFile = cacheDir.appendingPathComponent("\(fingerprint).jpg")
        if FileManager.default.fileExists(atPath: targetFile.path) {
            return targetFile.path
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 270)

        let targetSec = Double(durationMs ?? 10_000) / 1000.0 * 0.1
        let time = CMTime(seconds: max(1.0, targetSec), preferredTimescale: 600)

        do {
            let (cgImage, _) = try await generator.image(at: time)
            if saveCGImageAsJPEG(cgImage, to: targetFile) {
                return targetFile.path
            }
        } catch {
            // Fallback at start
            if let (cgImage, _) = try? await generator.image(at: .zero) {
                if saveCGImageAsJPEG(cgImage, to: targetFile) {
                    return targetFile.path
                }
            }
        }
        return nil
    }

    // MARK: - Audio Metadata

    private func extractAudioMetadata(item: LibraryItemRecord, url: URL) async {
        let asset = AVURLAsset(url: url)
        var durationMs: UInt32?
        var title: String?
        var artist: String?
        var album: String?
        let albumArtist: String? = nil
        let trackNo: UInt32? = nil
        let discNo: UInt32? = nil
        var genre: String?
        var year: UInt32?
        var thumbnailPath: String?

        if let duration = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(duration)
            if seconds > 0 && !seconds.isNaN && !seconds.isInfinite {
                durationMs = UInt32(seconds * 1000)
            }
        }

        if let metadataList = try? await asset.load(.commonMetadata) {
            for meta in metadataList {
                guard let key = meta.commonKey?.rawValue else { continue }
                if let strValue = try? await meta.load(.stringValue) {
                    switch key {
                    case AVMetadataKey.commonKeyTitle.rawValue:
                        title = strValue
                    case AVMetadataKey.commonKeyArtist.rawValue:
                        artist = strValue
                    case AVMetadataKey.commonKeyAlbumName.rawValue:
                        album = strValue
                    case AVMetadataKey.commonKeyType.rawValue:
                        genre = strValue
                    default:
                        break
                    }
                } else if let numValue = try? await meta.load(.numberValue) {
                    if key == AVMetadataKey.commonKeyCreationDate.rawValue {
                        year = numValue.uint32Value
                    }
                } else if key == AVMetadataKey.commonKeyArtwork.rawValue {
                    if let data = try? await meta.load(.dataValue) {
                        let thumbFile = cacheDir.appendingPathComponent("\(item.fingerprint).jpg")
                        try? data.write(to: thumbFile)
                        thumbnailPath = thumbFile.path
                    }
                }
            }
        }

        // Fallback title to stem if empty
        if title == nil || title?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            title = URL(fileURLWithPath: item.relPath).deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: ".", with: " ")
                .replacingOccurrences(of: "_", with: " ")
        }

        let input = LibraryItemMetadataInput(
            title: title,
            durationMs: durationMs,
            width: nil,
            height: nil,
            codec: nil,
            artist: artist,
            album: album,
            albumArtist: albumArtist,
            trackNo: trackNo,
            discNo: discNo,
            genre: genre,
            year: year,
            takenAt: nil,
            thumbnailPath: thumbnailPath
        )

        try? engine.libraryStoreMetadata(itemId: item.id, metadata: input)
    }

    // MARK: - Image Metadata

    private func extractImageMetadata(item: LibraryItemRecord, url: URL) async {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]

        let width = properties?[kCGImagePropertyPixelWidth] as? UInt32
        let height = properties?[kCGImagePropertyPixelHeight] as? UInt32
        var takenAt: Int64?

        if let exif = properties?[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            if let dateStr = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
                if let d = formatter.date(from: dateStr) {
                    takenAt = Int64(d.timeIntervalSince1970)
                }
            }
        }

        // Generate downsampled thumbnail with ImageIO (bounded memory)
        let thumbFile = cacheDir.appendingPathComponent("\(item.fingerprint).jpg")
        var thumbPath: String?
        if !FileManager.default.fileExists(atPath: thumbFile.path) {
            let thumbOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 320,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            if let thumbCG = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) {
                if saveCGImageAsJPEG(thumbCG, to: thumbFile) {
                    thumbPath = thumbFile.path
                }
            }
        } else {
            thumbPath = thumbFile.path
        }

        let input = LibraryItemMetadataInput(
            title: item.title,
            durationMs: nil,
            width: width,
            height: height,
            codec: nil,
            artist: nil,
            album: nil,
            albumArtist: nil,
            trackNo: nil,
            discNo: nil,
            genre: nil,
            year: nil,
            takenAt: takenAt,
            thumbnailPath: thumbPath
        )

        try? engine.libraryStoreMetadata(itemId: item.id, metadata: input)
    }

    // MARK: - Helpers

    private func saveCGImageAsJPEG(_ cgImage: CGImage, to fileURL: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(fileURL as CFURL, "public.jpeg" as CFString, 1, nil) else {
            return false
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.8]
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    private func fourCCToString(_ code: FourCharCode) -> String {
        let bytes: [CChar] = [
            CChar((code >> 24) & 0xff),
            CChar((code >> 16) & 0xff),
            CChar((code >> 8) & 0xff),
            CChar(code & 0xff),
            0
        ]
        return String(cString: bytes).trimmingCharacters(in: .whitespaces)
    }
}
#endif
