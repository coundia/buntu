import Testing
import Foundation
@testable import CndIptvKit
import CndCoreBridge

final class MockRecordingsBackend: RecordingsBackend, @unchecked Sendable {
    var recordings: [RecordingRecord] = []
    var seriesRules: [SeriesRuleRecord] = []
    var nextId: Int64 = 1

    func listRecordings(stateFilter: String?) throws -> [RecordingRecord] {
        if let filter = stateFilter {
            return recordings.filter { $0.state == filter }
        }
        return recordings
    }

    func scheduleRecording(req: NewRecordingRequest) throws -> Int64 {
        let id = nextId
        nextId += 1
        let rec = RecordingRecord(
            id: id,
            itemId: req.itemId,
            channelTvgId: req.channelTvgId,
            channelName: req.channelName,
            title: req.title,
            subtitle: req.subtitle,
            streamUrl: req.streamUrl,
            startTs: req.startTs,
            endTs: req.endTs,
            prePaddingS: req.prePaddingS ?? 120,
            postPaddingS: req.postPaddingS ?? 300,
            state: "scheduled",
            filePath: nil,
            bytesWritten: 0,
            ruleId: req.ruleId,
            error: nil,
            createdAt: Int64(Date().timeIntervalSince1970)
        )
        recordings.append(rec)
        return id
    }

    func recordNow(itemId: Int64, durationMinutes: UInt32) throws -> Int64 {
        let id = nextId
        nextId += 1
        let now = Int64(Date().timeIntervalSince1970)
        let rec = RecordingRecord(
            id: id,
            itemId: itemId,
            channelTvgId: "tf1.fr",
            channelName: "TF1 HD",
            title: "Direct TF1",
            subtitle: nil,
            streamUrl: "http://example.com/live.ts",
            startTs: now,
            endTs: now + Int64(durationMinutes * 60),
            prePaddingS: 0,
            postPaddingS: 0,
            state: "recording",
            filePath: "/tmp/recording.ts",
            bytesWritten: 1024,
            ruleId: nil,
            error: nil,
            createdAt: now
        )
        recordings.append(rec)
        return id
    }

    func cancelRecording(id: Int64) throws -> Bool {
        if let idx = recordings.firstIndex(where: { $0.id == id }) {
            recordings[idx].state = "cancelled"
            return true
        }
        return false
    }

    func deleteRecording(id: Int64, deleteFile: Bool) throws -> Bool {
        if let idx = recordings.firstIndex(where: { $0.id == id }) {
            recordings.remove(at: idx)
            return true
        }
        return false
    }

    func setRecordingDirectory(dir: String) {}

    func addSeriesRule(channelTvgId: String?, title: String) throws -> Int64 {
        let id = nextId
        nextId += 1
        seriesRules.append(SeriesRuleRecord(
            id: id,
            channelTvgId: channelTvgId,
            titleKey: title.lowercased(),
            createdAt: Int64(Date().timeIntervalSince1970)
        ))
        return id
    }

    func removeSeriesRule(id: Int64) throws -> Bool {
        if let idx = seriesRules.firstIndex(where: { $0.id == id }) {
            seriesRules.remove(at: idx)
            return true
        }
        return false
    }

    func listSeriesRules() throws -> [SeriesRuleRecord] {
        seriesRules
    }
}

@Suite("PVR Recordings Tests")
struct RecordingsTests {

    @Test("Schedule, filter and cancel recording workflow")
    @MainActor
    func testScheduleAndCancelRecording() throws {
        let backend = MockRecordingsBackend()
        let model = RecordingsModel(backend: backend)

        #expect(model.recordings.isEmpty)

        let req = NewRecordingRequest(
            itemId: 42,
            channelTvgId: "fr2.fr",
            channelName: "France 2 HD",
            title: "Journal 20h",
            subtitle: "Édition spéciale",
            streamUrl: "http://example.com/live.m3u8",
            startTs: 1700000000,
            endTs: 1700002400,
            prePaddingS: 120,
            postPaddingS: 300,
            ruleId: nil
        )

        let id = try model.schedule(req: req)
        #expect(id > 0)
        #expect(model.recordings.count == 1)
        #expect(model.recordings[0].title == "Journal 20h")
        #expect(model.recordings[0].state == "scheduled")

        // Filter tests
        model.filter = .scheduled
        #expect(model.filteredRecordings.count == 1)

        model.filter = .recording
        #expect(model.filteredRecordings.isEmpty)

        // Search text test
        model.filter = .all
        model.searchText = "journal"
        #expect(model.filteredRecordings.count == 1)

        model.searchText = "météo"
        #expect(model.filteredRecordings.isEmpty)
        model.searchText = ""

        // Cancel test
        model.cancel(id: id)
        #expect(model.recordings[0].state == "cancelled")

        // Delete test
        model.delete(id: id)
        #expect(model.recordings.isEmpty)
    }

    @Test("Series-link rules creation and deletion")
    @MainActor
    func testSeriesLinkRules() throws {
        let backend = MockRecordingsBackend()
        let model = RecordingsModel(backend: backend)

        #expect(model.seriesRules.isEmpty)

        let ruleId = try model.addSeriesRule(channelTvgId: "arte.fr", title: "Tracks")
        #expect(ruleId > 0)
        #expect(model.seriesRules.count == 1)
        #expect(model.seriesRules[0].titleKey == "tracks")

        model.removeSeriesRule(id: ruleId)
        #expect(model.seriesRules.isEmpty)
    }

    @Test("PlayableMedia from recording is not live stream")
    func testPlayableMediaRecordingKind() {
        let url = URL(fileURLWithPath: "/tmp/recording.ts")
        let media = PlayableMedia(
            title: "France 2 — Journal",
            url: url,
            kind: .recording,
            stableHash: "recording_1"
        )

        #expect(media.kind == .recording)
        #expect(media.kind != .live)
    }
}
