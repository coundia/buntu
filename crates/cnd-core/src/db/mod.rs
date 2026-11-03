pub mod catalog_repo;
pub mod download_repo;
pub mod epg_repo;
pub mod ingestion_writer;
pub mod profile_repo;
pub mod recording_repo;
pub mod schema;
pub mod settings_repo;
pub mod sync_repo;

pub use profile_repo::{is_adult_category, FavoriteFolderRecord, ProfileRecord};
pub use recording_repo::{NewRecordingRequest, RecordingRecord, SeriesRuleRecord};

use rusqlite::{params, Connection};
use std::path::Path;
use std::sync::Mutex;
use thiserror::Error;

#[derive(Error, Debug)]
pub enum DbError {
    #[error("SQLite error: {0}")]
    Sqlite(#[from] rusqlite::Error),
    #[error("Database lock error: {0}")]
    Lock(String),
    #[error("Record not found: {0}")]
    NotFound(String),
    #[error("Serialization error: {0}")]
    Serialization(String),
    #[error("Query error: {0}")]
    Query(String),
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct DbStats {
    pub total_sources: u32,
    pub total_live_channels: u32,
    pub total_movies: u32,
    pub total_series: u32,
    pub total_episodes: u32,
    pub total_favorites: u32,
    pub total_broken: u32,
    pub total_downloads: u32,
    pub db_size_bytes: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct StreamHealthRecord {
    pub stable_hash: String,
    pub status: String,
    pub latency_ms: Option<u32>,
    pub checked_at: i64,
    pub consecutive_failures: u32,
    pub last_ok_at: Option<i64>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct IptvSourceRecord {
    pub id: i64,
    pub uuid: String,
    pub name: String,
    pub source_type: String,
    pub url: Option<String>,
    pub server: Option<String>,
    pub username: Option<String>,
    pub password_ref: Option<String>,
    pub epg_url: Option<String>,
    pub exp_date: Option<i64>,
    pub max_connections: Option<u32>,
    pub active_cons: Option<u32>,
    pub account_status: Option<String>,
    pub item_count: u32,
    pub updated_at: i64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct IptvItemRecord {
    pub id: i64,
    pub source_id: i64,
    pub series_id: Option<i64>,
    pub stable_hash: String,
    pub kind: String,
    pub season_num: Option<u32>,
    pub episode_num: Option<u32>,
    pub name: String,
    pub name_clean: String,
    pub year: Option<u32>,
    pub group_title: Option<String>,
    pub tvg_id: Option<String>,
    pub logo_url: Option<String>,
    pub chno: Option<u32>,
    pub host: String,
    pub container_ext: Option<String>,
    pub stream_url: String,
    pub user_agent: Option<String>,
    pub referer: Option<String>,
    pub headers_json: Option<String>,
    pub catchup_type: Option<String>,
    pub catchup_source: Option<String>,
    pub catchup_days: Option<u32>,
    pub plot: Option<String>,
    pub imdb_id: Option<String>,
    pub imdb_rating: Option<f64>,
    pub is_favorite: bool,
    pub is_broken: bool,
    pub resume_position_ms: i64,
    pub duration_ms: i64,
    pub is_completed: bool,
}

pub struct DatabaseManager {
    conn: Mutex<Connection>,
    db_path: String,
}

impl DatabaseManager {
    pub fn open<P: AsRef<Path>>(path: P) -> std::result::Result<Self, DbError> {
        let path_str = path.as_ref().to_string_lossy().to_string();
        let conn = Connection::open(&path)?;
        
        // Execute PRAGMAs and Schema creation
        conn.execute_batch(schema::INIT_SQL)?;
        Self::apply_incremental_migrations(&conn)?;
        Self::init_active_profile(&conn)?;

        Ok(Self {
            conn: Mutex::new(conn),
            db_path: path_str,
        })
    }

    pub fn open_in_memory() -> std::result::Result<Self, DbError> {
        let conn = Connection::open_in_memory()?;
        conn.execute_batch(schema::INIT_SQL)?;
        Self::apply_incremental_migrations(&conn)?;
        Self::init_active_profile(&conn)?;
        Ok(Self {
            conn: Mutex::new(conn),
            db_path: ":memory:".to_string(),
        })
    }

    /// The profile whose hidden lists and custom order the catalog queries apply. It lives in a
    /// connection-local table so the SQL can read it (`(SELECT id FROM temp.active_profile)`) without
    /// threading a parameter through every query. Profile 1 ("Principal") is the default.
    fn init_active_profile(conn: &Connection) -> std::result::Result<(), DbError> {
        conn.execute_batch(
            "CREATE TEMP TABLE IF NOT EXISTS active_profile (id INTEGER NOT NULL);
             DELETE FROM temp.active_profile;
             INSERT INTO temp.active_profile (id) VALUES (1);
             CREATE TEMP TABLE IF NOT EXISTS catalog_flags (show_adult INTEGER NOT NULL);
             DELETE FROM temp.catalog_flags;
             INSERT INTO temp.catalog_flags (show_adult) VALUES (0);",
        )?;
        // The same word-boundary keyword rule as `is_adult_category`, callable from the catalog SQL.
        conn.create_scalar_function(
            "is_adult_group",
            1,
            rusqlite::functions::FunctionFlags::SQLITE_UTF8 | rusqlite::functions::FunctionFlags::SQLITE_DETERMINISTIC,
            |ctx| {
                let group: Option<String> = ctx.get(0)?;
                Ok(group.is_some_and(|g| profile_repo::is_adult_category(&g)))
            },
        )?;
        Ok(())
    }

    /// Whether categories recognised as adult (keywords on the name) appear in the catalog. Off by
    /// default; the app turns it on for a session once the parental PIN has been entered.
    pub fn set_adult_content_visible(&self, visible: bool) -> std::result::Result<(), DbError> {
        self.with_conn(|conn| {
            conn.execute("UPDATE temp.catalog_flags SET show_adult = ?1", params![visible as i64])?;
            Ok(())
        })
    }

    pub fn set_active_profile(&self, id: i64) -> std::result::Result<(), DbError> {
        self.with_conn(|conn| {
            conn.execute("UPDATE temp.active_profile SET id = ?1", params![id])?;
            Ok(())
        })
    }

    fn apply_incremental_migrations(conn: &Connection) -> std::result::Result<(), DbError> {
        let alter_stmts = [
            "ALTER TABLE iptv_sources ADD COLUMN exp_date INTEGER",
            "ALTER TABLE iptv_sources ADD COLUMN max_connections INTEGER",
            "ALTER TABLE iptv_sources ADD COLUMN server_utc_offset_secs INTEGER",
            "ALTER TABLE iptv_sources ADD COLUMN active_cons INTEGER",
            "ALTER TABLE iptv_sources ADD COLUMN account_status TEXT",
            "ALTER TABLE series_catalog ADD COLUMN stable_hash TEXT NOT NULL DEFAULT ''",
            "CREATE INDEX IF NOT EXISTS idx_series_stable_hash ON series_catalog(stable_hash)",
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_epg_unique_slot ON epg_programs(channel_tvg_id, start_ts)",
            "ALTER TABLE download_tasks ADD COLUMN headers_json TEXT",
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_download_parts_task_idx ON download_parts(task_id, part_index)",
            "CREATE INDEX IF NOT EXISTS idx_download_logs_task ON download_logs(task_id, id DESC)",
            "ALTER TABLE broken_flags ADD COLUMN origin TEXT NOT NULL DEFAULT 'user'",
            "CREATE TABLE IF NOT EXISTS stream_health (
                stable_hash TEXT PRIMARY KEY,
                status TEXT NOT NULL,
                latency_ms INTEGER,
                checked_at INTEGER NOT NULL,
                consecutive_failures INTEGER NOT NULL DEFAULT 0,
                last_ok_at INTEGER
            )",
            "CREATE INDEX IF NOT EXISTS idx_stream_health_checked ON stream_health(checked_at)",
            "CREATE TABLE IF NOT EXISTS profiles (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                uuid TEXT NOT NULL UNIQUE,
                name TEXT NOT NULL,
                avatar TEXT NOT NULL DEFAULT 'person.crop.circle',
                is_kids INTEGER NOT NULL DEFAULT 0,
                created_at INTEGER NOT NULL
            )",
            "INSERT OR IGNORE INTO profiles(id, uuid, name, avatar, is_kids, created_at) VALUES (1, '00000000-0000-0000-0000-000000000001', 'Principal', 'person.crop.circle', 0, 1700000000)",
            "CREATE TABLE IF NOT EXISTS hidden_groups (
                profile_id INTEGER NOT NULL DEFAULT 1,
                kind TEXT NOT NULL,
                group_key TEXT NOT NULL,
                PRIMARY KEY(profile_id, kind, group_key)
            )",
            "CREATE TABLE IF NOT EXISTS hidden_items (
                profile_id INTEGER NOT NULL DEFAULT 1,
                stable_hash TEXT NOT NULL,
                PRIMARY KEY(profile_id, stable_hash)
            )",
            "CREATE TABLE IF NOT EXISTS custom_order (
                profile_id INTEGER NOT NULL DEFAULT 1,
                scope TEXT NOT NULL,
                key TEXT NOT NULL,
                position INTEGER NOT NULL,
                PRIMARY KEY(profile_id, scope, key)
            )",
            "CREATE TABLE IF NOT EXISTS favorite_folders (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                profile_id INTEGER NOT NULL DEFAULT 1,
                name TEXT NOT NULL,
                position INTEGER NOT NULL DEFAULT 0,
                created_at INTEGER NOT NULL
            )",
            "CREATE TABLE IF NOT EXISTS favorite_folder_items (
                folder_id INTEGER NOT NULL,
                stable_hash TEXT NOT NULL,
                position INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY(folder_id, stable_hash),
                FOREIGN KEY(folder_id) REFERENCES favorite_folders(id) ON DELETE CASCADE
            )",
            "ALTER TABLE favorites ADD COLUMN profile_id INTEGER NOT NULL DEFAULT 1",
            "ALTER TABLE watch_history ADD COLUMN profile_id INTEGER NOT NULL DEFAULT 1",
        ];
        for sql in alter_stmts {
            // Ignore duplicate column error on already-migrated databases
            let _ = conn.execute(sql, []);
        }
        Ok(())
    }

    pub(crate) fn with_conn<F, T>(&self, f: F) -> std::result::Result<T, DbError>
    where
        F: FnOnce(&Connection) -> std::result::Result<T, DbError>,
    {
        let guard = self.conn.lock().map_err(|e| DbError::Lock(e.to_string()))?;
        f(&guard)
    }

    pub(crate) fn with_conn_mut<F, T>(&self, f: F) -> std::result::Result<T, DbError>
    where
        F: FnOnce(&mut Connection) -> std::result::Result<T, DbError>,
    {
        let mut guard = self.conn.lock().map_err(|e| DbError::Lock(e.to_string()))?;
        f(&mut guard)
    }

    pub fn get_stats(&self) -> std::result::Result<DbStats, DbError> {
        let conn = self.conn.lock().map_err(|e| DbError::Lock(e.to_string()))?;

        let total_sources: u32 = conn.query_row(
            "SELECT COUNT(*) FROM iptv_sources",
            [],
            |r| r.get(0),
        ).unwrap_or(0);

        let total_live_channels: u32 = conn.query_row(
            "SELECT COUNT(*) FROM iptv_items WHERE kind = 'live'",
            [],
            |r| r.get(0),
        ).unwrap_or(0);

        let total_movies: u32 = conn.query_row(
            "SELECT COUNT(*) FROM iptv_items WHERE kind = 'movie'",
            [],
            |r| r.get(0),
        ).unwrap_or(0);

        let total_series: u32 = conn.query_row(
            "SELECT COUNT(*) FROM series_catalog",
            [],
            |r| r.get(0),
        ).unwrap_or(0);

        let total_episodes: u32 = conn.query_row(
            "SELECT COUNT(*) FROM iptv_items WHERE kind = 'episode'",
            [],
            |r| r.get(0),
        ).unwrap_or(0);

        let total_favorites: u32 = conn.query_row(
            "SELECT COUNT(*) FROM favorites",
            [],
            |r| r.get(0),
        ).unwrap_or(0);

        let total_broken: u32 = conn.query_row(
            "SELECT COUNT(*) FROM broken_flags",
            [],
            |r| r.get(0),
        ).unwrap_or(0);

        let total_downloads: u32 = conn.query_row(
            "SELECT COUNT(*) FROM download_tasks",
            [],
            |r| r.get(0),
        ).unwrap_or(0);

        let db_size_bytes = if self.db_path != ":memory:" {
            std::fs::metadata(&self.db_path)
                .map(|m| m.len())
                .unwrap_or(0)
        } else {
            0
        };

        Ok(DbStats {
            total_sources,
            total_live_channels,
            total_movies,
            total_series,
            total_episodes,
            total_favorites,
            total_broken,
            total_downloads,
            db_size_bytes,
        })
    }

    pub fn add_source(&self, name: &str, source_type: &str, url: Option<&str>, server: Option<&str>, username: Option<&str>, password_ref: Option<&str>) -> std::result::Result<i64, DbError> {
        let conn = self.conn.lock().map_err(|e| DbError::Lock(e.to_string()))?;
        let now = chrono_now_ts();
        let uuid = new_source_uuid(name, now);

        conn.execute(
            "INSERT INTO iptv_sources (uuid, name, source_type, url, server, username, password_ref, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?8)",
            params![uuid, name, source_type, url, server, username, password_ref, now],
        )?;

        Ok(conn.last_insert_rowid())
    }

    pub fn list_sources(&self) -> std::result::Result<Vec<IptvSourceRecord>, DbError> {
        let conn = self.conn.lock().map_err(|e| DbError::Lock(e.to_string()))?;
        let mut stmt = conn.prepare(
            "SELECT id, uuid, name, source_type, url, server, username, password_ref, epg_url,
                    exp_date, max_connections, active_cons, account_status, item_count, updated_at
             FROM iptv_sources ORDER BY updated_at DESC"
        )?;

        let rows = stmt.query_map([], |r| {
            Ok(IptvSourceRecord {
                id: r.get(0)?,
                uuid: r.get(1)?,
                name: r.get(2)?,
                source_type: r.get(3)?,
                url: r.get(4)?,
                server: r.get(5)?,
                username: r.get(6)?,
                password_ref: r.get(7)?,
                epg_url: r.get(8)?,
                exp_date: r.get(9)?,
                max_connections: r.get(10)?,
                active_cons: r.get(11)?,
                account_status: r.get(12)?,
                item_count: r.get(13)?,
                updated_at: r.get(14)?,
            })
        })?;

        let mut list = Vec::new();
        for item in rows {
            list.push(item?);
        }
        Ok(list)
    }

    pub fn toggle_favorite(&self, stable_hash: &str, item_kind: &str) -> std::result::Result<bool, DbError> {
        let conn = self.conn.lock().map_err(|e| DbError::Lock(e.to_string()))?;
        let exists: bool = conn.query_row(
            "SELECT EXISTS(SELECT 1 FROM favorites WHERE stable_hash = ?1)",
            params![stable_hash],
            |r| r.get(0),
        ).unwrap_or(false);

        if exists {
            conn.execute("DELETE FROM favorites WHERE stable_hash = ?1", params![stable_hash])?;
            sync_repo::upsert_tombstone(&conn, sync_repo::TOMBSTONE_FAVORITE, stable_hash, chrono_now_ts())?;
            Ok(false)
        } else {
            let now = chrono_now_ts();
            conn.execute(
                "INSERT INTO favorites (stable_hash, item_kind, created_at) VALUES (?1, ?2, ?3)",
                params![stable_hash, item_kind, now],
            )?;
            conn.execute(
                "DELETE FROM sync_tombstones WHERE kind = ?1 AND key = ?2",
                params![sync_repo::TOMBSTONE_FAVORITE, stable_hash],
            )?;
            Ok(true)
        }
    }

    pub fn toggle_broken(&self, stable_hash: &str, item_kind: &str) -> std::result::Result<bool, DbError> {
        let conn = self.conn.lock().map_err(|e| DbError::Lock(e.to_string()))?;
        let exists: bool = conn.query_row(
            "SELECT EXISTS(SELECT 1 FROM broken_flags WHERE stable_hash = ?1)",
            params![stable_hash],
            |r| r.get(0),
        ).unwrap_or(false);

        if exists {
            conn.execute("DELETE FROM broken_flags WHERE stable_hash = ?1", params![stable_hash])?;
            Ok(false)
        } else {
            let now = chrono_now_ts();
            conn.execute(
                "INSERT INTO broken_flags (stable_hash, item_kind, flagged_at, origin) VALUES (?1, ?2, ?3, 'user')",
                params![stable_hash, item_kind, now],
            )?;
            Ok(true)
        }
    }

    pub fn set_broken(&self, stable_hash: &str, item_kind: &str, broken: bool) -> std::result::Result<bool, DbError> {
        self.set_broken_with_origin(stable_hash, item_kind, broken, "user")
    }

    pub fn set_broken_with_origin(
        &self,
        stable_hash: &str,
        item_kind: &str,
        broken: bool,
        origin: &str,
    ) -> std::result::Result<bool, DbError> {
        let conn = self.conn.lock().map_err(|e| DbError::Lock(e.to_string()))?;
        if broken {
            let now = chrono_now_ts();
            conn.execute(
                "INSERT INTO broken_flags (stable_hash, item_kind, flagged_at, origin)
                 VALUES (?1, ?2, ?3, ?4)
                 ON CONFLICT(stable_hash) DO UPDATE SET
                     flagged_at = excluded.flagged_at,
                     origin = CASE WHEN broken_flags.origin = 'user' THEN 'user' ELSE excluded.origin END",
                params![stable_hash, item_kind, now, origin],
            )?;
            Ok(true)
        } else {
            if origin == "auto" {
                conn.execute(
                    "DELETE FROM broken_flags WHERE stable_hash = ?1 AND origin = 'auto'",
                    params![stable_hash],
                )?;
            } else {
                conn.execute("DELETE FROM broken_flags WHERE stable_hash = ?1", params![stable_hash])?;
            }
            Ok(false)
        }
    }

    pub fn is_broken(&self, stable_hash: &str) -> std::result::Result<bool, DbError> {
        let conn = self.conn.lock().map_err(|e| DbError::Lock(e.to_string()))?;
        let exists: bool = conn.query_row(
            "SELECT EXISTS(SELECT 1 FROM broken_flags WHERE stable_hash = ?1)",
            params![stable_hash],
            |r| r.get(0),
        ).unwrap_or(false);
        Ok(exists)
    }

    pub fn save_stream_health(&self, record: &StreamHealthRecord) -> std::result::Result<(), DbError> {
        let conn = self.conn.lock().map_err(|e| DbError::Lock(e.to_string()))?;
        conn.execute(
            "INSERT INTO stream_health (stable_hash, status, latency_ms, checked_at, consecutive_failures, last_ok_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)
             ON CONFLICT(stable_hash) DO UPDATE SET
                 status = excluded.status,
                 latency_ms = excluded.latency_ms,
                 checked_at = excluded.checked_at,
                 consecutive_failures = excluded.consecutive_failures,
                 last_ok_at = COALESCE(excluded.last_ok_at, stream_health.last_ok_at)",
            params![
                record.stable_hash,
                record.status,
                record.latency_ms,
                record.checked_at,
                record.consecutive_failures,
                record.last_ok_at
            ],
        )?;
        Ok(())
    }

    pub fn get_stream_health(&self, stable_hash: &str) -> std::result::Result<Option<StreamHealthRecord>, DbError> {
        let conn = self.conn.lock().map_err(|e| DbError::Lock(e.to_string()))?;
        let mut stmt = conn.prepare(
            "SELECT stable_hash, status, latency_ms, checked_at, consecutive_failures, last_ok_at
             FROM stream_health WHERE stable_hash = ?1",
        )?;
        let mut rows = stmt.query(params![stable_hash])?;
        if let Some(r) = rows.next()? {
            Ok(Some(StreamHealthRecord {
                stable_hash: r.get(0)?,
                status: r.get(1)?,
                latency_ms: r.get(2)?,
                checked_at: r.get(3)?,
                consecutive_failures: r.get(4)?,
                last_ok_at: r.get(5)?,
            }))
        } else {
            Ok(None)
        }
    }

    pub fn get_stream_health_batch(&self, hashes: &[String]) -> std::result::Result<Vec<StreamHealthRecord>, DbError> {
        if hashes.is_empty() {
            return Ok(Vec::new());
        }
        let conn = self.conn.lock().map_err(|e| DbError::Lock(e.to_string()))?;
        let placeholders = hashes.iter().map(|_| "?").collect::<Vec<_>>().join(",");
        let sql = format!(
            "SELECT stable_hash, status, latency_ms, checked_at, consecutive_failures, last_ok_at
             FROM stream_health WHERE stable_hash IN ({placeholders})"
        );
        let mut stmt = conn.prepare(&sql)?;
        let rows = stmt.query_map(rusqlite::params_from_iter(hashes.iter()), |r| {
            Ok(StreamHealthRecord {
                stable_hash: r.get(0)?,
                status: r.get(1)?,
                latency_ms: r.get(2)?,
                checked_at: r.get(3)?,
                consecutive_failures: r.get(4)?,
                last_ok_at: r.get(5)?,
            })
        })?;
        let mut result = Vec::new();
        for row in rows {
            result.push(row?);
        }
        Ok(result)
    }

    pub fn query_items(
        &self,
        kind: &str,
        query: &str,
        group: Option<&str>,
        host: Option<&str>,
        limit: u32,
        offset: u32,
    ) -> std::result::Result<Vec<IptvItemRecord>, DbError> {
        self.query_catalog(&catalog_repo::CatalogFilter {
            kind: kind.to_string(),
            source_id: None,
            query: query.to_string(),
            group_title: group.map(|s| s.to_string()),
            host: host.map(|s| s.to_string()),
            favorites_only: false,
            include_broken: false,
            include_hidden: false,
            sort_by: catalog_repo::SortField::Name,
            sort_asc: true,
            limit,
            offset,
        })
    }
}

/// `src_<unix seconds>_<hash>`. The hash mixes the name with a nanosecond clock and a process-wide
/// counter, so two sources with the same name created in the same second never collide, and the
/// uuid stays a safe identity across devices.
fn new_source_uuid(name: &str, now: i64) -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let seq = COUNTER.fetch_add(1, Ordering::Relaxed);
    let digest = blake3::hash(format!("{name}|{nanos}|{seq}").as_bytes());
    let short: String = digest.to_hex().chars().take(12).collect();
    format!("src_{now}_{short}")
}

pub(crate) fn chrono_now_ts() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_db_init_and_stats() {
        let db = DatabaseManager::open_in_memory().expect("open memory db");
        let stats = db.get_stats().expect("get stats");
        assert_eq!(stats.total_sources, 0);
        assert_eq!(stats.total_live_channels, 0);

        let src_id = db.add_source(
            "Test Source",
            "m3u",
            Some("http://example.com/test.m3u"),
            None,
            None,
            None,
        ).expect("add source");

        assert!(src_id > 0);
        let sources = db.list_sources().expect("list sources");
        assert_eq!(sources.len(), 1);
        assert_eq!(sources[0].name, "Test Source");
    }

    #[test]
    fn test_fts5_triggers_and_query() {
        let db = DatabaseManager::open_in_memory().expect("open memory db");
        let src_id = db.add_source("TV Source", "m3u", None, None, None, None).unwrap();

        {
            let conn = db.conn.lock().unwrap();
            conn.execute(
                "INSERT INTO iptv_items (source_id, stable_hash, kind, name, name_clean, group_title, host, stream_url, created_at, updated_at)
                 VALUES (?1, 'hash_france24', 'live', 'France 24 HD', 'France 24', 'News', 'stream.tv', 'http://stream.tv/f24.m3u8', 100, 100)",
                params![src_id],
            ).unwrap();
        }

        // Test normal list
        let items = db.query_items("live", "", None, None, 10, 0).unwrap();
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].name, "France 24 HD");
        assert!(!items[0].is_favorite);

        // Test toggle favorite
        let is_fav = db.toggle_favorite("hash_france24", "live").unwrap();
        assert!(is_fav);
        let items_fav = db.query_items("live", "", None, None, 10, 0).unwrap();
        assert!(items_fav[0].is_favorite);

        // Test FTS5 search
        let search_res = db.query_items("live", "France", None, None, 10, 0).unwrap();
        assert_eq!(search_res.len(), 1);

        let search_none = db.query_items("live", "Canal", None, None, 10, 0).unwrap();
        assert_eq!(search_none.len(), 0);
    }
}
