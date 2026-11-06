//! Queries of the prompt search (PRD 33). Every query applies the active profile's rules: items and
//! groups the user hid, adult categories, the kids allow-list, and streams flagged as broken.

use crate::db::catalog_repo::{map_item_row, map_series_row, SeriesRecord, ITEM_SELECT_COLUMNS};
use crate::db::epg_repo::EpgProgramRecord;
use crate::db::{DatabaseManager, DbError, IptvItemRecord};
use rusqlite::params;

/// The profile rules on `iptv_items i` (alias `i`), with `broken_flags bf` joined.
const VISIBLE_ITEM: &str = "bf.stable_hash IS NULL \
 AND NOT EXISTS (SELECT 1 FROM hidden_items h WHERE h.profile_id = (SELECT id FROM temp.active_profile) AND h.stable_hash = i.stable_hash) \
 AND (i.group_title IS NULL OR NOT EXISTS (SELECT 1 FROM hidden_groups g WHERE g.profile_id = (SELECT id FROM temp.active_profile) AND g.kind = i.kind AND g.group_key = LOWER(TRIM(i.group_title)))) \
 AND (((SELECT show_adult FROM temp.catalog_flags) = 1 AND (SELECT kids_only FROM temp.catalog_flags) = 0) OR NOT is_adult_group(i.group_title)) \
 AND ((SELECT kids_only FROM temp.catalog_flags) = 0 OR EXISTS (SELECT 1 FROM kids_allowed_groups k WHERE k.profile_id = (SELECT id FROM temp.active_profile) AND k.kind = i.kind AND k.group_key = LOWER(TRIM(i.group_title))))";

/// The profile rules on `series_catalog sc` (alias `sc`), with `broken_flags bf` joined.
const VISIBLE_SERIES: &str = "bf.stable_hash IS NULL \
 AND (sc.group_title IS NULL OR NOT EXISTS (SELECT 1 FROM hidden_groups g WHERE g.profile_id = (SELECT id FROM temp.active_profile) AND g.kind = 'series' AND g.group_key = LOWER(TRIM(sc.group_title)))) \
 AND (((SELECT show_adult FROM temp.catalog_flags) = 1 AND (SELECT kids_only FROM temp.catalog_flags) = 0) OR NOT is_adult_group(sc.group_title)) \
 AND ((SELECT kids_only FROM temp.catalog_flags) = 0 OR EXISTS (SELECT 1 FROM kids_allowed_groups k WHERE k.profile_id = (SELECT id FROM temp.active_profile) AND k.kind = 'series' AND k.group_key = LOWER(TRIM(sc.group_title))))";

const SERIES_SELECT: &str = "SELECT sc.id, sc.source_id, sc.canonical_key, sc.stable_hash, sc.title, sc.group_title, sc.poster_url, \
 sc.backdrop_url, sc.imdb_id, sc.imdb_rating, sc.plot, sc.episode_count, sc.season_count, \
 (f.stable_hash IS NOT NULL) AS is_favorite, (bf.stable_hash IS NOT NULL) AS is_broken \
 FROM series_catalog sc \
 LEFT JOIN favorites f ON f.profile_id = (SELECT id FROM temp.active_profile) AND f.stable_hash = sc.stable_hash \
 LEFT JOIN broken_flags bf ON bf.stable_hash = sc.stable_hash";

/// ` kr ` is a word of a category such as `KR | SERIES`: separators turned into spaces, then matched whole.
fn group_has_token(column: &str) -> String {
    format!("(' ' || REPLACE(REPLACE(REPLACE(fold_text(COALESCE({column}, '')), '|', ' '), ':', ' '), '-', ' ') || ' ') LIKE ?")
}

const ITEM_JOINS: &str = "FROM iptv_items i \
 LEFT JOIN favorites f ON f.profile_id = (SELECT id FROM temp.active_profile) AND f.stable_hash = i.stable_hash \
 LEFT JOIN broken_flags bf ON bf.stable_hash = i.stable_hash \
 LEFT JOIN watch_history wh ON wh.profile_id = (SELECT id FROM temp.active_profile) AND wh.stable_hash = i.stable_hash";

/// A programme on the air in a window, with the live channel that carries it.
#[derive(Debug, Clone)]
pub struct AiringProgram {
    pub program: EpgProgramRecord,
    pub channel_id: i64,
}

impl DatabaseManager {
    /// Whether the active profile is the kids profile (no remote AI then).
    pub fn is_kids_only(&self) -> bool {
        self.with_conn(|conn| {
            let v: i64 = conn.query_row("SELECT kids_only FROM temp.catalog_flags", [], |r| r.get(0))?;
            Ok(v != 0)
        })
        .unwrap_or(true)
    }

    /// These items, in the order asked, when the profile may see them.
    pub fn visible_items_by_ids(&self, ids: &[i64]) -> Result<Vec<IptvItemRecord>, DbError> {
        if ids.is_empty() {
            return Ok(Vec::new());
        }
        self.with_conn(|conn| {
            let marks = vec!["?"; ids.len()].join(",");
            let sql = format!(
                "SELECT {ITEM_SELECT_COLUMNS} {ITEM_JOINS} WHERE i.id IN ({marks}) AND {VISIBLE_ITEM}"
            );
            let mut stmt = conn.prepare(&sql)?;
            let rows = stmt.query_map(rusqlite::params_from_iter(ids.iter()), map_item_row)?;
            let mut by_id = std::collections::HashMap::new();
            for row in rows {
                let item = row?;
                by_id.insert(item.id, item);
            }
            Ok(ids.iter().filter_map(|id| by_id.remove(id)).collect())
        })
    }

    /// `(id, cleaned name)` of every visible item of a kind: the pool for typo-tolerant matching.
    pub fn visible_name_pool(&self, kind: &str) -> Result<Vec<(i64, String)>, DbError> {
        self.with_conn(|conn| {
            let sql = format!(
                "SELECT i.id, i.name_clean {ITEM_JOINS} WHERE i.kind = ?1 AND {VISIBLE_ITEM}"
            );
            let mut stmt = conn.prepare(&sql)?;
            let rows = stmt.query_map(params![kind], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?)))?;
            let mut out = Vec::new();
            for row in rows {
                out.push(row?);
            }
            Ok(out)
        })
    }

    /// Programmes overlapping `[from, to]` whose folded title, subtitle or description holds every word,
    /// on a visible live channel. `words` are already folded (lower-case, no accent).
    pub fn search_epg(&self, words: &[String], from: i64, to: i64, limit: u32) -> Result<Vec<AiringProgram>, DbError> {
        self.with_conn(|conn| {
            let mut clauses = String::new();
            for _ in words {
                clauses.push_str(
                    " AND (fold_text(e.title) LIKE ? ESCAPE '\\' OR fold_text(COALESCE(e.subtitle,'')) LIKE ? ESCAPE '\\' \
                     OR fold_text(COALESCE(e.description,'')) LIKE ? ESCAPE '\\' OR fold_text(COALESCE(e.category,'')) LIKE ? ESCAPE '\\')",
                );
            }
            let sql = format!(
                "SELECT e.id, e.channel_tvg_id, e.start_ts, e.end_ts, e.title, e.subtitle, e.description, e.category, i.id \
                 {ITEM_JOINS} \
                 JOIN epg_programs e ON e.channel_tvg_id = i.tvg_id \
                 WHERE i.kind = 'live' AND e.end_ts > ?1 AND e.start_ts < ?2 AND {VISIBLE_ITEM}{clauses} \
                 ORDER BY e.start_ts ASC LIMIT ?"
            );
            let mut values: Vec<rusqlite::types::Value> = vec![from.into(), to.into()];
            for word in words {
                let pattern = format!("%{}%", word.replace('\\', "\\\\").replace('%', "\\%").replace('_', "\\_"));
                for _ in 0..4 {
                    values.push(pattern.clone().into());
                }
            }
            values.push((limit as i64).into());
            let mut stmt = conn.prepare(&sql)?;
            let rows = stmt.query_map(rusqlite::params_from_iter(values.iter()), |r| {
                Ok(AiringProgram {
                    program: EpgProgramRecord {
                        id: r.get(0)?,
                        channel_tvg_id: r.get(1)?,
                        start_ts: r.get(2)?,
                        end_ts: r.get(3)?,
                        title: r.get(4)?,
                        subtitle: r.get(5)?,
                        description: r.get(6)?,
                        category: r.get(7)?,
                        progress_ratio: 0.0,
                    },
                    channel_id: r.get(8)?,
                })
            })?;
            let mut out = Vec::new();
            for row in rows {
                out.push(row?);
            }
            Ok(out)
        })
    }

    /// Movies or series whose cached OMDb metadata names these genres, people, or country.
    /// Every given group must match (any of its words); empty groups are ignored.
    pub fn search_by_metadata(
        &self,
        kind: &str,
        genres: &[String],
        people: &[String],
        countries: &[String],
        limit: u32,
    ) -> Result<Vec<i64>, DbError> {
        if genres.is_empty() && people.is_empty() && countries.is_empty() {
            return Ok(Vec::new());
        }
        self.with_conn(|conn| {
            let mut sql = format!(
                "SELECT DISTINCT i.id {ITEM_JOINS} \
                 JOIN media_metadata_cache m ON (i.imdb_id IS NOT NULL AND i.imdb_id = m.imdb_id) \
                   OR m.lookup_key = i.kind || ':' || LOWER(TRIM(i.name_clean)) \
                   OR m.lookup_key = i.kind || ':' || LOWER(TRIM(i.name_clean)) || ':' || COALESCE(i.year, 0) \
                 WHERE i.kind = ?1 AND {VISIBLE_ITEM}"
            );
            let mut values: Vec<rusqlite::types::Value> = vec![kind.to_string().into()];
            let mut group = |sql: &mut String, words: &[String], columns: &[&str]| {
                if words.is_empty() {
                    return;
                }
                sql.push_str(" AND (");
                let mut first = true;
                for word in words {
                    for column in columns {
                        if !first {
                            sql.push_str(" OR ");
                        }
                        first = false;
                        sql.push_str(&format!("fold_text(COALESCE(m.{column},'')) LIKE ?"));
                        values.push(format!("%{word}%").into());
                    }
                }
                sql.push(')');
            };
            group(&mut sql, genres, &["genres"]);
            group(&mut sql, people, &["actors", "director"]);
            group(&mut sql, countries, &["country", "language"]);
            sql.push_str(" ORDER BY i.imdb_rating DESC LIMIT ?");
            values.push((limit as i64).into());
            let mut stmt = conn.prepare(&sql)?;
            let rows = stmt.query_map(rusqlite::params_from_iter(values.iter()), |r| r.get::<_, i64>(0))?;
            let mut out = Vec::new();
            for row in rows {
                out.push(row?);
            }
            Ok(out)
        })
    }

    /// Series whose folded title holds every word (the stock `query_series` looks for the whole phrase).
    pub fn search_series_words(&self, words: &[String], limit: u32) -> Result<Vec<SeriesRecord>, DbError> {
        if words.is_empty() {
            return Ok(Vec::new());
        }
        self.with_conn(|conn| {
            let mut sql = format!("{SERIES_SELECT} WHERE {VISIBLE_SERIES}");
            let mut values: Vec<rusqlite::types::Value> = Vec::new();
            for word in words {
                sql.push_str(" AND fold_text(sc.title) LIKE ? ESCAPE '\\'");
                values.push(format!("%{}%", word.replace('\\', "\\\\").replace('%', "\\%").replace('_', "\\_")).into());
            }
            sql.push_str(" ORDER BY sc.imdb_rating DESC, sc.title COLLATE NOCASE LIMIT ?");
            values.push((limit as i64).into());
            let mut stmt = conn.prepare(&sql)?;
            let rows = stmt.query_map(rusqlite::params_from_iter(values.iter()), map_series_row)?;
            let mut out = Vec::new();
            for row in rows {
                out.push(row?);
            }
            Ok(out)
        })
    }

    /// Series of the categories that carry one of these words (`romance`, `kr`), best rated first.
    pub fn browse_series(&self, group_words: &[String], limit: u32) -> Result<Vec<SeriesRecord>, DbError> {
        if group_words.is_empty() {
            return Ok(Vec::new());
        }
        self.with_conn(|conn| {
            let mut sql = format!("{SERIES_SELECT} WHERE {VISIBLE_SERIES} AND (");
            let mut values: Vec<rusqlite::types::Value> = Vec::new();
            for (i, word) in group_words.iter().enumerate() {
                if i > 0 {
                    sql.push_str(" OR ");
                }
                sql.push_str(&group_has_token("sc.group_title"));
                values.push(format!("% {word} %").into());
            }
            sql.push_str(") ORDER BY sc.imdb_rating DESC, sc.title COLLATE NOCASE LIMIT ?");
            values.push((limit as i64).into());
            let mut stmt = conn.prepare(&sql)?;
            let rows = stmt.query_map(rusqlite::params_from_iter(values.iter()), map_series_row)?;
            let mut out = Vec::new();
            for row in rows {
                out.push(row?);
            }
            Ok(out)
        })
    }

    /// Items of a kind from a year range and/or categories carrying one of the words, best rated first:
    /// "films de 2019", "films coréens".
    pub fn browse_items(
        &self,
        kind: &str,
        year_from: Option<u32>,
        year_to: Option<u32>,
        group_words: &[String],
        limit: u32,
    ) -> Result<Vec<IptvItemRecord>, DbError> {
        self.with_conn(|conn| {
            let mut sql = format!("SELECT {ITEM_SELECT_COLUMNS} {ITEM_JOINS} WHERE i.kind = ? AND {VISIBLE_ITEM}");
            let mut values: Vec<rusqlite::types::Value> = vec![kind.to_string().into()];
            if let Some(from) = year_from {
                sql.push_str(" AND i.year >= ?");
                values.push((from as i64).into());
            }
            if let Some(to) = year_to {
                sql.push_str(" AND i.year <= ?");
                values.push((to as i64).into());
            }
            if !group_words.is_empty() {
                sql.push_str(" AND (");
                for (i, word) in group_words.iter().enumerate() {
                    if i > 0 {
                        sql.push_str(" OR ");
                    }
                    sql.push_str(&group_has_token("i.group_title"));
                    values.push(format!("% {word} %").into());
                }
                sql.push(')');
            }
            sql.push_str(" ORDER BY i.imdb_rating DESC, i.name COLLATE NOCASE LIMIT ?");
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
}
