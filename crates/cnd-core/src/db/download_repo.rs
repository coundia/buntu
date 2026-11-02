use crate::db::{chrono_now_ts, DatabaseManager, DbError};
use rusqlite::{params, Connection, OptionalExtension};

#[derive(Debug, Clone, uniffi::Record)]
pub struct NewDownloadRequest {
    pub url: String,
    pub file_name: Option<String>,
    pub save_dir: String,
    pub user_agent: Option<String>,
    pub referer: Option<String>,
    pub headers_json: Option<String>,
    pub auto_start: bool,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct DownloadPartRecord {
    pub part_index: u32,
    pub byte_start: u64,
    pub byte_end: u64,
    pub downloaded_bytes: u64,
    pub state: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct DownloadTaskRecord {
    pub id: i64,
    pub url: String,
    pub file_name: String,
    pub save_path: String,
    pub total_bytes: u64,
    pub downloaded_bytes: u64,
    pub accept_ranges: bool,
    pub state: String,
    pub speed_bps: f64,
    pub eta_seconds: u64,
    pub parts: Vec<DownloadPartRecord>,
    pub updated_at: i64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct DownloadLogRecord {
    pub id: i64,
    pub timestamp: i64,
    pub level: String,
    pub message: String,
}

/// Internal full row of `download_tasks` (includes request headers and temp path).
#[derive(Debug, Clone)]
pub struct DownloadTaskRow {
    pub id: i64,
    pub url: String,
    pub last_real_url: Option<String>,
    pub referer: Option<String>,
    pub user_agent: Option<String>,
    pub headers_json: Option<String>,
    pub file_name: String,
    pub save_path: String,
    pub temp_path: String,
    pub total_bytes: u64,
    pub downloaded_bytes: u64,
    pub accept_ranges: bool,
    pub state: String,
}

#[derive(Debug, Clone)]
pub struct NewPart {
    pub part_index: u32,
    pub byte_start: u64,
    pub byte_end: u64,
}

#[derive(Debug, Clone)]
pub struct PartProgress {
    pub part_index: u32,
    pub downloaded_bytes: u64,
    pub state: &'static str,
}

const TASK_COLUMNS: &str = "id, url, last_real_url, referer, user_agent, headers_json, file_name, \
     save_path, temp_path, total_bytes, downloaded_bytes, accept_ranges, state";

fn map_task_row(r: &rusqlite::Row<'_>) -> rusqlite::Result<DownloadTaskRow> {
    Ok(DownloadTaskRow {
        id: r.get(0)?,
        url: r.get(1)?,
        last_real_url: r.get(2)?,
        referer: r.get(3)?,
        user_agent: r.get(4)?,
        headers_json: r.get(5)?,
        file_name: r.get(6)?,
        save_path: r.get(7)?,
        temp_path: r.get(8)?,
        total_bytes: r.get::<_, Option<i64>>(9)?.unwrap_or(0).max(0) as u64,
        downloaded_bytes: r.get::<_, Option<i64>>(10)?.unwrap_or(0).max(0) as u64,
        accept_ranges: r.get::<_, Option<i64>>(11)?.unwrap_or(0) != 0,
        state: r.get(12)?,
    })
}

fn load_parts(conn: &Connection, task_id: i64) -> Result<Vec<DownloadPartRecord>, DbError> {
    let mut stmt = conn.prepare_cached(
        "SELECT part_index, byte_start, byte_end, downloaded_bytes, state
         FROM download_parts WHERE task_id = ?1 ORDER BY part_index",
    )?;
    let rows = stmt.query_map(params![task_id], |r| {
        Ok(DownloadPartRecord {
            part_index: r.get(0)?,
            byte_start: r.get::<_, i64>(1)?.max(0) as u64,
            byte_end: r.get::<_, i64>(2)?.max(0) as u64,
            downloaded_bytes: r.get::<_, Option<i64>>(3)?.unwrap_or(0).max(0) as u64,
            state: r.get(4)?,
        })
    })?;
    let mut parts = Vec::new();
    for p in rows {
        parts.push(p?);
    }
    Ok(parts)
}

impl DatabaseManager {
    #[allow(clippy::too_many_arguments)]
    pub fn create_download_task(
        &self,
        url: &str,
        last_real_url: Option<&str>,
        referer: Option<&str>,
        user_agent: Option<&str>,
        headers_json: Option<&str>,
        file_name: &str,
        save_path: &str,
        temp_path: &str,
        total_bytes: u64,
        accept_ranges: bool,
    ) -> Result<i64, DbError> {
        self.with_conn(|conn| {
            let now = chrono_now_ts();
            conn.execute(
                "INSERT INTO download_tasks
                    (url, last_real_url, referer, user_agent, headers_json, file_name, save_path,
                     temp_path, total_bytes, accept_ranges, state, created_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, 'paused', ?11, ?11)",
                params![
                    url,
                    last_real_url,
                    referer,
                    user_agent,
                    headers_json,
                    file_name,
                    save_path,
                    temp_path,
                    total_bytes as i64,
                    accept_ranges as i64,
                    now
                ],
            )?;
            Ok(conn.last_insert_rowid())
        })
    }

    pub fn get_download_task_row(&self, task_id: i64) -> Result<DownloadTaskRow, DbError> {
        self.with_conn(|conn| {
            conn.query_row(
                &format!("SELECT {TASK_COLUMNS} FROM download_tasks WHERE id = ?1"),
                params![task_id],
                map_task_row,
            )
            .optional()?
            .ok_or_else(|| DbError::NotFound(format!("download task id={task_id}")))
        })
    }

    pub fn list_download_task_rows(&self) -> Result<Vec<DownloadTaskRow>, DbError> {
        self.with_conn(|conn| {
            let mut stmt = conn.prepare(&format!(
                "SELECT {TASK_COLUMNS} FROM download_tasks ORDER BY id DESC"
            ))?;
            let rows = stmt.query_map([], map_task_row)?;
            let mut list = Vec::new();
            for r in rows {
                list.push(r?);
            }
            Ok(list)
        })
    }

    pub fn list_downloads_with_parts(
        &self,
        query: Option<&str>,
    ) -> Result<Vec<DownloadTaskRecord>, DbError> {
        let needle = query
            .map(|q| q.trim().to_lowercase())
            .filter(|q| !q.is_empty());
        self.with_conn(|conn| {
            let mut stmt = conn.prepare(
                "SELECT id, url, file_name, save_path, total_bytes, downloaded_bytes, accept_ranges,
                        state, speed_bps, eta_seconds, updated_at
                 FROM download_tasks ORDER BY id DESC",
            )?;
            let rows = stmt.query_map([], |r| {
                Ok(DownloadTaskRecord {
                    id: r.get(0)?,
                    url: r.get(1)?,
                    file_name: r.get(2)?,
                    save_path: r.get(3)?,
                    total_bytes: r.get::<_, Option<i64>>(4)?.unwrap_or(0).max(0) as u64,
                    downloaded_bytes: r.get::<_, Option<i64>>(5)?.unwrap_or(0).max(0) as u64,
                    accept_ranges: r.get::<_, Option<i64>>(6)?.unwrap_or(0) != 0,
                    state: r.get(7)?,
                    speed_bps: r.get::<_, Option<f64>>(8)?.unwrap_or(0.0),
                    eta_seconds: r.get::<_, Option<i64>>(9)?.unwrap_or(0).max(0) as u64,
                    parts: Vec::new(),
                    updated_at: r.get(10)?,
                })
            })?;
            let mut list = Vec::new();
            for r in rows {
                let mut task = r?;
                if let Some(ref n) = needle {
                    if !task.file_name.to_lowercase().contains(n)
                        && !task.url.to_lowercase().contains(n)
                    {
                        continue;
                    }
                }
                task.parts = load_parts(conn, task.id)?;
                list.push(task);
            }
            Ok(list)
        })
    }

    pub fn list_download_parts(&self, task_id: i64) -> Result<Vec<DownloadPartRecord>, DbError> {
        self.with_conn(|conn| load_parts(conn, task_id))
    }

    pub fn is_download_path_taken(&self, save_path: &str) -> Result<bool, DbError> {
        self.with_conn(|conn| {
            Ok(conn.query_row(
                "SELECT EXISTS(SELECT 1 FROM download_tasks WHERE save_path = ?1 OR temp_path = ?1)",
                params![save_path],
                |r| r.get(0),
            )?)
        })
    }

    pub fn set_download_state(&self, task_id: i64, state: &str) -> Result<(), DbError> {
        self.with_conn(|conn| {
            conn.execute(
                "UPDATE download_tasks SET state = ?2, updated_at = ?3,
                        speed_bps = CASE WHEN ?2 = 'running' THEN speed_bps ELSE 0 END,
                        eta_seconds = CASE WHEN ?2 = 'running' THEN eta_seconds ELSE 0 END
                 WHERE id = ?1",
                params![task_id, state, chrono_now_ts()],
            )?;
            Ok(())
        })
    }

    /// Moves a task to `paused` only if it is still `queued` or `running`.
    pub fn pause_download_state(&self, task_id: i64) -> Result<(), DbError> {
        self.with_conn(|conn| {
            conn.execute(
                "UPDATE download_tasks SET state = 'paused', speed_bps = 0, eta_seconds = 0,
                        updated_at = ?2
                 WHERE id = ?1 AND state IN ('queued', 'running')",
                params![task_id, chrono_now_ts()],
            )?;
            Ok(())
        })
    }

    pub fn update_download_probe(
        &self,
        task_id: i64,
        last_real_url: &str,
        total_bytes: u64,
        accept_ranges: bool,
    ) -> Result<(), DbError> {
        self.with_conn(|conn| {
            conn.execute(
                "UPDATE download_tasks SET last_real_url = ?2, total_bytes = ?3, accept_ranges = ?4,
                        updated_at = ?5
                 WHERE id = ?1",
                params![
                    task_id,
                    last_real_url,
                    total_bytes as i64,
                    accept_ranges as i64,
                    chrono_now_ts()
                ],
            )?;
            Ok(())
        })
    }

    pub fn replace_download_parts(&self, task_id: i64, parts: &[NewPart]) -> Result<(), DbError> {
        self.with_conn_mut(|conn| {
            let tx = conn.transaction()?;
            tx.execute(
                "DELETE FROM download_parts WHERE task_id = ?1",
                params![task_id],
            )?;
            {
                let mut stmt = tx.prepare(
                    "INSERT INTO download_parts (task_id, part_index, byte_start, byte_end, downloaded_bytes, state)
                     VALUES (?1, ?2, ?3, ?4, 0, 'idle')",
                )?;
                for p in parts {
                    stmt.execute(params![
                        task_id,
                        p.part_index,
                        p.byte_start as i64,
                        p.byte_end as i64
                    ])?;
                }
            }
            tx.execute(
                "UPDATE download_tasks SET downloaded_bytes = 0, updated_at = ?2 WHERE id = ?1",
                params![task_id, chrono_now_ts()],
            )?;
            tx.commit()?;
            Ok(())
        })
    }

    pub fn clear_download_parts(&self, task_id: i64) -> Result<(), DbError> {
        self.with_conn(|conn| {
            conn.execute(
                "DELETE FROM download_parts WHERE task_id = ?1",
                params![task_id],
            )?;
            conn.execute(
                "UPDATE download_tasks SET downloaded_bytes = 0, updated_at = ?2 WHERE id = ?1",
                params![task_id, chrono_now_ts()],
            )?;
            Ok(())
        })
    }

    pub fn save_download_progress(
        &self,
        task_id: i64,
        downloaded_bytes: u64,
        speed_bps: f64,
        eta_seconds: u64,
        parts: &[PartProgress],
    ) -> Result<(), DbError> {
        self.with_conn_mut(|conn| {
            let tx = conn.transaction()?;
            {
                let mut stmt = tx.prepare_cached(
                    "UPDATE download_parts SET downloaded_bytes = ?3, state = ?4
                     WHERE task_id = ?1 AND part_index = ?2",
                )?;
                for p in parts {
                    stmt.execute(params![
                        task_id,
                        p.part_index,
                        p.downloaded_bytes as i64,
                        p.state
                    ])?;
                }
            }
            tx.execute(
                "UPDATE download_tasks SET downloaded_bytes = ?2, speed_bps = ?3, eta_seconds = ?4,
                        updated_at = ?5
                 WHERE id = ?1",
                params![
                    task_id,
                    downloaded_bytes as i64,
                    speed_bps,
                    eta_seconds as i64,
                    chrono_now_ts()
                ],
            )?;
            tx.commit()?;
            Ok(())
        })
    }

    pub fn complete_download_task(
        &self,
        task_id: i64,
        total_bytes: u64,
        file_name: &str,
        save_path: &str,
    ) -> Result<(), DbError> {
        self.with_conn(|conn| {
            conn.execute(
                "UPDATE download_parts SET downloaded_bytes = byte_end - byte_start + 1,
                        state = 'completed'
                 WHERE task_id = ?1 AND ?2 > 0",
                params![task_id, total_bytes as i64],
            )?;
            conn.execute(
                "UPDATE download_tasks SET state = 'completed', total_bytes = ?2, downloaded_bytes = ?2,
                        file_name = ?3, save_path = ?4, speed_bps = 0, eta_seconds = 0, updated_at = ?5
                 WHERE id = ?1",
                params![
                    task_id,
                    total_bytes as i64,
                    file_name,
                    save_path,
                    chrono_now_ts()
                ],
            )?;
            Ok(())
        })
    }

    pub fn delete_download_task(&self, task_id: i64) -> Result<(), DbError> {
        self.with_conn(|conn| {
            conn.execute("DELETE FROM download_tasks WHERE id = ?1", params![task_id])?;
            Ok(())
        })
    }

    pub fn insert_download_log(
        &self,
        task_id: i64,
        level: &str,
        message: &str,
    ) -> Result<(), DbError> {
        self.with_conn(|conn| {
            conn.execute(
                "INSERT INTO download_logs (task_id, timestamp, level, message) VALUES (?1, ?2, ?3, ?4)",
                params![task_id, chrono_now_ts(), level, message],
            )?;
            Ok(())
        })
    }

    pub fn get_download_logs(
        &self,
        task_id: i64,
        limit: u32,
    ) -> Result<Vec<DownloadLogRecord>, DbError> {
        self.with_conn(|conn| {
            let mut stmt = conn.prepare(
                "SELECT id, timestamp, level, message FROM download_logs
                 WHERE task_id = ?1 ORDER BY id DESC LIMIT ?2",
            )?;
            let rows = stmt.query_map(params![task_id, limit], |r| {
                Ok(DownloadLogRecord {
                    id: r.get(0)?,
                    timestamp: r.get(1)?,
                    level: r.get(2)?,
                    message: r.get(3)?,
                })
            })?;
            let mut list = Vec::new();
            for r in rows {
                list.push(r?);
            }
            Ok(list)
        })
    }

    /// Crash recovery: tasks left `running` by an abrupt shutdown become `paused`.
    pub fn reset_running_tasks_on_startup(&self) -> Result<u32, DbError> {
        self.with_conn(|conn| {
            let n = conn.execute(
                "UPDATE download_tasks SET state = 'paused', speed_bps = 0, eta_seconds = 0
                 WHERE state = 'running'",
                [],
            )?;
            conn.execute(
                "UPDATE download_parts SET state = 'idle' WHERE state = 'running'",
                [],
            )?;
            Ok(n as u32)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_download_repo_crud_and_startup_reset() {
        let db = DatabaseManager::open_in_memory().expect("db");
        let id = db
            .create_download_task(
                "http://h/a.mkv",
                None,
                None,
                None,
                None,
                "a.mkv",
                "/tmp/a.mkv",
                "/tmp/a.mkv.part",
                100,
                true,
            )
            .expect("create");
        db.replace_download_parts(
            id,
            &[
                NewPart { part_index: 0, byte_start: 0, byte_end: 49 },
                NewPart { part_index: 1, byte_start: 50, byte_end: 99 },
            ],
        )
        .expect("parts");
        db.save_download_progress(
            id,
            30,
            10.0,
            7,
            &[PartProgress { part_index: 0, downloaded_bytes: 30, state: "running" }],
        )
        .expect("progress");
        db.set_download_state(id, "running").expect("state");

        assert_eq!(db.reset_running_tasks_on_startup().expect("reset"), 1);
        let list = db.list_downloads_with_parts(None).expect("list");
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].state, "paused");
        assert_eq!(list[0].downloaded_bytes, 30);
        assert_eq!(list[0].parts.len(), 2);
        assert_eq!(list[0].parts[0].state, "idle");
        assert_eq!(list[0].parts[0].downloaded_bytes, 30);

        assert!(db.list_downloads_with_parts(Some("zzz")).expect("filter").is_empty());
        assert!(db.is_download_path_taken("/tmp/a.mkv").expect("taken"));

        db.insert_download_log(id, "info", "hello").expect("log");
        assert_eq!(db.get_download_logs(id, 10).expect("logs").len(), 1);

        db.delete_download_task(id).expect("delete");
        assert!(db.list_download_parts(id).expect("parts").is_empty());
        assert!(db.get_download_logs(id, 10).expect("logs").is_empty());
    }
}
