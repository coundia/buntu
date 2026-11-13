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
pub const TOMBSTONE_PROFILE: &str = "profile";

/// The built-in "Principal" profile: same uuid on every device, and it keeps the original record names
/// (no profile uuid), so what was synced before profiles existed stays valid.
pub const MAIN_PROFILE_UUID: &str = "00000000-0000-0000-0000-000000000001";

/// Local source of the same IPTV account (`cnd_domain::identity::account_identity_key`), whatever its
/// uuid: `(id, updated_at)` of the oldest one.
pub(crate) fn same_account_source(
    conn: &rusqlite::Connection,
    source_type: &str,
    server: Option<&str>,
    url: Option<&str>,
    username: Option<&str>,
) -> Result<Option<(i64, i64)>, rusqlite::Error> {
    let wanted = cnd_domain::identity::account_identity_key(source_type, server, url, username);
    let mut stmt = conn.prepare(
        "SELECT id, updated_at, source_type, server, url, username FROM iptv_sources ORDER BY id ASC",
    )?;
    let rows = stmt.query_map([], |r| {
        Ok((
            r.get::<_, i64>(0)?,
            r.get::<_, Option<i64>>(1)?.unwrap_or(0),
            r.get::<_, String>(2)?,
            r.get::<_, Option<String>>(3)?,
            r.get::<_, Option<String>>(4)?,
            r.get::<_, Option<String>>(5)?,
        ))
    })?;
    for row in rows {
        let (id, updated_at, st, srv, u, user) = row?;
        let key = cnd_domain::identity::account_identity_key(&st, srv.as_deref(), u.as_deref(), user.as_deref());
        if key == wanted {
            return Ok(Some((id, updated_at)));
        }
    }
    Ok(None)
}

/// Key of a favorite in tombstones and record names: the bare hash for the main profile, `uuid|hash` for others.
pub fn favorite_key(profile_uuid: Option<&str>, stable_hash: &str) -> String {
    match profile_uuid {
        None => stable_hash.to_string(),
        Some(uuid) => format!("{uuid}|{stable_hash}"),
    }
}

/// Inverse of `favorite_key`. A `|` only means "profile prefix" when what precedes it looks like a uuid.
pub fn split_favorite_key(key: &str) -> (Option<&str>, &str) {
    match key.split_once('|') {
        Some((uuid, hash)) if uuid.len() == 36 => (Some(uuid), hash),
        _ => (None, key),
    }
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SyncProfile {
    pub uuid: String,
    pub name: String,
    pub avatar: String,
    pub is_kids: bool,
    pub updated_at: i64,
}

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
    /// `None` for the main profile.
    pub profile_uuid: Option<String>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SyncWatchProgress {
    pub stable_hash: String,
    pub position_ms: i64,
    pub duration_ms: i64,
    pub completed: bool,
    pub last_watched_at: i64,
    /// `None` for the main profile.
    pub profile_uuid: Option<String>,
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
    pub profiles: Vec<SyncProfile>,
    pub sources: Vec<SyncSource>,
    pub favorites: Vec<SyncFavorite>,
    pub watch_history: Vec<SyncWatchProgress>,
    pub tombstones: Vec<SyncTombstone>,
}

impl SyncDelta {
    pub fn is_empty(&self) -> bool {
        self.profiles.is_empty()
            && self.sources.is_empty()
            && self.favorites.is_empty()
            && self.watch_history.is_empty()
            && self.tombstones.is_empty()
    }
}

#[derive(Debug, Clone, Default, PartialEq, uniffi::Record)]
pub struct SyncImportSummary {
    pub profiles_applied: u32,
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
        self.profiles_applied + self.sources_applied + self.favorites_applied + self.watch_applied + self.deletions_applied
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

            let mut profiles = Vec::new();
            let mut stmt = conn.prepare(
                "SELECT uuid, name, avatar, is_kids, updated_at FROM profiles
                 WHERE updated_at > ?1 ORDER BY updated_at ASC, id ASC",
            )?;
            for row in stmt.query_map(params![since_ts], |r| {
                Ok(SyncProfile {
                    uuid: r.get(0)?,
                    name: r.get(1)?,
                    avatar: r.get(2)?,
                    is_kids: r.get::<_, i64>(3)? != 0,
                    updated_at: r.get(4)?,
                })
            })? {
                profiles.push(row?);
            }

            let mut favorites = Vec::new();
            let mut stmt = conn.prepare(
                "SELECT f.stable_hash, f.item_kind, f.created_at, CASE WHEN f.profile_id = 1 THEN NULL ELSE p.uuid END
                 FROM favorites f LEFT JOIN profiles p ON p.id = f.profile_id
                 WHERE f.created_at > ?1 AND (f.profile_id = 1 OR p.id IS NOT NULL)
                 ORDER BY f.created_at ASC, f.profile_id ASC, f.stable_hash ASC",
            )?;
            for row in stmt.query_map(params![since_ts], |r| {
                Ok(SyncFavorite {
                    stable_hash: r.get(0)?,
                    item_kind: r.get(1)?,
                    created_at: r.get(2)?,
                    profile_uuid: r.get(3)?,
                })
            })? {
                favorites.push(row?);
            }

            let mut watch_history = Vec::new();
            let mut stmt = conn.prepare(
                "SELECT w.stable_hash, w.position_ms, w.duration_ms, w.completed, w.last_watched_at,
                        CASE WHEN w.profile_id = 1 THEN NULL ELSE p.uuid END
                 FROM watch_history w LEFT JOIN profiles p ON p.id = w.profile_id
                 WHERE w.last_watched_at > ?1 AND (w.profile_id = 1 OR p.id IS NOT NULL)
                 ORDER BY w.last_watched_at ASC, w.profile_id ASC, w.stable_hash ASC",
            )?;
            for row in stmt.query_map(params![since_ts], |r| {
                Ok(SyncWatchProgress {
                    stable_hash: r.get(0)?,
                    position_ms: r.get(1)?,
                    duration_ms: r.get(2)?,
                    completed: r.get::<_, i64>(3)? != 0,
                    last_watched_at: r.get(4)?,
                    profile_uuid: r.get(5)?,
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
                let tomb = row?;
                // Account deletions stay on their device (`cnd_domain::sync::deletion_propagates`).
                if cnd_domain::sync::deletion_propagates(&tomb.kind) {
                    tombstones.push(tomb);
                }
            }

            Ok(SyncDelta {
                profiles,
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
                        let (profile_uuid, hash) = split_favorite_key(&tomb.key);
                        let Some(profile_id) = profile_id_for(&tx, profile_uuid)? else {
                            summary.skipped += 1;
                            continue;
                        };
                        let local: Option<i64> = tx
                            .query_row(
                                "SELECT created_at FROM favorites WHERE profile_id = ?1 AND stable_hash = ?2",
                                params![profile_id, hash],
                                |r| r.get(0),
                            )
                            .optional()?;
                        if matches!(local, Some(created) if created >= tomb.deleted_at) {
                            summary.skipped += 1;
                            continue;
                        }
                        if local.is_some() {
                            tx.execute(
                                "DELETE FROM favorites WHERE profile_id = ?1 AND stable_hash = ?2",
                                params![profile_id, hash],
                            )?;
                            summary.deletions_applied += 1;
                        } else {
                            summary.skipped += 1;
                        }
                        upsert_tombstone(&tx, TOMBSTONE_FAVORITE, &tomb.key, tomb.deleted_at)?;
                    }
                    TOMBSTONE_PROFILE => {
                        if tomb.key == MAIN_PROFILE_UUID {
                            summary.skipped += 1; // the main profile is never removed
                            continue;
                        }
                        let local: Option<(i64, i64)> = tx
                            .query_row(
                                "SELECT id, updated_at FROM profiles WHERE uuid = ?1",
                                params![tomb.key],
                                |r| Ok((r.get(0)?, r.get(1)?)),
                            )
                            .optional()?;
                        if matches!(local, Some((_, updated)) if updated > tomb.deleted_at) {
                            summary.skipped += 1;
                            continue;
                        }
                        if let Some((id, _)) = local {
                            for table in ["favorites", "watch_history", "hidden_groups", "hidden_items", "custom_order", "kids_allowed_groups"] {
                                tx.execute(&format!("DELETE FROM {table} WHERE profile_id = ?1"), params![id])?;
                            }
                            tx.execute("DELETE FROM profiles WHERE id = ?1", params![id])?;
                            summary.deletions_applied += 1;
                        } else {
                            summary.skipped += 1;
                        }
                        upsert_tombstone(&tx, TOMBSTONE_PROFILE, &tomb.key, tomb.deleted_at)?;
                    }
                    // Sent by an older app: an account is never deleted by another device.
                    TOMBSTONE_SOURCE if !cnd_domain::sync::deletion_propagates(TOMBSTONE_SOURCE) => {
                        summary.skipped += 1;
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

            for profile in &delta.profiles {
                let tomb: Option<i64> = tx
                    .query_row(
                        "SELECT deleted_at FROM sync_tombstones WHERE kind = ?1 AND key = ?2",
                        params![TOMBSTONE_PROFILE, profile.uuid],
                        |r| r.get(0),
                    )
                    .optional()?;
                if profile.uuid == MAIN_PROFILE_UUID {
                    // Same identity everywhere: only its name and avatar can change.
                } else if matches!(tomb, Some(deleted) if deleted >= profile.updated_at) {
                    summary.skipped += 1;
                    continue;
                }
                let local: Option<i64> = tx
                    .query_row("SELECT updated_at FROM profiles WHERE uuid = ?1", params![profile.uuid], |r| r.get(0))
                    .optional()?;
                match local {
                    None => {
                        tx.execute(
                            "INSERT INTO profiles (uuid, name, avatar, is_kids, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?5)",
                            params![profile.uuid, profile.name, profile.avatar, i64::from(profile.is_kids), profile.updated_at],
                        )?;
                        tx.execute(
                            "DELETE FROM sync_tombstones WHERE kind = ?1 AND key = ?2",
                            params![TOMBSTONE_PROFILE, profile.uuid],
                        )?;
                        summary.profiles_applied += 1;
                    }
                    Some(local_ts) if profile.updated_at > local_ts => {
                        tx.execute(
                            "UPDATE profiles SET name = ?2, avatar = ?3, is_kids = ?4, updated_at = ?5 WHERE uuid = ?1",
                            params![profile.uuid, profile.name, profile.avatar, i64::from(profile.is_kids), profile.updated_at],
                        )?;
                        summary.profiles_applied += 1;
                    }
                    Some(_) => summary.skipped += 1,
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
                // A local deletion no longer blocks an account sent by another device: "Recevoir" brings it back.
                if cnd_domain::sync::deletion_propagates(TOMBSTONE_SOURCE)
                    && matches!(tomb, Some(deleted) if deleted >= src.updated_at)
                {
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
                // Same account under another uuid (added on each device, or re-created by the TV): one row.
                if local.is_none() {
                    if let Some((same_id, same_ts)) = same_account_source(&tx, &src.source_type, src.server.as_deref(), src.url.as_deref(), src.username.as_deref())? {
                        if src.updated_at > same_ts {
                            // This device keeps its own uuid and its password reference (the secret lives here).
                            tx.execute(
                                "UPDATE iptv_sources
                                 SET name = ?2, url = COALESCE(?3, url), server = COALESCE(?4, server),
                                     username = COALESCE(?5, username), password_ref = COALESCE(password_ref, ?6),
                                     epg_url = COALESCE(?7, epg_url), updated_at = ?8
                                 WHERE id = ?1",
                                params![
                                    same_id, src.name, src.url, src.server, src.username,
                                    src.password_ref, src.epg_url, src.updated_at
                                ],
                            )?;
                            summary.sources_applied += 1;
                        } else {
                            summary.skipped += 1;
                        }
                        continue;
                    }
                }
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
                // A favorite of a profile this device does not know (yet) cannot be placed.
                let Some(profile_id) = profile_id_for(&tx, fav.profile_uuid.as_deref())? else {
                    summary.skipped += 1;
                    continue;
                };
                let key = favorite_key(fav.profile_uuid.as_deref().filter(|u| *u != MAIN_PROFILE_UUID), &fav.stable_hash);
                let tomb: Option<i64> = tx
                    .query_row(
                        "SELECT deleted_at FROM sync_tombstones WHERE kind = ?1 AND key = ?2",
                        params![TOMBSTONE_FAVORITE, key],
                        |r| r.get(0),
                    )
                    .optional()?;
                if matches!(tomb, Some(deleted) if deleted > fav.created_at) {
                    summary.skipped += 1;
                    continue;
                }
                let local: Option<i64> = tx
                    .query_row(
                        "SELECT created_at FROM favorites WHERE profile_id = ?1 AND stable_hash = ?2",
                        params![profile_id, fav.stable_hash],
                        |r| r.get(0),
                    )
                    .optional()?;
                match local {
                    None => {
                        tx.execute(
                            "INSERT INTO favorites (profile_id, stable_hash, item_kind, created_at) VALUES (?1, ?2, ?3, ?4)",
                            params![profile_id, fav.stable_hash, fav.item_kind, fav.created_at],
                        )?;
                        tx.execute(
                            "DELETE FROM sync_tombstones WHERE kind = ?1 AND key = ?2",
                            params![TOMBSTONE_FAVORITE, key],
                        )?;
                        summary.favorites_applied += 1;
                    }
                    Some(local_ts) if fav.created_at > local_ts => {
                        tx.execute(
                            "UPDATE favorites SET item_kind = ?3, created_at = ?4 WHERE profile_id = ?1 AND stable_hash = ?2",
                            params![profile_id, fav.stable_hash, fav.item_kind, fav.created_at],
                        )?;
                        summary.favorites_applied += 1;
                    }
                    Some(_) => summary.skipped += 1,
                }
            }

            for watch in &delta.watch_history {
                let Some(profile_id) = profile_id_for(&tx, watch.profile_uuid.as_deref())? else {
                    summary.skipped += 1;
                    continue;
                };
                let local: Option<i64> = tx
                    .query_row(
                        "SELECT last_watched_at FROM watch_history WHERE profile_id = ?1 AND stable_hash = ?2",
                        params![profile_id, watch.stable_hash],
                        |r| r.get(0),
                    )
                    .optional()?;
                if matches!(local, Some(local_ts) if local_ts >= watch.last_watched_at) {
                    summary.skipped += 1;
                    continue;
                }
                tx.execute(
                    "INSERT INTO watch_history (profile_id, stable_hash, position_ms, duration_ms, completed, last_watched_at)
                     VALUES (?6, ?1, ?2, ?3, ?4, ?5)
                     ON CONFLICT(profile_id, stable_hash) DO UPDATE SET
                         position_ms = excluded.position_ms,
                         duration_ms = excluded.duration_ms,
                         completed = excluded.completed,
                         last_watched_at = excluded.last_watched_at",
                    params![
                        watch.stable_hash, watch.position_ms.max(0), watch.duration_ms.max(0),
                        i64::from(watch.completed), watch.last_watched_at, profile_id
                    ],
                )?;
                summary.watch_applied += 1;
            }

            // The active profile may just have become (or stopped being) a Kids profile.
            tx.execute(
                "UPDATE temp.catalog_flags SET kids_only =
                    COALESCE((SELECT is_kids FROM profiles WHERE id = (SELECT id FROM temp.active_profile)), 0)",
                [],
            )?;
            tx.commit()?;
            Ok(summary)
        })
    }
}

/// The local id of a profile from its sync identity (`None` = the main profile); `None` if unknown here.
fn profile_id_for(tx: &rusqlite::Connection, profile_uuid: Option<&str>) -> Result<Option<i64>, DbError> {
    match profile_uuid {
        None => Ok(Some(1)),
        Some(MAIN_PROFILE_UUID) => Ok(Some(1)),
        Some(uuid) => Ok(tx
            .query_row("SELECT id FROM profiles WHERE uuid = ?1", params![uuid], |r| r.get(0))
            .optional()?),
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
            // One playlist per test account: the same address is the same account.
            url: Some(format!("http://example.com/{uuid}.m3u")),
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
            profile_uuid: None,
        }
    }

    fn watch(hash: &str, pos: i64, at: i64) -> SyncWatchProgress {
        SyncWatchProgress {
            stable_hash: hash.to_string(),
            position_ms: pos,
            duration_ms: 100_000,
            completed: false,
            last_watched_at: at,
            profile_uuid: None,
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

    fn xtream(uuid: &str, server: &str, user: &str, updated_at: i64) -> SyncSource {
        SyncSource {
            uuid: uuid.to_string(),
            name: "Premium".to_string(),
            source_type: "xtream".to_string(),
            url: None,
            server: Some(server.to_string()),
            username: Some(user.to_string()),
            password_ref: Some(format!("cnd.xtream.{uuid}")),
            epg_url: None,
            updated_at,
        }
    }

    fn delta_of(sources: Vec<SyncSource>) -> SyncDelta {
        SyncDelta { profiles: vec![], sources, favorites: vec![], watch_history: vec![], tombstones: vec![] }
    }

    #[test]
    fn the_same_account_from_another_device_is_not_duplicated() {
        let tv = db();
        let local = tv
            .add_source("Mon compte", "xtream", None, Some("http://srv.example:8080"), Some("bob"), Some("cnd.xtream.local"))
            .unwrap();

        // Added on the iPhone by itself: another uuid, the server written differently.
        let summary = tv
            .import_sync_delta(&delta_of(vec![xtream("src_iphone", "http://SRV.example:8080/", "Bob ", 1)]))
            .unwrap();
        assert!(summary.inserted_source_ids.is_empty());
        let sources = tv.list_sources().unwrap();
        assert_eq!(sources.len(), 1);
        assert_eq!(sources[0].id, local);
        // This device keeps its own password reference.
        assert_eq!(sources[0].password_ref.as_deref(), Some("cnd.xtream.local"));

        // Importing it again, or a newer version of it, still gives one account.
        tv.import_sync_delta(&delta_of(vec![xtream("src_iphone", "http://srv.example:8080", "bob", i64::MAX / 2)]))
            .unwrap();
        assert_eq!(tv.list_sources().unwrap().len(), 1);
    }

    #[test]
    fn a_delta_carrying_one_account_twice_adds_it_once() {
        let mac = db();
        let summary = mac
            .import_sync_delta(&delta_of(vec![
                xtream("src_a", "http://srv.example:8080", "bob", 10),
                xtream("src_b", "http://srv.example:8080/", "BOB", 11),
                xtream("src_c", "http://srv.example:8080", "alice", 12),
            ]))
            .unwrap();
        assert_eq!(summary.inserted_source_ids.len(), 2);
        assert_eq!(mac.list_sources().unwrap().len(), 2);
    }

    #[test]
    fn adding_an_existing_account_returns_it() {
        let phone = db();
        let first = phone
            .add_source("Premium", "xtream", None, Some("http://srv.example:8080"), Some("bob"), Some("ref.1"))
            .unwrap();
        let again = phone
            .add_source("Premium bis", "m3u", Some("http://srv.example:8080/get.php?username=bob&password=x&type=m3u_plus"), None, None, Some("ref.2"))
            .unwrap();
        assert_eq!(first, again);
        let sources = phone.list_sources().unwrap();
        assert_eq!(sources.len(), 1);
        assert_eq!(sources[0].password_ref.as_deref(), Some("ref.2"));

        let other = phone
            .add_source("Alice", "xtream", None, Some("http://srv.example:8080"), Some("alice"), None)
            .unwrap();
        assert_ne!(first, other);
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
    fn deleting_an_account_stays_on_its_device() {
        let a = db();
        let b = db();
        let id = a.add_source("Kept", "m3u", Some("http://x/l.m3u"), None, None, None).unwrap();
        b.import_sync_delta(&a.export_sync_delta(0).unwrap()).unwrap();
        assert_eq!(b.list_sources().unwrap().len(), 1);

        // Deleted on A: nothing about it leaves A, B keeps its account.
        a.delete_source(id).unwrap();
        let delta = a.export_sync_delta(0).unwrap();
        assert!(delta.sources.is_empty());
        assert!(delta.tombstones.iter().all(|t| t.kind != TOMBSTONE_SOURCE));
        b.import_sync_delta(&delta).unwrap();
        assert_eq!(b.list_sources().unwrap().len(), 1);

        // A deletion sent by an older app is ignored too.
        let uuid = b.list_sources().unwrap()[0].uuid.clone();
        let old_app = SyncDelta {
            tombstones: vec![SyncTombstone { kind: TOMBSTONE_SOURCE.to_string(), key: uuid, deleted_at: i64::MAX / 2 }],
            ..Default::default()
        };
        let summary = b.import_sync_delta(&old_app).unwrap();
        assert_eq!(summary.deletions_applied, 0);
        assert_eq!(b.list_sources().unwrap().len(), 1);

        // "Recevoir" on A brings the account back, once.
        a.import_sync_delta(&b.export_sync_delta(0).unwrap()).unwrap();
        a.import_sync_delta(&b.export_sync_delta(0).unwrap()).unwrap();
        assert_eq!(a.list_sources().unwrap().len(), 1);
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
            profiles: vec![],
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

    // MARK: profiles

    const KIDS_UUID: &str = "11111111-2222-3333-4444-555555555555";

    fn profile(uuid: &str, name: &str, kids: bool, at: i64) -> SyncProfile {
        SyncProfile { uuid: uuid.to_string(), name: name.to_string(), avatar: "star".to_string(), is_kids: kids, updated_at: at }
    }

    fn fav_for(uuid: &str, hash: &str, at: i64) -> SyncFavorite {
        SyncFavorite { profile_uuid: Some(uuid.to_string()), ..fav(hash, at) }
    }

    fn profile_by_uuid(db: &DatabaseManager, uuid: &str) -> Option<(i64, String, bool)> {
        db.list_profiles().unwrap().into_iter().find(|p| p.uuid == uuid).map(|p| (p.id, p.name, p.is_kids))
    }

    fn favorites_of(db: &DatabaseManager, profile_id: i64) -> Vec<String> {
        db.with_conn(|c| {
            let mut stmt = c.prepare("SELECT stable_hash FROM favorites WHERE profile_id = ?1 ORDER BY stable_hash")?;
            let rows = stmt.query_map(params![profile_id], |r| r.get(0))?;
            Ok(rows.collect::<Result<Vec<String>, _>>()?)
        })
        .unwrap()
    }

    #[test]
    fn a_new_profile_and_its_favorites_reach_the_other_device() {
        let a = db();
        let kids = a.create_profile("Léa", "star", true).unwrap();
        a.set_active_profile(kids.id).unwrap();
        a.toggle_favorite("cartoon", "live").unwrap();
        a.record_watch_progress("cartoon", 5_000, 60_000).unwrap();

        let b = db();
        let summary = b.import_sync_delta(&a.export_sync_delta(0).unwrap()).unwrap();
        assert_eq!(summary.profiles_applied, 1);

        let (id, name, is_kids) = profile_by_uuid(&b, &kids.uuid).expect("the profile exists on device B");
        assert_eq!((name.as_str(), is_kids), ("Léa", true));
        assert_ne!(id, 1);
        assert_eq!(favorites_of(&b, id), vec!["cartoon"]);
        assert!(favorites_of(&b, 1).is_empty(), "nothing leaks into the main profile");
        let position: i64 = b
            .with_conn(|c| Ok(c.query_row("SELECT position_ms FROM watch_history WHERE profile_id = ?1", params![id], |r| r.get(0))?))
            .unwrap();
        assert_eq!(position, 5_000);

        // Importing the same delta again changes nothing.
        assert_eq!(b.import_sync_delta(&a.export_sync_delta(0).unwrap()).unwrap().applied(), 0);
    }

    #[test]
    fn main_profile_data_keeps_its_original_shape() {
        let a = db();
        a.toggle_favorite("m", "movie").unwrap();
        let delta = a.export_sync_delta(0).unwrap();
        assert_eq!(delta.favorites[0].profile_uuid, None, "no profile uuid for the main profile");
        assert_eq!(delta.tombstones.len(), 0);

        // A record from before profiles existed (no uuid) lands in the main profile.
        let b = db();
        b.import_sync_delta(&SyncDelta { favorites: vec![fav("old", 100)], ..Default::default() }).unwrap();
        assert_eq!(favorites_of(&b, 1), vec!["old"]);
        // So does one that names the main profile explicitly.
        b.import_sync_delta(&SyncDelta { favorites: vec![fav_for(MAIN_PROFILE_UUID, "named", 100)], ..Default::default() }).unwrap();
        assert_eq!(favorites_of(&b, 1), vec!["named", "old"]);
    }

    #[test]
    fn a_favorite_of_an_unknown_profile_is_skipped_not_misplaced() {
        let b = db();
        let summary = b
            .import_sync_delta(&SyncDelta { favorites: vec![fav_for(KIDS_UUID, "x", 100)], ..Default::default() })
            .unwrap();
        assert_eq!((summary.favorites_applied, summary.skipped), (0, 1));
        assert!(favorites_of(&b, 1).is_empty());
    }

    #[test]
    fn the_profile_and_its_favorites_can_arrive_in_the_same_delta() {
        let b = db();
        let summary = b
            .import_sync_delta(&SyncDelta {
                profiles: vec![profile(KIDS_UUID, "Léa", true, 100)],
                favorites: vec![fav_for(KIDS_UUID, "x", 100)],
                ..Default::default()
            })
            .unwrap();
        assert_eq!((summary.profiles_applied, summary.favorites_applied), (1, 1));
        let (id, ..) = profile_by_uuid(&b, KIDS_UUID).unwrap();
        assert_eq!(favorites_of(&b, id), vec!["x"]);
    }

    #[test]
    fn the_latest_edit_of_a_profile_wins() {
        let b = db();
        b.import_sync_delta(&SyncDelta { profiles: vec![profile(KIDS_UUID, "Léa", true, 100)], ..Default::default() }).unwrap();
        b.import_sync_delta(&SyncDelta { profiles: vec![profile(KIDS_UUID, "Léa (grande)", false, 200)], ..Default::default() }).unwrap();
        assert_eq!(profile_by_uuid(&b, KIDS_UUID).map(|p| (p.1, p.2)), Some(("Léa (grande)".to_string(), false)));
        let stale = b.import_sync_delta(&SyncDelta { profiles: vec![profile(KIDS_UUID, "Vieux nom", true, 50)], ..Default::default() }).unwrap();
        assert_eq!(stale.profiles_applied, 0);
        assert_eq!(profile_by_uuid(&b, KIDS_UUID).map(|p| p.1), Some("Léa (grande)".to_string()));
    }

    #[test]
    fn deleting_a_profile_removes_it_and_its_data_elsewhere() {
        let a = db();
        let kids = a.create_profile("Léa", "star", true).unwrap();
        a.set_active_profile(kids.id).unwrap();
        a.toggle_favorite("cartoon", "live").unwrap();
        let b = db();
        b.import_sync_delta(&a.export_sync_delta(0).unwrap()).unwrap();
        let (b_id, ..) = profile_by_uuid(&b, &kids.uuid).unwrap();
        assert_eq!(favorites_of(&b, b_id), vec!["cartoon"]);

        a.set_active_profile(1).unwrap();
        assert!(a.delete_profile(kids.id).unwrap());
        let delta = a.export_sync_delta(0).unwrap();
        assert!(delta.tombstones.iter().any(|t| t.kind == TOMBSTONE_PROFILE && t.key == kids.uuid));

        let summary = b.import_sync_delta(&delta).unwrap();
        assert_eq!(summary.deletions_applied, 1);
        assert!(profile_by_uuid(&b, &kids.uuid).is_none());
        assert!(favorites_of(&b, b_id).is_empty(), "its favorites went with it");
    }

    #[test]
    fn a_profile_recreated_after_a_deletion_is_not_blocked_but_an_older_copy_is() {
        let b = db();
        b.import_sync_delta(&SyncDelta {
            tombstones: vec![SyncTombstone { kind: TOMBSTONE_PROFILE.into(), key: KIDS_UUID.into(), deleted_at: 500 }],
            ..Default::default()
        })
        .unwrap();
        let old = b.import_sync_delta(&SyncDelta { profiles: vec![profile(KIDS_UUID, "Léa", true, 400)], ..Default::default() }).unwrap();
        assert_eq!(old.profiles_applied, 0, "edited before the deletion: stays deleted");
        let newer = b.import_sync_delta(&SyncDelta { profiles: vec![profile(KIDS_UUID, "Léa", true, 600)], ..Default::default() }).unwrap();
        assert_eq!(newer.profiles_applied, 1, "created again after the deletion");
    }

    #[test]
    fn the_main_profile_cannot_be_deleted_by_a_remote_tombstone() {
        let b = db();
        let summary = b
            .import_sync_delta(&SyncDelta {
                tombstones: vec![SyncTombstone { kind: TOMBSTONE_PROFILE.into(), key: MAIN_PROFILE_UUID.into(), deleted_at: 9_999_999_999 }],
                ..Default::default()
            })
            .unwrap();
        assert_eq!(summary.skipped, 1);
        assert!(profile_by_uuid(&b, MAIN_PROFILE_UUID).is_some());
        assert_eq!(b.list_profiles().unwrap().len(), 1);
    }

    #[test]
    fn removing_a_favorite_in_one_profile_does_not_touch_the_same_channel_in_another() {
        let b = db();
        b.import_sync_delta(&SyncDelta {
            profiles: vec![profile(KIDS_UUID, "Léa", true, 100)],
            favorites: vec![fav("same", 100), fav_for(KIDS_UUID, "same", 100)],
            ..Default::default()
        })
        .unwrap();
        let (kids_id, ..) = profile_by_uuid(&b, KIDS_UUID).unwrap();

        b.import_sync_delta(&SyncDelta {
            tombstones: vec![SyncTombstone { kind: TOMBSTONE_FAVORITE.into(), key: favorite_key(Some(KIDS_UUID), "same"), deleted_at: 200 }],
            ..Default::default()
        })
        .unwrap();
        assert!(favorites_of(&b, kids_id).is_empty());
        assert_eq!(favorites_of(&b, 1), vec!["same"], "the main profile keeps it");
    }

    #[test]
    fn favorite_keys_round_trip() {
        assert_eq!(favorite_key(None, "movie_1"), "movie_1");
        assert_eq!(split_favorite_key("movie_1"), (None, "movie_1"));
        let key = favorite_key(Some(KIDS_UUID), "movie_1");
        assert_eq!(split_favorite_key(&key), (Some(KIDS_UUID), "movie_1"));
        // A hash that happens to contain a bar is not mistaken for a profile prefix.
        assert_eq!(split_favorite_key("a|b"), (None, "a|b"));
    }
}
