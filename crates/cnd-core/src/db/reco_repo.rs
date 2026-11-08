//! Queries of the per-kind recommendations (PRD 34). Every query takes ONE kind and applies the
//! active profile's rules (hidden items and groups, adult categories, kids allow-list, broken streams).

use crate::db::catalog_repo::{map_item_row, map_series_row, SeriesRecord, ITEM_SELECT_COLUMNS};
use crate::db::epg_repo::EpgProgramRecord;
use crate::db::recommend_repo::CachedItemMetadata;
use crate::db::search_repo::{ITEM_JOINS, SERIES_SELECT, VISIBLE_ITEM, VISIBLE_SERIES};
use crate::db::{chrono_now_ts, DatabaseManager, DbError, IptvItemRecord};
use rusqlite::{params, OptionalExtension};
use std::collections::{HashMap, HashSet};

/// One row of the active profile's watch history.
#[derive(Debug, Clone)]
pub struct WatchedEntry {
    pub item: IptvItemRecord,
    pub last_watched_at: i64,
    pub position_ms: i64,
    pub duration_ms: i64,
    pub completed: bool,
}

/// The cached OMDb metadata, indexed once per call so a pool of hundreds is scored without a query each.
#[derive(Debug, Default)]
pub struct MetadataIndex {
    by_imdb: HashMap<String, CachedItemMetadata>,
    by_key: HashMap<String, CachedItemMetadata>,
}

impl MetadataIndex {
    /// The metadata of an item: by imdb id, then by `kind:title:year`, then by `kind:title`.
    pub fn for_item(&self, item: &IptvItemRecord) -> Option<&CachedItemMetadata> {
        self.lookup(item.imdb_id.as_deref(), &item.kind, &item.name_clean, item.year)
    }

    /// The metadata of a series (cached under the `series` media type).
    pub fn for_series(&self, series: &SeriesRecord) -> Option<&CachedItemMetadata> {
        self.lookup(series.imdb_id.as_deref(), "series", &series.title, None)
    }

    fn lookup(&self, imdb: Option<&str>, kind: &str, title: &str, year: Option<u32>) -> Option<&CachedItemMetadata> {
        if let Some(id) = imdb.map(str::trim).filter(|v| !v.is_empty()) {
            if let Some(found) = self.by_imdb.get(&id.to_lowercase()) {
                return Some(found);
            }
        }
        let title = title.trim().to_lowercase();
        if let Some(y) = year {
            if let Some(found) = self.by_key.get(&format!("{kind}:{title}:{y}")) {
                return Some(found);
            }
        }
        self.by_key.get(&format!("{kind}:{title}"))
    }
}

/// Ends of the EPG: whether anything is on the air now.
#[derive(Debug, Clone, Copy)]
pub struct EpgFreshness {
    pub on_air_now: u32,
    pub last_end_ts: Option<i64>,
}

impl DatabaseManager {
    // MARK: - History

    /// The most recently watched items of a kind (`movie`, `episode` or `live`) for the active profile.
    pub fn watched_entries(&self, kind: &str, limit: u32) -> Result<Vec<WatchedEntry>, DbError> {
        self.with_conn(|conn| {
            let sql = format!(
                "SELECT {ITEM_SELECT_COLUMNS}, wh.last_watched_at
                 FROM watch_history wh
                 INNER JOIN iptv_items i ON i.stable_hash = wh.stable_hash
                 LEFT JOIN favorites f ON f.profile_id = (SELECT id FROM temp.active_profile) AND f.stable_hash = i.stable_hash
                 LEFT JOIN broken_flags bf ON bf.stable_hash = i.stable_hash
                 WHERE wh.profile_id = (SELECT id FROM temp.active_profile) AND i.kind = ?1
                 ORDER BY wh.last_watched_at DESC, i.id DESC
                 LIMIT ?2"
            );
            let mut stmt = conn.prepare(&sql)?;
            let rows = stmt.query_map(params![kind, limit], |r| {
                let item = map_item_row(r)?;
                let last: i64 = r.get(r.as_ref().column_count() - 1)?;
                Ok(WatchedEntry {
                    last_watched_at: last,
                    position_ms: item.resume_position_ms,
                    duration_ms: item.duration_ms,
                    completed: item.is_completed,
                    item,
                })
            })?;
            let mut out = Vec::new();
            for row in rows {
                out.push(row?);
            }
            Ok(out)
        })
    }

    /// Stable hashes of the profile's favorites.
    pub fn favorite_hashes(&self) -> Result<HashSet<String>, DbError> {
        self.with_conn(|conn| {
            let mut stmt = conn.prepare(
                "SELECT stable_hash FROM favorites WHERE profile_id = (SELECT id FROM temp.active_profile)",
            )?;
            let rows = stmt.query_map([], |r| r.get::<_, String>(0))?;
            let mut out = HashSet::new();
            for row in rows {
                out.insert(row?);
            }
            Ok(out)
        })
    }

    // MARK: - Pools of candidates (one kind each)

    /// Visible items of one kind: the best rated, then the most recently added. Both lists are bounded.
    pub fn reco_item_pool(&self, kind: &str, top_rated: u32, newest: u32) -> Result<Vec<IptvItemRecord>, DbError> {
        let mut out: Vec<IptvItemRecord> = self.with_conn(|conn| {
            let sql = format!(
                "SELECT {ITEM_SELECT_COLUMNS} {ITEM_JOINS} WHERE i.kind = ?1 AND {VISIBLE_ITEM}
                 ORDER BY i.imdb_rating DESC, i.id DESC LIMIT ?2"
            );
            let mut stmt = conn.prepare(&sql)?;
            let rows = stmt.query_map(params![kind, top_rated], map_item_row)?;
            let mut items = Vec::new();
            for row in rows {
                items.push(row?);
            }
            Ok(items)
        })?;
        // The newest are the highest ids: a backward scan of the table stops after a few hundred rows
        // (an index on `created_at` would confuse the planner of other queries), then the profile's
        // rules are applied to those rows only.
        let ids: Vec<i64> = self.with_conn(|conn| {
            let mut stmt = conn.prepare(
                "SELECT i.id FROM iptv_items i NOT INDEXED WHERE i.kind = ?1 ORDER BY i.id DESC LIMIT ?2",
            )?;
            let rows = stmt.query_map(params![kind, newest.saturating_mul(3)], |r| r.get::<_, i64>(0))?;
            let mut ids = Vec::new();
            for row in rows {
                ids.push(row?);
            }
            Ok(ids)
        })?;
        let mut seen: HashSet<i64> = out.iter().map(|i| i.id).collect();
        for item in self.visible_items_by_ids(&ids)?.into_iter().take(newest as usize) {
            if seen.insert(item.id) {
                out.push(item);
            }
        }
        Ok(out)
    }

    /// Visible items of one kind in the given categories (`group_title`), best rated first.
    pub fn reco_items_in_groups(&self, kind: &str, groups: &[String], limit: u32) -> Result<Vec<IptvItemRecord>, DbError> {
        if groups.is_empty() {
            return Ok(Vec::new());
        }
        self.with_conn(|conn| {
            let marks = vec!["?"; groups.len()].join(",");
            let sql = format!(
                "SELECT {ITEM_SELECT_COLUMNS} {ITEM_JOINS}
                 WHERE i.kind = ? AND i.group_title IN ({marks}) AND {VISIBLE_ITEM}
                 ORDER BY i.imdb_rating DESC, i.id DESC LIMIT ?"
            );
            let mut values: Vec<rusqlite::types::Value> = vec![kind.to_string().into()];
            values.extend(groups.iter().map(|g| rusqlite::types::Value::from(g.clone())));
            values.push((limit as i64).into());
            let mut stmt = conn.prepare(&sql)?;
            let rows = stmt.query_map(rusqlite::params_from_iter(values.iter()), map_item_row)?;
            let mut out = Vec::new();
            for row in rows {
                out.push(row?);
            }
            Ok(out)
        })
    }

    /// Visible series: the best rated, then the most recently updated.
    pub fn reco_series_pool(&self, top_rated: u32, newest: u32) -> Result<Vec<SeriesRecord>, DbError> {
        self.with_conn(|conn| {
            let mut seen = HashSet::new();
            let mut out = Vec::new();
            for (order, limit) in [("sc.imdb_rating DESC, sc.id DESC", top_rated), ("sc.updated_at DESC, sc.id DESC", newest)] {
                let sql = format!("{SERIES_SELECT} WHERE {VISIBLE_SERIES} ORDER BY {order} LIMIT ?1");
                let mut stmt = conn.prepare(&sql)?;
                let rows = stmt.query_map(params![limit], map_series_row)?;
                for row in rows {
                    let series = row?;
                    if seen.insert(series.id) {
                        out.push(series);
                    }
                }
            }
            Ok(out)
        })
    }

    /// These series, in the order asked, when the profile may see them.
    pub fn visible_series_by_ids(&self, ids: &[i64]) -> Result<Vec<SeriesRecord>, DbError> {
        if ids.is_empty() {
            return Ok(Vec::new());
        }
        self.with_conn(|conn| {
            let marks = vec!["?"; ids.len()].join(",");
            let sql = format!("{SERIES_SELECT} WHERE sc.id IN ({marks}) AND {VISIBLE_SERIES}");
            let mut stmt = conn.prepare(&sql)?;
            let rows = stmt.query_map(rusqlite::params_from_iter(ids.iter()), map_series_row)?;
            let mut by_id = HashMap::new();
            for row in rows {
                let series = row?;
                by_id.insert(series.id, series);
            }
            Ok(ids.iter().filter_map(|id| by_id.remove(id)).collect())
        })
    }

    pub fn item_by_stable_hash(&self, hash: &str) -> Result<Option<IptvItemRecord>, DbError> {
        self.with_conn(|conn| {
            let sql = format!("SELECT {ITEM_SELECT_COLUMNS} {ITEM_JOINS} WHERE i.stable_hash = ?1");
            let mut stmt = conn.prepare(&sql)?;
            Ok(stmt.query_row(params![hash], map_item_row).optional()?)
        })
    }

    /// Finds the local item designated by a household `content_key` (PRD-42 § 6).
    ///
    /// 1. exact match on the stable hash (the common case: the keys are shared since PRD-41);
    /// 2. fallback by the provider identifier, **only inside the source whose `source_key`
    ///    matches** and for the same kind: the same numeric id exists in every account and for
    ///    live, movie and series alike, so a global search would play the wrong content.
    ///
    /// No stream URL is ever rebuilt here: the SQLite database only holds a *reference* to the
    /// password (`password_ref`, the Keychain entry), never the password itself.
    pub fn item_by_content_key(
        &self,
        content_key: &str,
        source_key: Option<&str>,
        provider_ref: Option<&str>,
        item_kind: Option<&str>,
    ) -> Result<Option<IptvItemRecord>, DbError> {
        if let Some(item) = self.item_by_stable_hash(content_key)? {
            return Ok(Some(item));
        }

        let (Some(s_key), Some(pref)) = (source_key, provider_ref) else {
            return Ok(None);
        };
        let pref = pref.trim();
        if pref.is_empty() || !pref.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-') {
            return Ok(None);
        }

        let source_ids: Vec<i64> = self.with_conn(|conn| {
            let mut stmt = conn.prepare(
                "SELECT id, source_type, server, url, username FROM iptv_sources",
            )?;
            let rows = stmt.query_map([], |r| {
                Ok((
                    r.get::<_, i64>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, Option<String>>(2)?.unwrap_or_default(),
                    r.get::<_, Option<String>>(3)?.unwrap_or_default(),
                    r.get::<_, Option<String>>(4)?.unwrap_or_default(),
                ))
            })?;
            let mut ids = Vec::new();
            for (id, source_type, server, url, username) in rows.flatten() {
                let locator = if source_type.eq_ignore_ascii_case("xtream") { &server } else { &url };
                let key = cnd_domain::identity::compute_source_key(&source_type, locator, Some(&username));
                if key.eq_ignore_ascii_case(s_key.trim()) {
                    ids.push(id);
                }
            }
            Ok(ids)
        })?;
        if source_ids.is_empty() {
            return Ok(None);
        }

        let kind = item_kind.unwrap_or("").trim().to_ascii_lowercase();
        let kind_clause = match kind.as_str() {
            "live" | "movie" | "episode" => " AND i.kind = ?4",
            _ => "",
        };
        for source_id in source_ids {
            let found: Option<IptvItemRecord> = self.with_conn(|conn| {
                let sql = format!(
                    "SELECT {ITEM_SELECT_COLUMNS} {ITEM_JOINS} \
                     WHERE i.source_id = ?1 AND (i.stream_url LIKE ?2 OR i.stream_url LIKE ?3){kind_clause} LIMIT 1"
                );
                let mut stmt = conn.prepare(&sql)?;
                let p_dot = format!("%/{pref}.%");
                let p_end = format!("%/{pref}");
                let row = if kind_clause.is_empty() {
                    stmt.query_row(params![source_id, p_dot, p_end], map_item_row).optional()?
                } else {
                    stmt.query_row(params![source_id, p_dot, p_end, kind], map_item_row).optional()?
                };
                Ok(row)
            })?;
            if found.is_some() {
                return Ok(found);
            }
        }
        Ok(None)
    }

    pub fn series_by_stable_hash(&self, hash: &str) -> Result<Option<SeriesRecord>, DbError> {
        self.with_conn(|conn| {
            let sql = format!("{SERIES_SELECT} WHERE sc.stable_hash = ?1");
            let mut stmt = conn.prepare(&sql)?;
            Ok(stmt.query_row(params![hash], map_series_row).optional()?)
        })
    }

    // MARK: - Metadata

    /// All cached OMDb metadata (bounded), indexed for the scoring loops.
    pub fn metadata_index(&self) -> Result<MetadataIndex, DbError> {
        self.with_conn(|conn| {
            let mut stmt = conn.prepare(
                "SELECT lookup_key, imdb_id, genres, director, actors, plot, imdb_rating
                 FROM media_metadata_cache ORDER BY fetched_at DESC LIMIT 30000",
            )?;
            let rows = stmt.query_map([], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, Option<String>>(1)?,
                    CachedItemMetadata {
                        genres: r.get(2)?,
                        director: r.get(3)?,
                        actors: r.get(4)?,
                        plot: r.get(5)?,
                        imdb_rating: r.get(6)?,
                    },
                ))
            })?;
            let mut index = MetadataIndex::default();
            for row in rows {
                let (key, imdb, meta) = row?;
                if let Some(id) = imdb.map(|v| v.trim().to_lowercase()).filter(|v| !v.is_empty()) {
                    index.by_imdb.entry(id).or_insert_with(|| meta.clone());
                }
                index.by_key.entry(key.to_lowercase()).or_insert(meta);
            }
            Ok(index)
        })
    }

    // MARK: - EPG

    /// Programmes on the air in `[from, to]` with the visible live channel that carries each: the
    /// favorites, the channels already watched, then the lowest channel numbers come first when the
    /// guide is bigger than `limit`.
    pub fn reco_airing_with_channels(
        &self,
        from: i64,
        to: i64,
        limit: u32,
    ) -> Result<Vec<(IptvItemRecord, EpgProgramRecord)>, DbError> {
        self.with_conn(|conn| {
            let sql = format!(
                "SELECT {ITEM_SELECT_COLUMNS}, e.id, e.channel_tvg_id, e.start_ts, e.end_ts, e.title, e.subtitle, e.description, e.category
                 {ITEM_JOINS}
                 JOIN epg_programs e ON e.channel_tvg_id = i.tvg_id
                 WHERE i.kind = 'live' AND e.end_ts > ?1 AND e.start_ts < ?2 AND {VISIBLE_ITEM}
                 ORDER BY (f.stable_hash IS NOT NULL) DESC, (wh.stable_hash IS NOT NULL) DESC,
                          COALESCE(i.chno, 1000000) ASC, i.id ASC LIMIT ?3"
            );
            let mut stmt = conn.prepare(&sql)?;
            let rows = stmt.query_map(params![from, to, limit], |r| {
                let item = map_item_row(r)?;
                let base = 31;
                Ok((
                    item,
                    EpgProgramRecord {
                        id: r.get(base)?,
                        channel_tvg_id: r.get(base + 1)?,
                        start_ts: r.get(base + 2)?,
                        end_ts: r.get(base + 3)?,
                        title: r.get(base + 4)?,
                        subtitle: r.get(base + 5)?,
                        description: r.get(base + 6)?,
                        category: r.get(base + 7)?,
                        progress_ratio: 0.0,
                    },
                ))
            })?;
            let mut out = Vec::new();
            for row in rows {
                out.push(row?);
            }
            Ok(out)
        })
    }

    /// The first episode of a series (season then episode order), one row.
    pub fn first_episode_of(&self, series_id: i64) -> Result<Option<IptvItemRecord>, DbError> {
        self.with_conn(|conn| {
            let sql = format!(
                "SELECT {ITEM_SELECT_COLUMNS} {ITEM_JOINS}
                 WHERE i.series_id = ?1 AND i.kind = 'episode'
                 ORDER BY COALESCE(i.season_num, 1) ASC, COALESCE(i.episode_num, 1) ASC, i.id ASC LIMIT 1"
            );
            let mut stmt = conn.prepare_cached(&sql)?;
            Ok(stmt.query_row(params![series_id], map_item_row).optional()?)
        })
    }

    /// When the first episode of a season was added to the catalog.
    pub fn season_first_added(&self, series_id: i64, season_num: u32) -> Result<Option<i64>, DbError> {
        self.with_conn(|conn| {
            Ok(conn
                .query_row(
                    "SELECT MIN(created_at) FROM iptv_items INDEXED BY idx_items_series
                     WHERE series_id = ?1 AND COALESCE(season_num, 1) = ?2",
                    params![series_id, season_num],
                    |r| r.get::<_, Option<i64>>(0),
                )
                .optional()?
                .flatten())
        })
    }

    /// The programme a channel was showing at a time, if the guide still holds it.
    pub fn program_at(&self, tvg_id: &str, ts: i64) -> Result<Option<EpgProgramRecord>, DbError> {
        self.with_conn(|conn| {
            let mut stmt = conn.prepare_cached(
                "SELECT id, channel_tvg_id, start_ts, end_ts, title, subtitle, description, category
                 FROM epg_programs WHERE channel_tvg_id = ?1 AND start_ts <= ?2 AND end_ts > ?2 LIMIT 1",
            )?;
            Ok(stmt
                .query_row(params![tvg_id, ts], |r| {
                    Ok(EpgProgramRecord {
                        id: r.get(0)?,
                        channel_tvg_id: r.get(1)?,
                        start_ts: r.get(2)?,
                        end_ts: r.get(3)?,
                        title: r.get(4)?,
                        subtitle: r.get(5)?,
                        description: r.get(6)?,
                        category: r.get(7)?,
                        progress_ratio: 0.0,
                    })
                })
                .optional()?)
        })
    }

    /// How many programmes are on the air at `now`, and when the guide ends.
    pub fn epg_freshness(&self, now: i64) -> Result<EpgFreshness, DbError> {
        self.with_conn(|conn| {
            let on_air: i64 = conn.query_row(
                "SELECT COUNT(*) FROM epg_programs WHERE start_ts <= ?1 AND end_ts > ?1",
                params![now],
                |r| r.get(0),
            )?;
            let last: Option<i64> = conn.query_row("SELECT MAX(end_ts) FROM epg_programs", [], |r| r.get(0))?;
            Ok(EpgFreshness { on_air_now: on_air.max(0) as u32, last_end_ts: last })
        })
    }

    // MARK: - Feedback

    /// Adds `delta` to a taste feature of a kind ("Moins de ce genre" uses a negative one).
    pub fn add_reco_feedback(&self, kind: &str, feature: &str, delta: f64) -> Result<(), DbError> {
        let now = chrono_now_ts();
        self.with_conn(|conn| {
            conn.execute(
                "INSERT INTO reco_feedback (profile_id, kind, feature, delta, created_at)
                 VALUES ((SELECT id FROM temp.active_profile), ?1, ?2, ?3, ?4)
                 ON CONFLICT(profile_id, kind, feature) DO UPDATE SET
                     delta = reco_feedback.delta + excluded.delta, created_at = excluded.created_at",
                params![kind, feature, delta, now],
            )?;
            Ok(())
        })
    }

    pub fn load_reco_feedback(&self, kind: &str) -> Result<HashMap<String, f64>, DbError> {
        self.with_conn(|conn| {
            let mut stmt = conn.prepare(
                "SELECT feature, delta FROM reco_feedback
                 WHERE profile_id = (SELECT id FROM temp.active_profile) AND kind = ?1",
            )?;
            let rows = stmt.query_map(params![kind], |r| Ok((r.get::<_, String>(0)?, r.get::<_, f64>(1)?)))?;
            let mut out = HashMap::new();
            for row in rows {
                let (k, v) = row?;
                out.insert(k, v);
            }
            Ok(out)
        })
    }

    /// Forgets the feedback and the cached AI answer of one kind.
    pub fn reset_reco_taste(&self, kind: &str) -> Result<(), DbError> {
        self.with_conn(|conn| {
            conn.execute(
                "DELETE FROM reco_feedback WHERE profile_id = (SELECT id FROM temp.active_profile) AND kind = ?1",
                params![kind],
            )?;
            conn.execute(
                "DELETE FROM reco_ai_cache WHERE profile_id = (SELECT id FROM temp.active_profile) AND kind = ?1",
                params![kind],
            )?;
            Ok(())
        })
    }

    // MARK: - AI cache and daily cap

    pub fn save_reco_ai_cache(
        &self,
        kind: &str,
        provider: &str,
        candidates_hash: &str,
        picks_json: &str,
        ttl_secs: i64,
    ) -> Result<(), DbError> {
        let now = chrono_now_ts();
        self.with_conn(|conn| {
            conn.execute(
                "INSERT OR REPLACE INTO reco_ai_cache
                    (profile_id, kind, provider, candidates_hash, picks, created_at, expires_at)
                 VALUES ((SELECT id FROM temp.active_profile), ?1, ?2, ?3, ?4, ?5, ?6)",
                params![kind, provider, candidates_hash, picks_json, now, now + ttl_secs],
            )?;
            Ok(())
        })
    }

    /// The cached answer when it is still valid for this provider and this candidate list.
    pub fn load_reco_ai_cache(&self, kind: &str, provider: &str, candidates_hash: &str, now: i64) -> Result<Option<String>, DbError> {
        self.with_conn(|conn| {
            Ok(conn
                .query_row(
                    "SELECT picks FROM reco_ai_cache
                     WHERE profile_id = (SELECT id FROM temp.active_profile) AND kind = ?1
                       AND provider = ?2 AND candidates_hash = ?3 AND expires_at > ?4",
                    params![kind, provider, candidates_hash, now],
                    |r| r.get::<_, String>(0),
                )
                .optional()?)
        })
    }

    pub fn invalidate_reco_ai_cache(&self, kind: &str) -> Result<(), DbError> {
        self.with_conn(|conn| {
            conn.execute(
                "DELETE FROM reco_ai_cache WHERE profile_id = (SELECT id FROM temp.active_profile) AND kind = ?1",
                params![kind],
            )?;
            Ok(())
        })
    }

    pub fn reco_ai_calls_today(&self, day: &str, provider: &str) -> Result<u32, DbError> {
        self.with_conn(|conn| {
            Ok(conn
                .query_row(
                    "SELECT calls FROM reco_ai_usage WHERE day = ?1 AND provider = ?2",
                    params![day, provider],
                    |r| r.get::<_, i64>(0),
                )
                .optional()?
                .unwrap_or(0)
                .max(0) as u32)
        })
    }

    pub fn count_reco_ai_call(&self, day: &str, provider: &str) -> Result<(), DbError> {
        self.with_conn(|conn| {
            conn.execute(
                "INSERT INTO reco_ai_usage (day, provider, calls) VALUES (?1, ?2, 1)
                 ON CONFLICT(day, provider) DO UPDATE SET calls = calls + 1",
                params![day, provider],
            )?;
            // Keep a week of counters at most.
            conn.execute("DELETE FROM reco_ai_usage WHERE day < date(?1, '-7 day')", params![day])?;
            Ok(())
        })
    }
}
