use crate::db::{chrono_now_ts, DatabaseManager, DbError, IptvItemRecord};
use rusqlite::params;

pub const ITEM_SELECT_COLUMNS: &str = r#"
    i.id, i.source_id, i.series_id, i.stable_hash, i.kind, i.season_num, i.episode_num,
    i.name, i.name_clean, i.year, i.group_title, i.tvg_id, i.logo_url, i.chno, i.host,
    i.container_ext, i.stream_url, i.user_agent, i.referer, i.headers_json,
    i.catchup_type, i.catchup_source, i.catchup_days, i.plot, i.imdb_id, i.imdb_rating,
    (f.stable_hash IS NOT NULL) AS is_favorite,
    (bf.stable_hash IS NOT NULL) AS is_broken,
    COALESCE(wh.position_ms, 0) AS resume_position_ms,
    COALESCE(wh.duration_ms, 0) AS duration_ms,
    (COALESCE(wh.completed, 0) != 0) AS is_completed
"#;

#[derive(Debug, Clone, uniffi::Record)]
pub struct FacetCount {
    pub value: String,
    pub count: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SortField {
    Name,
    Group,
    Host,
    Rating,
    RecentlyAdded,
    ChannelNumber,
    Custom,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct CatalogFilter {
    pub kind: String,
    pub source_id: Option<i64>,
    pub query: String,
    pub group_title: Option<String>,
    pub host: Option<String>,
    pub favorites_only: bool,
    pub include_broken: bool,
    pub include_hidden: bool,
    pub sort_by: SortField,
    pub sort_asc: bool,
    pub limit: u32,
    pub offset: u32,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct SeriesRecord {
    pub id: i64,
    pub source_id: i64,
    pub canonical_key: String,
    pub stable_hash: String,
    pub title: String,
    pub group_title: Option<String>,
    pub poster_url: Option<String>,
    pub backdrop_url: Option<String>,
    pub imdb_id: Option<String>,
    pub imdb_rating: Option<f64>,
    pub plot: Option<String>,
    pub episode_count: u32,
    pub season_count: u32,
    pub is_favorite: bool,
    pub is_broken: bool,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct SeasonSummary {
    pub season_num: u32,
    pub episode_count: u32,
}

/// Tokenizes user input safely for SQLite FTS5 (`"term1"* AND "term2"*`), preventing syntax
/// errors on special characters like `"`, `*`, `-`, `:`, `(`, `)`, `'`, `+`.
pub fn build_safe_fts5_match_query(raw: &str) -> Option<String> {
    let tokens: Vec<&str> = raw
        .split(|c: char| !c.is_alphanumeric())
        .filter(|tok| !tok.is_empty())
        .collect();

    if tokens.is_empty() {
        return None;
    }

    let mut out = String::with_capacity(raw.len() + tokens.len() * 8);
    for (idx, tok) in tokens.iter().enumerate() {
        if idx > 0 {
            out.push_str(" AND ");
        }
        out.push('"');
        out.push_str(tok);
        out.push_str("\"*");
    }
    Some(out)
}

fn static_item_order_clause(sort_by: SortField, sort_asc: bool) -> &'static str {
    match (sort_by, sort_asc) {
        (SortField::Name, true) => "i.name COLLATE NOCASE ASC",
        (SortField::Name, false) => "i.name COLLATE NOCASE DESC",
        (SortField::Group, true) => "COALESCE(i.group_title, '') COLLATE NOCASE ASC, i.name COLLATE NOCASE ASC",
        (SortField::Group, false) => "COALESCE(i.group_title, '') COLLATE NOCASE DESC, i.name COLLATE NOCASE ASC",
        (SortField::Host, true) => "i.host COLLATE NOCASE ASC, i.name COLLATE NOCASE ASC",
        (SortField::Host, false) => "i.host COLLATE NOCASE DESC, i.name COLLATE NOCASE ASC",
        (SortField::Rating, true) => "COALESCE(i.imdb_rating, 0.0) ASC, i.name COLLATE NOCASE ASC",
        (SortField::Rating, false) => "COALESCE(i.imdb_rating, 0.0) DESC, i.name COLLATE NOCASE ASC",
        (SortField::RecentlyAdded, true) => "i.id ASC",
        (SortField::RecentlyAdded, false) => "i.id DESC",
        (SortField::ChannelNumber, true) => "COALESCE(i.chno, 999999) ASC, i.name COLLATE NOCASE ASC",
        (SortField::ChannelNumber, false) => "COALESCE(i.chno, 0) DESC, i.name COLLATE NOCASE ASC",
        (SortField::Custom, true) => "COALESCE((SELECT position FROM custom_order c WHERE c.profile_id = 1 AND c.scope = 'channel' AND c.key = i.stable_hash), 999999) ASC, i.name COLLATE NOCASE ASC",
        (SortField::Custom, false) => "COALESCE((SELECT position FROM custom_order c WHERE c.profile_id = 1 AND c.scope = 'channel' AND c.key = i.stable_hash), 0) DESC, i.name COLLATE NOCASE ASC",
    }
}

fn static_series_order_clause(sort_by: SortField, sort_asc: bool) -> &'static str {
    match (sort_by, sort_asc) {
        (SortField::Rating, true) => "COALESCE(sc.imdb_rating, 0.0) ASC, sc.title COLLATE NOCASE ASC",
        (SortField::Rating, false) => "COALESCE(sc.imdb_rating, 0.0) DESC, sc.title COLLATE NOCASE ASC",
        (SortField::Group, true) => "COALESCE(sc.group_title, '') COLLATE NOCASE ASC, sc.title COLLATE NOCASE ASC",
        (SortField::Group, false) => "COALESCE(sc.group_title, '') COLLATE NOCASE DESC, sc.title COLLATE NOCASE ASC",
        (SortField::RecentlyAdded, true) => "sc.updated_at ASC, sc.id ASC",
        (SortField::RecentlyAdded, false) => "sc.updated_at DESC, sc.id DESC",
        (SortField::Custom, true) => "COALESCE((SELECT position FROM custom_order c WHERE c.profile_id = 1 AND c.scope = 'series' AND c.key = sc.stable_hash), 999999) ASC, sc.title COLLATE NOCASE ASC",
        (SortField::Custom, false) => "COALESCE((SELECT position FROM custom_order c WHERE c.profile_id = 1 AND c.scope = 'series' AND c.key = sc.stable_hash), 0) DESC, sc.title COLLATE NOCASE ASC",
        (_, true) => "sc.title COLLATE NOCASE ASC",
        (_, false) => "sc.title COLLATE NOCASE DESC",
    }
}

pub(crate) fn map_item_row(r: &rusqlite::Row<'_>) -> rusqlite::Result<IptvItemRecord> {
    Ok(IptvItemRecord {
        id: r.get(0)?,
        source_id: r.get(1)?,
        series_id: r.get(2)?,
        stable_hash: r.get(3)?,
        kind: r.get(4)?,
        season_num: r.get(5)?,
        episode_num: r.get(6)?,
        name: r.get(7)?,
        name_clean: r.get(8)?,
        year: r.get(9)?,
        group_title: r.get(10)?,
        tvg_id: r.get(11)?,
        logo_url: r.get(12)?,
        chno: r.get(13)?,
        host: r.get(14)?,
        container_ext: r.get(15)?,
        stream_url: r.get(16)?,
        user_agent: r.get(17)?,
        referer: r.get(18)?,
        headers_json: r.get(19)?,
        catchup_type: r.get(20)?,
        catchup_source: r.get(21)?,
        catchup_days: r.get(22)?,
        plot: r.get(23)?,
        imdb_id: r.get(24)?,
        imdb_rating: r.get(25)?,
        is_favorite: r.get(26)?,
        is_broken: r.get(27)?,
        resume_position_ms: r.get(28)?,
        duration_ms: r.get(29)?,
        is_completed: r.get(30)?,
    })
}

fn map_series_row(r: &rusqlite::Row<'_>) -> rusqlite::Result<SeriesRecord> {
    Ok(SeriesRecord {
        id: r.get(0)?,
        source_id: r.get(1)?,
        canonical_key: r.get(2)?,
        stable_hash: r.get(3)?,
        title: r.get(4)?,
        group_title: r.get(5)?,
        poster_url: r.get(6)?,
        backdrop_url: r.get(7)?,
        imdb_id: r.get(8)?,
        imdb_rating: r.get(9)?,
        plot: r.get(10)?,
        episode_count: r.get(11)?,
        season_count: r.get(12)?,
        is_favorite: r.get(13)?,
        is_broken: r.get(14)?,
    })
}

impl DatabaseManager {
    pub fn get_groups(&self, kind: &str, source_id: Option<i64>, include_hidden: bool) -> Result<Vec<FacetCount>, DbError> {
        self.with_conn(|conn| {
            let hidden_clause = if include_hidden {
                ""
            } else {
                " AND NOT EXISTS (SELECT 1 FROM hidden_groups h WHERE h.profile_id = 1 AND h.kind = ?2 AND h.group_key = LOWER(TRIM(group_title)))"
            };

            let sql = if kind == "series" {
                format!(
                    "SELECT group_title, COUNT(*)
                     FROM series_catalog
                     WHERE group_title IS NOT NULL AND TRIM(group_title) != ''
                       AND (?1 IS NULL OR source_id = ?1)
                       {hidden_clause}
                     GROUP BY group_title
                     ORDER BY COALESCE((SELECT position FROM custom_order c WHERE c.profile_id = 1 AND c.scope = 'group' AND c.key = LOWER(TRIM(group_title))), 999999) ASC, group_title COLLATE NOCASE ASC"
                )
            } else {
                format!(
                    "SELECT group_title, COUNT(*)
                     FROM iptv_items
                     WHERE kind = ?2
                       AND group_title IS NOT NULL AND TRIM(group_title) != ''
                       AND (?1 IS NULL OR source_id = ?1)
                       {hidden_clause}
                     GROUP BY group_title
                     ORDER BY COALESCE((SELECT position FROM custom_order c WHERE c.profile_id = 1 AND c.scope = 'group' AND c.key = LOWER(TRIM(group_title))), 999999) ASC, group_title COLLATE NOCASE ASC"
                )
            };

            let mut stmt = conn.prepare(&sql)?;
            let mut out = Vec::new();
            if kind == "series" {
                let rows = stmt.query_map(params![source_id, kind], |r| {
                    Ok(FacetCount {
                        value: r.get(0)?,
                        count: r.get(1)?,
                    })
                })?;
                for item in rows {
                    out.push(item?);
                }
            } else {
                let rows = stmt.query_map(params![source_id, kind], |r| {
                    Ok(FacetCount {
                        value: r.get(0)?,
                        count: r.get(1)?,
                    })
                })?;
                for item in rows {
                    out.push(item?);
                }
            }
            Ok(out)
        })
    }

    pub fn get_hosts(&self, kind: &str, source_id: Option<i64>) -> Result<Vec<FacetCount>, DbError> {
        let effective_kind = if kind == "series" { "episode" } else { kind };
        self.with_conn(|conn| {
            let mut stmt = conn.prepare_cached(
                "SELECT host, COUNT(*)
                 FROM iptv_items
                 WHERE kind = ?1
                   AND host IS NOT NULL AND TRIM(host) != ''
                   AND (?2 IS NULL OR source_id = ?2)
                 GROUP BY host
                 ORDER BY count(*) DESC, host COLLATE NOCASE ASC",
            )?;
            let rows = stmt.query_map(params![effective_kind, source_id], |r| {
                Ok(FacetCount {
                    value: r.get(0)?,
                    count: r.get(1)?,
                })
            })?;
            let mut out = Vec::new();
            for row in rows {
                out.push(row?);
            }
            Ok(out)
        })
    }

    pub fn query_catalog(&self, filter: &CatalogFilter) -> Result<Vec<IptvItemRecord>, DbError> {
        self.with_conn(|conn| {
            let order_sql = static_item_order_clause(filter.sort_by, filter.sort_asc);
            let fav_join = if filter.favorites_only {
                "INNER JOIN favorites f ON f.stable_hash = i.stable_hash"
            } else {
                "LEFT JOIN favorites f ON f.stable_hash = i.stable_hash"
            };
            let broken_clause = if filter.include_broken {
                ""
            } else {
                "AND bf.stable_hash IS NULL"
            };
            let hidden_clause = if filter.include_hidden {
                ""
            } else {
                "AND NOT EXISTS (SELECT 1 FROM hidden_items h WHERE h.profile_id = 1 AND h.stable_hash = i.stable_hash) \
                 AND (i.group_title IS NULL OR NOT EXISTS (SELECT 1 FROM hidden_groups g WHERE g.profile_id = 1 AND g.kind = i.kind AND g.group_key = LOWER(TRIM(i.group_title))))"
            };

            let trimmed_q = filter.query.trim();
            if !trimmed_q.is_empty() {
                if let Some(fts_match) = build_safe_fts5_match_query(trimmed_q) {
                    let sql = format!(
                        "SELECT {ITEM_SELECT_COLUMNS}
                         FROM iptv_items i
                         JOIN iptv_items_fts ON iptv_items_fts.rowid = i.id
                         {fav_join}
                         LEFT JOIN broken_flags bf ON bf.stable_hash = i.stable_hash
                         LEFT JOIN watch_history wh ON wh.stable_hash = i.stable_hash
                         WHERE iptv_items_fts MATCH ?1
                           AND i.kind = ?2
                           AND (?3 IS NULL OR i.source_id = ?3)
                           AND (?4 IS NULL OR i.group_title = ?4)
                           AND (?5 IS NULL OR i.host = ?5)
                           {broken_clause}
                           {hidden_clause}
                         ORDER BY bm25(iptv_items_fts), {order_sql}
                         LIMIT ?6 OFFSET ?7"
                    );
                    let mut stmt = conn.prepare(&sql)?;
                    let rows = stmt.query_map(
                        params![
                            fts_match,
                            filter.kind,
                            filter.source_id,
                            filter.group_title,
                            filter.host,
                            filter.limit,
                            filter.offset
                        ],
                        map_item_row,
                    )?;
                    let mut out = Vec::new();
                    for item in rows {
                        out.push(item?);
                    }
                    return Ok(out);
                } else {
                    // Pure punctuation query fallback (e.g., "+") using parameterized LIKE
                    let like_pattern = format!("%{}%", trimmed_q.replace('%', "\\%").replace('_', "\\_"));
                    let sql = format!(
                        "SELECT {ITEM_SELECT_COLUMNS}
                         FROM iptv_items i
                         {fav_join}
                         LEFT JOIN broken_flags bf ON bf.stable_hash = i.stable_hash
                         LEFT JOIN watch_history wh ON wh.stable_hash = i.stable_hash
                         WHERE i.kind = ?1
                           AND i.name LIKE ?2 ESCAPE '\\'
                           AND (?3 IS NULL OR i.source_id = ?3)
                           AND (?4 IS NULL OR i.group_title = ?4)
                           AND (?5 IS NULL OR i.host = ?5)
                           {broken_clause}
                           {hidden_clause}
                         ORDER BY {order_sql}
                         LIMIT ?6 OFFSET ?7"
                    );
                    let mut stmt = conn.prepare(&sql)?;
                    let rows = stmt.query_map(
                        params![
                            filter.kind,
                            like_pattern,
                            filter.source_id,
                            filter.group_title,
                            filter.host,
                            filter.limit,
                            filter.offset
                        ],
                        map_item_row,
                    )?;
                    let mut out = Vec::new();
                    for item in rows {
                        out.push(item?);
                    }
                    return Ok(out);
                }
            }

            let sql = format!(
                "SELECT {ITEM_SELECT_COLUMNS}
                 FROM iptv_items i
                 {fav_join}
                 LEFT JOIN broken_flags bf ON bf.stable_hash = i.stable_hash
                 LEFT JOIN watch_history wh ON wh.stable_hash = i.stable_hash
                 WHERE i.kind = ?1
                   AND (?2 IS NULL OR i.source_id = ?2)
                   AND (?3 IS NULL OR i.group_title = ?3)
                   AND (?4 IS NULL OR i.host = ?4)
                   {broken_clause}
                   {hidden_clause}
                 ORDER BY {order_sql}
                 LIMIT ?5 OFFSET ?6"
            );
            let mut stmt = conn.prepare(&sql)?;
            let rows = stmt.query_map(
                params![
                    filter.kind,
                    filter.source_id,
                    filter.group_title,
                    filter.host,
                    filter.limit,
                    filter.offset
                ],
                map_item_row,
            )?;
            let mut out = Vec::new();
            for item in rows {
                out.push(item?);
            }
            Ok(out)
        })
    }

    pub fn query_series(&self, filter: &CatalogFilter) -> Result<Vec<SeriesRecord>, DbError> {
        self.with_conn(|conn| {
            let order_sql = static_series_order_clause(filter.sort_by, filter.sort_asc);
            let fav_join = if filter.favorites_only {
                "INNER JOIN favorites f ON f.stable_hash = sc.stable_hash"
            } else {
                "LEFT JOIN favorites f ON f.stable_hash = sc.stable_hash"
            };
            let broken_clause = if filter.include_broken {
                ""
            } else {
                "AND bf.stable_hash IS NULL"
            };
            let hidden_clause = if filter.include_hidden {
                ""
            } else {
                "AND (sc.group_title IS NULL OR NOT EXISTS (SELECT 1 FROM hidden_groups g WHERE g.profile_id = 1 AND g.kind = 'series' AND g.group_key = LOWER(TRIM(sc.group_title))))"
            };

            let trimmed_q = filter.query.trim();
            let like_param = if trimmed_q.is_empty() {
                None
            } else {
                Some(format!(
                    "%{}%",
                    trimmed_q.replace('%', "\\%").replace('_', "\\_")
                ))
            };

            let sql = format!(
                "SELECT sc.id, sc.source_id, sc.canonical_key, sc.stable_hash, sc.title,
                        sc.group_title, sc.poster_url, sc.backdrop_url, sc.imdb_id,
                        sc.imdb_rating, sc.plot, sc.episode_count, sc.season_count,
                        (f.stable_hash IS NOT NULL) AS is_favorite,
                        (bf.stable_hash IS NOT NULL) AS is_broken
                 FROM series_catalog sc
                 {fav_join}
                 LEFT JOIN broken_flags bf ON bf.stable_hash = sc.stable_hash
                 WHERE (?1 IS NULL OR sc.source_id = ?1)
                   AND (?2 IS NULL OR sc.group_title = ?2)
                   AND (?3 IS NULL OR sc.title LIKE ?3 ESCAPE '\\' OR sc.group_title LIKE ?3 ESCAPE '\\')
                   {broken_clause}
                   {hidden_clause}
                 ORDER BY {order_sql}
                 LIMIT ?4 OFFSET ?5"
            );

            let mut stmt = conn.prepare(&sql)?;
            let rows = stmt.query_map(
                params![
                    filter.source_id,
                    filter.group_title,
                    like_param,
                    filter.limit,
                    filter.offset
                ],
                map_series_row,
            )?;
            let mut out = Vec::new();
            for item in rows {
                out.push(item?);
            }
            Ok(out)
        })
    }

    pub fn get_series_seasons(&self, series_id: i64) -> Result<Vec<SeasonSummary>, DbError> {
        self.with_conn(|conn| {
            let mut stmt = conn.prepare_cached(
                "SELECT COALESCE(season_num, 1) AS s_num, COUNT(*)
                 FROM iptv_items
                 WHERE series_id = ?1 AND kind = 'episode'
                 GROUP BY s_num
                 ORDER BY s_num ASC",
            )?;
            let rows = stmt.query_map(params![series_id], |r| {
                Ok(SeasonSummary {
                    season_num: r.get(0)?,
                    episode_count: r.get(1)?,
                })
            })?;
            let mut out = Vec::new();
            for row in rows {
                out.push(row?);
            }
            Ok(out)
        })
    }

    pub fn get_series_episodes(
        &self,
        series_id: i64,
        season_num: Option<u32>,
    ) -> Result<Vec<IptvItemRecord>, DbError> {
        self.with_conn(|conn| {
            let sql = format!(
                "SELECT {ITEM_SELECT_COLUMNS}
                 FROM iptv_items i
                 LEFT JOIN favorites f ON f.stable_hash = i.stable_hash
                 LEFT JOIN broken_flags bf ON bf.stable_hash = i.stable_hash
                 LEFT JOIN watch_history wh ON wh.stable_hash = i.stable_hash
                 WHERE i.series_id = ?1
                   AND i.kind = 'episode'
                   AND (?2 IS NULL OR COALESCE(i.season_num, 1) = ?2)
                 ORDER BY COALESCE(i.season_num, 1) ASC, COALESCE(i.episode_num, 1) ASC, i.id ASC"
            );
            let mut stmt = conn.prepare_cached(&sql)?;
            let rows = stmt.query_map(params![series_id, season_num], map_item_row)?;
            let mut out = Vec::new();
            for item in rows {
                out.push(item?);
            }
            Ok(out)
        })
    }

    pub fn list_favorite_items(&self, kind: &str) -> Result<Vec<IptvItemRecord>, DbError> {
        self.with_conn(|conn| {
            let sql = format!(
                "SELECT {ITEM_SELECT_COLUMNS}
                 FROM favorites f
                 INNER JOIN iptv_items i ON i.stable_hash = f.stable_hash
                 LEFT JOIN broken_flags bf ON bf.stable_hash = i.stable_hash
                 LEFT JOIN watch_history wh ON wh.stable_hash = i.stable_hash
                 WHERE i.kind = ?1
                 ORDER BY f.created_at DESC, i.name COLLATE NOCASE ASC"
            );
            let mut stmt = conn.prepare_cached(&sql)?;
            let rows = stmt.query_map(params![kind], map_item_row)?;
            let mut out = Vec::new();
            for item in rows {
                out.push(item?);
            }
            Ok(out)
        })
    }

    pub fn list_favorite_series(&self) -> Result<Vec<SeriesRecord>, DbError> {
        self.with_conn(|conn| {
            let mut stmt = conn.prepare_cached(
                "SELECT sc.id, sc.source_id, sc.canonical_key, sc.stable_hash, sc.title,
                        sc.group_title, sc.poster_url, sc.backdrop_url, sc.imdb_id,
                        sc.imdb_rating, sc.plot, sc.episode_count, sc.season_count,
                        1 AS is_favorite,
                        (bf.stable_hash IS NOT NULL) AS is_broken
                 FROM favorites f
                 INNER JOIN series_catalog sc ON sc.stable_hash = f.stable_hash
                 LEFT JOIN broken_flags bf ON bf.stable_hash = sc.stable_hash
                 ORDER BY f.created_at DESC, sc.title COLLATE NOCASE ASC",
            )?;
            let rows = stmt.query_map([], map_series_row)?;
            let mut out = Vec::new();
            for item in rows {
                out.push(item?);
            }
            Ok(out)
        })
    }

    pub fn record_watch_progress(
        &self,
        stable_hash: &str,
        position_ms: i64,
        duration_ms: i64,
    ) -> Result<(), DbError> {
        let safe_pos = position_ms.max(0);
        let safe_dur = duration_ms.max(0);
        let completed = if safe_dur > 0 && (safe_pos as f64 / safe_dur as f64) >= 0.92 {
            1i32
        } else {
            0i32
        };
        let now = chrono_now_ts();

        self.with_conn(|conn| {
            conn.execute(
                "INSERT INTO watch_history (stable_hash, position_ms, duration_ms, completed, last_watched_at)
                 VALUES (?1, ?2, ?3, ?4, ?5)
                 ON CONFLICT(stable_hash) DO UPDATE SET
                     position_ms = excluded.position_ms,
                     duration_ms = excluded.duration_ms,
                     completed = excluded.completed,
                     last_watched_at = excluded.last_watched_at",
                params![stable_hash, safe_pos, safe_dur, completed, now],
            )?;
            Ok(())
        })
    }

    pub fn get_item_by_id(&self, item_id: i64) -> Result<Option<IptvItemRecord>, DbError> {
        self.with_conn(|conn| {
            use rusqlite::OptionalExtension;
            let sql = format!(
                "SELECT {ITEM_SELECT_COLUMNS}
                 FROM iptv_items i
                 LEFT JOIN favorites f ON f.stable_hash = i.stable_hash
                 LEFT JOIN broken_flags bf ON bf.stable_hash = i.stable_hash
                 LEFT JOIN watch_history wh ON wh.stable_hash = i.stable_hash
                 WHERE i.id = ?1"
            );
            let mut stmt = conn.prepare_cached(&sql)?;
            let item = stmt.query_row(params![item_id], map_item_row).optional()?;
            Ok(item)
        })
    }

    pub fn get_series_by_id(&self, series_id: i64) -> Result<Option<SeriesRecord>, DbError> {
        self.with_conn(|conn| {
            use rusqlite::OptionalExtension;
            let mut stmt = conn.prepare_cached(
                "SELECT sc.id, sc.source_id, sc.canonical_key, sc.stable_hash, sc.title,
                        sc.group_title, sc.poster_url, sc.backdrop_url, sc.imdb_id,
                        sc.imdb_rating, sc.plot, sc.episode_count, sc.season_count,
                        (f.stable_hash IS NOT NULL) AS is_favorite,
                        (bf.stable_hash IS NOT NULL) AS is_broken
                 FROM series_catalog sc
                 LEFT JOIN favorites f ON f.stable_hash = sc.stable_hash
                 LEFT JOIN broken_flags bf ON bf.stable_hash = sc.stable_hash
                 WHERE sc.id = ?1",
            )?;
            let series = stmt
                .query_row(params![series_id], map_series_row)
                .optional()?;
            Ok(series)
        })
    }

    pub fn list_recent_items(&self, kind: &str, limit: u32) -> Result<Vec<IptvItemRecord>, DbError> {
        if limit == 0 {
            return Ok(Vec::new());
        }
        self.with_conn(|conn| {
            let sql = format!(
                "SELECT {ITEM_SELECT_COLUMNS}
                 FROM watch_history wh
                 INNER JOIN iptv_items i ON i.stable_hash = wh.stable_hash
                 LEFT JOIN favorites f ON f.stable_hash = i.stable_hash
                 LEFT JOIN broken_flags bf ON bf.stable_hash = i.stable_hash
                 WHERE i.kind = ?1
                 ORDER BY wh.last_watched_at DESC, i.id DESC
                 LIMIT ?2"
            );
            let mut stmt = conn.prepare_cached(&sql)?;
            let rows = stmt.query_map(params![kind, limit], map_item_row)?;
            let mut out = Vec::new();
            for item in rows {
                out.push(item?);
            }
            Ok(out)
        })
    }

    pub fn list_recent_series(&self, limit: u32) -> Result<Vec<SeriesRecord>, DbError> {
        if limit == 0 {
            return Ok(Vec::new());
        }
        self.with_conn(|conn| {
            let mut stmt = conn.prepare_cached(
                "SELECT sc.id, sc.source_id, sc.canonical_key, sc.stable_hash, sc.title,
                        sc.group_title, sc.poster_url, sc.backdrop_url, sc.imdb_id,
                        sc.imdb_rating, sc.plot, sc.episode_count, sc.season_count,
                        (f.stable_hash IS NOT NULL) AS is_favorite,
                        (bf.stable_hash IS NOT NULL) AS is_broken
                 FROM series_catalog sc
                 INNER JOIN iptv_items ep ON ep.series_id = sc.id AND ep.kind = 'episode'
                 INNER JOIN watch_history wh ON wh.stable_hash = ep.stable_hash
                 LEFT JOIN favorites f ON f.stable_hash = sc.stable_hash
                 LEFT JOIN broken_flags bf ON bf.stable_hash = sc.stable_hash
                 GROUP BY sc.id
                 ORDER BY MAX(wh.last_watched_at) DESC
                 LIMIT ?1",
            )?;
            let rows = stmt.query_map(params![limit], map_series_row)?;
            let mut out = Vec::new();
            for item in rows {
                out.push(item?);
            }
            Ok(out)
        })
    }

    pub fn list_broken_items(&self, kind: &str) -> Result<Vec<IptvItemRecord>, DbError> {
        self.with_conn(|conn| {
            let sql = format!(
                "SELECT {ITEM_SELECT_COLUMNS}
                 FROM broken_flags bf
                 INNER JOIN iptv_items i ON i.stable_hash = bf.stable_hash
                 LEFT JOIN favorites f ON f.stable_hash = i.stable_hash
                 LEFT JOIN watch_history wh ON wh.stable_hash = i.stable_hash
                 WHERE i.kind = ?1
                 ORDER BY bf.flagged_at DESC, i.name COLLATE NOCASE ASC"
            );
            let mut stmt = conn.prepare_cached(&sql)?;
            let rows = stmt.query_map(params![kind], map_item_row)?;
            let mut out = Vec::new();
            for item in rows {
                out.push(item?);
            }
            Ok(out)
        })
    }

    pub fn list_broken_series(&self) -> Result<Vec<SeriesRecord>, DbError> {
        self.with_conn(|conn| {
            let mut stmt = conn.prepare_cached(
                "SELECT sc.id, sc.source_id, sc.canonical_key, sc.stable_hash, sc.title,
                        sc.group_title, sc.poster_url, sc.backdrop_url, sc.imdb_id,
                        sc.imdb_rating, sc.plot, sc.episode_count, sc.season_count,
                        (f.stable_hash IS NOT NULL) AS is_favorite,
                        1 AS is_broken
                 FROM broken_flags bf
                 INNER JOIN series_catalog sc ON sc.stable_hash = bf.stable_hash
                 LEFT JOIN favorites f ON f.stable_hash = sc.stable_hash
                 ORDER BY bf.flagged_at DESC, sc.title COLLATE NOCASE ASC",
            )?;
            let rows = stmt.query_map([], map_series_row)?;
            let mut out = Vec::new();
            for item in rows {
                out.push(item?);
            }
            Ok(out)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_fts5_special_characters_and_diacritics() {
        let db = DatabaseManager::open_in_memory().expect("open db");
        let src_id = db
            .add_source("Special Chars Source", "m3u", None, None, None, None)
            .unwrap();

        db.with_conn(|conn| {
            conn.execute(
                "INSERT INTO iptv_items (source_id, stable_hash, kind, name, name_clean, group_title, host, stream_url, created_at, updated_at)
                 VALUES
                 (?1, 'h_spidey', 'movie', 'Spider-Man: No Way Home (2021)', 'Spider-Man: No Way Home', 'Marvel', 'vod.tv', 'http://vod.tv/1.mkv', 1, 1),
                 (?1, 'h_cplus', 'live', 'C+ Sport HD', 'C+ Sport', 'Sports', 'live.tv', 'http://live.tv/2.ts', 1, 1),
                 (?1, 'h_equipe', 'live', 'L''Équipe TV', 'L''Équipe TV', 'Sports', 'live.tv', 'http://live.tv/3.ts', 1, 1)",
                params![src_id],
            )?;
            Ok(())
        })
        .unwrap();

        // 1. Spider-Man with colon, hyphen, and parentheses must NOT trigger FTS5 syntax error!
        let spidey = db
            .query_catalog(&CatalogFilter {
                kind: "movie".to_string(),
                source_id: None,
                query: "Spider-Man: No Way (2021)".to_string(),
                group_title: None,
                host: None,
                favorites_only: false,
                include_broken: false,
                include_hidden: false,
                sort_by: SortField::Name,
                sort_asc: true,
                limit: 20,
                offset: 0,
            })
            .expect("query spider-man");
        assert_eq!(spidey.len(), 1);
        assert_eq!(spidey[0].stable_hash, "h_spidey");

        // 2. "C+" search
        let cplus = db
            .query_catalog(&CatalogFilter {
                kind: "live".to_string(),
                source_id: None,
                query: "C+".to_string(),
                group_title: None,
                host: None,
                favorites_only: false,
                include_broken: false,
                include_hidden: false,
                sort_by: SortField::Name,
                sort_asc: true,
                limit: 20,
                offset: 0,
            })
            .expect("query C+");
        assert_eq!(cplus.len(), 1);
        assert_eq!(cplus[0].stable_hash, "h_cplus");

        // 3. "L'Equipe" (without accent) & "L'Équipe" (with accent + apostrophe)
        for q in ["L'Équipe", "L'Equipe", "equipe"] {
            let eq_res = db
                .query_catalog(&CatalogFilter {
                    kind: "live".to_string(),
                    source_id: None,
                    query: q.to_string(),
                    group_title: None,
                    host: None,
                    favorites_only: false,
                    include_broken: false,
                    include_hidden: false,
                    sort_by: SortField::Name,
                    sort_asc: true,
                    limit: 20,
                    offset: 0,
                })
                .expect("query equipe");
            assert_eq!(eq_res.len(), 1, "Failed query: {q}");
            assert_eq!(eq_res[0].stable_hash, "h_equipe");
        }
    }

    #[test]
    fn test_favorite_at_rank_1000_and_watch_progress_92_percent() {
        let db = DatabaseManager::open_in_memory().expect("open db");
        let src_id = db
            .add_source("Big Catalog", "m3u", None, None, None, None)
            .unwrap();

        db.with_conn_mut(|conn| {
            let tx = conn.transaction()?;
            {
                let mut stmt = tx.prepare(
                    "INSERT INTO iptv_items (source_id, stable_hash, kind, name, name_clean, group_title, host, stream_url, created_at, updated_at)
                     VALUES (?1, ?2, 'live', ?3, ?3, 'General', 'cdn.tv', ?4, 1, 1)",
                )?;
                for idx in 1..=1_200 {
                    stmt.execute(params![
                        src_id,
                        format!("hash_{idx:04}"),
                        format!("Channel {idx:04}"),
                        format!("http://cdn.tv/{idx}.ts")
                    ])?;
                }
            }
            tx.commit()?;
            Ok(())
        })
        .unwrap();

        // Mark item at rank 1,000 as favorite while catalog page is at offset=0, limit=50
        db.toggle_favorite("hash_1000", "live")
            .expect("toggle rank 1000");

        let page1 = db.query_items("live", "", None, None, 50, 0).unwrap();
        assert_eq!(page1.len(), 50);

        let all_favs = db.list_favorite_items("live").expect("list favs");
        assert_eq!(all_favs.len(), 1);
        assert_eq!(all_favs[0].stable_hash, "hash_1000");
        assert_eq!(all_favs[0].name, "Channel 1000");

        // Test watch progress below and above 92% completion threshold
        db.record_watch_progress("hash_1000", 50_000, 100_000)
            .expect("50% progress");
        let recents_half = db.list_recent_items("live", 10).expect("recents 1");
        assert_eq!(recents_half.len(), 1);
        assert_eq!(recents_half[0].resume_position_ms, 50_000);
        assert!(!recents_half[0].is_completed);

        db.record_watch_progress("hash_1000", 93_000, 100_000)
            .expect("93% progress");
        let recents_done = db.list_recent_items("live", 10).expect("recents 2");
        assert_eq!(recents_done[0].resume_position_ms, 93_000);
        assert!(recents_done[0].is_completed);
    }

    #[test]
    fn test_facets_series_seasons_episodes_and_recent_series() {
        let db = DatabaseManager::open_in_memory().expect("open db");
        let src_id = db
            .add_source("Series Source", "m3u", None, None, None, None)
            .unwrap();

        let series_id: i64 = db
            .with_conn(|conn| {
                conn.execute(
                    "INSERT INTO series_catalog (source_id, canonical_key, stable_hash, title, group_title, imdb_rating, episode_count, season_count, updated_at)
                     VALUES (?1, 'severance', 'series:sev_hash', 'Severance', 'Sci-Fi', 8.7, 2, 1, 100)",
                    params![src_id],
                )?;
                let sid = conn.last_insert_rowid();
                conn.execute(
                    "INSERT INTO iptv_items (source_id, series_id, stable_hash, kind, season_num, episode_num, name, name_clean, group_title, host, stream_url, created_at, updated_at)
                     VALUES
                     (?1, ?2, 'ep_1', 'episode', 1, 1, 'Severance S01E01', 'Severance', 'Sci-Fi', 'vod.cdn', 'http://vod.cdn/1.mkv', 1, 1),
                     (?1, ?2, 'ep_2', 'episode', 1, 2, 'Severance S01E02', 'Severance', 'Sci-Fi', 'vod.cdn', 'http://vod.cdn/2.mkv', 1, 1)",
                    params![src_id, sid],
                )?;
                Ok(sid)
            })
            .unwrap();

        let groups = db.get_groups("series", None, false).expect("series groups");
        assert_eq!(groups.len(), 1);
        assert_eq!(groups[0].value, "Sci-Fi");
        assert_eq!(groups[0].count, 1);

        let hosts = db.get_hosts("series", None).expect("series hosts");
        assert_eq!(hosts.len(), 1);
        assert_eq!(hosts[0].value, "vod.cdn");
        assert_eq!(hosts[0].count, 2);

        db.toggle_favorite("series:sev_hash", "series")
            .expect("fav series");
        let fav_series = db.list_favorite_series().expect("list fav series");
        assert_eq!(fav_series.len(), 1);
        assert!(fav_series[0].is_favorite);

        let seasons = db.get_series_seasons(series_id).expect("seasons");
        assert_eq!(seasons.len(), 1);
        assert_eq!(seasons[0].season_num, 1);
        assert_eq!(seasons[0].episode_count, 2);

        db.record_watch_progress("ep_1", 1_200_000, 3_000_000)
            .expect("watch ep_1");
        let eps = db
            .get_series_episodes(series_id, Some(1))
            .expect("episodes");
        assert_eq!(eps.len(), 2);
        assert_eq!(eps[0].resume_position_ms, 1_200_000);
        assert_eq!(eps[1].resume_position_ms, 0);

        let rec_series = db.list_recent_series(10).expect("recent series");
        assert_eq!(rec_series.len(), 1);
        assert_eq!(rec_series[0].title, "Severance");
    }

    #[test]
    fn test_broken_flag_filtering_and_persistence() {
        let db = DatabaseManager::open_in_memory().expect("open db");
        let src_id = db
            .add_source("Source 1", "m3u", None, None, None, None)
            .unwrap();

        db.with_conn_mut(|conn| {
            conn.execute(
                "INSERT INTO iptv_items (source_id, stable_hash, kind, name, name_clean, group_title, host, stream_url, created_at, updated_at)
                 VALUES
                 (?1, 'hash_live_working', 'live', 'France 2 HD', 'France 2', 'General', 'live.cdn', 'http://live.cdn/1.ts', 1, 1),
                 (?1, 'hash_live_broken', 'live', 'France 3 HD', 'France 3', 'General', 'live.cdn', 'http://live.cdn/2.ts', 1, 1),
                 (?1, 'hash_movie_broken', 'movie', 'Dune Part Two', 'Dune Part Two', 'Sci-Fi', 'vod.cdn', 'http://vod.cdn/dune.mkv', 1, 1)",
                params![src_id],
            )?;

            conn.execute(
                "INSERT INTO series_catalog (source_id, canonical_key, stable_hash, title, group_title, episode_count, season_count, updated_at)
                 VALUES
                 (?1, 'key_series_working', 'hash_series_working', 'Breaking Bad', 'Drama', 62, 5, 1),
                 (?1, 'key_series_broken', 'hash_series_broken', 'Game of Thrones', 'Fantasy', 73, 8, 1)",
                params![src_id],
            )?;
            Ok(())
        })
        .unwrap();

        // Initially nothing is broken
        assert_eq!(db.get_stats().unwrap().total_broken, 0);

        // Flag France 3 and Game of Thrones as broken
        assert!(db.toggle_broken("hash_live_broken", "live").unwrap());
        assert!(db.is_broken("hash_live_broken").unwrap());
        assert!(db.toggle_broken("hash_series_broken", "series").unwrap());
        assert!(db.is_broken("hash_series_broken").unwrap());

        assert_eq!(db.get_stats().unwrap().total_broken, 2);

        // 1. Query live channels with default include_broken = false:
        // Broken item France 3 must NOT be returned!
        let filter_live_clean = CatalogFilter {
            kind: "live".to_string(),
            source_id: None,
            query: "".to_string(),
            group_title: None,
            host: None,
            favorites_only: false,
            include_broken: false,
            include_hidden: false,
            sort_by: SortField::Name,
            sort_asc: true,
            limit: 10,
            offset: 0,
        };
        let clean_live = db.query_catalog(&filter_live_clean).unwrap();
        assert_eq!(clean_live.len(), 1);
        assert_eq!(clean_live[0].stable_hash, "hash_live_working");
        assert!(!clean_live[0].is_broken);

        // Even searching specifically for "France 3" returns empty when include_broken = false
        let search_broken = CatalogFilter {
            kind: "live".to_string(),
            source_id: None,
            query: "France 3".to_string(),
            group_title: None,
            host: None,
            favorites_only: false,
            include_broken: false,
            include_hidden: false,
            sort_by: SortField::Name,
            sort_asc: true,
            limit: 10,
            offset: 0,
        };
        assert!(db.query_catalog(&search_broken).unwrap().is_empty());

        // 2. Query live channels with include_broken = true:
        // Both items returned, and France 3 is marked is_broken = true
        let mut filter_live_all = filter_live_clean;
        filter_live_all.include_broken = true;
        let all_live = db.query_catalog(&filter_live_all).unwrap();
        assert_eq!(all_live.len(), 2);
        let broken_item = all_live.iter().find(|i| i.stable_hash == "hash_live_broken").unwrap();
        assert!(broken_item.is_broken);

        // 3. Query series with include_broken = false:
        let filter_series_clean = CatalogFilter {
            kind: "series".to_string(),
            source_id: None,
            query: "".to_string(),
            group_title: None,
            host: None,
            favorites_only: false,
            include_broken: false,
            include_hidden: false,
            sort_by: SortField::Name,
            sort_asc: true,
            limit: 10,
            offset: 0,
        };
        let clean_series = db.query_series(&filter_series_clean).unwrap();
        assert_eq!(clean_series.len(), 1);
        assert_eq!(clean_series[0].title, "Breaking Bad");

        // With include_broken = true:
        let mut filter_series_all = filter_series_clean;
        filter_series_all.include_broken = true;
        let all_series = db.query_series(&filter_series_all).unwrap();
        assert_eq!(all_series.len(), 2);
        let broken_series = all_series.iter().find(|s| s.title == "Game of Thrones").unwrap();
        assert!(broken_series.is_broken);

        // 4. list_broken_items and list_broken_series
        let broken_items = db.list_broken_items("live").unwrap();
        assert_eq!(broken_items.len(), 1);
        assert_eq!(broken_items[0].stable_hash, "hash_live_broken");

        let broken_series_list = db.list_broken_series().unwrap();
        assert_eq!(broken_series_list.len(), 1);
        assert_eq!(broken_series_list[0].stable_hash, "hash_series_broken");

        // 5. Unflagging France 3
        assert!(!db.toggle_broken("hash_live_broken", "live").unwrap());
        assert!(!db.is_broken("hash_live_broken").unwrap());
        assert_eq!(db.get_stats().unwrap().total_broken, 1);

        // Now France 3 appears in default query
        let clean_live_after = db.query_catalog(&CatalogFilter {
            kind: "live".to_string(),
            source_id: None,
            query: "".to_string(),
            group_title: None,
            host: None,
            favorites_only: false,
            include_broken: false,
            include_hidden: false,
            sort_by: SortField::Name,
            sort_asc: true,
            limit: 10,
            offset: 0,
        }).unwrap();
        assert_eq!(clean_live_after.len(), 2);
    }
}
