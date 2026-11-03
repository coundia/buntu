import CloudKit
import Foundation
import CndCoreBridge

/// Converts between the engine's sync delta and CloudKit records. Only three record types exist;
/// the catalog (`iptv_items`) and the guide (`epg_programs`) have no representation here.
struct SyncRecordMapper {
    static let sourceType = "CndSource"
    static let favoriteType = "CndFavorite"
    static let watchType = "CndWatchProgress"

    static let sourcePrefix = "src:"
    static let favoritePrefix = "fav:"
    static let watchPrefix = "watch:"

    let zoneID: CKRecordZone.ID

    init(zoneID: CKRecordZone.ID = CKRecordZone.ID(zoneName: "CndZone", ownerName: CKCurrentUserDefaultName)) {
        self.zoneID = zoneID
    }

    private func id(_ prefix: String, _ key: String) -> CKRecord.ID {
        CKRecord.ID(recordName: prefix + key, zoneID: zoneID)
    }

    // MARK: Delta -> CloudKit

    func records(from delta: SyncDelta) -> [CKRecord] {
        var records: [CKRecord] = []
        for source in delta.sources {
            let record = CKRecord(recordType: Self.sourceType, recordID: id(Self.sourcePrefix, source.uuid))
            record["uuid"] = source.uuid as CKRecordValue
            record["name"] = source.name as CKRecordValue
            record["sourceType"] = source.sourceType as CKRecordValue
            record["url"] = source.url as CKRecordValue?
            record["server"] = source.server as CKRecordValue?
            record["username"] = source.username as CKRecordValue?
            record["passwordRef"] = source.passwordRef as CKRecordValue?
            record["epgUrl"] = source.epgUrl as CKRecordValue?
            record["updatedAt"] = NSNumber(value: source.updatedAt)
            records.append(record)
        }
        for favorite in delta.favorites {
            let record = CKRecord(recordType: Self.favoriteType, recordID: id(Self.favoritePrefix, favorite.stableHash))
            record["stableHash"] = favorite.stableHash as CKRecordValue
            record["itemKind"] = favorite.itemKind as CKRecordValue
            record["createdAt"] = NSNumber(value: favorite.createdAt)
            records.append(record)
        }
        for watch in delta.watchHistory {
            let record = CKRecord(recordType: Self.watchType, recordID: id(Self.watchPrefix, watch.stableHash))
            record["stableHash"] = watch.stableHash as CKRecordValue
            record["positionMs"] = NSNumber(value: watch.positionMs)
            record["durationMs"] = NSNumber(value: watch.durationMs)
            record["completed"] = NSNumber(value: watch.completed ? 1 : 0)
            record["lastWatchedAt"] = NSNumber(value: watch.lastWatchedAt)
            records.append(record)
        }
        return records
    }

    /// Deletions of sources and favorites travel as CloudKit record deletions.
    func deletions(from delta: SyncDelta) -> [CKRecord.ID] {
        delta.tombstones.compactMap { tombstone in
            switch tombstone.kind {
            case "source": return id(Self.sourcePrefix, tombstone.key)
            case "favorite": return id(Self.favoritePrefix, tombstone.key)
            default: return nil
            }
        }
    }

    // MARK: CloudKit -> delta

    /// CloudKit does not report when a record was deleted, so deletions are stamped with `now`.
    func delta(fromSaved records: [CKRecord], deleted ids: [CKRecord.ID], now: Int64) -> SyncDelta {
        var delta = SyncDelta(sources: [], favorites: [], watchHistory: [], tombstones: [])
        for record in records {
            switch record.recordType {
            case Self.sourceType:
                guard let uuid = record["uuid"] as? String, let name = record["name"] as? String,
                      let type = record["sourceType"] as? String,
                      let updatedAt = (record["updatedAt"] as? NSNumber)?.int64Value else { continue }
                delta.sources.append(SyncSource(
                    uuid: uuid, name: name, sourceType: type,
                    url: record["url"] as? String, server: record["server"] as? String,
                    username: record["username"] as? String, passwordRef: record["passwordRef"] as? String,
                    epgUrl: record["epgUrl"] as? String, updatedAt: updatedAt
                ))
            case Self.favoriteType:
                guard let hash = record["stableHash"] as? String, let kind = record["itemKind"] as? String,
                      let createdAt = (record["createdAt"] as? NSNumber)?.int64Value else { continue }
                delta.favorites.append(SyncFavorite(stableHash: hash, itemKind: kind, createdAt: createdAt))
            case Self.watchType:
                guard let hash = record["stableHash"] as? String,
                      let position = (record["positionMs"] as? NSNumber)?.int64Value,
                      let duration = (record["durationMs"] as? NSNumber)?.int64Value,
                      let last = (record["lastWatchedAt"] as? NSNumber)?.int64Value else { continue }
                delta.watchHistory.append(SyncWatchProgress(
                    stableHash: hash, positionMs: position, durationMs: duration,
                    completed: (record["completed"] as? NSNumber)?.intValue == 1, lastWatchedAt: last
                ))
            default:
                continue
            }
        }
        for recordID in ids {
            let name = recordID.recordName
            if name.hasPrefix(Self.sourcePrefix) {
                delta.tombstones.append(SyncTombstone(kind: "source", key: String(name.dropFirst(Self.sourcePrefix.count)), deletedAt: now))
            } else if name.hasPrefix(Self.favoritePrefix) {
                delta.tombstones.append(SyncTombstone(kind: "favorite", key: String(name.dropFirst(Self.favoritePrefix.count)), deletedAt: now))
            }
        }
        return delta
    }
}
