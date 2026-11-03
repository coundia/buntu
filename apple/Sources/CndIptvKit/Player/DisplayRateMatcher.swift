import Foundation
import SwiftUI
#if os(tvOS)
import AVFoundation
import UIKit
import CoreMedia
#endif
#if os(macOS)
import CoreGraphics
import AppKit
#endif

/// Standard video frame rates in Hz for broadcast and film.
public enum StandardFrameRate: Double, CaseIterable, Sendable {
    case fps23_976 = 23.976
    case fps24 = 24.0
    case fps25 = 25.0
    case fps29_97 = 29.97
    case fps30 = 30.0
    case fps50 = 50.0
    case fps59_94 = 59.94
    case fps60 = 60.0

    /// Snaps a raw measured frame rate to the closest standard broadcast/cinema cadence
    /// within a tolerance of 0.75 Hz. Returns nil if unknown or out of range.
    public static func snap(rawFps: Double) -> StandardFrameRate? {
        guard rawFps > 10.0 && rawFps < 130.0 else { return nil }
        var closest: StandardFrameRate?
        var minDiff = Double.greatestFiniteMagnitude

        for rate in Self.allCases {
            let diff = abs(rate.rawValue - rawFps)
            if diff < minDiff {
                minDiff = diff
                closest = rate
            }
        }

        if minDiff <= 0.75 {
            return closest
        }
        return nil
    }

    /// Clean user-facing description for the player HUD ("23,976 i/s", "50 i/s", etc.).
    public var displayDescription: String {
        switch self {
        case .fps23_976: return "23,976 i/s"
        case .fps24: return "24 i/s"
        case .fps25: return "25 i/s"
        case .fps29_97: return "29,97 i/s"
        case .fps30: return "30 i/s"
        case .fps50: return "50 i/s"
        case .fps59_94: return "59,94 i/s"
        case .fps60: return "60 i/s"
        }
    }
}

/// Dynamic range of the stream.
public enum VideoDynamicRange: String, CaseIterable, Sendable {
    case sdr = "SDR"
    case hdr10 = "HDR10"
    case hlg = "HLG"
    case dolbyVision = "Dolby Vision"

    public static func detect(gamma: String?, primaries: String?) -> VideoDynamicRange {
        let g = gamma?.lowercased() ?? ""
        let p = primaries?.lowercased() ?? ""
        if g.contains("hlg") || g.contains("arib-std-b67") {
            return .hlg
        }
        if g.contains("pq") || g.contains("smpte2084") || p.contains("bt2020") {
            return .hdr10
        }
        return .sdr
    }
}

/// Information about the current stream's display format.
public struct DisplayFormatInfo: Equatable, Sendable {
    public let rawFps: Double
    public let matchedRate: StandardFrameRate?
    public let dynamicRange: VideoDynamicRange
    public let width: Int?
    public let height: Int?

    public init(rawFps: Double, dynamicRange: VideoDynamicRange = .sdr, width: Int? = nil, height: Int? = nil) {
        self.width = (width ?? 0) > 0 ? width : nil
        self.height = (height ?? 0) > 0 ? height : nil
        self.rawFps = rawFps
        self.matchedRate = StandardFrameRate.snap(rawFps: rawFps)
        self.dynamicRange = dynamicRange
    }

    public var summary: String {
        let fpsText = matchedRate?.displayDescription ?? String(format: "%.2f i/s", rawFps)
        let base = "\(fpsText) · \(dynamicRange.rawValue)"
        guard let width, let height else { return base }
        return "\(width)×\(height) · \(base)"
    }
}

/// Manages Auto-Framerate Matching (AFR) and Dynamic Range matching.
/// Follows PRD-25 SLA:
/// - 2-second stability debounce to prevent flickering during rapid channel zapping.
/// - Automatically restores system refresh rate when exiting the player.
@Observable
@MainActor
public final class DisplayRateMatcher {
    public static let shared = DisplayRateMatcher()

    /// Current detected format info.
    public private(set) var currentFormat: DisplayFormatInfo?
    
    /// User setting: whether Auto-Framerate matching is enabled.
    /// tvOS defaults to true; macOS defaults to false.
    public var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "afr.enabled")
            if !isEnabled { reset() }
        }
    }

    /// Whether display criteria is currently applied.
    public private(set) var isRateMatched = false

    /// Stability debounce task.
    @ObservationIgnored
    private var pendingTask: Task<Void, Never>?

    public init() {
        #if os(tvOS)
        let defaultEnabled = true
        #else
        let defaultEnabled = false
        #endif
        if UserDefaults.standard.object(forKey: "afr.enabled") != nil {
            self.isEnabled = UserDefaults.standard.bool(forKey: "afr.enabled")
        } else {
            self.isEnabled = defaultEnabled
        }
    }

    /// Proposes a new detected frame rate and dynamic range.
    /// Debounces application for 2 seconds to ensure stability.
    public func update(rawFps: Double, gamma: String? = nil, primaries: String? = nil, width: Int? = nil, height: Int? = nil) {
        guard rawFps > 0 else { return }
        let dr = VideoDynamicRange.detect(gamma: gamma, primaries: primaries)
        let info = DisplayFormatInfo(rawFps: rawFps, dynamicRange: dr, width: width, height: height)

        guard info != currentFormat else { return }
        self.currentFormat = info

        pendingTask?.cancel()
        guard isEnabled, let matched = info.matchedRate else { return }

        pendingTask = Task { [weak self] in
            // Wait 2 seconds of playback stability before changing hardware mode
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.applyRate(matched, dynamicRange: dr)
        }
    }

    /// Resets display settings to system defaults (when leaving player or closing stream).
    public func reset() {
        pendingTask?.cancel()
        pendingTask = nil
        currentFormat = nil

        #if os(tvOS)
        if isRateMatched {
            guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let window = windowScene.windows.first else { return }
            window.avDisplayManager.preferredDisplayCriteria = nil
        }
        #endif

        isRateMatched = false
    }

    private func applyRate(_ rate: StandardFrameRate, dynamicRange: VideoDynamicRange) {
        #if os(tvOS)
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first else { return }

        let refreshRate = Float(rate.rawValue)
        // The display criteria carry the dynamic range through the format description's color keys.
        var extensions: [CFString: Any] = [:]
        switch dynamicRange {
        case .hdr10, .dolbyVision:
            extensions[kCMFormatDescriptionExtension_ColorPrimaries] = kCMFormatDescriptionColorPrimaries_ITU_R_2020
            extensions[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
            extensions[kCMFormatDescriptionExtension_YCbCrMatrix] = kCMFormatDescriptionYCbCrMatrix_ITU_R_2020
        case .hlg:
            extensions[kCMFormatDescriptionExtension_ColorPrimaries] = kCMFormatDescriptionColorPrimaries_ITU_R_2020
            extensions[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
            extensions[kCMFormatDescriptionExtension_YCbCrMatrix] = kCMFormatDescriptionYCbCrMatrix_ITU_R_2020
        case .sdr:
            break
        }
        var formatDesc: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: dynamicRange == .sdr ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC,
            width: 1920,
            height: 1080,
            extensions: extensions.isEmpty ? nil : extensions as CFDictionary,
            formatDescriptionOut: &formatDesc
        )
        if status == noErr, let formatDesc {
            let avCriteria = AVDisplayCriteria(refreshRate: refreshRate, formatDescription: formatDesc)
            window.avDisplayManager.preferredDisplayCriteria = avCriteria
            isRateMatched = true
        }
        #else
        // Only Apple TV can ask the display for a mode: on macOS the detected format is shown in the
        // player, and iOS/iPadOS manage variable refresh rates themselves (ProMotion).
        _ = (rate, dynamicRange)
        #endif
    }
}

