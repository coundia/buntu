import Foundation
import Network
#if os(macOS)
import AppKit
#elseif os(iOS) || os(tvOS) || os(visionOS)
import UIKit
#endif
import CndCoreBridge

/// Coordinates display and system power assertions across macOS, iOS, iPadOS, tvOS, and visionOS.
///
/// Distinguishes between two activity categories:
/// - `.videoPlayback`: requires the display to remain on and system sleep to be prevented.
/// - `.backgroundTransfer`: allows the display to turn off (black screen / display sleep)
///   while keeping the CPU, disk, and network interfaces active (on macOS), preventing auto-CEC
///   sleep on tvOS, or keeping the screen awake on iOS if configured by user setting.
@MainActor
public final class SystemPowerCoordinator {
    public static let shared = SystemPowerCoordinator()

    public enum ActivityKind: Hashable, Sendable {
        case videoPlayback
        case backgroundTransfer
    }

    private var playbackTokens: Set<UUID> = []
    private var transferTokens: Set<UUID> = []

    #if os(macOS)
    nonisolated(unsafe) private var displaySleepActivity: NSObjectProtocol?
    nonisolated(unsafe) private var systemSleepActivity: NSObjectProtocol?
    private var sleepObserver: (any NSObjectProtocol)?
    private var wakeObserver: (any NSObjectProtocol)?
    private var pathMonitor: NWPathMonitor?
    private var isNetworkSatisfied = true
    #endif

    /// When true on iOS/iPadOS, the screen will be kept awake during active downloads.
    public var keepScreenAwakeOnDownload: Bool = false {
        didSet {
            updateAssertions()
        }
    }

    public private(set) weak var engine: CndEngine?

    /// Hook for observation or unit tests.
    public var onAssertionChanged: ((_ displaySleepBlocked: Bool, _ systemSleepBlocked: Bool) -> Void)?

    /// Whether the screen is currently prevented from sleeping.
    public var isDisplaySleepBlocked: Bool {
        if !playbackTokens.isEmpty { return true }
        #if os(tvOS)
        if !transferTokens.isEmpty { return true }
        #elseif os(iOS) || os(visionOS)
        if !transferTokens.isEmpty && keepScreenAwakeOnDownload { return true }
        #endif
        return false
    }

    /// Whether background system sleep (CPU / Wi-Fi idle sleep) is currently blocked.
    public var isSystemSleepBlocked: Bool {
        !playbackTokens.isEmpty || !transferTokens.isEmpty
    }

    public var activePlaybackCount: Int {
        playbackTokens.count
    }

    public var activeTransferCount: Int {
        transferTokens.count
    }

    public init() {
        #if os(macOS)
        setupWorkspaceNotifications()
        #endif
    }

    deinit {
        #if os(macOS)
        if let token = displaySleepActivity {
            ProcessInfo.processInfo.endActivity(token)
        }
        if let token = systemSleepActivity {
            ProcessInfo.processInfo.endActivity(token)
        }
        if let obs = sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        if let obs = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        pathMonitor?.cancel()
        #endif
    }

    public func attachEngine(_ engine: CndEngine) {
        self.engine = engine
    }

    public func setHolding(_ isHolding: Bool, kind: ActivityKind, for id: UUID) {
        switch kind {
        case .videoPlayback:
            if isHolding { playbackTokens.insert(id) } else { playbackTokens.remove(id) }
        case .backgroundTransfer:
            if isHolding { transferTokens.insert(id) } else { transferTokens.remove(id) }
        }
        updateAssertions()
    }

    public func remove(id: UUID) {
        playbackTokens.remove(id)
        transferTokens.remove(id)
        updateAssertions()
    }

    public func reset() {
        playbackTokens.removeAll()
        transferTokens.removeAll()
        updateAssertions()
    }

    private func updateAssertions() {
        let blockDisplay = isDisplaySleepBlocked
        let blockSystem = isSystemSleepBlocked

        #if os(macOS)
        if blockDisplay {
            // Display and system sleep disabled (video playback)
            if let token = systemSleepActivity {
                ProcessInfo.processInfo.endActivity(token)
                systemSleepActivity = nil
            }
            if displaySleepActivity == nil {
                displaySleepActivity = ProcessInfo.processInfo.beginActivity(
                    options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled, .userInitiated],
                    reason: "Lecture vidéo \(AppBrand.name)"
                )
                AppLog.shared.info("POWER", "Veille écran et système désactivée (lecture vidéo)")
            }
        } else if blockSystem {
            // System sleep disabled, but display allowed to turn off (download / transfer)
            if let token = displaySleepActivity {
                ProcessInfo.processInfo.endActivity(token)
                displaySleepActivity = nil
            }
            if systemSleepActivity == nil {
                systemSleepActivity = ProcessInfo.processInfo.beginActivity(
                    options: [.idleSystemSleepDisabled, .userInitiated],
                    reason: "Téléchargement média \(AppBrand.name) en cours"
                )
                AppLog.shared.info("POWER", "Veille système désactivée, écran autorisé à s'éteindre (téléchargement actif)")
            }
        } else {
            // Restore normal power management
            if let token = displaySleepActivity {
                ProcessInfo.processInfo.endActivity(token)
                displaySleepActivity = nil
            }
            if let token = systemSleepActivity {
                ProcessInfo.processInfo.endActivity(token)
                systemSleepActivity = nil
            }
            AppLog.shared.info("POWER", "Gestion d'énergie normale restaurée (aucun flux ni transfert)")
        }
        #elseif os(iOS) || os(tvOS) || os(visionOS)
        if UIApplication.shared.isIdleTimerDisabled != blockDisplay {
            UIApplication.shared.isIdleTimerDisabled = blockDisplay
            if blockDisplay {
                AppLog.shared.info("POWER", "Veille écran désactivée (\(AppBrand.name))")
            } else {
                AppLog.shared.info("POWER", "Veille écran réactivée")
            }
        }
        #endif

        onAssertionChanged?(blockDisplay, blockSystem)
    }

    #if os(macOS)
    private func setupWorkspaceNotifications() {
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                AppLog.shared.info("POWER", "Notification willSleep reçue: suspension propre des téléchargements")
                if let engine = self.engine {
                    _ = try? await engine.suspendDownloadsForSystemSleep()
                }
            }
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                AppLog.shared.info("POWER", "Notification didWake reçue: attente réseau puis reprise des téléchargements")
                self.waitForNetworkAndResume()
            }
        }

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.isNetworkSatisfied = (path.status == .satisfied)
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.pcoundia.buntu.power.nwmonitor"))
        self.pathMonitor = monitor
    }

    private func waitForNetworkAndResume() {
        Task { [weak self] in
            var attempts = 0
            while attempts < 30 {
                if self?.isNetworkSatisfied == true { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
                attempts += 1
            }
            if let engine = self?.engine {
                _ = try? await engine.resumeDownloadsAfterSystemWake()
            }
        }
    }
    #endif
}
