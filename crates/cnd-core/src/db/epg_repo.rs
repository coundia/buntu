use crate::db::{chrono_now_ts, DatabaseManager, DbError};
use crate::iptv::epg::{parse_epg_shift_seconds, ParsedEpgProgram};
use rusqlite::{params, OptionalExtension};
use std::collections::HashMap;

#[derive(Debug, Clone, uniffi::Record)]
pub struct EpgProgramRecord {
    pub id: i64,
    pub channel_tvg_id: String,
    pub start_ts: i64,
    pub end_ts: i64,
    pub title: String,
    pub subtitle: Option<String>,
    pub description: Option<String>,
    pub category: Option<String>,
    pub progress_ratio: f64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct ChannelNowNext {
    pub channel_tvg_id: String,
    pub now: Option<EpgProgramRecord>,
    pub next: Option<EpgProgramRecord>,
}

#[inline]
pub fn compute_progress_ratio(start_ts: i64, end_ts: i64, now_ts: i64) -> f64 {
    if now_ts <= start_ts {
        0.0
    } else if now_ts >= end_ts {
        1.0
    } else {
        let span = (end_ts - start_ts).max(1) as f64;
        ((now_ts - start_ts) as f64 / span).clamp(0.0, 1.0)
    }
}

impl DatabaseManager {
    /// Loads known `tvg_id -> epg_shift_seconds` from `iptv_items` (optionally scoped or global).
    pub fn load_known_tvg_channels(&self, source_id: Option<i64>) -> Result<HashMap<String, i64>, DbError> {
        self.with_conn(|conn| {
            let mut map = HashMap::new();
            if let Some(sid) = source_id {
                let mut stmt = conn.prepare(
                    "SELECT DISTINCT tvg_id, epg_shift
                     FROM iptv_items
                     WHERE source_id = ?1 AND tvg_id IS NOT NULL AND TRIM(tvg_id) != ''",
                )?;
                let rows = stmt.query_map(params![sid], |r| {
                    Ok((r.get::<_, String>(0)?, r.get::<_, Option<String>>(1)?))
                })?;
                for row in rows {
                    let (tvg_id, shift_raw) = row?;
                    map.insert(tvg_id, parse_epg_shift_seconds(shift_raw.as_deref()));
                }
            } else {
                let mut stmt = conn.prepare(
                    "SELECT DISTINCT tvg_id, epg_shift
                     FROM iptv_items
                     WHERE tvg_id IS NOT NULL AND TRIM(tvg_id) != ''",
                )?;
                let rows = stmt.query_map([], |r| {
                    Ok((r.get::<_, String>(0)?, r.get::<_, Option<String>>(1)?))
                })?;
                for row in rows {
                    let (tvg_id, shift_raw) = row?;
                    map.insert(tvg_id, parse_epg_shift_seconds(shift_raw.as_deref()));
                }
            }
            Ok(map)
        })
    }

    pub fn purge_expired_epg(&self, older_than_ts: i64) -> Result<usize, DbError> {
        self.with_conn(|conn| {
            let removed = conn.execute(
                "DELETE FROM epg_programs WHERE end_ts < ?1",
                params![older_than_ts],
            )?;
            Ok(removed)
        })
    }

    pub fn insert_epg_batch(&self, batch: &[ParsedEpgProgram]) -> Result<(), DbError> {
        if batch.is_empty() {
            return Ok(());
        }
        self.with_conn_mut(|conn| {
            let tx = conn.transaction()?;
            {
                let mut stmt = tx.prepare_cached(
                    "INSERT OR REPLACE INTO epg_programs (
                        channel_tvg_id, start_ts, end_ts, title, subtitle, description, category
                    ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                )?;
                for p in batch {
                    stmt.execute(params![
                        p.channel_tvg_id,
                        p.start_ts,
                        p.end_ts,
                        p.title,
                        p.subtitle,
                        p.description,
                        p.category
                    ])?;
                }
            }
            tx.commit()?;
            Ok(())
        })
    }

    pub fn get_epg_now_next(&self, tvg_ids: &[String]) -> Result<Vec<ChannelNowNext>, DbError> {
        self.get_epg_now_next_at(tvg_ids, chrono_now_ts())
    }

    pub fn get_epg_now_next_at(
        &self,
        tvg_ids: &[String],
        now_ts: i64,
    ) -> Result<Vec<ChannelNowNext>, DbError> {
        if tvg_ids.is_empty() {
            return Ok(Vec::new());
        }

        self.with_conn(|conn| {
            let mut now_stmt = conn.prepare_cached(
                "SELECT id, channel_tvg_id, start_ts, end_ts, title, subtitle, description, category
                 FROM epg_programs
                 WHERE channel_tvg_id = ?1 AND start_ts <= ?2 AND end_ts > ?2
                 ORDER BY start_ts DESC
                 LIMIT 1",
            )?;

            let mut next_stmt = conn.prepare_cached(
                "SELECT id, channel_tvg_id, start_ts, end_ts, title, subtitle, description, category
                 FROM epg_programs
                 WHERE channel_tvg_id = ?1 AND start_ts >= ?2
                 ORDER BY start_ts ASC
                 LIMIT 1",
            )?;

            let mut results = Vec::with_capacity(tvg_ids.len());
            for tvg_id in tvg_ids {
                if tvg_id.trim().is_empty() {
                    continue;
                }
                let now_prog = now_stmt
                    .query_row(params![tvg_id, now_ts], |r| map_epg_row(r, now_ts))
                    .optional()?;

                let next_pivot = now_prog.as_ref().map(|p| p.end_ts).unwrap_or(now_ts);
                let next_prog = next_stmt
                    .query_row(params![tvg_id, next_pivot], |r| map_epg_row(r, now_ts))
                    .optional()?;

                results.push(ChannelNowNext {
                    channel_tvg_id: tvg_id.clone(),
                    now: now_prog,
                    next: next_prog,
                });
            }

            Ok(results)
        })
    }

    pub fn get_channel_epg(
        &self,
        tvg_id: &str,
        from_ts: i64,
        to_ts: i64,
    ) -> Result<Vec<EpgProgramRecord>, DbError> {
        self.get_channel_epg_at(tvg_id, from_ts, to_ts, chrono_now_ts())
    }

    pub fn get_channel_epg_at(
        &self,
        tvg_id: &str,
        from_ts: i64,
        to_ts: i64,
        now_ts: i64,
    ) -> Result<Vec<EpgProgramRecord>, DbError> {
        self.with_conn(|conn| {
            let mut stmt = conn.prepare_cached(
                "SELECT id, channel_tvg_id, start_ts, end_ts, title, subtitle, description, category
                 FROM epg_programs
                 WHERE channel_tvg_id = ?1 AND end_ts > ?2 AND start_ts < ?3
                 ORDER BY start_ts ASC",
            )?;
            let rows = stmt.query_map(params![tvg_id, from_ts, to_ts], |r| map_epg_row(r, now_ts))?;
            let mut out = Vec::new();
            for row in rows {
                out.push(row?);
            }
            Ok(out)
        })
    }
}

fn map_epg_row(r: &rusqlite::Row<'_>, now_ts: i64) -> rusqlite::Result<EpgProgramRecord> {
    let start_ts: i64 = r.get(2)?;
    let end_ts: i64 = r.get(3)?;
    Ok(EpgProgramRecord {
        id: r.get(0)?,
        channel_tvg_id: r.get(1)?,
        start_ts,
        end_ts,
        title: r.get(4)?,
        subtitle: r.get(5)?,
        description: r.get(6)?,
        category: r.get(7)?,
        progress_ratio: compute_progress_ratio(start_ts, end_ts, now_ts),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_epg_now_next_and_progress_ratio() {
        let db = DatabaseManager::open_in_memory().expect("open memory db");
        let batch = vec![
            ParsedEpgProgram {
                channel_tvg_id: "arte.fr".to_string(),
                start_ts: 1_000,
                end_ts: 2_000,
                title: "28 Minutes".to_string(),
                subtitle: Some("Débat".to_string()),
                description: Some("Magazine d'actualité".to_string()),
                category: Some("Talk".to_string()),
            },
            ParsedEpgProgram {
                channel_tvg_id: "arte.fr".to_string(),
                start_ts: 2_000,
                end_ts: 5_600,
                title: "Le Cinéma d'ARTE".to_string(),
                subtitle: None,
                description: None,
                category: Some("Movie".to_string()),
            },
        ];

        db.insert_epg_batch(&batch).expect("insert epg");

        // At now_ts = 1_250, 28 Minutes is 25% elapsed (progress_ratio = 0.25)
        let res = db
            .get_epg_now_next_at(&["arte.fr".to_string()], 1_250)
            .expect("now next");
        assert_eq!(res.len(), 1);
        let now_p = res[0].now.as_ref().expect("now program");
        let next_p = res[0].next.as_ref().expect("next program");
        assert_eq!(now_p.title, "28 Minutes");
        assert!((now_p.progress_ratio - 0.25).abs() < 1e-6);
        assert_eq!(next_p.title, "Le Cinéma d'ARTE");
        assert!((next_p.progress_ratio - 0.0).abs() < 1e-6);

        let timeline = db
            .get_channel_epg_at("arte.fr", 900, 6_000, 1_250)
            .expect("timeline");
        assert_eq!(timeline.len(), 2);
    }
}

