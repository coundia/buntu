import CloudKit
import Foundation
import Observation
import CndCoreBridge
#if os(macOS)
import Security
#endif

// MARK: - Availability

enum SyncAvailability: Equatable {
    case available(containerID: String)
    /// iCloud cannot be used (no container configured, no entitlement, no account): the app keeps working locally.
    case localOnly(reason: String)
}

/// Decides whether CloudKit may be touched at all. `CKContainer` raises an Objective-C exception
/// (a crash, not a Swift error) when the entitlement is missing, so every precondition is checked
/// first and CloudKit is only reached when all of them hold.
struct CloudKitAvailabilityChecker {
    /// Info.plist key that carries the iCloud container identifier. Absent in a plain SwiftPM or
    /// "Sign to Run Locally" build, which is what keeps those builds sync-free and crash-free.
    static let containerInfoKey = "CndCloudKitContainerIdentifier"

    var infoValue: (String) -> Any?
    var hasCloudKitEntitlement: () -> Bool
    var hasICloudAccount: () -> Bool

    static let live = CloudKitAvailabilityChecker(
        infoValue: { Bundle.main.object(forInfoDictionaryKey: $0) },
        hasCloudKitEntitlement: Self.liveEntitlementCheck,
        hasICloudAccount: { FileManager.default.ubiquityIdentityToken != nil }
    )

    func current() -> SyncAvailability {
        guard let container = infoValue(Self.containerInfoKey) as? String, !container.isEmpty else {
            return .localOnly(reason: "Aucun conteneur iCloud n'est configuré dans cette version de l'application.")
        }
        guard hasCloudKitEntitlement() else {
            return .localOnly(reason: "L'application n'a pas l'autorisation iCloud (signature locale).")
        }
        guard hasICloudAccount() else {
            return .localOnly(reason: "Aucun compte iCloud n'est connecté sur cet appareil.")
        }
        return .available(containerID: container)
    }

    private static func liveEntitlementCheck() -> Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil) else {
            return false
        }
        if let services = value as? [String] { return services.contains("CloudKit") || services.contains("CloudKit-Anonymous") }
        if let service = value as? String { return service.hasPrefix("CloudKit") }
        return false
        #else
        // iOS has no public entitlement API; the Info.plist container key plus a signed-in account
        // is the gate there, and a build without the entitlement does not ship that key.
        return true
        #endif
    }
}

// MARK: - Status

enum SyncStatus: Equatable {
    case localOnly(reason: String)
    case idle
    case syncing
    case synced(Date)
    case failed(String)

    var title: String {
        switch self {
        case .localOnly: return "Mode local uniquement"
        case .idle: return "Prêt à synchroniser"
        case .syncing: return "Synchronisation…"
        case .synced(let date): return "Synchronisé à \(date.formatted(date: .omitted, time: .shortened))"
        case .failed: return "Échec de la synchronisation"
        }
    }

    var detail: String? {
        switch self {
        case .localOnly(let reason): return reason
        case .failed(let message): return message
        default: return nil
        }
    }
}

// MARK: - Transport

/// What the manager needs from CloudKit; faked in tests.
@MainActor
protocol SyncTransport: AnyObject {
    /// Set by the manager; the transport calls it with remote changes as they arrive.
    var onReceive: ((SyncDelta) async -> Void)? { get set }
    func push(_ delta: SyncDelta) async throws
    func fetch() async throws
}

// MARK: - Manager

/// Keeps sources, favorites and watch progress in step across devices through a private CloudKit
/// database. It never throws to the UI and never blocks: with no usable iCloud it simply reports
/// "Mode local uniquement".
@Observable
@MainActor
final class CloudKitSyncManager {
    static let cursorKey = "sync.lastPushTimestamp"
    /// Re-exports a little before the cursor so a change made in the same second as the last sync is not missed.
    nonisolated static var cursorOverlapSeconds: Int64 { 2 }

    let engine: CndEngine
    private(set) var status: SyncStatus
    private(set) var lastSyncDate: Date?

    @ObservationIgnored private let availability: SyncAvailability
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let makeTransport: @MainActor (String) -> SyncTransport?
    @ObservationIgnored private let now: () -> Int64
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored var onRemoteChange: (_ insertedSourceIds: [Int64]) -> Void = { _ in }

    @ObservationIgnored private var transport: SyncTransport?
    @ObservationIgnored private var scheduled: Task<Void, Never>?
    @ObservationIgnored private var isSyncing = false

    init(
        engine: CndEngine,
        availability: SyncAvailability = CloudKitAvailabilityChecker.live.current(),
        defaults: UserDefaults = .standard,
        debounce: Duration = .seconds(2),
        now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970) },
        makeTransport: (@MainActor (String) -> SyncTransport?)? = nil
    ) {
        self.engine = engine
        self.availability = availability
        self.defaults = defaults
        self.debounce = debounce
        self.now = now
        self.makeTransport = makeTransport ?? { CKSyncEngineTransport(containerID: $0) }
        switch availability {
        case .localOnly(let reason): status = .localOnly(reason: reason)
        case .available: status = .idle
        }
    }

    var isAvailable: Bool {
        if case .available = availability { return true }
        return false
    }

    var cursor: Int64 { Int64(defaults.integer(forKey: Self.cursorKey)) }

    func start() {
        guard case .available(let containerID) = availability, transport == nil else { return }
        guard let transport = makeTransport(containerID) else {
            status = .localOnly(reason: "Impossible d'initialiser CloudKit sur cet appareil.")
            return
        }
        transport.onReceive = { [weak self] delta in await self?.receive(delta) }
        self.transport = transport
        scheduleSync(after: .zero)
    }

    func stop() {
        scheduled?.cancel()
        scheduled = nil
        transport = nil
    }

    /// Coalesces bursts of local changes (several favorites in a row) into one sync.
    func scheduleSync(after delay: Duration? = nil) {
        guard transport != nil else { return }
        scheduled?.cancel()
        let wait = delay ?? debounce
        scheduled = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    func syncNow() async {
        guard let transport, !isSyncing else { return }
        isSyncing = true
        status = .syncing
        defer { isSyncing = false }
        let startedAt = now()
        let since = max(0, cursor - Self.cursorOverlapSeconds)
        let engine = self.engine
        do {
            let delta = try await Task.detached(priority: .utility) { try engine.exportSyncDelta(sinceTs: since) }.value
            if !SyncDeltaInspector.isEmpty(delta) { try await transport.push(delta) }
            try await transport.fetch()
            defaults.set(Int(startedAt), forKey: Self.cursorKey)
            let date = Date()
            lastSyncDate = date
            status = .synced(date)
        } catch {
            status = .failed(userMessage(for: error))
        }
    }

    /// Merges remote changes; sources created this way have no catalog yet and are reported so the app can refresh them.
    func receive(_ delta: SyncDelta) async {
        guard !SyncDeltaInspector.isEmpty(delta) else { return }
        let engine = self.engine
        do {
            let summary = try await Task.detached(priority: .utility) { try engine.importSyncDelta(delta: delta) }.value
            if summary.sourcesApplied + summary.favoritesApplied + summary.watchApplied + summary.deletionsApplied > 0 {
                onRemoteChange(summary.insertedSourceIds)
            }
        } catch {
            status = .failed(userMessage(for: error))
        }
    }
}

enum SyncDeltaInspector {
    static func isEmpty(_ delta: SyncDelta) -> Bool {
        delta.sources.isEmpty && delta.favorites.isEmpty && delta.watchHistory.isEmpty && delta.tombstones.isEmpty
    }
}

// MARK: - CKSyncEngine transport

/// Real CloudKit transport. Only built when `CloudKitAvailabilityChecker` reports `.available`,
/// so it is never constructed in a build without the iCloud entitlement.
@MainActor
final class CKSyncEngineTransport: NSObject, SyncTransport, CKSyncEngineDelegate {
    static let stateKey = "sync.ck.stateSerialization"

    var onReceive: ((SyncDelta) async -> Void)?

    private let mapper = SyncRecordMapper()
    private let defaults: UserDefaults
    private var pending: [CKRecord.ID: CKRecord] = [:]
    private var engine: CKSyncEngine?

    init?(containerID: String, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
        let container = CKContainer(identifier: containerID)
        var serialization: CKSyncEngine.State.Serialization?
        if let data = defaults.data(forKey: Self.stateKey) {
            serialization = try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
        }
        var configuration = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase, stateSerialization: serialization, delegate: self
        )
        configuration.automaticallySync = true
        engine = CKSyncEngine(configuration)
    }

    func push(_ delta: SyncDelta) async throws {
        guard let engine else { return }
        let records = mapper.records(from: delta)
        let deletions = mapper.deletions(from: delta)
        for record in records { pending[record.recordID] = record }
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: mapper.zoneID))])
        engine.state.add(pendingRecordZoneChanges:
            records.map { .saveRecord($0.recordID) } + deletions.map { .deleteRecord($0) }
        )
        try await engine.sendChanges()
    }

    func fetch() async throws {
        try await engine?.fetchChanges()
    }

    // MARK: CKSyncEngineDelegate

    nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            if let data = try? JSONEncoder().encode(update.stateSerialization) {
                await MainActor.run { defaults.set(data, forKey: Self.stateKey) }
            }
        case .fetchedRecordZoneChanges(let changes):
            let saved = changes.modifications.map(\.record)
            let deleted = changes.deletions.map(\.recordID)
            let now = Int64(Date().timeIntervalSince1970)
            let delta = await MainActor.run { mapper.delta(fromSaved: saved, deleted: deleted, now: now) }
            let handler = await MainActor.run { onReceive }
            await handler?(delta)
        case .accountChange(let change):
            if case .signOut = change.changeType {
                await MainActor.run { defaults.removeObject(forKey: Self.stateKey) }
            }
        default:
            break
        }
    }

    nonisolated func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let changes = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        let records = await MainActor.run { pending }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { recordID in
            records[recordID]
        }
    }
}
