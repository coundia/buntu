import Foundation
#if os(macOS)
import AppKit
#elseif os(iOS) || os(tvOS) || os(visionOS)
import UIKit
#endif

/// Manages system and display sleep assertions during video playback.
///
/// Prevents the screen from dimming/turning off and prevents the system from sleeping
/// while at least one video player is actively streaming or buffering. Supports multi-controller
/// playback (e.g. MultiView) via token reference-counting so sleep is only re-enabled once
/// every active player has paused, stopped, failed, or terminated.
@MainActor
public final class PlaybackSleepManager {
    public static let shared = PlaybackSleepManager()

    private var activeTokens: Set<UUID> = []

    #if os(macOS)
    nonisolated(unsafe) private var sleepActivityToken: NSObjectProtocol?
    #endif

    /// Hook for unit tests or telemetry to observe sleep assertion toggles.
    public var onAssertionChanged: ((Bool) -> Void)?

    /// Whether sleep prevention (display & system) is currently active.
    public var isBlockingSleep: Bool {
        !activeTokens.isEmpty
    }

    /// Number of distinct players currently holding sleep prevention assertions.
    public var activeCount: Int {
        activeTokens.count
    }

    public init() {}

    deinit {
        #if os(macOS)
        if let token = sleepActivityToken {
            ProcessInfo.processInfo.endActivity(token)
        }
        #endif
    }

    /// Updates the playback state for a given player identifier.
    public func setPlaying(_ isPlaying: Bool, for id: UUID) {
        let wasBlocking = isBlockingSleep
        if isPlaying {
            activeTokens.insert(id)
        } else {
            activeTokens.remove(id)
        }

        if isBlockingSleep != wasBlocking {
            updateSleepAssertion()
        }
    }

    /// Releases any sleep assertion held by the given player identifier.
    public func remove(id: UUID) {
        guard activeTokens.contains(id) else { return }
        let wasBlocking = isBlockingSleep
        activeTokens.remove(id)

        if isBlockingSleep != wasBlocking {
            updateSleepAssertion()
        }
    }

    /// Releases all assertions and re-enables normal system sleep.
    public func reset() {
        guard !activeTokens.isEmpty else { return }
        activeTokens.removeAll()
        updateSleepAssertion()
    }

    private func updateSleepAssertion() {
        let shouldBlock = isBlockingSleep

        #if os(macOS)
        if shouldBlock {
            if sleepActivityToken == nil {
                sleepActivityToken = ProcessInfo.processInfo.beginActivity(
                    options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled, .userInitiated],
                    reason: "Lecture vidéo CND IPTV"
                )
                AppLog.shared.info("POWER", "Veille de l'écran et du système désactivée pendant la lecture vidéo (\(self.activeTokens.count) flux actif(s))")
            }
        } else {
            if let token = sleepActivityToken {
                ProcessInfo.processInfo.endActivity(token)
                sleepActivityToken = nil
                AppLog.shared.info("POWER", "Veille de l'écran et du système réactivée : fin de la lecture vidéo")
            }
        }
        #elseif os(iOS) || os(tvOS) || os(visionOS)
        if UIApplication.shared.isIdleTimerDisabled != shouldBlock {
            UIApplication.shared.isIdleTimerDisabled = shouldBlock
            if shouldBlock {
                AppLog.shared.info("POWER", "Veille de l'écran désactivée pendant la lecture vidéo (\(self.activeTokens.count) flux actif(s))")
            } else {
                AppLog.shared.info("POWER", "Veille de l'écran réactivée : fin de la lecture vidéo")
            }
        }
        #endif

        onAssertionChanged?(shouldBlock)
    }
}

