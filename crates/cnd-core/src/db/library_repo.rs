use crate::db::{DatabaseManager, DbError};
use rusqlite::{params, Row};
use std::time::{SystemTime, UNIX_EPOCH};

fn now_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct LibraryFolderRecord {
    pub id: i64,
    pub display_name: String,
    pub path: String,
    pub bookmark: Option<Vec<u8>>,
    pub include_subfolders: bool,
    pub kinds: String,
    pub state: String,
    pub item_count: u32,
    pub last_scan_at: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct LibraryScanReport {
    pub added: u32,
    pub updated: u32,
    pub removed: u32,
    pub unchanged: u32,
    pub ignored: u32,
    pub duration_ms: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct LibraryItemRecord {
    pub id: i64,
    pub folder_id: i64,
    pub rel_path: String,
    pub full_path: String,
    pub kind: String,
    pub size: u64,
    pub mtime: i64,
    pub fingerprint: String,
    pub title: Option<String>,
    pub duration_ms: Option<u32>,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub codec: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub album_artist: Option<String>,
    pub track_no: Option<u32>,
    pub disc_no: Option<u32>,
    pub genre: Option<String>,
    pub year: Option<u32>,
    pub taken_at: Option<i64>,
    pub thumbnail_path: Option<String>,
    pub subtitles: Vec<String>,
    pub metadata_state: String,
    pub added_at: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct LibraryBrowseEntry {
    pub name: String,
    pub rel_path: String,
    pub is_directory: bool,
    pub kind: Option<String>,
    pub item_id: Option<i64>,
    pub size: Option<u64>,
    pub duration_ms: Option<u32>,
    pub thumbnail_path: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct LibraryAlbumRecord {
    pub name: String,
    pub artist: Option<String>,
    pub year: Option<u32>,
    pub track_count: u32,
    pub thumbnail_path: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct LibraryArtistRecord {
    pub name: String,
    pub album_count: u32,
    pub track_count: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct LibraryGenreRecord {
    pub name: String,
    pub track_count: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct LibraryProgressRecord {
    pub fingerprint: String,
    pub position_ms: i64,
    pub duration_ms: i64,
    pub completed: bool,
    pub last_played_at: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct LibraryItemMetadataInput {
    pub title: Option<String>,
    pub duration_ms: Option<u32>,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub codec: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub album_artist: Option<String>,
    pub track_no: Option<u32>,
    pub disc_no: Option<u32>,
    pub genre: Option<String>,
    pub year: Option<u32>,
    pub taken_at: Option<i64>,
    pub thumbnail_path: Option<String>,
}

pub(crate) fn parse_subtitles_json(s: Option<String>) -> Vec<String> {
    if let Some(raw) = s {
        serde_json::from_str(&raw).unwrap_or_default()
    } else {
        Vec::new()
    }
}

pub(crate) fn row_to_item(row: &Row<'_>, folder_path: &str) -> rusqlite::Result<LibraryItemRecord> {
    let rel_path: String = row.get("rel_path")?;
    let full_path = if folder_path.is_empty() {
        rel_path.clone()
    } else {
        format!("{folder_path}/{rel_path}")
    };
    let subtitles_raw: Option<String> = row.get("subtitles_json").ok();

    Ok(LibraryItemRecord {
        id: row.get("id")?,
        folder_id: row.get("folder_id")?,
        rel_path,
        full_path,
        kind: row.get("kind")?,
        size: row.get::<_, i64>("size")? as u64,
        mtime: row.get("mtime")?,
        fingerprint: row.get("fingerprint")?,
        title: row.get("title")?,
        duration_ms: row.get::<_, Option<i64>>("duration_ms")?.map(|v| v.max(0) as u32),
        width: row.get::<_, Option<i64>>("width")?.map(|v| v.max(0) as u32),
        height: row.get::<_, Option<i64>>("height")?.map(|v| v.max(0) as u32),
        codec: row.get("codec")?,
        artist: row.get("artist")?,
        album: row.get("album")?,
        album_artist: row.get("album_artist")?,
        track_no: row.get::<_, Option<i64>>("track_no")?.map(|v| v.max(0) as u32),
        disc_no: row.get::<_, Option<i64>>("disc_no")?.map(|v| v.max(0) as u32),
        genre: row.get("genre")?,
        year: row.get::<_, Option<i64>>("year")?.map(|v| v.max(0) as u32),
        taken_at: row.get("taken_at")?,
        thumbnail_path: row.get("thumbnail_path")?,
        subtitles: parse_subtitles_json(subtitles_raw),
        metadata_state: row.get("metadata_state")?,
        added_at: row.get("added_at")?,
    })
}

impl DatabaseManager {
    // ------------------------------------------------------------------------
    // Folder management
    // ------------------------------------------------------------------------

    pub fn add_library_folder(
        &self,
        display_name: &str,
        path: &str,
        bookmark: Option<Vec<u8>>,
        include_subfolders: bool,
        kinds: &str,
    ) -> Result<LibraryFolderRecord, DbError> {
        let now = now_secs();
        self.with_conn(|conn| {
            // Check if folder with exact path already exists
            let existing: Option<i64> = conn
                .query_row(
                    "SELECT id FROM library_folders WHERE path = ?1",
                    params![path],
                    |r| r.get(0),
                )
                .ok();

            let id = if let Some(id) = existing {
                conn.execute(
                    "UPDATE library_folders
                     SET display_name = ?1, bookmark = ?2, include_subfolders = ?3, kinds = ?4, state = 'ok', updated_at = ?5
                     WHERE id = ?6",
                    params![display_name, bookmark, include_subfolders as i64, kinds, now, id],
                )?;
                id
            } else {
                conn.execute(
                    "INSERT INTO library_folders (display_name, path, bookmark, include_subfolders, kinds, state, item_count, last_scan_at, created_at, updated_at)
                     VALUES (?1, ?2, ?3, ?4, ?5, 'ok', 0, 0, ?6, ?6)",
                    params![display_name, path, bookmark, include_subfolders as i64, kinds, now],
                )?;
                conn.last_insert_rowid()
            };

            Ok(LibraryFolderRecord {
                id,
                display_name: display_name.to_string(),
                path: path.to_string(),
                bookmark,
                include_subfolders,
                kinds: kinds.to_string(),
                state: "ok".to_string(),
                item_count: 0,
                last_scan_at: 0,
            })
        })
    }

    pub fn remove_library_folder(&self, id: i64) -> Result<(), DbError> {
        self.with_conn(|conn| {
            conn.execute("DELETE FROM library_folders WHERE id = ?1", params![id])?;
            Ok(())
        })
    }

    pub fn update_library_folder_state(&self, id: i64, state: &str) -> Result<(), DbError> {
        let now = now_secs();
        self.with_conn(|conn| {
            conn.execute(
                "UPDATE library_folders SET state = ?1, updated_at = ?2 WHERE id = ?3",
                params![state, now, id],
            )?;
            Ok(())
        })
    }

    pub fn list_library_folders(&self) -> Result<Vec<LibraryFolderRecord>, DbError> {
        self.with_conn(|conn| {
            let mut stmt = conn.prepare(
                "SELECT id, display_name, path, bookmark, include_subfolders, kinds, state, item_count, last_scan_at
                 FROM library_folders ORDER BY display_name ASC",
            )?;
            let rows = stmt.query_map([], |r| {
                Ok(LibraryFolderRecord {
                    id: r.get(0)?,
                    display_name: r.get(1)?,
                    path: r.get(2)?,
                    bookmark: r.get(3)?,
                    include_subfolders: r.get::<_, i64>(4)? == 1,
                    kinds: r.get(5)?,
                    state: r.get(6)?,
                    item_count: r.get::<_, i64>(7)? as u32,
                    last_scan_at: r.get(8)?,
                })
            })?;

            let mut out = Vec::new();
            for r in rows {
                out.push(r?);
            }
            Ok(out)
        })
    }

    pub fn get_library_folder(&self, id: i64) -> Result<Option<LibraryFolderRecord>, DbError> {
        self.with_conn(|conn| {
            let mut stmt = conn.prepare(
                "SELECT id, display_name, path, bookmark, include_subfolders, kinds, state, item_count, last_scan_at
                 FROM library_folders WHERE id = ?1",
            )?;
            let mut rows = stmt.query(params![id])?;
            if let Some(r) = rows.next()? {
                Ok(Some(LibraryFolderRecord {
                    id: r.get(0)?,
                    display_name: r.get(1)?,
                    path: r.get(2)?,
                    bookmark: r.get(3)?,
                    include_subfolders: r.get::<_, i64>(4)? == 1,
                    kinds: r.get(5)?,
                    state: r.get(6)?,
                    item_count: r.get::<_, i64>(7)? as u32,
                    last_scan_at: r.get(8)?,
                }))
            } else {
                Ok(None)
            }
        })
    }

    // ------------------------------------------------------------------------
    // Items querying
    // ------------------------------------------------------------------------

    pub fn list_library_items(
        &self,
        kind: Option<String>,
        folder_id: Option<i64>,
        sort_by: Option<String>,
        sort_asc: bool,
        offset: u32,
        limit: u32,
    ) -> Result<Vec<LibraryItemRecord>, DbError> {
        self.with_conn(|conn| {
            let mut sql = String::from(
                "SELECT i.id, i.folder_id, i.rel_path, i.kind, i.size, i.mtime, i.fingerprint,
                        i.title, i.duration_ms, i.width, i.height, i.codec, i.artist, i.album,
                        i.album_artist, i.track_no, i.disc_no, i.genre, i.year, i.taken_at,
                        i.thumbnail_path, i.subtitles_json, i.metadata_state, i.added_at,
                        f.path AS folder_path
                 FROM library_items i
                 JOIN library_folders f ON f.id = i.folder_id
                 WHERE 1=1 ",
            );

            let mut params_vec: Vec<rusqlite::types::Value> = Vec::new();

            if let Some(ref k) = kind {
                params_vec.push(rusqlite::types::Value::Text(k.clone()));
                sql.push_str(&format!("AND i.kind = ?{} ", params_vec.len()));
            }

            if let Some(fid) = folder_id {
                params_vec.push(rusqlite::types::Value::Integer(fid));
                sql.push_str(&format!("AND i.folder_id = ?{} ", params_vec.len()));
            }

            let order_col = match sort_by.as_deref() {
                Some("title") => "COALESCE(i.title, i.rel_path)",
                Some("date") | Some("mtime") => "i.mtime",
                Some("added") => "i.added_at",
                Some("duration") => "i.duration_ms",
                Some("size") => "i.size",
                Some("track") => "i.disc_no, i.track_no",
                _ => "COALESCE(i.title, i.rel_path)",
            };
            let dir = if sort_asc { "ASC" } else { "DESC" };
            sql.push_str(&format!("ORDER BY {order_col} {dir} "));

            params_vec.push(rusqlite::types::Value::Integer(limit as i64));
            sql.push_str(&format!("LIMIT ?{} ", params_vec.len()));

            params_vec.push(rusqlite::types::Value::Integer(offset as i64));
            sql.push_str(&format!("OFFSET ?{} ", params_vec.len()));

            let mut stmt = conn.prepare(&sql)?;
            let param_refs: Vec<&dyn rusqlite::ToSql> = params_vec.iter().map(|p| p as &dyn rusqlite::ToSql).collect();

            let rows = stmt.query_map(param_refs.as_slice(), |r| {
                let folder_path: String = r.get("folder_path")?;
                row_to_item(r, &folder_path)
            })?;

            let mut out = Vec::new();
            for r in rows {
                out.push(r?);
            }
            Ok(out)
        })
    }

    pub fn get_library_item(&self, id: i64) -> Result<Option<LibraryItemRecord>, DbError> {
        self.with_conn(|conn| {
            let mut stmt = conn.prepare(
                "SELECT i.id, i.folder_id, i.rel_path, i.kind, i.size, i.mtime, i.fingerprint,
                        i.title, i.duration_ms, i.width, i.height, i.codec, i.artist, i.album,
                        i.album_artist, i.track_no, i.disc_no, i.genre, i.year, i.taken_at,
                        i.thumbnail_path, i.subtitles_json, i.metadata_state, i.added_at,
                        f.path AS folder_path
                 FROM library_items i
                 JOIN library_folders f ON f.id = i.folder_id
                 WHERE i.id = ?1",
            )?;
            let mut rows = stmt.query(params![id])?;
            if let Some(r) = rows.next()? {
                let folder_path: String = r.get("folder_path")?;
                Ok(Some(row_to_item(r, &folder_path)?))
            } else {
                Ok(None)
            }
        })
    }

    pub fn search_library(&self, query: &str, kind: Option<String>, limit: u32) -> Result<Vec<LibraryItemRecord>, DbError> {
        let trimmed = query.trim();
        if trimmed.is_empty() {
            return Ok(Vec::new());
        }

        self.with_conn(|conn| {
            let clean_q: String = trimmed
                .chars()
                .filter(|c| c.is_alphanumeric() || c.is_whitespace())
                .collect();
            let mut fts_query = clean_q
                .split_whitespace()
                .map(|token| format!("{token}*"))
                .collect::<Vec<_>>()
                .join(" ");

            if fts_query.is_empty() {
                fts_query = format!("{trimmed}*");
            }

            let (sql, params_vec): (String, Vec<rusqlite::types::Value>) = if let Some(ref k) = kind {
                (
                    "SELECT i.id, i.folder_id, i.rel_path, i.kind, i.size, i.mtime, i.fingerprint,
                            i.title, i.duration_ms, i.width, i.height, i.codec, i.artist, i.album,
                            i.album_artist, i.track_no, i.disc_no, i.genre, i.year, i.taken_at,
                            i.thumbnail_path, i.subtitles_json, i.metadata_state, i.added_at,
                            f.path AS folder_path
                     FROM library_items_fts fts
                     JOIN library_items i ON i.id = fts.rowid
                     JOIN library_folders f ON f.id = i.folder_id
                     WHERE library_items_fts MATCH ?1 AND i.kind = ?2
                     ORDER BY rank
                     LIMIT ?3"
                        .to_string(),
                    vec![
                        rusqlite::types::Value::Text(fts_query),
                        rusqlite::types::Value::Text(k.clone()),
                        rusqlite::types::Value::Integer(limit as i64),
                    ],
                )
            } else {
                (
                    "SELECT i.id, i.folder_id, i.rel_path, i.kind, i.size, i.mtime, i.fingerprint,
                            i.title, i.duration_ms, i.width, i.height, i.codec, i.artist, i.album,
                            i.album_artist, i.track_no, i.disc_no, i.genre, i.year, i.taken_at,
                            i.thumbnail_path, i.subtitles_json, i.metadata_state, i.added_at,
                            f.path AS folder_path
                     FROM library_items_fts fts
                     JOIN library_items i ON i.id = fts.rowid
                     JOIN library_folders f ON f.id = i.folder_id
                     WHERE library_items_fts MATCH ?1
                     ORDER BY rank
                     LIMIT ?2"
                        .to_string(),
                    vec![
                        rusqlite::types::Value::Text(fts_query),
                        rusqlite::types::Value::Integer(limit as i64),
                    ],
                )
            };

            let mut stmt = conn.prepare(&sql)?;
            let param_refs: Vec<&dyn rusqlite::ToSql> = params_vec.iter().map(|p| p as &dyn rusqlite::ToSql).collect();

            let rows = stmt.query_map(param_refs.as_slice(), |r| {
                let folder_path: String = r.get("folder_path")?;
                row_to_item(r, &folder_path)
            })?;

            let mut out = Vec::new();
            for r in rows {
                out.push(r?);
            }
            Ok(out)
        })
    }

    // ------------------------------------------------------------------------
    // Music / Audio Views: Albums, Artists, Genres
    // ------------------------------------------------------------------------

    pub fn get_library_albums(&self, limit: u32, offset: u32) -> Result<Vec<LibraryAlbumRecord>, DbError> {
        self.with_conn(|conn| {
            let mut stmt = conn.prepare(
                "SELECT COALESCE(album, 'Album inconnu') AS album_name,
                        COALESCE(album_artist, artist, 'Artiste inconnu') AS artist_name,
                        MAX(year) AS rel_year,
                        COUNT(id) AS track_count,
                        MAX(thumbnail_path) AS cover
                 FROM library_items
                 WHERE kind = 'audio' AND album IS NOT NULL AND TRIM(album) != ''
                 GROUP BY album_name, artist_name
                 ORDER BY album_name ASC
                 LIMIT ?1 OFFSET ?2",
            )?;

            let rows = stmt.query_map(params![limit, offset], |r| {
                Ok(LibraryAlbumRecord {
                    name: r.get(0)?,
                    artist: r.get(1)?,
                    year: r.get::<_, Option<i64>>(2)?.map(|v| v.max(0) as u32),
                    track_count: r.get::<_, i64>(3)? as u32,
                    thumbnail_path: r.get(4)?,
                })
            })?;

            let mut out = Vec::new();
            for r in rows {
                out.push(r?);
            }
            Ok(out)
        })
    }

    pub fn get_library_artists(&self, limit: u32, offset: u32) -> Result<Vec<LibraryArtistRecord>, DbError> {
        self.with_conn(|conn| {
            let mut stmt = conn.prepare(
                "SELECT COALESCE(artist, album_artist, 'Artiste inconnu') AS artist_name,
                        COUNT(DISTINCT album) AS album_cnt,
                        COUNT(id) AS track_cnt
                 FROM library_items
                 WHERE kind = 'audio' AND (artist IS NOT NULL OR album_artist IS NOT NULL)
                 GROUP BY artist_name
                 ORDER BY artist_name ASC
                 LIMIT ?1 OFFSET ?2",
            )?;

            let rows = stmt.query_map(params![limit, offset], |r| {
                Ok(LibraryArtistRecord {
                    name: r.get(0)?,
                    album_count: r.get::<_, i64>(1)? as u32,
                    track_count: r.get::<_, i64>(2)? as u32,
                })
            })?;

            let mut out = Vec::new();
            for r in rows {
                out.push(r?);
            }
            Ok(out)
        })
    }

    pub fn get_library_genres(&self) -> Result<Vec<LibraryGenreRecord>, DbError> {
        self.with_conn(|conn| {
            let mut stmt = conn.prepare(
                "SELECT genre, COUNT(id) AS track_cnt
                 FROM library_items
                 WHERE kind = 'audio' AND genre IS NOT NULL AND TRIM(genre) != ''
                 GROUP BY genre
                 ORDER BY track_cnt DESC",
            )?;

            let rows = stmt.query_map([], |r| {
                Ok(LibraryGenreRecord {
                    name: r.get(0)?,
                    track_count: r.get::<_, i64>(1)? as u32,
                })
            })?;

            let mut out = Vec::new();
            for r in rows {
                out.push(r?);
            }
            Ok(out)
        })
    }

    // ------------------------------------------------------------------------
    // Directory Browser
    // ------------------------------------------------------------------------

    pub fn browse_library_dir(
        &self,
        folder_id: i64,
        rel_dir: &str,
    ) -> Result<Vec<LibraryBrowseEntry>, DbError> {
        self.with_conn(|conn| {
            let normalized_dir = rel_dir.trim_matches('/');
            let prefix = if normalized_dir.is_empty() {
                String::new()
            } else {
                format!("{normalized_dir}/")
            };

            let mut stmt = conn.prepare(
                "SELECT id, rel_path, kind, size, duration_ms, thumbnail_path
                 FROM library_items
                 WHERE folder_id = ?1 AND rel_path LIKE ?2",
            )?;

            let like_pattern = format!("{prefix}%");
            let mut subdirs = std::collections::BTreeSet::new();
            let mut files = Vec::new();

            let mut rows = stmt.query(params![folder_id, like_pattern])?;
            while let Some(r) = rows.next()? {
                let rel_path: String = r.get(1)?;
                let rest = &rel_path[prefix.len()..];

                if let Some(slash_idx) = rest.find('/') {
                    let subdir_name = &rest[..slash_idx];
                    let sub_rel = if prefix.is_empty() {
                        subdir_name.to_string()
                    } else {
                        format!("{prefix}{subdir_name}")
                    };
                    subdirs.insert((subdir_name.to_string(), sub_rel));
                } else {
                    let file_name = rest.to_string();
                    let item_id: i64 = r.get(0)?;
                    let kind: String = r.get(2)?;
                    let size: i64 = r.get(3)?;
                    let duration: Option<i64> = r.get(4)?;
                    let thumbnail: Option<String> = r.get(5)?;

                    files.push(LibraryBrowseEntry {
                        name: file_name,
                        rel_path,
                        is_directory: false,
                        kind: Some(kind),
                        item_id: Some(item_id),
                        size: Some(size as u64),
                        duration_ms: duration.map(|d| d.max(0) as u32),
                        thumbnail_path: thumbnail,
                    });
                }
            }

            let mut out = Vec::new();
            for (name, rel) in subdirs {
                out.push(LibraryBrowseEntry {
                    name,
                    rel_path: rel,
                    is_directory: true,
                    kind: None,
                    item_id: None,
                    size: None,
                    duration_ms: None,
                    thumbnail_path: None,
                });
            }
            out.extend(files);
            Ok(out)
        })
    }

    // ------------------------------------------------------------------------
    // Metadata Pipeline
    // ------------------------------------------------------------------------

    pub fn get_pending_metadata(&self, limit: u32) -> Result<Vec<LibraryItemRecord>, DbError> {
        self.with_conn(|conn| {
            let mut stmt = conn.prepare(
                "SELECT i.id, i.folder_id, i.rel_path, i.kind, i.size, i.mtime, i.fingerprint,
                        i.title, i.duration_ms, i.width, i.height, i.codec, i.artist, i.album,
                        i.album_artist, i.track_no, i.disc_no, i.genre, i.year, i.taken_at,
                        i.thumbnail_path, i.subtitles_json, i.metadata_state, i.added_at,
                        f.path AS folder_path
                 FROM library_items i
                 JOIN library_folders f ON f.id = i.folder_id
                 WHERE i.metadata_state = 'pending'
                 ORDER BY i.id ASC
                 LIMIT ?1",
            )?;

            let rows = stmt.query_map(params![limit], |r| {
                let folder_path: String = r.get("folder_path")?;
                row_to_item(r, &folder_path)
            })?;

            let mut out = Vec::new();
            for r in rows {
                out.push(r?);
            }
            Ok(out)
        })
    }

    pub fn update_item_metadata(&self, item_id: i64, meta: &LibraryItemMetadataInput) -> Result<(), DbError> {
        let now = now_secs();
        self.with_conn(|conn| {
            conn.execute(
                "UPDATE library_items
                 SET title = COALESCE(?1, title),
                     duration_ms = COALESCE(?2, duration_ms),
                     width = COALESCE(?3, width),
                     height = COALESCE(?4, height),
                     codec = COALESCE(?5, codec),
                     artist = COALESCE(?6, artist),
                     album = COALESCE(?7, album),
                     album_artist = COALESCE(?8, album_artist),
                     track_no = COALESCE(?9, track_no),
                     disc_no = COALESCE(?10, disc_no),
                     genre = COALESCE(?11, genre),
                     year = COALESCE(?12, year),
                     taken_at = COALESCE(?13, taken_at),
                     thumbnail_path = COALESCE(?14, thumbnail_path),
                     metadata_state = 'done',
                     updated_at = ?15
                 WHERE id = ?16",
                params![
                    meta.title,
                    meta.duration_ms.map(|d| d as i64),
                    meta.width.map(|w| w as i64),
                    meta.height.map(|h| h as i64),
                    meta.codec,
                    meta.artist,
                    meta.album,
                    meta.album_artist,
                    meta.track_no.map(|t| t as i64),
                    meta.disc_no.map(|d| d as i64),
                    meta.genre,
                    meta.year.map(|y| y as i64),
                    meta.taken_at,
                    meta.thumbnail_path,
                    now,
                    item_id,
                ],
            )?;
            Ok(())
        })
    }

    // ------------------------------------------------------------------------
    // Progress & Recent Items
    // ------------------------------------------------------------------------

    pub fn record_library_progress(
        &self,
        profile_id: i64,
        fingerprint: &str,
        position_ms: i64,
        duration_ms: i64,
    ) -> Result<(), DbError> {
        let now = now_secs();
        let completed = if duration_ms > 0 && position_ms >= (duration_ms * 9) / 10 {
            1
        } else {
            0
        };

        self.with_conn(|conn| {
            conn.execute(
                "INSERT INTO library_progress (profile_id, fingerprint, position_ms, duration_ms, completed, last_played_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                 ON CONFLICT(profile_id, fingerprint) DO UPDATE SET
                     position_ms = excluded.position_ms,
                     duration_ms = excluded.duration_ms,
                     completed = excluded.completed,
                     last_played_at = excluded.last_played_at",
                params![profile_id, fingerprint, position_ms, duration_ms, completed, now],
            )?;
            Ok(())
        })
    }

    pub fn get_library_progress(
        &self,
        profile_id: i64,
        fingerprint: &str,
    ) -> Result<Option<LibraryProgressRecord>, DbError> {
        self.with_conn(|conn| {
            let mut stmt = conn.prepare(
                "SELECT fingerprint, position_ms, duration_ms, completed, last_played_at
                 FROM library_progress
                 WHERE profile_id = ?1 AND fingerprint = ?2",
            )?;
            let mut rows = stmt.query(params![profile_id, fingerprint])?;
            if let Some(r) = rows.next()? {
                Ok(Some(LibraryProgressRecord {
                    fingerprint: r.get(0)?,
                    position_ms: r.get(1)?,
                    duration_ms: r.get(2)?,
                    completed: r.get::<_, i64>(3)? == 1,
                    last_played_at: r.get(4)?,
                }))
            } else {
                Ok(None)
            }
        })
    }

    pub fn list_recent_library_items(
        &self,
        kind: Option<String>,
        profile_id: i64,
        limit: u32,
    ) -> Result<Vec<LibraryItemRecord>, DbError> {
        self.with_conn(|conn| {
            let sql = if kind.is_some() {
                "SELECT i.id, i.folder_id, i.rel_path, i.kind, i.size, i.mtime, i.fingerprint,
                        i.title, i.duration_ms, i.width, i.height, i.codec, i.artist, i.album,
                        i.album_artist, i.track_no, i.disc_no, i.genre, i.year, i.taken_at,
                        i.thumbnail_path, i.subtitles_json, i.metadata_state, i.added_at,
                        f.path AS folder_path
                 FROM library_progress p
                 JOIN library_items i ON i.fingerprint = p.fingerprint
                 JOIN library_folders f ON f.id = i.folder_id
                 WHERE p.profile_id = ?1 AND i.kind = ?2 AND p.completed = 0 AND p.position_ms > 0
                 ORDER BY p.last_played_at DESC
                 LIMIT ?3"
            } else {
                "SELECT i.id, i.folder_id, i.rel_path, i.kind, i.size, i.mtime, i.fingerprint,
                        i.title, i.duration_ms, i.width, i.height, i.codec, i.artist, i.album,
                        i.album_artist, i.track_no, i.disc_no, i.genre, i.year, i.taken_at,
                        i.thumbnail_path, i.subtitles_json, i.metadata_state, i.added_at,
                        f.path AS folder_path
                 FROM library_progress p
                 JOIN library_items i ON i.fingerprint = p.fingerprint
                 JOIN library_folders f ON f.id = i.folder_id
                 WHERE p.profile_id = ?1 AND p.completed = 0 AND p.position_ms > 0
                 ORDER BY p.last_played_at DESC
                 LIMIT ?2"
            };

            let mut stmt = conn.prepare(sql)?;
            let mut out = Vec::new();

            if let Some(ref k) = kind {
                let rows = stmt.query_map(params![profile_id, k, limit], |r| {
                    let folder_path: String = r.get("folder_path")?;
                    row_to_item(r, &folder_path)
                })?;
                for r in rows {
                    out.push(r?);
                }
            } else {
                let rows = stmt.query_map(params![profile_id, limit], |r| {
                    let folder_path: String = r.get("folder_path")?;
                    row_to_item(r, &folder_path)
                })?;
                for r in rows {
                    out.push(r?);
                }
            }

            Ok(out)
        })
    }

    pub fn list_recently_added_library_items(
        &self,
        kind: Option<String>,
        limit: u32,
    ) -> Result<Vec<LibraryItemRecord>, DbError> {
        self.list_library_items(kind, None, Some("added".to_string()), false, 0, limit)
    }
}
