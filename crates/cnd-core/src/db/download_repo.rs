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

#[derive(Debug, Clone, uniffi::Record)]
pub struct DownloadPlatformTicket {
    pub id: i64,
    pub url: String,
    pub final_url: Option<String>,
    pub file_name: String,
    pub save_path: String,
    pub temp_path: String,
    pub total_bytes: u64,
    pub downloaded_bytes: u64,
    pub accept_ranges: bool,
    pub user_agent: Option<String>,
    pub referer: Option<String>,
    pub headers_json: Option<String>,
    pub platform_resume_data: Option<Vec<u8>>,
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
    pub driver: String,
    pub platform_resume_data: Option<Vec<u8>>,
    pub resume_on_wake: bool,
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
     save_path, temp_path, total_bytes, downloaded_bytes, accept_ranges, state, driver, platform_resume_data, resume_on_wake";

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
        driver: r.get::<_, Option<String>>(13)?.unwrap_or_else(|| "rust".to_string()),
        platform_resume_data: r.get(14)?,
        resume_on_wake: r.get::<_, Option<i64>>(15)?.unwrap_or(0) != 0,
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

    pub fn claim_next_queued_for_platform(
        &self,
        max_concurrent: u32,
    ) -> Result<Vec<DownloadPlatformTicket>, DbError> {
        self.with_conn_mut(|conn| {
            let tx = conn.transaction()?;
            let mut tickets = Vec::new();
            {
                let mut stmt = tx.prepare(
                    "SELECT id, url, last_real_url, file_name, save_path, temp_path,
                            total_bytes, downloaded_bytes, accept_ranges, user_agent,
                            referer, headers_json, platform_resume_data
                     FROM download_tasks
                     WHERE state = 'queued'
                     ORDER BY id ASC
                     LIMIT ?1",
                )?;
                let rows = stmt.query_map(params![max_concurrent as i64], |r| {
                    Ok(DownloadPlatformTicket {
                        id: r.get(0)?,
                        url: r.get(1)?,
                        final_url: r.get(2)?,
                        file_name: r.get(3)?,
                        save_path: r.get(4)?,
                        temp_path: r.get(5)?,
                        total_bytes: r.get::<_, Option<i64>>(6)?.unwrap_or(0).max(0) as u64,
                        downloaded_bytes: r.get::<_, Option<i64>>(7)?.unwrap_or(0).max(0) as u64,
                        accept_ranges: r.get::<_, Option<i64>>(8)?.unwrap_or(0) != 0,
                        user_agent: r.get(9)?,
                        referer: r.get(10)?,
                        headers_json: r.get(11)?,
                        platform_resume_data: r.get(12)?,
                    })
                })?;
                for t in rows {
                    tickets.push(t?);
                }
            }
            let now = chrono_now_ts();
            for t in &tickets {
                tx.execute(
                    "UPDATE download_tasks SET state = 'running', driver = 'urlsession', updated_at = ?2 WHERE id = ?1",
                    params![t.id, now],
                )?;
            }
            tx.commit()?;
            Ok(tickets)
        })
    }

    pub fn get_platform_ticket(&self, task_id: i64) -> Result<DownloadPlatformTicket, DbError> {
        self.with_conn(|conn| {
            conn.query_row(
                "SELECT id, url, last_real_url, file_name, save_path, temp_path,
                        total_bytes, downloaded_bytes, accept_ranges, user_agent,
                        referer, headers_json, platform_resume_data
                 FROM download_tasks WHERE id = ?1",
                params![task_id],
                |r| {
                    Ok(DownloadPlatformTicket {
                        id: r.get(0)?,
                        url: r.get(1)?,
                        final_url: r.get(2)?,
                        file_name: r.get(3)?,
                        save_path: r.get(4)?,
                        temp_path: r.get(5)?,
                        total_bytes: r.get::<_, Option<i64>>(6)?.unwrap_or(0).max(0) as u64,
                        downloaded_bytes: r.get::<_, Option<i64>>(7)?.unwrap_or(0).max(0) as u64,
                        accept_ranges: r.get::<_, Option<i64>>(8)?.unwrap_or(0) != 0,
                        user_agent: r.get(9)?,
                        referer: r.get(10)?,
                        headers_json: r.get(11)?,
                        platform_resume_data: r.get(12)?,
                    })
                },
            )
            .optional()?
            .ok_or_else(|| DbError::NotFound(format!("download task id={task_id}")))
        })
    }

    pub fn update_platform_download_progress(
        &self,
        task_id: i64,
        downloaded_bytes: u64,
        total_bytes: u64,
        speed_bps: f64,
        eta_seconds: u64,
        flush_db: bool,
    ) -> Result<(), DbError> {
        if !flush_db {
            return Ok(());
        }
        self.with_conn(|conn| {
            conn.execute(
                "UPDATE download_tasks
                 SET downloaded_bytes = ?2,
                     total_bytes = CASE WHEN ?3 > 0 THEN ?3 ELSE total_bytes END,
                     speed_bps = ?4,
                     eta_seconds = ?5,
                     updated_at = ?6
                 WHERE id = ?1",
                params![
                    task_id,
                    downloaded_bytes as i64,
                    total_bytes as i64,
                    speed_bps,
                    eta_seconds as i64,
                    chrono_now_ts()
                ],
            )?;
            Ok(())
        })
    }

    pub fn save_platform_resume_data(
        &self,
        task_id: i64,
        state: &str,
        downloaded_bytes: u64,
        resume_data: Option<&[u8]>,
        error_message: Option<&str>,
    ) -> Result<(), DbError> {
        self.with_conn(|conn| {
            let now = chrono_now_ts();
            conn.execute(
                "UPDATE download_tasks
                 SET state = ?2,
                     downloaded_bytes = ?3,
                     platform_resume_data = ?4,
                     speed_bps = 0,
                     eta_seconds = 0,
                     updated_at = ?5
                 WHERE id = ?1",
                params![
                    task_id,
                    state,
                    downloaded_bytes as i64,
                    resume_data,
                    now
                ],
            )?;
            if let Some(err) = error_message {
                conn.execute(
                    "INSERT INTO download_logs (task_id, timestamp, level, message) VALUES (?1, ?2, 'error', ?3)",
                    params![task_id, now, err],
                )?;
            }
            Ok(())
        })
    }

    pub fn complete_platform_download(
        &self,
        task_id: i64,
        final_size: u64,
    ) -> Result<(), DbError> {
        self.with_conn(|conn| {
            let now = chrono_now_ts();
            conn.execute(
                "UPDATE download_parts SET downloaded_bytes = byte_end - byte_start + 1, state = 'completed'
                 WHERE task_id = ?1",
                params![task_id],
            )?;
            conn.execute(
                "UPDATE download_tasks
                 SET state = 'completed',
                     total_bytes = CASE WHEN ?2 > 0 THEN ?2 ELSE total_bytes END,
                     downloaded_bytes = CASE WHEN ?2 > 0 THEN ?2 ELSE downloaded_bytes END,
                     platform_resume_data = NULL,
                     speed_bps = 0,
                     eta_seconds = 0,
                     updated_at = ?3
                 WHERE id = ?1",
                params![task_id, final_size as i64, now],
            )?;
            conn.execute(
                "INSERT INTO download_logs (task_id, timestamp, level, message) VALUES (?1, ?2, 'info', 'Completed via platform background transfer')",
                params![task_id, now],
            )?;
            Ok(())
        })
    }

    pub fn suspend_downloads_for_system_sleep(&self) -> Result<u32, DbError> {
        self.with_conn(|conn| {
            let now = chrono_now_ts();
            let count = conn.execute(
                "UPDATE download_tasks
                 SET state = 'paused',
                     resume_on_wake = 1,
                     speed_bps = 0,
                     eta_seconds = 0,
                     updated_at = ?1
                 WHERE state IN ('queued', 'running')",
                params![now],
            )?;
            conn.execute(
                "UPDATE download_parts SET state = 'idle' WHERE state = 'running'",
                [],
            )?;
            Ok(count as u32)
        })
    }

    pub fn resume_downloads_after_system_wake(&self) -> Result<u32, DbError> {
        self.with_conn(|conn| {
            let now = chrono_now_ts();
            let count = conn.execute(
                "UPDATE download_tasks
                 SET state = 'queued',
                     resume_on_wake = 0,
                     speed_bps = 0,
                     eta_seconds = 0,
                     updated_at = ?1
                 WHERE resume_on_wake = 1 AND state = 'paused'",
                params![now],
            )?;
            Ok(count as u32)
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

    #[test]
    fn test_platform_download_lifecycle_and_sleep_wake() {
        let db = DatabaseManager::open_in_memory().expect("db");
        let id1 = db
            .create_download_task(
                "http://h/ep1.mkv",
                Some("http://cdn/ep1.mkv?token=abc"),
                None,
                Some("TestAgent"),
                None,
                "ep1.mkv",
                "/tmp/ep1.mkv",
                "/tmp/ep1.mkv.part",
                1000,
                true,
            )
            .expect("create1");
        db.set_download_state(id1, "queued").expect("queue1");

        let id2 = db
            .create_download_task(
                "http://h/ep2.mkv",
                None,
                None,
                None,
                None,
                "ep2.mkv",
                "/tmp/ep2.mkv",
                "/tmp/ep2.mkv.part",
                2000,
                true,
            )
            .expect("create2");
        db.set_download_state(id2, "queued").expect("queue2");

        // Claim 1 task
        let claimed = db.claim_next_queued_for_platform(1).expect("claim");
        assert_eq!(claimed.len(), 1);
        assert_eq!(claimed[0].id, id1);
        assert_eq!(claimed[0].final_url.as_deref(), Some("http://cdn/ep1.mkv?token=abc"));
        assert_eq!(claimed[0].user_agent.as_deref(), Some("TestAgent"));

        let row1 = db.get_download_task_row(id1).expect("row1");
        assert_eq!(row1.state, "running");
        assert_eq!(row1.driver, "urlsession");

        // Progress update with flush
        db.update_platform_download_progress(id1, 500, 1000, 250_000.0, 2, true).expect("prog");
        let ticket = db.get_platform_ticket(id1).expect("ticket");
        assert_eq!(ticket.downloaded_bytes, 500);

        // Save platform resume data
        let resume_blob = vec![0x12, 0x34, 0x56];
        db.save_platform_resume_data(id1, "paused", 500, Some(&resume_blob), Some("Cancelled by user")).expect("save resume");
        let row1_paused = db.get_download_task_row(id1).expect("row1 paused");
        assert_eq!(row1_paused.state, "paused");
        assert_eq!(row1_paused.platform_resume_data, Some(resume_blob));

        // Sleep / Wake cycle
        db.set_download_state(id2, "running").expect("run2");
        assert_eq!(db.suspend_downloads_for_system_sleep().expect("suspend"), 1); // id2 was running
        let row2_suspended = db.get_download_task_row(id2).expect("row2 susp");
        assert_eq!(row2_suspended.state, "paused");
        assert!(row2_suspended.resume_on_wake);

        assert_eq!(db.resume_downloads_after_system_wake().expect("wake"), 1);
        let row2_woken = db.get_download_task_row(id2).expect("row2 wake");
        assert_eq!(row2_woken.state, "queued");
        assert!(!row2_woken.resume_on_wake);

        // Completion
        db.complete_platform_download(id1, 1000).expect("complete");
        let row1_done = db.get_download_task_row(id1).expect("row1 done");
        assert_eq!(row1_done.state, "completed");
        assert_eq!(row1_done.downloaded_bytes, 1000);
        assert!(row1_done.platform_resume_data.is_none());
    }
}
