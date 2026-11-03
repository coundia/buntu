import Foundation
import Observation
import CndCoreBridge

/// Edits `RuntimeSettings` and the OMDb key. Changes are saved after a short pause (so typing a
/// User-Agent does not rebuild the HTTP pool on every keystroke); `flush()` saves immediately.
@Observable
@MainActor
final class SettingsModel {
    nonisolated static var segmentRange: ClosedRange<Int> { 1...16 }
    nonisolated static var partSizeRangeMB: ClosedRange<Int> { 1...256 }
    nonisolated static var activeFilesRange: ClosedRange<Int> { 1...8 }

    let engine: CndEngine
    let keychain: KeychainStore
    let directory: DownloadDirectoryManager
    @ObservationIgnored var onConsoleVisibilityChanged: (Bool) -> Void = { _ in }

    var segmentsPerFile: Int { didSet { scheduleSave() } }
    var partSizeMB: Int { didSet { scheduleSave() } }
    var maxActiveFiles: Int { didSet { scheduleSave() } }
    var userAgent: String { didSet { scheduleSave() } }
    var referer: String { didSet { scheduleSave() } }
    var showNetworkConsole: Bool { didSet { scheduleSave(after: .zero) } }
    var omdbKey: String { didSet { scheduleSave() } }

    /// Whether Xtream passwords live in iCloud Keychain (opt-in, see `setPasswordSync`).
    private(set) var syncsPasswords: Bool
    private(set) var passwordSyncError: String?

    private(set) var errorMessage: String?
    private(set) var saveCount = 0
    private(set) var cacheClearedAt: Date?

    @ObservationIgnored private let saveDelay: Duration
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var base: RuntimeSettings

    init(
        engine: CndEngine,
        keychain: KeychainStore = .shared,
        directory: DownloadDirectoryManager,
        saveDelay: Duration = .milliseconds(400)
    ) {
        self.engine = engine
        self.keychain = keychain
        self.directory = directory
        self.saveDelay = saveDelay
        let settings = engine.getSettings()
        base = settings
        segmentsPerFile = Int(settings.segmentsPerFile)
        partSizeMB = Int(settings.partSizeBytes / (1024 * 1024))
        maxActiveFiles = Int(settings.maxActiveFiles)
        userAgent = settings.defaultUserAgent
        referer = settings.defaultReferer ?? ""
        showNetworkConsole = settings.showNetworkConsole
        omdbKey = (try? keychain.readSecret(forKey: KeychainStore.omdbApiKeyRef)) ?? ""
        syncsPasswords = keychain.passwordScope == .iCloud
    }

    /// Turns the iCloud Keychain option on or off and moves the existing source passwords with it.
    /// The choice is only recorded once every password has moved; on failure nothing changes.
    func setPasswordSync(_ enabled: Bool) {
        passwordSyncError = nil
        let sources = (try? engine.listSources()) ?? []
        let keys = sources.filter { $0.sourceType == "xtream" }
            .map { $0.passwordRef ?? KeychainStore.xtreamKey(forSourceUuid: $0.uuid) }
        do {
            try keychain.move(keys: keys, to: enabled ? .iCloud : .local)
            keychain.passwordScope = enabled ? .iCloud : .local
            syncsPasswords = enabled
        } catch {
            passwordSyncError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            syncsPasswords = keychain.passwordScope == .iCloud
        }
    }

    private func scheduleSave(after delay: Duration? = nil) {
        saveTask?.cancel()
        let wait = delay ?? saveDelay
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    /// Saves now and cancels any pending delayed save.
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        save()
    }

    /// Called after the download folder changed (it is part of the persisted settings).
    func downloadDirectoryChanged() { scheduleSave(after: .zero) }

    func save() {
        let trimmedAgent = userAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedReferer = referer.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = omdbKey.trimmingCharacters(in: .whitespacesAndNewlines)

        var settings = base
        settings.segmentsPerFile = UInt32(segmentsPerFile.clamped(to: Self.segmentRange))
        settings.partSizeBytes = UInt64(partSizeMB.clamped(to: Self.partSizeRangeMB)) * 1024 * 1024
        settings.maxActiveFiles = UInt32(maxActiveFiles.clamped(to: Self.activeFilesRange))
        settings.defaultUserAgent = trimmedAgent.isEmpty ? base.defaultUserAgent : trimmedAgent
        settings.defaultReferer = trimmedReferer.isEmpty ? nil : trimmedReferer
        settings.downloadDir = directory.isCustom ? directory.directory.path : nil
        settings.showNetworkConsole = showNetworkConsole
        settings.omdbApiKeyRef = trimmedKey.isEmpty ? nil : KeychainStore.omdbApiKeyRef

        do {
            if trimmedKey.isEmpty {
                try keychain.deleteSecret(forKey: KeychainStore.omdbApiKeyRef)
            } else {
                try keychain.saveSecret(trimmedKey, forKey: KeychainStore.omdbApiKeyRef)
            }
            try engine.updateSettings(settings: settings)
            let consoleChanged = base.showNetworkConsole != settings.showNetworkConsole
            base = settings
            errorMessage = nil
            saveCount += 1
            if consoleChanged { onConsoleVisibilityChanged(settings.showNetworkConsole) }
        } catch {
            errorMessage = userMessage(for: error)
        }
    }

    // MARK: Diagnostics

    func clearImageCache() async {
        await ImageThumbnailCache.shared.clearAll()
        cacheClearedAt = Date()
    }

    var engineVersion: String { engine.version() }

    nonisolated static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(version) (\($0))" } ?? version
    }
}

extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int { Swift.min(Swift.max(self, range.lowerBound), range.upperBound) }
}
