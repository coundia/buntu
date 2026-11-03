import XCTest
import CndCoreBridge
@testable import CndIptvKit

// MARK: - Fakes and builders

func makeTask(
    id: Int64, name: String = "file.mkv", state: String, total: UInt64 = 1000, done: UInt64 = 0,
    speed: Double = 0, eta: UInt64 = 0, parts: [DownloadPartRecord] = []
) -> DownloadTaskRecord {
    DownloadTaskRecord(
        id: id, url: "http://127.0.0.1:9/\(name)", fileName: name, savePath: "/tmp/\(name)",
        totalBytes: total, downloadedBytes: done, acceptRanges: true, state: state,
        speedBps: speed, etaSeconds: eta, parts: parts, updatedAt: 0
    )
}

/// Scripted backend: every `listDownloads` returns the next snapshot (the last one repeats).
final class FakeDownloads: DownloadsBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [[DownloadTaskRecord]]
    private(set) var listCalls = 0
    private(set) var log: [String] = []

    init(script: [[DownloadTaskRecord]]) { self.script = script }

    private func note(_ entry: String) { lock.withLock { log.append(entry) } }
    var calls: [String] { lock.withLock { log } }
    var listCount: Int { lock.withLock { listCalls } }

    func replace(script: [[DownloadTaskRecord]]) { lock.withLock { self.script = script } }

    func listDownloads(query: String?) throws -> [DownloadTaskRecord] {
        lock.withLock {
            listCalls += 1
            return script.count > 1 ? script.removeFirst() : (script.first ?? [])
        }
    }
    func enqueueDownload(req: NewDownloadRequest) async throws -> Int64 { note("enqueue:\(req.url)"); return 1 }
    func startDownload(taskId: Int64) async throws { note("start:\(taskId)") }
    func pauseDownload(taskId: Int64) async throws { note("pause:\(taskId)") }
    func retryDownload(taskId: Int64) async throws { note("retry:\(taskId)") }
    func removeDownload(taskId: Int64, deleteFiles: Bool) async throws { note("remove:\(taskId):\(deleteFiles)") }
    func startAllDownloads() async throws { note("startAll") }
    func pauseAllDownloads() async throws { note("pauseAll") }
    func getDownloadLogs(taskId: Int64, limit: UInt32) throws -> [DownloadLogRecord] { [] }
}

// MARK: - Download folder

@MainActor
final class DownloadDirectoryManagerTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        root = try TestFixtures.makeTempDirectory()
        suiteName = "cnd.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    private func canonical(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }
    private var platformDefault: URL { root.appendingPathComponent("default") }

    func testStartsOnThePlatformDefaultAndCreatesIt() {
        let manager = DownloadDirectoryManager(defaults: defaults, platformDefault: platformDefault)
        XCTAssertEqual(canonical(manager.directory), canonical(platformDefault))
        XCTAssertFalse(manager.isCustom)
        XCTAssertTrue(FileManager.default.fileExists(atPath: platformDefault.path))
    }

    func testChosenFolderSurvivesARestart() throws {
        let chosen = root.appendingPathComponent("External SSD/CND")
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)

        let first = DownloadDirectoryManager(defaults: defaults, platformDefault: platformDefault)
        try first.setDirectory(chosen)
        XCTAssertTrue(first.isCustom)
        XCTAssertEqual(defaults.string(forKey: DownloadLocation.defaultsKey), chosen.path)
        #if os(macOS)
        XCTAssertNotNil(defaults.data(forKey: DownloadDirectoryManager.bookmarkKey), "a security-scoped bookmark is stored")
        #endif

        let relaunched = DownloadDirectoryManager(defaults: defaults, platformDefault: platformDefault)
        XCTAssertTrue(relaunched.isCustom)
        XCTAssertEqual(canonical(relaunched.directory), canonical(chosen))
        XCTAssertNil(relaunched.lastError)
    }

    func testChangingFolderReleasesThePreviousScope() throws {
        let a = root.appendingPathComponent("A")
        let b = root.appendingPathComponent("B")
        for url in [a, b] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }

        let manager = DownloadDirectoryManager(defaults: defaults, platformDefault: platformDefault)
        try manager.setDirectory(a)
        try manager.setDirectory(b)
        if let accessed = manager.accessedURL {
            XCTAssertEqual(canonical(accessed), canonical(b), "the scope of A must have been closed")
        }
        XCTAssertEqual(canonical(manager.directory), canonical(b))

        manager.closeAccess()
        XCTAssertNil(manager.accessedURL)
    }

    func testResetGoesBackToTheDefaultAndForgetsTheBookmark() throws {
        let chosen = root.appendingPathComponent("Custom")
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        let manager = DownloadDirectoryManager(defaults: defaults, platformDefault: platformDefault)
        try manager.setDirectory(chosen)

        manager.resetToDefault()
        XCTAssertEqual(canonical(manager.directory), canonical(platformDefault))
        XCTAssertFalse(manager.isCustom)
        XCTAssertNil(manager.accessedURL)
        XCTAssertNil(defaults.data(forKey: DownloadDirectoryManager.bookmarkKey))
        XCTAssertNil(defaults.string(forKey: DownloadLocation.defaultsKey))
        XCTAssertFalse(DownloadDirectoryManager(defaults: defaults, platformDefault: platformDefault).isCustom)
    }

    #if os(macOS)
    func testCorruptBookmarkFallsBackWithAnError() {
        defaults.set(Data("garbage".utf8), forKey: DownloadDirectoryManager.bookmarkKey)
        let manager = DownloadDirectoryManager(defaults: defaults, platformDefault: platformDefault)
        XCTAssertEqual(canonical(manager.directory), canonical(platformDefault))
        XCTAssertNotNil(manager.lastError)
        XCTAssertNil(defaults.data(forKey: DownloadDirectoryManager.bookmarkKey), "a dead bookmark is dropped")
    }
    #endif
}

// MARK: - Polling and state

@MainActor
final class DownloadsModelTests: XCTestCase {
    private func model(_ backend: FakeDownloads) -> DownloadsModel {
        DownloadsModel(backend: backend, pollInterval: .milliseconds(20))
    }

    func testPollsWhileActiveThenStopsCompletely() async throws {
        let backend = FakeDownloads(script: [
            [makeTask(id: 1, state: "running", done: 100)],
            [makeTask(id: 1, state: "running", done: 500)],
            [makeTask(id: 1, state: "running", done: 900)],
            [makeTask(id: 1, state: "completed", done: 1000)],
        ])
        let model = model(backend)
        model.ensurePolling()
        XCTAssertTrue(model.isPolling)

        let stopped = await eventually { !model.isPolling }
        XCTAssertTrue(stopped, "the loop ends once nothing is running or queued")
        XCTAssertEqual(model.tasks.first?.state, "completed")
        XCTAssertEqual(model.pollCount, 4)

        // No timer survives: the backend is no longer queried.
        let calls = backend.listCount
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(backend.listCount, calls)
        XCTAssertEqual(model.pollCount, 4)
    }

    func testIdleListPollsExactlyOnce() async throws {
        let backend = FakeDownloads(script: [[makeTask(id: 1, state: "paused"), makeTask(id: 2, state: "completed")]])
        let model = model(backend)
        model.ensurePolling()
        let stopped = await eventually { !model.isPolling }
        XCTAssertTrue(stopped)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(backend.listCount, 1)
        XCTAssertFalse(model.hasActive)
    }

    func testEnsurePollingIsIdempotentAndStopPollingCancels() async throws {
        let backend = FakeDownloads(script: [[makeTask(id: 1, state: "running")]])
        let model = model(backend)
        model.ensurePolling()
        model.ensurePolling()
        model.ensurePolling()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(model.isPolling)
        let perInterval = backend.listCount
        XCTAssertLessThan(perInterval, 12, "three calls must not start three loops (≈ 5 ticks expected)")

        model.stopPolling()
        XCTAssertFalse(model.isPolling)
        try await Task.sleep(for: .milliseconds(60))
        let frozen = backend.listCount
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(backend.listCount, frozen, "no refresh after the tab is left")

        model.ensurePolling()
        XCTAssertTrue(model.isPolling, "polling can restart after a stop")
        model.stopPolling()
    }

    func testStatsAndFilters() async {
        let backend = FakeDownloads(script: [[
            makeTask(id: 1, name: "Alpha.mkv", state: "running", speed: 2_000_000),
            makeTask(id: 2, name: "Beta.mkv", state: "running", speed: 1_000_000),
            makeTask(id: 3, name: "Gamma.mkv", state: "queued"),
            makeTask(id: 4, name: "Delta.mkv", state: "paused"),
            makeTask(id: 5, name: "Epsilon.mkv", state: "completed"),
            makeTask(id: 6, name: "Zeta.mkv", state: "error"),
        ]])
        let model = model(backend)
        await model.refresh()

        let stats = model.stats
        XCTAssertEqual(stats.total, 6)
        XCTAssertEqual(stats.running, 2)
        XCTAssertEqual(stats.queued, 1)
        XCTAssertEqual(stats.paused, 1)
        XCTAssertEqual(stats.completed, 1)
        XCTAssertEqual(stats.errors, 1)
        XCTAssertEqual(stats.speedBps, 3_000_000)

        model.stateFilter = .active
        XCTAssertEqual(model.visibleTasks.map(\.id), [1, 2, 3])
        model.stateFilter = .error
        XCTAssertEqual(model.visibleTasks.map(\.id), [6])
        model.stateFilter = .all
        model.query = "ta.mkv"
        XCTAssertEqual(Set(model.visibleTasks.map(\.id)), [2, 4, 6], "Beta, Delta and Zeta")
        model.query = "  "
        XCTAssertEqual(model.visibleTasks.count, 6)
    }

    func testGlobalActionsReachTheEngineAndResumePolling() async throws {
        let backend = FakeDownloads(script: [
            [makeTask(id: 1, state: "paused"), makeTask(id: 2, state: "error"), makeTask(id: 3, state: "error")],
            [makeTask(id: 1, state: "running"), makeTask(id: 2, state: "queued"), makeTask(id: 3, state: "queued")],
            [makeTask(id: 1, state: "completed"), makeTask(id: 2, state: "completed"), makeTask(id: 3, state: "completed")],
        ])
        let model = model(backend)
        await model.refresh()
        XCTAssertFalse(model.isPolling)

        await model.retryErrors()
        XCTAssertEqual(backend.calls, ["retry:2", "retry:3"])
        XCTAssertTrue(model.hasActive || model.isPolling, "an action that makes tasks active restarts polling")

        let settled = await eventually { !model.isPolling }
        XCTAssertTrue(settled)

        await model.startAll()
        await model.pauseAll()
        await model.start(makeTask(id: 9, state: "paused"))
        await model.pause(makeTask(id: 9, state: "running"))
        await model.retry(makeTask(id: 9, state: "error"))
        await model.remove(makeTask(id: 9, state: "paused"), deleteFile: true)
        XCTAssertEqual(backend.calls.suffix(6), ["startAll", "pauseAll", "start:9", "pause:9", "retry:9", "remove:9:true"])
    }

    func testEnqueueSendsEveryRequest() async {
        let backend = FakeDownloads(script: [[]])
        let model = model(backend)
        let requests = ["http://a/1.mkv", "http://a/2.mkv"].map {
            NewDownloadRequest(url: $0, fileName: nil, saveDir: "/tmp", userAgent: nil, referer: nil, headersJson: nil, autoStart: true)
        }
        let queued = await model.enqueue(requests)
        XCTAssertEqual(queued, 2)
        XCTAssertEqual(backend.calls, ["enqueue:http://a/1.mkv", "enqueue:http://a/2.mkv"])
    }
}

// MARK: - Engine-backed

@MainActor
final class DownloadsEngineTests: XCTestCase {
    func testEnqueueFailingUrlShowsErrorThenRetryAndRemove() async throws {
        let engine = try CndEngine.inMemory()
        let directory = try TestFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = DownloadsModel(backend: engine, pollInterval: .milliseconds(30))

        let request = NewDownloadRequest(
            url: "http://127.0.0.1:9/video.mkv", fileName: "video.mkv", saveDir: directory.path,
            userAgent: nil, referer: nil, headersJson: nil, autoStart: true
        )
        let queued = await model.enqueue([request])
        XCTAssertEqual(queued, 1)

        let failed = await eventually(timeout: 15) { model.tasks.first?.state == "error" }
        XCTAssertTrue(failed, "connection refused ends in the error state")
        let task = try XCTUnwrap(model.tasks.first)
        XCTAssertEqual(task.fileName, "video.mkv")

        let logs = await model.logs(for: task)
        XCTAssertFalse(logs.isEmpty, "the task keeps a journal")
        XCTAssertTrue(DownloadLogFormatter.text(logs).contains(logs[0].message))

        let settled = await eventually(timeout: 15) { !model.isPolling }
        XCTAssertTrue(settled)

        await model.remove(task, deleteFile: false)
        XCTAssertTrue(model.tasks.isEmpty)
        XCTAssertTrue(try engine.listDownloads(query: nil).isEmpty)
    }
}

// MARK: - Pure helpers

final class DownloadPresentationTests: XCTestCase {
    private func part(_ index: UInt32, _ start: UInt64, _ end: UInt64, done: UInt64) -> DownloadPartRecord {
        DownloadPartRecord(partIndex: index, byteStart: start, byteEnd: end, downloadedBytes: done, state: "running")
    }

    func testSegmentBarsFollowEachPartsOwnProgress() {
        let parts = [
            part(0, 0, 249, done: 250),
            part(1, 250, 499, done: 125),
            part(2, 500, 749, done: 0),
            part(3, 750, 999, done: 250),
        ]
        let bars = SegmentGeometry.bars(parts: parts, width: 406, gap: 2)
        XCTAssertEqual(bars.count, 4)
        XCTAssertEqual(bars.map(\.fill), [1, 0.5, 0, 1])
        XCTAssertEqual(bars[0].width, 100, accuracy: 0.001)
        XCTAssertEqual(bars[1].x, 102, accuracy: 0.001)
        XCTAssertEqual(bars[3].x + bars[3].width, 406, accuracy: 0.001)
    }

    func testSegmentBarsAreProportionalAndOrderedAndClamped() {
        let parts = [
            part(1, 100, 999, done: 5_000),   // 900 bytes, over-reported
            part(0, 0, 99, done: 50),          // 100 bytes
        ]
        let bars = SegmentGeometry.bars(parts: parts, width: 1002, gap: 2)
        XCTAssertEqual(bars[0].width, 100, accuracy: 0.001)
        XCTAssertEqual(bars[1].width, 900, accuracy: 0.001)
        XCTAssertEqual(bars[0].fill, 0.5)
        XCTAssertEqual(bars[1].fill, 1, "fill never exceeds 1")
        XCTAssertTrue(SegmentGeometry.bars(parts: [], width: 300).isEmpty)
        XCTAssertTrue(SegmentGeometry.bars(parts: parts, width: 0).isEmpty)
    }

    func testPercentAndEta() {
        XCTAssertEqual(DownloadFormat.percent(makeTask(id: 1, state: "running", total: 200, done: 50)), 0.25)
        XCTAssertEqual(DownloadFormat.percent(makeTask(id: 1, state: "running", total: 100, done: 500)), 1)
        XCTAssertNil(DownloadFormat.percent(makeTask(id: 1, state: "running", total: 0, done: 5)))
        XCTAssertEqual(DownloadFormat.eta(seconds: 45), "45 s")
        XCTAssertEqual(DownloadFormat.eta(seconds: 125), "2 min 05 s")
        XCTAssertEqual(DownloadFormat.eta(seconds: 3_780), "1 h 03 min")
    }

    func testUrlParserKeepsValidDeduplicatedHttpLines() {
        let text = """
        http://a.tv/1.mkv

        https://b.tv/2.mp4?token=x
          http://a.tv/1.mkv
        ftp://c.tv/3.mkv
        not a url
        file:///etc/passwd
        """
        let result = AddUrlsParser.parse(text)
        XCTAssertEqual(result.valid.map(\.absoluteString), ["http://a.tv/1.mkv", "https://b.tv/2.mp4?token=x"])
        XCTAssertEqual(result.invalid, ["ftp://c.tv/3.mkv", "not a url", "file:///etc/passwd"])
        XCTAssertTrue(AddUrlsParser.parse("  \n ").valid.isEmpty)
    }
}
