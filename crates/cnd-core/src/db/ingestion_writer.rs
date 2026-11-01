use crate::db::{chrono_now_ts, DatabaseManager, DbError, IptvSourceRecord};
use crate::iptv::m3u_parser::{M3uHeaderInfo, ParsedM3uItem};
use crate::iptv::normalizer::ItemKind;
use rusqlite::{params, OptionalExtension};
use std::collections::{HashMap, HashSet};

#[derive(Debug, Clone, uniffi::Record)]
pub struct SyncSummary {
    pub source_id: i64,
    pub total_items: u32,
    pub live_count: u32,
    pub movie_count: u32,
    pub series_count: u32,
    pub episode_count: u32,
    pub duration_ms: u64,
}

pub struct SourceIngestionSession {
    source_id: i64,
    source_uuid: String,
    purged_existing: bool,
    series_cache: HashMap<String, i64>,
    seen_hashes: HashSet<String>,
    pub total_items: u32,
    pub live_count: u32,
    pub movie_count: u32,
    pub episode_count: u32,
}

impl SourceIngestionSession {
    pub fn new(source_id: i64, source_uuid: &str) -> Self {
        Self {
            source_id,
            source_uuid: source_uuid.to_string(),
            purged_existing: false,
            series_cache: HashMap::new(),
            seen_hashes: HashSet::new(),
            total_items: 0,
            live_count: 0,
            movie_count: 0,
            episode_count: 0,
        }
    }
}

pub fn make_series_stable_hash(source_uuid: &str, canonical_key: &str) -> String {
    format!(
        "series:{}",
        blake3::hash(format!("{source_uuid}:{canonical_key}").as_bytes()).to_hex()
    )
}

impl DatabaseManager {
    pub fn get_source_by_id(&self, source_id: i64) -> Result<IptvSourceRecord, DbError> {
        self.with_conn(|conn| {
            conn.query_row(
                "SELECT id, uuid, name, source_type, url, server, username, password_ref, epg_url,
                        exp_date, max_connections, active_cons, account_status, item_count, updated_at
                 FROM iptv_sources WHERE id = ?1",
                params![source_id],
                |r| {
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
                },
            )
            .optional()?
            .ok_or_else(|| DbError::NotFound(format!("Source id={source_id} not found")))
        })
    }

    pub fn update_xtream_source(
        &self,
        source_id: i64,
        name: &str,
        server: &str,
        username: &str,
        password_ref: Option<&str>,
        epg_url: Option<&str>,
    ) -> Result<(), DbError> {
        self.with_conn(|conn| {
            let now = chrono_now_ts();
            let affected = conn.execute(
                "UPDATE iptv_sources
                 SET name = ?1, server = ?2, username = ?3,
                     password_ref = COALESCE(?4, password_ref),
                     epg_url = ?5, updated_at = ?6
                 WHERE id = ?7",
                params![name, server, username, password_ref, epg_url, now, source_id],
            )?;
            if affected == 0 {
                return Err(DbError::NotFound(format!("Source id={source_id} not found")));
            }
            Ok(())
        })
    }

    pub fn update_source(
        &self,
        source_id: i64,
        name: &str,
        url: Option<&str>,
        epg_url: Option<&str>,
    ) -> Result<(), DbError> {
        self.with_conn(|conn| {
            let now = chrono_now_ts();
            let affected = conn.execute(
                "UPDATE iptv_sources
                 SET name = ?1, url = ?2, epg_url = ?3, updated_at = ?4
                 WHERE id = ?5",
                params![name, url, epg_url, now, source_id],
            )?;
            if affected == 0 {
                return Err(DbError::NotFound(format!("Source id={source_id} not found")));
            }
            Ok(())
        })
    }

    pub fn delete_source(&self, source_id: i64) -> Result<(), DbError> {
        self.with_conn(|conn| {
            let affected = conn.execute("DELETE FROM iptv_sources WHERE id = ?1", params![source_id])?;
            if affected == 0 {
                return Err(DbError::NotFound(format!("Source id={source_id} not found")));
            }
            Ok(())
        })
    }

    pub fn write_m3u_batch(
        &self,
        session: &mut SourceIngestionSession,
        batch: &[ParsedM3uItem],
    ) -> Result<(), DbError> {
        if batch.is_empty() {
            return Ok(());
        }

        self.with_conn_mut(|conn| {
            let tx = conn.transaction()?;
            let now = chrono_now_ts();

            if !session.purged_existing {
                tx.execute(
                    "DELETE FROM iptv_items WHERE source_id = ?1",
                    params![session.source_id],
                )?;
                tx.execute(
                    "DELETE FROM series_catalog WHERE source_id = ?1",
                    params![session.source_id],
                )?;
                session.purged_existing = true;
            }

            {
                let mut insert_series_stmt = tx.prepare_cached(
                    "INSERT INTO series_catalog (
                        source_id, canonical_key, stable_hash, title, group_title, poster_url,
                        imdb_id, imdb_rating, plot, episode_count, season_count, updated_at
                    ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, 0, 0, ?10)
                    ON CONFLICT(source_id, canonical_key) DO UPDATE SET
                        stable_hash = excluded.stable_hash,
                        poster_url = COALESCE(series_catalog.poster_url, excluded.poster_url),
                        imdb_id = COALESCE(series_catalog.imdb_id, excluded.imdb_id),
                        imdb_rating = COALESCE(series_catalog.imdb_rating, excluded.imdb_rating),
                        plot = COALESCE(series_catalog.plot, excluded.plot),
                        updated_at = excluded.updated_at",
                )?;

                let mut lookup_series_stmt = tx.prepare_cached(
                    "SELECT id FROM series_catalog WHERE source_id = ?1 AND canonical_key = ?2",
                )?;

                let mut insert_item_stmt = tx.prepare_cached(
                    "INSERT INTO iptv_items (
                        source_id, series_id, stable_hash, kind, season_num, episode_num,
                        name, name_clean, year, group_title, tvg_id, tvg_name, logo_url, chno,
                        country, language, catchup_type, catchup_source, catchup_days, epg_shift,
                        user_agent, referer, headers_json, host, container_ext, stream_url,
                        imdb_id, imdb_rating, plot, created_at, updated_at
                    ) VALUES (
                        ?1, ?2, ?3, ?4, ?5, ?6,
                        ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14,
                        ?15, ?16, ?17, ?18, ?19, ?20,
                        ?21, ?22, ?23, ?24, ?25, ?26,
                        ?27, ?28, ?29, ?30, ?30
                    )
                    ON CONFLICT(stable_hash) DO UPDATE SET
                        source_id = excluded.source_id,
                        series_id = excluded.series_id,
                        kind = excluded.kind,
                        season_num = excluded.season_num,
                        episode_num = excluded.episode_num,
                        name = excluded.name,
                        name_clean = excluded.name_clean,
                        year = excluded.year,
                        group_title = excluded.group_title,
                        tvg_id = excluded.tvg_id,
                        tvg_name = excluded.tvg_name,
                        logo_url = excluded.logo_url,
                        chno = excluded.chno,
                        country = excluded.country,
                        language = excluded.language,
                        catchup_type = excluded.catchup_type,
                        catchup_source = excluded.catchup_source,
                        catchup_days = excluded.catchup_days,
                        epg_shift = excluded.epg_shift,
                        user_agent = excluded.user_agent,
                        referer = excluded.referer,
                        headers_json = excluded.headers_json,
                        host = excluded.host,
                        container_ext = excluded.container_ext,
                        stream_url = excluded.stream_url,
                        imdb_id = COALESCE(excluded.imdb_id, iptv_items.imdb_id),
                        imdb_rating = COALESCE(excluded.imdb_rating, iptv_items.imdb_rating),
                        plot = COALESCE(excluded.plot, iptv_items.plot),
                        updated_at = excluded.updated_at",
                )?;

                for item in batch {
                    let is_new_hash = session.seen_hashes.insert(item.stable_hash.clone());

                    let (series_id, season_num, episode_num) =
                        if let Some(ref s_info) = item.series_info {
                            let sid = if let Some(&cached_id) =
                                session.series_cache.get(&s_info.canonical_key)
                            {
                                cached_id
                            } else {
                                let s_hash = make_series_stable_hash(
                                    &session.source_uuid,
                                    &s_info.canonical_key,
                                );
                                insert_series_stmt.execute(params![
                                    session.source_id,
                                    s_info.canonical_key,
                                    s_hash,
                                    s_info.series_title,
                                    item.group_title,
                                    item.logo_url,
                                    item.imdb_id,
                                    item.imdb_rating,
                                    item.plot,
                                    now
                                ])?;
                                let resolved_id: i64 = lookup_series_stmt.query_row(
                                    params![session.source_id, s_info.canonical_key],
                                    |r| r.get(0),
                                )?;
                                session
                                    .series_cache
                                    .insert(s_info.canonical_key.clone(), resolved_id);
                                resolved_id
                            };
                            (Some(sid), Some(s_info.season_num), Some(s_info.episode_num))
                        } else {
                            (None, None, None)
                        };

                    insert_item_stmt.execute(params![
                        session.source_id,
                        series_id,
                        item.stable_hash,
                        item.kind.as_str(),
                        season_num,
                        episode_num,
                        item.name,
                        item.name_clean,
                        item.year,
                        item.group_title,
                        item.tvg_id,
                        item.tvg_name,
                        item.logo_url,
                        item.chno,
                        item.country,
                        item.language,
                        item.catchup_type,
                        item.catchup_source,
                        item.catchup_days,
                        item.epg_shift,
                        item.user_agent,
                        item.referer,
                        item.headers_json,
                        item.host,
                        item.container_ext,
                        item.stream_url,
                        item.imdb_id,
                        item.imdb_rating,
                        item.plot,
                        now
                    ])?;

                    if is_new_hash {
                        session.total_items += 1;
                        match item.kind {
                            ItemKind::Live => session.live_count += 1,
                            ItemKind::Movie => session.movie_count += 1,
                            ItemKind::Episode => session.episode_count += 1,
                        }
                    }
                }
            }

            tx.commit()?;
            Ok(())
        })
    }

    pub fn finalize_m3u_ingestion(
        &self,
        session: &mut SourceIngestionSession,
        header: &M3uHeaderInfo,
        duration_ms: u64,
    ) -> Result<SyncSummary, DbError> {
        self.with_conn_mut(|conn| {
            let tx = conn.transaction()?;
            let now = chrono_now_ts();

            if !session.purged_existing {
                tx.execute(
                    "DELETE FROM iptv_items WHERE source_id = ?1",
                    params![session.source_id],
                )?;
                tx.execute(
                    "DELETE FROM series_catalog WHERE source_id = ?1",
                    params![session.source_id],
                )?;
                session.purged_existing = true;
            }

            tx.execute(
                "UPDATE series_catalog SET
                    episode_count = (SELECT COUNT(*) FROM iptv_items WHERE series_id = series_catalog.id),
                    season_count = (SELECT COUNT(DISTINCT COALESCE(season_num, 1)) FROM iptv_items WHERE series_id = series_catalog.id)
                 WHERE source_id = ?1",
                params![session.source_id],
            )?;

            let series_count: u32 = tx
                .query_row(
                    "SELECT COUNT(*) FROM series_catalog WHERE source_id = ?1",
                    params![session.source_id],
                    |r| r.get(0),
                )
                .unwrap_or(0);

            if let Some(ref discovered_epg) = header.epg_url {
                tx.execute(
                    "UPDATE iptv_sources
                     SET item_count = ?1,
                         last_sync_at = ?2,
                         updated_at = ?2,
                         epg_url = CASE
                             WHEN epg_url IS NULL OR TRIM(epg_url) = '' THEN ?3
                             ELSE epg_url
                         END
                     WHERE id = ?4",
                    params![session.total_items, now, discovered_epg, session.source_id],
                )?;
            } else {
                tx.execute(
                    "UPDATE iptv_sources
                     SET item_count = ?1, last_sync_at = ?2, updated_at = ?2
                     WHERE id = ?3",
                    params![session.total_items, now, session.source_id],
                )?;
            }

            tx.commit()?;

            Ok(SyncSummary {
                source_id: session.source_id,
                total_items: session.total_items,
                live_count: session.live_count,
                movie_count: session.movie_count,
                series_count,
                episode_count: session.episode_count,
                duration_ms,
            })
        })
    }
}

