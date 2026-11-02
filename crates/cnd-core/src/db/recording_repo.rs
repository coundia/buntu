use crate::db::{DatabaseManager, DbError};
use rusqlite::params;
use serde::{Deserialize, Serialize};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct RecordingRecord {
    pub id: i64,
    pub item_id: i64,
    pub channel_tvg_id: Option<String>,
    pub channel_name: String,
    pub title: String,
    pub subtitle: Option<String>,
    pub stream_url: String,
    pub start_ts: i64,
    pub end_ts: i64,
    pub pre_padding_s: u32,
    pub post_padding_s: u32,
    pub state: String,
    pub file_path: Option<String>,
    pub bytes_written: u64,
    pub rule_id: Option<i64>,
    pub error: Option<String>,
    pub created_at: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct SeriesRuleRecord {
    pub id: i64,
    pub channel_tvg_id: Option<String>,
    pub title_key: String,
    pub created_at: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct NewRecordingRequest {
    pub item_id: i64,
    pub channel_tvg_id: Option<String>,
    pub channel_name: String,
    pub title: String,
    pub subtitle: Option<String>,
    pub stream_url: String,
    pub start_ts: i64,
    pub end_ts: i64,
    pub pre_padding_s: Option<u32>,
    pub post_padding_s: Option<u32>,
    pub rule_id: Option<i64>,
}

fn now_epoch_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}

pub fn normalize_title_key(title: &str) -> String {
    title
        .trim()
        .to_lowercase()
        .chars()
        .filter(|c| c.is_alphanumeric() || c.is_whitespace())
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

impl DatabaseManager {
    pub fn insert_recording(&self, req: &NewRecordingRequest) -> Result<i64, DbError> {
        let conn = self.conn.lock().unwrap();
        let created_at = now_epoch_secs();
        let pre = req.pre_padding_s.unwrap_or(120);
        let post = req.post_padding_s.unwrap_or(300);

        conn.execute(
            "INSERT INTO recordings (
                item_id, channel_tvg_id, channel_name, title, subtitle, stream_url,
                start_ts, end_ts, pre_padding_s, post_padding_s, state, rule_id, created_at
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, 'scheduled', ?11, ?12)",
            params![
                req.item_id,
                req.channel_tvg_id,
                req.channel_name,
                req.title,
                req.subtitle,
                req.stream_url,
                req.start_ts,
                req.end_ts,
                pre,
                post,
                req.rule_id,
                created_at,
            ],
        )?;

        Ok(conn.last_insert_rowid())
    }

    pub fn get_recording(&self, id: i64) -> Result<Option<RecordingRecord>, DbError> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT id, item_id, channel_tvg_id, channel_name, title, subtitle, stream_url,
                    start_ts, end_ts, pre_padding_s, post_padding_s, state, file_path,
                    bytes_written, rule_id, error, created_at
             FROM recordings WHERE id = ?1",
        )?;

        let mut rows = stmt.query(params![id])?;
        if let Some(row) = rows.next()? {
            let bytes: i64 = row.get(13)?;
            Ok(Some(RecordingRecord {
                id: row.get(0)?,
                item_id: row.get(1)?,
                channel_tvg_id: row.get(2)?,
                channel_name: row.get(3)?,
                title: row.get(4)?,
                subtitle: row.get(5)?,
                stream_url: row.get(6)?,
                start_ts: row.get(7)?,
                end_ts: row.get(8)?,
                pre_padding_s: row.get(9)?,
                post_padding_s: row.get(10)?,
                state: row.get(11)?,
                file_path: row.get(12)?,
                bytes_written: bytes.max(0) as u64,
                rule_id: row.get(14)?,
                error: row.get(15)?,
                created_at: row.get(16)?,
            }))
        } else {
            Ok(None)
        }
    }

    pub fn list_recordings(&self, state_filter: Option<&str>) -> Result<Vec<RecordingRecord>, DbError> {
        let conn = self.conn.lock().unwrap();
        let mut res = Vec::new();

        if let Some(state) = state_filter {
            let mut stmt = conn.prepare(
                "SELECT id, item_id, channel_tvg_id, channel_name, title, subtitle, stream_url,
                        start_ts, end_ts, pre_padding_s, post_padding_s, state, file_path,
                        bytes_written, rule_id, error, created_at
                 FROM recordings WHERE state = ?1 ORDER BY start_ts DESC",
            )?;
            let rows = stmt.query_map(params![state], |r| self.map_recording_row(r))?;
            for r in rows {
                res.push(r?);
            }
        } else {
            let mut stmt = conn.prepare(
                "SELECT id, item_id, channel_tvg_id, channel_name, title, subtitle, stream_url,
                        start_ts, end_ts, pre_padding_s, post_padding_s, state, file_path,
                        bytes_written, rule_id, error, created_at
                 FROM recordings ORDER BY start_ts DESC",
            )?;
            let rows = stmt.query_map([], |r| self.map_recording_row(r))?;
            for r in rows {
                res.push(r?);
            }
        }

        Ok(res)
    }

    fn map_recording_row(&self, row: &rusqlite::Row) -> rusqlite::Result<RecordingRecord> {
        let bytes: i64 = row.get(13)?;
        Ok(RecordingRecord {
            id: row.get(0)?,
            item_id: row.get(1)?,
            channel_tvg_id: row.get(2)?,
            channel_name: row.get(3)?,
            title: row.get(4)?,
            subtitle: row.get(5)?,
            stream_url: row.get(6)?,
            start_ts: row.get(7)?,
            end_ts: row.get(8)?,
            pre_padding_s: row.get(9)?,
            post_padding_s: row.get(10)?,
            state: row.get(11)?,
            file_path: row.get(12)?,
            bytes_written: bytes.max(0) as u64,
            rule_id: row.get(14)?,
            error: row.get(15)?,
            created_at: row.get(16)?,
        })
    }

    pub fn update_recording_state(
        &self,
        id: i64,
        state: &str,
        bytes_written: u64,
        file_path: Option<&str>,
        error: Option<&str>,
    ) -> Result<(), DbError> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "UPDATE recordings
             SET state = ?1, bytes_written = ?2, file_path = COALESCE(?3, file_path), error = ?4
             WHERE id = ?5",
            params![state, bytes_written as i64, file_path, error, id],
        )?;
        Ok(())
    }

    pub fn cancel_recording(&self, id: i64) -> Result<bool, DbError> {
        let conn = self.conn.lock().unwrap();
        let changed = conn.execute(
            "UPDATE recordings SET state = 'cancelled' WHERE id = ?1 AND state IN ('scheduled', 'recording')",
            params![id],
        )?;
        Ok(changed > 0)
    }

    pub fn delete_recording(&self, id: i64) -> Result<Option<String>, DbError> {
        let conn = self.conn.lock().unwrap();
        let path: Option<String> = conn
            .query_row(
                "SELECT file_path FROM recordings WHERE id = ?1",
                params![id],
                |r| r.get(0),
            )
            .ok();

        conn.execute("DELETE FROM recordings WHERE id = ?1", params![id])?;
        Ok(path)
    }

    pub fn get_due_recordings(&self, now_ts: i64) -> Result<Vec<RecordingRecord>, DbError> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT id, item_id, channel_tvg_id, channel_name, title, subtitle, stream_url,
                    start_ts, end_ts, pre_padding_s, post_padding_s, state, file_path,
                    bytes_written, rule_id, error, created_at
             FROM recordings
             WHERE state = 'scheduled' AND (start_ts - pre_padding_s) <= ?1
             ORDER BY start_ts ASC",
        )?;

        let rows = stmt.query_map(params![now_ts], |r| self.map_recording_row(r))?;
        let mut res = Vec::new();
        for r in rows {
            res.push(r?);
        }
        Ok(res)
    }

    pub fn reap_missed_recordings(&self, now_ts: i64) -> Result<u32, DbError> {
        let conn = self.conn.lock().unwrap();
        let count = conn.execute(
            "UPDATE recordings
             SET state = 'failed', error = 'Enregistrement manqué : application fermée à l heure prévue'
             WHERE state = 'scheduled' AND (end_ts + post_padding_s) < ?1",
            params![now_ts],
        )?;
        Ok(count as u32)
    }

    pub fn is_program_scheduled(&self, channel_tvg_id: Option<&str>, start_ts: i64) -> Result<bool, DbError> {
        let conn = self.conn.lock().unwrap();
        let count: i64 = match channel_tvg_id {
            Some(tvg_id) => conn.query_row(
                "SELECT COUNT(*) FROM recordings WHERE channel_tvg_id = ?1 AND start_ts = ?2 AND state IN ('scheduled', 'recording')",
                params![tvg_id, start_ts],
                |r| r.get(0),
            )?,
            None => 0,
        };
        Ok(count > 0)
    }

    // MARK: - Series Rules

    pub fn add_series_rule(&self, channel_tvg_id: Option<&str>, title: &str) -> Result<i64, DbError> {
        let conn = self.conn.lock().unwrap();
        let title_key = normalize_title_key(title);
        let created_at = now_epoch_secs();

        conn.execute(
            "INSERT INTO recording_series_rules (channel_tvg_id, title_key, created_at)
             VALUES (?1, ?2, ?3)",
            params![channel_tvg_id, title_key, created_at],
        )?;

        Ok(conn.last_insert_rowid())
    }

    pub fn remove_series_rule(&self, id: i64) -> Result<bool, DbError> {
        let conn = self.conn.lock().unwrap();
        let count = conn.execute(
            "DELETE FROM recording_series_rules WHERE id = ?1",
            params![id],
        )?;
        Ok(count > 0)
    }

    pub fn list_series_rules(&self) -> Result<Vec<SeriesRuleRecord>, DbError> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT id, channel_tvg_id, title_key, created_at FROM recording_series_rules ORDER BY id DESC"
        )?;

        let rows = stmt.query_map([], |r| {
            Ok(SeriesRuleRecord {
                id: r.get(0)?,
                channel_tvg_id: r.get(1)?,
                title_key: r.get(2)?,
                created_at: r.get(3)?,
            })
        })?;

        let mut res = Vec::new();
        for r in rows {
            res.push(r?);
        }
        Ok(res)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_recordings_crud_and_reap() {
        let db = DatabaseManager::open_in_memory().unwrap();

        let req = NewRecordingRequest {
            item_id: 42,
            channel_tvg_id: Some("tf1.fr".to_string()),
            channel_name: "TF1 HD".to_string(),
            title: "Le Journal de 20h".to_string(),
            subtitle: Some("Édition spéciale".to_string()),
            stream_url: "http://stream.example/live.ts".to_string(),
            start_ts: 1000,
            end_ts: 2000,
            pre_padding_s: Some(60),
            post_padding_s: Some(120),
            rule_id: None,
        };

        let id = db.insert_recording(&req).unwrap();
        let rec = db.get_recording(id).unwrap().expect("record found");
        assert_eq!(rec.title, "Le Journal de 20h");
        assert_eq!(rec.state, "scheduled");
        assert_eq!(rec.pre_padding_s, 60);

        assert!(db.is_program_scheduled(Some("tf1.fr"), 1000).unwrap());
        assert!(!db.is_program_scheduled(Some("tf1.fr"), 9999).unwrap());

        // Update state to recording
        db.update_recording_state(id, "recording", 5000, Some("/tmp/rec.ts"), None).unwrap();
        let rec2 = db.get_recording(id).unwrap().unwrap();
        assert_eq!(rec2.state, "recording");
        assert_eq!(rec2.bytes_written, 5000);
        assert_eq!(rec2.file_path.as_deref(), Some("/tmp/rec.ts"));

        // Missed recordings reap test
        let past_req = NewRecordingRequest {
            item_id: 43,
            channel_tvg_id: Some("m6.fr".to_string()),
            channel_name: "M6".to_string(),
            title: "Zone Interdite".to_string(),
            subtitle: None,
            stream_url: "http://stream.example/m6.ts".to_string(),
            start_ts: 500,
            end_ts: 800,
            pre_padding_s: Some(0),
            post_padding_s: Some(0),
            rule_id: None,
        };
        let past_id = db.insert_recording(&past_req).unwrap();

        let reaped = db.reap_missed_recordings(1500).unwrap();
        assert_eq!(reaped, 1);

        let past_rec = db.get_recording(past_id).unwrap().unwrap();
        assert_eq!(past_rec.state, "failed");
        assert!(past_rec.error.unwrap().contains("manqué"));

        // Series rule test
        let rule_id = db.add_series_rule(Some("tf1.fr"), "Le Journal de 20h").unwrap();
        let rules = db.list_series_rules().unwrap();
        assert_eq!(rules.len(), 1);
        assert_eq!(rules[0].title_key, "le journal de 20h");

        assert!(db.remove_series_rule(rule_id).unwrap());
        assert_eq!(db.list_series_rules().unwrap().len(), 0);
    }
}
