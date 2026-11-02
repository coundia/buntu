import XCTest
import CloudKit
import CndCoreBridge
@testable import CndIptvApp

// MARK: - Mapper

final class SyncRecordMapperTests: XCTestCase {
    private let mapper = SyncRecordMapper()

    private var sample: SyncDelta {
        SyncDelta(
            sources: [
                SyncSource(uuid: "u1", name: "Premium", sourceType: "xtream", url: nil, server: "http://srv:80",
                           username: "bob", passwordRef: "cnd.xtream.u1", epgUrl: nil, updatedAt: 1_700_000_100),
                SyncSource(uuid: "u2", name: "Freebox", sourceType: "m3u", url: "http://x/l.m3u", server: nil,
                           username: nil, passwordRef: nil, epgUrl: "http://x/epg.xml", updatedAt: 1_700_000_200),
            ],
            favorites: [SyncFavorite(stableHash: "movie_1", itemKind: "movie", createdAt: 1_700_000_300)],
            watchHistory: [SyncWatchProgress(stableHash: "movie_1", positionMs: 42_000, durationMs: 100_000, completed: false, lastWatchedAt: 1_700_000_400)],
            tombstones: [
                SyncTombstone(kind: "favorite", key: "movie_9", deletedAt: 1_700_000_500),
                SyncTombstone(kind: "source", key: "u9", deletedAt: 1_700_000_600),
            ]
        )
    }

    func testOnlyTheThreeUserDataRecordTypesExist() {
        let types = Set(mapper.records(from: sample).map(\.recordType))
        XCTAssertEqual(types, ["CndSource", "CndFavorite", "CndWatchProgress"])
        for forbidden in ["iptv_items", "epg_programs", "CndItem", "CndEpg"] {
            XCTAssertFalse(types.contains(forbidden))
        }
    }

    func testRecordsRoundTripBackToTheSameDelta() {
        let records = mapper.records(from: sample)
        XCTAssertEqual(records.count, 4)
        let back = mapper.delta(fromSaved: records, deleted: [], now: 0)
        XCTAssertEqual(back.sources, sample.sources)
        XCTAssertEqual(back.favorites, sample.favorites)
        XCTAssertEqual(back.watchHistory, sample.watchHistory)
        XCTAssertTrue(back.tombstones.isEmpty)
    }

    func testRecordsLiveInTheCustomZoneWithStableNames() {
        let names = Set(mapper.records(from: sample).map(\.recordID.recordName))
        XCTAssertEqual(names, ["src:u1", "src:u2", "fav:movie_1", "watch:movie_1"])
        XCTAssertTrue(mapper.records(from: sample).allSatisfy { $0.recordID.zoneID == mapper.zoneID })
    }

    func testOptionalFieldsAreAbsentNotNull() {
        let source = mapper.records(from: sample).first { $0.recordID.recordName == "src:u1" }
        XCTAssertNil(source?["url"])
        XCTAssertEqual(source?["server"] as? String, "http://srv:80")
        XCTAssertEqual(source?["passwordRef"] as? String, "cnd.xtream.u1", "only the Keychain reference travels")
    }

    func testTombstonesBecomeRecordDeletionsAndBack() {
        let ids = mapper.deletions(from: sample)
        XCTAssertEqual(Set(ids.map(\.recordName)), ["fav:movie_9", "src:u9"])

        let back = mapper.delta(fromSaved: [], deleted: ids + [CKRecord.ID(recordName: "watch:x", zoneID: mapper.zoneID)], now: 777)
        XCTAssertEqual(Set(back.tombstones.map { "\($0.kind):\($0.key)" }), ["favorite:movie_9", "source:u9"])
        XCTAssertTrue(back.tombstones.allSatisfy { $0.deletedAt == 777 })
    }

    func testMalformedOrUnknownRecordsAreIgnored() {
        let broken = CKRecord(recordType: "CndFavorite", recordID: CKRecord.ID(recordName: "fav:x", zoneID: mapper.zoneID))
        let unknown = CKRecord(recordType: "SomethingElse", recordID: CKRecord.ID(recordName: "zzz", zoneID: mapper.zoneID))
        let back = mapper.delta(fromSaved: [broken, unknown], deleted: [], now: 0)
        XCTAssertTrue(SyncDeltaInspector.isEmpty(back))
    }
}

// MARK: - Availability (graceful degradation)

final class CloudKitAvailabilityTests: XCTestCase {
    private func checker(container: String? = "iCloud.com.cnd.iptv", entitlement: Bool = true, account: Bool = true) -> CloudKitAvailabilityChecker {
        CloudKitAvailabilityChecker(
            infoValue: { $0 == CloudKitAvailabilityChecker.containerInfoKey ? container : nil },
            hasCloudKitEntitlement: { entitlement },
            hasICloudAccount: { account }
        )
    }

    func testEveryMissingPrerequisiteMeansLocalOnlyWithAReason() {
        for sut in [checker(container: nil), checker(container: ""), checker(entitlement: false), checker(account: false)] {
            guard case .localOnly(let reason) = sut.current() else { return XCTFail("expected local only") }
            XCTAssertFalse(reason.isEmpty)
        }
        XCTAssertEqual(checker().current(), .available(containerID: "iCloud.com.cnd.iptv"))
    }

    func testEntitlementIsNotEvenConsultedWithoutAContainer() {
        var consulted = false
        let sut = CloudKitAvailabilityChecker(
            infoValue: { _ in nil },
            hasCloudKitEntitlement: { consulted = true; return true },
            hasICloudAccount: { consulted = true; return true }
        )
        XCTAssertEqual(sut.current(), .localOnly(reason: "Aucun conteneur iCloud n'est configuré dans cette version de l'application."))
        XCTAssertFalse(consulted)
    }

    func testThisBuildRunsLocalOnlyWithoutTouchingCloudKit() {
        // `swift test` and "Sign to Run Locally" builds have no container key in Info.plist.
        guard case .localOnly = CloudKitAvailabilityChecker.live.current() else {
            return XCTFail("a build without iCloud configuration must stay local")
        }
    }
}

// MARK: - Manager

@MainActor
final class LoopbackTransport: SyncTransport {
    var onReceive: ((SyncDelta) async -> Void)?
    weak var peer: LoopbackTransport?
    var pushError: Error?
    private(set) var pushed: [SyncDelta] = []
    private(set) var fetchCount = 0

    func push(_ delta: SyncDelta) async throws {
        if let pushError { throw pushError }
        pushed.append(delta)
        await peer?.onReceive?(delta)
    }

    func fetch() async throws { fetchCount += 1 }
}

@MainActor
final class CloudKitSyncManagerTests: XCTestCase {
    private var defaultsA: UserDefaults!
    private var defaultsB: UserDefaults!
    private var suites: [String] = []

    override func setUp() async throws {
        suites = ["cnd.sync.a.\(UUID())", "cnd.sync.b.\(UUID())"]
        defaultsA = UserDefaults(suiteName: suites[0])
        defaultsB = UserDefaults(suiteName: suites[1])
    }

    override func tearDown() async throws {
        suites.forEach { UserDefaults(suiteName: $0)?.removePersistentDomain(forName: $0) }
    }

    /// Two devices wired through a loopback "cloud".
    private func makePair(now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970) }) throws
        -> (a: CloudKitSyncManager, b: CloudKitSyncManager, engineA: CndEngine, engineB: CndEngine, ta: LoopbackTransport, tb: LoopbackTransport) {
        let engineA = try CndEngine.inMemory()
        let engineB = try CndEngine.inMemory()
        let ta = LoopbackTransport()
        let tb = LoopbackTransport()
        ta.peer = tb
        tb.peer = ta
        let a = CloudKitSyncManager(engine: engineA, availability: .available(containerID: "c"), defaults: defaultsA, debounce: .milliseconds(30), now: now, makeTransport: { _ in ta })
        let b = CloudKitSyncManager(engine: engineB, availability: .available(containerID: "c"), defaults: defaultsB, debounce: .milliseconds(30), now: now, makeTransport: { _ in tb })
        return (a, b, engineA, engineB, ta, tb)
    }

    func testLocalOnlyNeverCreatesATransportAndNeverFails() async throws {
        var factoryCalls = 0
        let manager = CloudKitSyncManager(
            engine: try CndEngine.inMemory(),
            availability: .localOnly(reason: "Pas de compte"),
            defaults: defaultsA,
            makeTransport: { _ in factoryCalls += 1; return nil }
        )
        manager.start()
        manager.scheduleSync(after: .zero)
        await manager.syncNow()
        XCTAssertEqual(factoryCalls, 0)
        XCTAssertFalse(manager.isAvailable)
        XCTAssertEqual(manager.status, .localOnly(reason: "Pas de compte"))
        XCTAssertEqual(manager.status.title, "Mode local uniquement")
        XCTAssertEqual(manager.status.detail, "Pas de compte")
    }

    func testAnUnavailableTransportFallsBackToLocalOnlyInsteadOfCrashing() throws {
        let manager = CloudKitSyncManager(
            engine: try CndEngine.inMemory(), availability: .available(containerID: "c"), defaults: defaultsA,
            makeTransport: { _ in nil }
        )
        manager.start()
        guard case .localOnly = manager.status else { return XCTFail("expected local only, got \(manager.status)") }
    }

    func testChangesFlowFromOneDeviceToTheOther() async throws {
        let pair = try makePair()
        pair.a.start()
        pair.b.start()

        _ = try pair.engineA.addSource(name: "Premium", sourceType: "m3u", url: "http://x/l.m3u", server: nil, username: nil, passwordRef: nil)
        _ = try pair.engineA.toggleFavorite(stableHash: "movie_1", itemKind: "movie")
        try pair.engineA.recordWatchProgress(stableHash: "movie_1", positionMs: 42_000, durationMs: 100_000)

        var remoteChanges: [[Int64]] = []
        pair.b.onRemoteChange = { remoteChanges.append($0) }
        await pair.a.syncNow()

        guard case .synced = pair.a.status else { return XCTFail("expected synced, got \(pair.a.status)") }
        XCTAssertNotNil(pair.a.lastSyncDate)
        XCTAssertEqual(pair.ta.pushed.count, 1)
        XCTAssertGreaterThan(pair.ta.fetchCount, 0)

        XCTAssertEqual(try pair.engineB.listSources().map(\.name), ["Premium"])
        let delta = try pair.engineB.exportSyncDelta(sinceTs: 0)
        XCTAssertEqual(delta.favorites.map(\.stableHash), ["movie_1"])
        XCTAssertEqual(delta.watchHistory.first?.positionMs, 42_000)
        XCTAssertEqual(remoteChanges.count, 1)
        XCTAssertEqual(remoteChanges.first?.count, 1, "the new source is reported so it can be refreshed")
        XCTAssertEqual(try pair.engineB.listSources().first?.itemCount, 0, "no catalog travels")
    }

    func testRemovingAFavoriteOnOneDeviceRemovesItOnTheOther() async throws {
        let pair = try makePair()
        pair.a.start()
        pair.b.start()

        _ = try pair.engineA.toggleFavorite(stableHash: "m", itemKind: "movie")
        await pair.a.syncNow()
        XCTAssertEqual(try pair.engineB.exportSyncDelta(sinceTs: 0).favorites.count, 1)

        // Later (a different second: ties favor the favorite) the favorite is removed on A.
        try await Task.sleep(for: .milliseconds(1_100))
        _ = try pair.engineA.toggleFavorite(stableHash: "m", itemKind: "movie")
        await pair.a.syncNow()
        let onB = try pair.engineB.exportSyncDelta(sinceTs: 0)
        XCTAssertTrue(onB.favorites.isEmpty)
        XCTAssertEqual(onB.tombstones.count, 1)
    }

    func testTheCursorAdvancesAndNothingIsResentWhenIdle() async throws {
        var clock: Int64 = 1_000
        let pair = try makePair(now: { clock })
        pair.a.start()
        XCTAssertEqual(pair.a.cursor, 0)

        _ = try pair.engineA.toggleFavorite(stableHash: "m", itemKind: "movie")
        clock = Int64(Date().timeIntervalSince1970) + 5
        await pair.a.syncNow()
        XCTAssertEqual(pair.ta.pushed.count, 1)
        XCTAssertEqual(pair.a.cursor, clock)

        clock += 100
        await pair.a.syncNow()
        XCTAssertEqual(pair.ta.pushed.count, 1, "nothing changed since the cursor: no push")
        XCTAssertEqual(pair.a.cursor, clock)
    }

    func testTransportErrorsBecomeAStatusNotACrash() async throws {
        let pair = try makePair()
        pair.a.start()
        _ = try pair.engineA.toggleFavorite(stableHash: "m", itemKind: "movie")
        pair.ta.pushError = CKError(.networkUnavailable)

        await pair.a.syncNow()
        guard case .failed(let message) = pair.a.status else { return XCTFail("expected failure, got \(pair.a.status)") }
        XCTAssertFalse(message.isEmpty)
        XCTAssertEqual(pair.a.cursor, 0, "a failed sync does not move the cursor: the change is retried")

        pair.ta.pushError = nil
        await pair.a.syncNow()
        guard case .synced = pair.a.status else { return XCTFail("expected recovery") }
        XCTAssertEqual(pair.ta.pushed.count, 1)
    }

    func testBurstOfScheduledSyncsIsCoalesced() async throws {
        let pair = try makePair()
        pair.a.start()
        let settled = await eventually { if case .synced = pair.a.status { return true } else { return false } }
        XCTAssertTrue(settled)
        let baseline = pair.ta.fetchCount

        for _ in 0..<5 { pair.a.scheduleSync() }
        let done = await eventually { pair.ta.fetchCount == baseline + 1 }
        XCTAssertTrue(done)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(pair.ta.fetchCount, baseline + 1, "five requests, one sync")
    }

    func testEmptyRemoteDeltaChangesNothing() async throws {
        let engine = try CndEngine.inMemory()
        let manager = CloudKitSyncManager(engine: engine, availability: .available(containerID: "c"), defaults: defaultsA, makeTransport: { _ in LoopbackTransport() })
        var called = false
        manager.onRemoteChange = { _ in called = true }
        await manager.receive(SyncDelta(sources: [], favorites: [], watchHistory: [], tombstones: []))
        XCTAssertFalse(called)
    }
}
