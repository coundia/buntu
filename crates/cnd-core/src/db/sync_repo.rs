//! Delta export / import of the light user data synced through iCloud: sources, favorites and
//! watch progress. Catalog rows (`iptv_items`) and guide rows (`epg_programs`) are never part of a
//! delta: each device rebuilds them locally from its sources.
//!
//! Conflicts are resolved Last-Write-Wins on a per-record timestamp (Unix seconds):
//! - sources: `updated_at`, identified by `uuid`;
//! - favorites: `created_at` of the addition, against the `deleted_at` of a tombstone;
//! - watch progress: `last_watched_at`.
//!
//! Ties favor the favorite (it stays) but the deletion of a *source* (it is removed).

use crate::db::{DatabaseManager, DbError};
use rusqlite::{params, OptionalExtension};

pub const TOMBSTONE_FAVORITE: &str = "favorite";
pub const TOMBSTONE_SOURCE: &str = "source";

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SyncSource {
    pub uuid: String,
    pub name: String,
    pub source_type: String,
    pub url: Option<String>,
    pub server: Option<String>,
    pub username: Option<String>,
    /// Keychain reference only; the secret itself is never stored in SQLite.
    pub password_ref: Option<String>,
    pub epg_url: Option<String>,
    pub updated_at: i64,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SyncFavorite {
    pub stable_hash: String,
    pub item_kind: String,
    pub created_at: i64,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SyncWatchProgress {
    pub stable_hash: String,
    pub position_ms: i64,
    pub duration_ms: i64,
    pub completed: bool,
    pub last_watched_at: i64,
}

/// A deletion. `kind` is `"favorite"` (key = stable hash) or `"source"` (key = source uuid).
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SyncTombstone {
    pub kind: String,
    pub key: String,
    pub deleted_at: i64,
}

#[derive(Debug, Clone, Default, PartialEq, uniffi::Record)]
pub struct SyncDelta {
    pub sources: Vec<SyncSource>,
    pub favorites: Vec<SyncFavorite>,
    pub watch_history: Vec<SyncWatchProgress>,
    pub tombstones: Vec<SyncTombstone>,
}

impl SyncDelta {
    pub fn is_empty(&self) -> bool {
        self.sources.is_empty()
            && self.favorites.is_empty()
            && self.watch_history.is_empty()
            && self.tombstones.is_empty()
    }
}

#[derive(Debug, Clone, Default, PartialEq, uniffi::Record)]
pub struct SyncImportSummary {
    pub sources_applied: u32,
    pub favorites_applied: u32,
    pub watch_applied: u32,
    pub deletions_applied: u32,
    pub skipped: u32,
    /// Local ids of sources created by this import; they have no catalog yet and need a refresh.
    pub inserted_source_ids: Vec<i64>,
}

impl SyncImportSummary {
    pub fn applied(&self) -> u32 {
        self.sources_applied + self.favorites_applied + self.watch_applied + self.deletions_applied
    }
}

impl DatabaseManager {
    /// Everything that changed strictly after `since_ts`. Sources backed by a local file are
    /// skipped: their path means nothing on another device.
    pub fn export_sync_delta(&self, since_ts: i64) -> Result<SyncDelta, DbError> {
        self.with_conn(|conn| {
            let mut sources = Vec::new();
            let mut stmt = conn.prepare(
                "SELECT uuid, name, source_type, url, server, username, password_ref, epg_url, updated_at
                 FROM iptv_sources
                 WHERE updated_at > ?1 AND (url IS NULL OR url NOT LIKE 'file://%')
                 ORDER BY updated_at ASC, id ASC",
            )?;
            for row in stmt.query_map(params![since_ts], |r| {
                Ok(SyncSource {
                    uuid: r.get(0)?,
                    name: r.get(1)?,
                    source_type: r.get(2)?,
                    url: r.get(3)?,
                    server: r.get(4)?,
                    username: r.get(5)?,
                    password_ref: r.get(6)?,
                    epg_url: r.get(7)?,
                    updated_at: r.get(8)?,
                })
            })? {
                sources.push(row?);
            }

            let mut favorites = Vec::new();
            let mut stmt = conn.prepare(
                "SELECT stable_hash, item_kind, created_at FROM favorites
                 WHERE profile_id = 1 AND created_at > ?1 ORDER BY created_at ASC, stable_hash ASC",
            )?;
            for row in stmt.query_map(params![since_ts], |r| {
                Ok(SyncFavorite {
                    stable_hash: r.get(0)?,
                    item_kind: r.get(1)?,
                    created_at: r.get(2)?,
                })
            })? {
                favorites.push(row?);
            }

            let mut watch_history = Vec::new();
            let mut stmt = conn.prepare(
                "SELECT stable_hash, position_ms, duration_ms, completed, last_watched_at
                 FROM watch_history WHERE profile_id = 1 AND last_watched_at > ?1
                 ORDER BY last_watched_at ASC, stable_hash ASC",
            )?;
            for row in stmt.query_map(params![since_ts], |r| {
                Ok(SyncWatchProgress {
                    stable_hash: r.get(0)?,
                    position_ms: r.get(1)?,
                    duration_ms: r.get(2)?,
                    completed: r.get::<_, i64>(3)? != 0,
                    last_watched_at: r.get(4)?,
                })
            })? {
                watch_history.push(row?);
            }

            let mut tombstones = Vec::new();
            let mut stmt = conn.prepare(
                "SELECT kind, key, deleted_at FROM sync_tombstones
                 WHERE deleted_at > ?1 ORDER BY deleted_at ASC, key ASC",
            )?;
            for row in stmt.query_map(params![since_ts], |r| {
                Ok(SyncTombstone {
                    kind: r.get(0)?,
                    key: r.get(1)?,
                    deleted_at: r.get(2)?,
                })
            })? {
                tombstones.push(row?);
            }

            Ok(SyncDelta {
                sources,
                favorites,
                watch_history,
                tombstones,
            })
        })
    }

    /// Merges a remote delta, all or nothing. Importing the same delta twice changes nothing.
    pub fn import_sync_delta(&self, delta: &SyncDelta) -> Result<SyncImportSummary, DbError> {
        self.with_conn_mut(|conn| {
            let tx = conn.transaction()?;
            let mut summary = SyncImportSummary::default();

            // Deletions first, so a record and its tombstone in one delta are compared correctly.
            for tomb in &delta.tombstones {
                match tomb.kind.as_str() {
                    TOMBSTONE_FAVORITE => {
                        let local: Option<i64> = tx
                            .query_row(
                                "SELECT created_at FROM favorites WHERE profile_id = 1 AND stable_hash = ?1",
                                params![tomb.key],
                                |r| r.get(0),
                            )
                            .optional()?;
                        if matches!(local, Some(created) if created >= tomb.deleted_at) {
                            summary.skipped += 1;
                            continue;
                        }
                        if local.is_some() {
                            tx.execute("DELETE FROM favorites WHERE profile_id = 1 AND stable_hash = ?1", params![tomb.key])?;
                            summary.deletions_applied += 1;
                        } else {
                            summary.skipped += 1;
                        }
                        upsert_tombstone(&tx, TOMBSTONE_FAVORITE, &tomb.key, tomb.deleted_at)?;
                    }
                    TOMBSTONE_SOURCE => {
                        let local: Option<i64> = tx
                            .query_row(
                                "SELECT updated_at FROM iptv_sources WHERE uuid = ?1",
                                params![tomb.key],
                                |r| r.get(0),
                            )
                            .optional()?;
                        if matches!(local, Some(updated) if updated > tomb.deleted_at) {
                            summary.skipped += 1;
                            continue;
                        }
                        if local.is_some() {
                            tx.execute("DELETE FROM iptv_sources WHERE uuid = ?1", params![tomb.key])?;
                            summary.deletions_applied += 1;
                        } else {
                            summary.skipped += 1;
                        }
                        upsert_tombstone(&tx, TOMBSTONE_SOURCE, &tomb.key, tomb.deleted_at)?;
                    }
                    _ => summary.skipped += 1,
                }
            }

            for src in &delta.sources {
                let tomb: Option<i64> = tx
                    .query_row(
                        "SELECT deleted_at FROM sync_tombstones WHERE kind = ?1 AND key = ?2",
                        params![TOMBSTONE_SOURCE, src.uuid],
                        |r| r.get(0),
                    )
                    .optional()?;
                if matches!(tomb, Some(deleted) if deleted >= src.updated_at) {
                    summary.skipped += 1;
                    continue;
                }
                let local: Option<i64> = tx
                    .query_row(
                        "SELECT updated_at FROM iptv_sources WHERE uuid = ?1",
                        params![src.uuid],
                        |r| r.get(0),
                    )
                    .optional()?;
                match local {
                    None => {
                        tx.execute(
                            "INSERT INTO iptv_sources
                                (uuid, name, source_type, url, server, username, password_ref, epg_url, created_at, updated_at)
                             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?9)",
                            params![
                                src.uuid, src.name, src.source_type, src.url, src.server,
                                src.username, src.password_ref, src.epg_url, src.updated_at
                            ],
                        )?;
                        summary.inserted_source_ids.push(tx.last_insert_rowid());
                        tx.execute(
                            "DELETE FROM sync_tombstones WHERE kind = ?1 AND key = ?2",
                            params![TOMBSTONE_SOURCE, src.uuid],
                        )?;
                        summary.sources_applied += 1;
                    }
                    Some(local_ts) if src.updated_at > local_ts => {
                        tx.execute(
                            "UPDATE iptv_sources
                             SET name = ?2, source_type = ?3, url = ?4, server = ?5, username = ?6,
                                 password_ref = ?7, epg_url = ?8, updated_at = ?9
                             WHERE uuid = ?1",
                            params![
                                src.uuid, src.name, src.source_type, src.url, src.server,
                                src.username, src.password_ref, src.epg_url, src.updated_at
                            ],
                        )?;
                        summary.sources_applied += 1;
                    }
                    Some(_) => summary.skipped += 1,
                }
            }

            for fav in &delta.favorites {
                let tomb: Option<i64> = tx
                    .query_row(
                        "SELECT deleted_at FROM sync_tombstones WHERE kind = ?1 AND key = ?2",
                        params![TOMBSTONE_FAVORITE, fav.stable_hash],
                        |r| r.get(0),
                    )
                    .optional()?;
                if matches!(tomb, Some(deleted) if deleted > fav.created_at) {
                    summary.skipped += 1;
                    continue;
                }
                let local: Option<i64> = tx
                    .query_row(
                        "SELECT created_at FROM favorites WHERE profile_id = 1 AND stable_hash = ?1",
                        params![fav.stable_hash],
                        |r| r.get(0),
                    )
                    .optional()?;
                match local {
                    None => {
                        tx.execute(
                            "INSERT INTO favorites (stable_hash, item_kind, created_at) VALUES (?1, ?2, ?3)",
                            params![fav.stable_hash, fav.item_kind, fav.created_at],
                        )?;
                        tx.execute(
                            "DELETE FROM sync_tombstones WHERE kind = ?1 AND key = ?2",
                            params![TOMBSTONE_FAVORITE, fav.stable_hash],
                        )?;
                        summary.favorites_applied += 1;
                    }
                    Some(local_ts) if fav.created_at > local_ts => {
                        tx.execute(
                            "UPDATE favorites SET item_kind = ?2, created_at = ?3 WHERE profile_id = 1 AND stable_hash = ?1",
                            params![fav.stable_hash, fav.item_kind, fav.created_at],
                        )?;
                        summary.favorites_applied += 1;
                    }
                    Some(_) => summary.skipped += 1,
                }
            }

            for watch in &delta.watch_history {
                let local: Option<i64> = tx
                    .query_row(
                        "SELECT last_watched_at FROM watch_history WHERE profile_id = 1 AND stable_hash = ?1",
                        params![watch.stable_hash],
                        |r| r.get(0),
                    )
                    .optional()?;
                if matches!(local, Some(local_ts) if local_ts >= watch.last_watched_at) {
                    summary.skipped += 1;
                    continue;
                }
                tx.execute(
                    "INSERT INTO watch_history (profile_id, stable_hash, position_ms, duration_ms, completed, last_watched_at)
                     VALUES (1, ?1, ?2, ?3, ?4, ?5)
                     ON CONFLICT(profile_id, stable_hash) DO UPDATE SET
                         position_ms = excluded.position_ms,
                         duration_ms = excluded.duration_ms,
                         completed = excluded.completed,
                         last_watched_at = excluded.last_watched_at",
                    params![
                        watch.stable_hash, watch.position_ms.max(0), watch.duration_ms.max(0),
                        i64::from(watch.completed), watch.last_watched_at
                    ],
                )?;
                summary.watch_applied += 1;
            }

            tx.commit()?;
            Ok(summary)
        })
    }
}

pub(crate) fn upsert_tombstone(
    conn: &rusqlite::Connection,
    kind: &str,
    key: &str,
    deleted_at: i64,
) -> Result<(), DbError> {
    conn.execute(
        "INSERT INTO sync_tombstones (kind, key, deleted_at) VALUES (?1, ?2, ?3)
         ON CONFLICT(kind, key) DO UPDATE SET deleted_at = MAX(deleted_at, excluded.deleted_at)",
        params![kind, key, deleted_at],
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn src(uuid: &str, name: &str, updated_at: i64) -> SyncSource {
        SyncSource {
            uuid: uuid.to_string(),
            name: name.to_string(),
            source_type: "m3u".to_string(),
            url: Some("http://example.com/list.m3u".to_string()),
            server: None,
            username: None,
            password_ref: None,
            epg_url: None,
            updated_at,
        }
    }

    fn fav(hash: &str, created_at: i64) -> SyncFavorite {
        SyncFavorite {
            stable_hash: hash.to_string(),
            item_kind: "movie".to_string(),
            created_at,
        }
    }

    fn watch(hash: &str, pos: i64, at: i64) -> SyncWatchProgress {
        SyncWatchProgress {
            stable_hash: hash.to_string(),
            position_ms: pos,
            duration_ms: 100_000,
            completed: false,
            last_watched_at: at,
        }
    }

    fn db() -> DatabaseManager {
        DatabaseManager::open_in_memory().expect("open db")
    }

    fn local_name(db: &DatabaseManager, uuid: &str) -> Option<String> {
        db.list_sources()
            .unwrap()
            .into_iter()
            .find(|s| s.uuid == uuid)
            .map(|s| s.name)
    }

    #[test]
    fn local_changes_travel_between_two_devices() {
        let a = db();
        let b = db();
        let source_id = a
            .add_source("Premium", "xtream", None, Some("http://srv:80"), Some("bob"), Some("cnd.xtream.x"))
            .unwrap();
        a.toggle_favorite("movie_1", "movie").unwrap();
        a.record_watch_progress("movie_1", 42_000, 100_000).unwrap();

        let delta = a.export_sync_delta(0).unwrap();
        assert_eq!(delta.sources.len(), 1);
        assert_eq!(delta.sources[0].password_ref.as_deref(), Some("cnd.xtream.x"));
        assert_eq!(delta.favorites.len(), 1);
        assert_eq!(delta.watch_history.len(), 1);
        assert!(delta.tombstones.is_empty());

        let summary = b.import_sync_delta(&delta).unwrap();
        assert_eq!(summary.sources_applied, 1);
        assert_eq!(summary.favorites_applied, 1);
        assert_eq!(summary.watch_applied, 1);
        assert_eq!(summary.inserted_source_ids.len(), 1);

        let imported = b.list_sources().unwrap();
        assert_eq!(imported.len(), 1);
        assert_eq!(imported[0].uuid, a.list_sources().unwrap()[0].uuid);
        assert_eq!(imported[0].name, "Premium");
        assert_eq!(imported[0].item_count, 0, "the catalog is rebuilt locally, never synced");
        assert_eq!(imported[0].id, summary.inserted_source_ids[0]);
        let _ = source_id;

        let again = b.import_sync_delta(&delta).unwrap();
        assert_eq!(again.applied(), 0, "importing the same delta twice is a no-op");
        assert!(again.skipped >= 3);
    }

    #[test]
    fn sources_resolve_last_write_wins() {
        let db = db();
        db.import_sync_delta(&SyncDelta { sources: vec![src("u1", "Original", 100)], ..Default::default() }).unwrap();

        let older = db
            .import_sync_delta(&SyncDelta { sources: vec![src("u1", "Stale edit", 50)], ..Default::default() })
            .unwrap();
        assert_eq!(older.sources_applied, 0);
        assert_eq!(local_name(&db, "u1").as_deref(), Some("Original"));

        let tie = db
            .import_sync_delta(&SyncDelta { sources: vec![src("u1", "Same second", 100)], ..Default::default() })
            .unwrap();
        assert_eq!(tie.sources_applied, 0);

        let newer = db
            .import_sync_delta(&SyncDelta { sources: vec![src("u1", "Fresh edit", 200)], ..Default::default() })
            .unwrap();
        assert_eq!(newer.sources_applied, 1);
        assert_eq!(newer.inserted_source_ids.len(), 0, "an update does not create a source");
        assert_eq!(local_name(&db, "u1").as_deref(), Some("Fresh edit"));
        assert_eq!(db.list_sources().unwrap().len(), 1);
    }

    #[test]
    fn two_devices_converge_whatever_the_import_order() {
        let delta_a = SyncDelta { sources: vec![src("u1", "From A", 300)], ..Default::default() };
        let delta_b = SyncDelta { sources: vec![src("u1", "From B", 200)], ..Default::default() };

        let first = db();
        first.import_sync_delta(&delta_a).unwrap();
        first.import_sync_delta(&delta_b).unwrap();
        let second = db();
        second.import_sync_delta(&delta_b).unwrap();
        second.import_sync_delta(&delta_a).unwrap();

        assert_eq!(local_name(&first, "u1").as_deref(), Some("From A"));
        assert_eq!(local_name(&second, "u1").as_deref(), Some("From A"));
    }

    #[test]
    fn removing_a_favorite_propagates_and_resists_stale_adds() {
        let a = db();
        let b = db();
        b.import_sync_delta(&SyncDelta { favorites: vec![fav("movie_1", 100)], ..Default::default() }).unwrap();
        assert_eq!(b.list_favorite_items("movie").unwrap().len(), 0, "no catalog row yet, but the favorite row exists");

        a.import_sync_delta(&SyncDelta { favorites: vec![fav("movie_1", 100)], ..Default::default() }).unwrap();
        assert!(!a.toggle_favorite("movie_1", "movie").unwrap(), "second toggle removes it");
        let delta = a.export_sync_delta(0).unwrap();
        assert_eq!(delta.tombstones.len(), 1);
        assert_eq!(delta.tombstones[0].kind, TOMBSTONE_FAVORITE);
        assert!(delta.favorites.is_empty());

        let applied = b.import_sync_delta(&delta).unwrap();
        assert_eq!(applied.deletions_applied, 1);

        // An older "add" arriving late must not resurrect it...
        let stale = b
            .import_sync_delta(&SyncDelta { favorites: vec![fav("movie_1", 100)], ..Default::default() })
            .unwrap();
        assert_eq!(stale.favorites_applied, 0);
        // ...but a genuinely newer add must.
        let newer_ts = delta.tombstones[0].deleted_at + 10;
        let readd = b
            .import_sync_delta(&SyncDelta { favorites: vec![fav("movie_1", newer_ts)], ..Default::default() })
            .unwrap();
        assert_eq!(readd.favorites_applied, 1);
        let back = b.export_sync_delta(0).unwrap();
        assert_eq!(back.favorites.len(), 1);
        assert!(back.tombstones.is_empty(), "re-adding clears the tombstone");
    }

    #[test]
    fn favorite_added_in_the_same_second_as_its_removal_stays() {
        let db = db();
        db.import_sync_delta(&SyncDelta {
            tombstones: vec![SyncTombstone { kind: TOMBSTONE_FAVORITE.into(), key: "m".into(), deleted_at: 500 }],
            ..Default::default()
        })
        .unwrap();
        let tie = db
            .import_sync_delta(&SyncDelta { favorites: vec![fav("m", 500)], ..Default::default() })
            .unwrap();
        assert_eq!(tie.favorites_applied, 1, "ties favor the favorite");
    }

    #[test]
    fn a_local_favorite_newer_than_a_remote_tombstone_survives() {
        let db = db();
        db.import_sync_delta(&SyncDelta { favorites: vec![fav("m", 900)], ..Default::default() }).unwrap();
        let summary = db
            .import_sync_delta(&SyncDelta {
                tombstones: vec![SyncTombstone { kind: TOMBSTONE_FAVORITE.into(), key: "m".into(), deleted_at: 800 }],
                ..Default::default()
            })
            .unwrap();
        assert_eq!(summary.deletions_applied, 0);
        assert_eq!(db.export_sync_delta(0).unwrap().favorites.len(), 1);
    }

    #[test]
    fn deleting_a_source_propagates_with_its_catalog() {
        let a = db();
        let b = db();
        let id = a.add_source("Doomed", "m3u", Some("http://x/l.m3u"), None, None, None).unwrap();
        b.import_sync_delta(&a.export_sync_delta(0).unwrap()).unwrap();
        assert_eq!(b.list_sources().unwrap().len(), 1);

        a.delete_source(id).unwrap();
        let delta = a.export_sync_delta(0).unwrap();
        assert!(delta.sources.is_empty());
        assert_eq!(delta.tombstones.len(), 1);
        assert_eq!(delta.tombstones[0].kind, TOMBSTONE_SOURCE);

        let summary = b.import_sync_delta(&delta).unwrap();
        assert_eq!(summary.deletions_applied, 1);
        assert!(b.list_sources().unwrap().is_empty());

        // The deleted source cannot come back from a stale copy.
        let stale = SyncDelta { sources: vec![src(&delta.tombstones[0].key, "Doomed", 1)], ..Default::default() };
        assert_eq!(b.import_sync_delta(&stale).unwrap().sources_applied, 0);
        assert!(b.list_sources().unwrap().is_empty());
    }

    #[test]
    fn watch_progress_keeps_the_latest_position() {
        let db = db();
        db.import_sync_delta(&SyncDelta { watch_history: vec![watch("m", 10_000, 100)], ..Default::default() }).unwrap();
        let older = db
            .import_sync_delta(&SyncDelta { watch_history: vec![watch("m", 99_000, 50)], ..Default::default() })
            .unwrap();
        assert_eq!(older.watch_applied, 0);
        let newer = db
            .import_sync_delta(&SyncDelta { watch_history: vec![watch("m", 55_000, 200)], ..Default::default() })
            .unwrap();
        assert_eq!(newer.watch_applied, 1);
        let delta = db.export_sync_delta(0).unwrap();
        assert_eq!(delta.watch_history[0].position_ms, 55_000);
        assert_eq!(delta.watch_history[0].last_watched_at, 200);
    }

    #[test]
    fn only_changes_after_the_cursor_are_exported() {
        let db = db();
        db.import_sync_delta(&SyncDelta {
            sources: vec![src("old", "Old", 100), src("new", "New", 300)],
            favorites: vec![fav("a", 100), fav("b", 300)],
            watch_history: vec![watch("a", 1, 100), watch("b", 2, 300)],
            tombstones: vec![SyncTombstone { kind: TOMBSTONE_FAVORITE.into(), key: "z".into(), deleted_at: 300 }],
        })
        .unwrap();

        let delta = db.export_sync_delta(200).unwrap();
        assert_eq!(delta.sources.iter().map(|s| s.uuid.as_str()).collect::<Vec<_>>(), vec!["new"]);
        assert_eq!(delta.favorites.len(), 1);
        assert_eq!(delta.watch_history.len(), 1);
        assert_eq!(delta.tombstones.len(), 1);
        assert!(db.export_sync_delta(300).unwrap().is_empty());
    }

    #[test]
    fn catalog_and_guide_never_leave_the_device_and_local_files_are_not_exported() {
        let db = db();
        let id = db
            .add_source("Big", "m3u", Some("http://x/list.m3u"), None, None, None)
            .unwrap();
        let local = db
            .add_source("Local file", "m3u", Some("file:///Users/me/list.m3u"), None, None, None)
            .unwrap();
        assert_ne!(id, local);
        db.with_conn(|conn| {
            for i in 0..1000 {
                conn.execute(
                    "INSERT INTO iptv_items (source_id, stable_hash, kind, name, name_clean, host, stream_url, created_at, updated_at)
                     VALUES (?1, ?2, 'live', ?3, ?3, 'h', 'http://h/s', 1000, 1000)",
                    params![id, format!("hash_{i}"), format!("Channel {i}")],
                )?;
            }
            conn.execute(
                "INSERT INTO epg_programs (channel_tvg_id, start_ts, end_ts, title) VALUES ('c', 1, 2, 'T')",
                [],
            )?;
            Ok(())
        })
        .unwrap();

        let delta = db.export_sync_delta(0).unwrap();
        assert_eq!(delta.sources.len(), 1, "the file:// source stays on this device");
        assert_eq!(delta.sources[0].name, "Big");
        assert!(delta.favorites.is_empty() && delta.watch_history.is_empty() && delta.tombstones.is_empty());
    }

    #[test]
    fn same_name_sources_created_in_the_same_second_get_distinct_uuids() {
        let db = db();
        let first = db.add_source("playlist", "m3u", Some("http://a/1.m3u"), None, None, None).unwrap();
        let second = db.add_source("playlist", "m3u", Some("http://b/2.m3u"), None, None, None).unwrap();
        assert_ne!(first, second);
        let sources = db.list_sources().unwrap();
        assert_eq!(sources.len(), 2);
        assert_ne!(sources[0].uuid, sources[1].uuid);
    }
}
