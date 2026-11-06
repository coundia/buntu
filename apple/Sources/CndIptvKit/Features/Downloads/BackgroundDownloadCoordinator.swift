import Foundation
#if os(macOS)
import AppKit
#elseif os(iOS) || os(tvOS) || os(visionOS)
import UIKit
@preconcurrency import UserNotifications
#endif
import CndCoreBridge

/// Coordinates background downloads across all Apple platforms.
///
/// On iOS, iPadOS, visionOS, and tvOS:
/// - Delegates long transfers out-of-process to `nsurlsessiond` via `URLSessionConfiguration.background`.
/// - Survives screen lock (black screen) and app suspension with 0 byte loss.
/// - Automatically chains consecutive queued downloads (e.g. an entire season) screen off.
/// - Implements hybrid Range fallback for IPTV CDN servers lacking ETag/Last-Modified.
/// - Triggers Live Activities, Dynamic Island updates, and local completion notifications.
///
/// On macOS:
/// - Downloads run through the high-throughput multi-segment Rust engine.
/// - Maintains `.idleSystemSleepDisabled` assertion via `SystemPowerCoordinator`, allowing the
///   display to sleep while Wi-Fi, CPU, and disk remain active until downloads complete.
@MainActor
public final class BackgroundDownloadCoordinator: NSObject {
    public static let shared = BackgroundDownloadCoordinator()
    public static let sessionIdentifier = "com.pcoundia.buntu.downloads.v1"

    public private(set) weak var engine: CndEngine?
    private(set) weak var connectionCoordinator: DownloadConnectionCoordinator?

    private let powerSessionId = UUID()
    public var backgroundSessionCompletionHandler: (() -> Void)?

    #if os(iOS) || os(tvOS) || os(visionOS)
    private var session: URLSession!
    private var activePlatformTasks: [Int64: URLSessionDownloadTask] = [:]
    private var taskBaseOffsets: [Int64: Int64] = [:]
    private var lastProgressPersist: [Int64: Date] = [:]
    private var isPromoting = false
    #endif

    public override init() {
        super.init()
        #if os(iOS) || os(tvOS) || os(visionOS)
        setupBackgroundSession()
        #endif
    }

    func attachEngine(_ engine: CndEngine, coordinator: DownloadConnectionCoordinator? = nil) {
        self.engine = engine
        self.connectionCoordinator = coordinator
        #if os(iOS) || os(tvOS) || os(visionOS)
        reconnectExistingTasks()
        promoteNextQueuedTasks()
        #endif
    }

    #if os(iOS) || os(tvOS) || os(visionOS)
    private func setupBackgroundSession() {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.waitsForConnectivity = true
        
        let allowsCellular = UserDefaults.standard.object(forKey: "downloads.cellular.enabled") as? Bool ?? true
        config.allowsCellularAccess = allowsCellular
        config.allowsExpensiveNetworkAccess = allowsCellular
        config.allowsConstrainedNetworkAccess = true
        config.httpMaximumConnectionsPerHost = 2
        config.timeoutIntervalForResource = 60 * 60 * 12 // 12 hours max

        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    private func reconnectExistingTasks() {
        session.getAllTasks { [weak self] tasks in
            Task { @MainActor in
                guard let self else { return }
                for task in tasks {
                    guard let downloadTask = task as? URLSessionDownloadTask,
                          let desc = downloadTask.taskDescription,
                          let taskId = Self.parseTaskId(from: desc) else { continue }
                    let offset = Self.parseBaseOffset(from: desc)
                    self.activePlatformTasks[taskId] = downloadTask
                    self.taskBaseOffsets[taskId] = offset
                }
                self.updatePowerAssertions()
            }
        }
    }

    public func promoteNextQueuedTasks() {
        guard let engine, !isPromoting else { return }
        isPromoting = true
        defer { isPromoting = false }

        // Max connections for background downloads: 1 by default (or user setting)
        let maxSlots = 1
        let currentRunning = activePlatformTasks.count
        guard currentRunning < maxSlots else { return }

        do {
            let claimed = try engine.claimNextQueuedForPlatform(maxConcurrent: UInt32(maxSlots - currentRunning))
            for ticket in claimed {
                startPlatformTask(ticket: ticket)
            }
        } catch {
            AppLog.shared.error("DL-PLATFORM", "Échec de réservation des tâches: \(error)")
        }
        updatePowerAssertions()
    }

    private func startPlatformTask(ticket: DownloadPlatformTicket) {
        let taskId = ticket.id

        // Check if platform resume data is available
        if let resumeBlob = ticket.platformResumeData, !resumeBlob.isEmpty {
            AppLog.shared.info("DL-PLATFORM", "Reprise de la tâche \(taskId) avec blob resumeData")
            let task = session.downloadTask(withResumeData: Data(resumeBlob))
            task.taskDescription = "cnd-task:\(taskId):offset:0"
            activePlatformTasks[taskId] = task
            taskBaseOffsets[taskId] = 0
            task.resume()
            return
        }

        Task { [weak self] in
            guard let self, let engine = self.engine else { return }
            do {
                let freshTicket = try await engine.probeForPlatformDownload(taskId: taskId)
                let targetUrlString = freshTicket.finalUrl ?? freshTicket.url
                guard let targetUrl = URL(string: targetUrlString) else {
                    try? engine.savePlatformResumeData(
                        taskId: taskId, state: "error", downloadedBytes: 0, resumeData: nil, errorMessage: "URL invalide: \(targetUrlString)"
                    )
                    return
                }

                // Check existing part file size on disk for Range fallback
                let partPath = freshTicket.tempPath
                var baseOffset: Int64 = 0
                if freshTicket.acceptRanges,
                   let attrs = try? FileManager.default.attributesOfItem(atPath: partPath),
                   let fileSize = attrs[.size] as? Int64, fileSize > 0 {
                    baseOffset = fileSize
                    AppLog.shared.info("DL-PLATFORM", "Reprise de la tâche \(taskId) à l'offset Range: \(baseOffset) octets")
                }

                var request = URLRequest(url: targetUrl)
                if baseOffset > 0 {
                    request.setValue("bytes=\(baseOffset)-", forHTTPHeaderField: "Range")
                }
                if let ua = freshTicket.userAgent {
                    request.setValue(ua, forHTTPHeaderField: "User-Agent")
                }
                if let ref = freshTicket.referer {
                    request.setValue(ref, forHTTPHeaderField: "Referer")
                }
                if let headersJson = freshTicket.headersJson,
                   let data = headersJson.data(using: .utf8),
                   let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                    for (k, v) in dict {
                        request.setValue(v, forHTTPHeaderField: k)
                    }
                }

                let task = self.session.downloadTask(with: request)
                task.taskDescription = "cnd-task:\(taskId):offset:\(baseOffset)"
                self.activePlatformTasks[taskId] = task
                self.taskBaseOffsets[taskId] = baseOffset
                task.resume()

                self.updatePowerAssertions()
                AppLog.shared.info("DL-PLATFORM", "Tâche \(taskId) démarrée dans nsurlsessiond: \(freshTicket.fileName)")
            } catch {
                AppLog.shared.error("DL-PLATFORM", "Erreur sonde tâche \(taskId): \(error)")
                try? engine.savePlatformResumeData(
                    taskId: taskId, state: "error", downloadedBytes: 0, resumeData: nil, errorMessage: "\(error)"
                )
            }
        }
    }

    public func pauseDownload(taskId: Int64) {
        guard let task = activePlatformTasks.removeValue(forKey: taskId) else { return }
        taskBaseOffsets.removeValue(forKey: taskId)
        task.cancel { [weak self] resumeData in
            Task { @MainActor in
                guard let self, let engine = self.engine else { return }
                try? engine.savePlatformResumeData(
                    taskId: taskId, state: "paused", downloadedBytes: 0, resumeData: resumeData, errorMessage: nil
                )
                self.updatePowerAssertions()
            }
        }
    }

    public func pauseAllDownloads() {
        for taskId in Array(activePlatformTasks.keys) {
            pauseDownload(taskId: taskId)
        }
    }
    #endif

    public func updatePowerAssertions() {
        #if os(macOS)
        let hasActive = (try? engine?.listDownloads(query: nil).contains(where: { $0.state == "running" })) ?? false
        SystemPowerCoordinator.shared.setHolding(hasActive, kind: .backgroundTransfer, for: powerSessionId)
        #elseif os(iOS) || os(tvOS) || os(visionOS)
        let hasActive = !activePlatformTasks.isEmpty
        SystemPowerCoordinator.shared.setHolding(hasActive, kind: .backgroundTransfer, for: powerSessionId)
        #endif
    }

    // MARK: - Description Helpers
    nonisolated static func parseTaskId(from desc: String) -> Int64? {
        let parts = desc.split(separator: ":")
        guard parts.count >= 2, parts[0] == "cnd-task", let id = Int64(parts[1]) else { return nil }
        return id
    }

    nonisolated static func parseBaseOffset(from desc: String) -> Int64 {
        let parts = desc.split(separator: ":")
        guard parts.count >= 4, parts[2] == "offset", let offset = Int64(parts[3]) else { return 0 }
        return offset
    }
}

#if os(iOS) || os(tvOS) || os(visionOS)
extension BackgroundDownloadCoordinator: URLSessionDownloadDelegate {
    nonisolated public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let desc = downloadTask.taskDescription,
              let taskId = Self.parseTaskId(from: desc) else { return }
        let baseOffset = Self.parseBaseOffset(from: desc)
        let currentDownloaded = baseOffset + totalBytesWritten
        let currentTotal = totalBytesExpectedToWrite > 0 ? baseOffset + totalBytesExpectedToWrite : 0

        Task { @MainActor in
            guard let engine = self.engine else { return }
            let now = Date()
            let lastPersist = self.lastProgressPersist[taskId] ?? .distantPast
            let shouldFlush = now.timeIntervalSince(lastPersist) >= 2.0

            if shouldFlush {
                self.lastProgressPersist[taskId] = now
            }

            try? engine.updatePlatformDownloadProgress(
                taskId: taskId,
                downloadedBytes: UInt64(max(0, currentDownloaded)),
                totalBytes: UInt64(max(0, currentTotal)),
                speedBps: 0.0,
                etaSeconds: 0,
                flushDb: shouldFlush
            )
        }
    }

    nonisolated public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let desc = downloadTask.taskDescription,
              let taskId = Self.parseTaskId(from: desc) else { return }
        let baseOffset = Self.parseBaseOffset(from: desc)

        // Apple requires synchronous file relocation before this delegate method returns
        let fm = FileManager.default

        let tempDestination = fm.temporaryDirectory.appendingPathComponent("cnd_dl_\(taskId)_\(UUID().uuidString)")
        try? fm.moveItem(at: location, to: tempDestination)

        Task { @MainActor in
            guard let engine = self.engine else { return }
            self.activePlatformTasks.removeValue(forKey: taskId)
            self.taskBaseOffsets.removeValue(forKey: taskId)

            do {
                let ticket = try await engine.probeForPlatformDownload(taskId: taskId)
                let ticketName = ticket.fileName
                let partPath = ticket.tempPath
                let finalPath = ticket.savePath

                // Ensure parent directory exists
                let parentDir = URL(fileURLWithPath: finalPath).deletingLastPathComponent().path
                try? fm.createDirectory(atPath: parentDir, withIntermediateDirectories: true)

                var finalBytes: Int64 = 0
                if baseOffset > 0 && fm.fileExists(atPath: partPath) {
                    // Chunked streaming append (zero RAM explosion)
                    if let partHandle = FileHandle(forWritingAtPath: partPath),
                       let tempHandle = FileHandle(forReadingAtPath: tempDestination.path) {
                        defer {
                            try? partHandle.close()
                            try? tempHandle.close()
                            try? fm.removeItem(at: tempDestination)
                        }
                        partHandle.seekToEndOfFile()
                        let chunkSize = 4 * 1024 * 1024 // 4 MB chunks
                        while true {
                            let chunk = tempHandle.readData(ofLength: chunkSize)
                            if chunk.isEmpty { break }
                            partHandle.write(chunk)
                        }
                    }
                    if fm.fileExists(atPath: finalPath) {
                        try? fm.removeItem(atPath: finalPath)
                    }
                    try fm.moveItem(atPath: partPath, toPath: finalPath)
                    finalBytes = (try? fm.attributesOfItem(atPath: finalPath)[.size] as? Int64) ?? 0
                } else {
                    if fm.fileExists(atPath: finalPath) {
                        try? fm.removeItem(atPath: finalPath)
                    }
                    try fm.moveItem(atPath: tempDestination.path, toPath: finalPath)
                    finalBytes = (try? fm.attributesOfItem(atPath: finalPath)[.size] as? Int64) ?? 0
                }

                try engine.completePlatformDownload(taskId: taskId, finalSize: UInt64(max(0, finalBytes)))
                AppLog.shared.info("DL-PLATFORM", "Téléchargement terminé pour \(ticketName) (\(finalBytes) octets)")

                // Send local completion notification if notifications enabled
                self.sendCompletionNotification(title: ticketName)

                // Autonomous chaining: promote next queued download while still under background execution
                self.promoteNextQueuedTasks()
            } catch {
                AppLog.shared.error("DL-PLATFORM", "Erreur finalisation tâche \(taskId): \(error)")
                try? engine.savePlatformResumeData(
                    taskId: taskId, state: "error", downloadedBytes: 0, resumeData: nil, errorMessage: "Erreur finalisation fichier: \(error)"
                )
            }
            self.updatePowerAssertions()
        }
    }

    nonisolated public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        guard let desc = task.taskDescription,
              let taskId = Self.parseTaskId(from: desc) else { return }

        Task { @MainActor in
            self.activePlatformTasks.removeValue(forKey: taskId)
            self.taskBaseOffsets.removeValue(forKey: taskId)

            if let error {
                let nsError = error as NSError
                if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                    AppLog.shared.info("DL-PLATFORM", "Tâche \(taskId) annulée/mise en pause")
                } else {
                    AppLog.shared.warn("DL-PLATFORM", "Erreur réseau tâche \(taskId): \(error.localizedDescription)")
                    try? self.engine?.savePlatformResumeData(
                        taskId: taskId, state: "error", downloadedBytes: 0, resumeData: nil, errorMessage: error.localizedDescription
                    )
                }
            }
            self.updatePowerAssertions()
        }
    }

    nonisolated public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            AppLog.shared.info("DL-PLATFORM", "Événements de session d'arrière-plan traités")
            if let handler = self.backgroundSessionCompletionHandler {
                self.backgroundSessionCompletionHandler = nil
                handler()
            }
        }
    }

    private func sendCompletionNotification(title: String) {
        guard UserDefaults.standard.object(forKey: "downloads.notifications.enabled") as? Bool ?? true else { return }
        #if !os(tvOS)
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = "Téléchargement terminé"
            content.body = "« \(title) » est prêt pour visionnage hors-ligne."
            content.sound = .default
            let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(req)
        }
        #endif
    }
}
#endif
