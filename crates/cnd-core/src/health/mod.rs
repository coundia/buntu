pub mod mirrors;
pub mod probe;

pub use mirrors::find_mirrors;
pub use probe::{probe_stream, ProbeResultRecord};

use crate::db::{self, DatabaseManager, DbError, StreamHealthRecord};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

enum WorkerHandle {
    Tokio(tokio::task::JoinHandle<()>),
    #[allow(dead_code)]
    Thread(std::thread::JoinHandle<()>),
}

pub struct HealthService {
    db: Arc<DatabaseManager>,
    running: Arc<AtomicBool>,
    handle: Mutex<Option<WorkerHandle>>,
}

impl HealthService {
    pub fn new(db: Arc<DatabaseManager>) -> Self {
        Self {
            db,
            running: Arc::new(AtomicBool::new(false)),
            handle: Mutex::new(None),
        }
    }

    pub fn is_running(&self) -> bool {
        self.running.load(Ordering::Relaxed)
    }

    pub fn start(&self, interval_minutes: Option<u32>) {
        if self.running.swap(true, Ordering::SeqCst) {
            // Already running
            return;
        }

        let interval = interval_minutes.unwrap_or(30).clamp(15, 120);
        let interval_duration = Duration::from_secs(interval as u64 * 60);
        let db = Arc::clone(&self.db);
        let running = Arc::clone(&self.running);

        let handle = if let Ok(tokio_handle) = tokio::runtime::Handle::try_current() {
            let task = tokio_handle.spawn(async move {
                while running.load(Ordering::Relaxed) {
                    let _ = Self::run_cycle_internal(&db, &running, true).await;

                    // Sleep interval or until stopped
                    let sleep_start = std::time::Instant::now();
                    while sleep_start.elapsed() < interval_duration && running.load(Ordering::Relaxed) {
                        tokio::time::sleep(Duration::from_millis(500)).await;
                    }
                }
            });
            WorkerHandle::Tokio(task)
        } else {
            let thread = std::thread::Builder::new()
                .name("cnd-health-worker".to_string())
                .spawn(move || {
                    let rt = match tokio::runtime::Builder::new_current_thread()
                        .enable_all()
                        .build()
                    {
                        Ok(rt) => rt,
                        Err(e) => {
                            eprintln!("Failed to initialize tokio runtime for health worker: {e}");
                            return;
                        }
                    };
                    rt.block_on(async move {
                        while running.load(Ordering::Relaxed) {
                            let _ = Self::run_cycle_internal(&db, &running, true).await;

                            // Sleep interval or until stopped
                            let sleep_start = std::time::Instant::now();
                            while sleep_start.elapsed() < interval_duration && running.load(Ordering::Relaxed) {
                                tokio::time::sleep(Duration::from_millis(500)).await;
                            }
                        }
                    });
                })
                .expect("Failed to spawn health check worker thread");
            WorkerHandle::Thread(thread)
        };

        if let Ok(mut lock) = self.handle.lock() {
            *lock = Some(handle);
        }
    }

    pub fn stop(&self) {
        self.running.store(false, Ordering::SeqCst);
        if let Ok(mut lock) = self.handle.lock() {
            if let Some(WorkerHandle::Tokio(handle)) = lock.take() {
                handle.abort();
            }
        }
    }

    /// Runs a single health check cycle immediately (used for testing or explicit refresh).
    pub async fn run_single_cycle(&self, throttle: bool) -> Result<u32, DbError> {
        let running = Arc::new(AtomicBool::new(true));
        Self::run_cycle_internal(&self.db, &running, throttle).await
    }

    async fn run_cycle_internal(
        db: &Arc<DatabaseManager>,
        running: &AtomicBool,
        throttle: bool,
    ) -> Result<u32, DbError> {
        struct ProbeTarget {
            source_id: i64,
            stable_hash: String,
            stream_url: String,
            headers_json: Option<String>,
            user_agent: Option<String>,
            referer: Option<String>,
        }

        // 1. Fetch up to 50 live channels: favorites + recent 20
        let targets = db.with_conn(|conn| {
            let sql = "SELECT DISTINCT i.source_id, i.stable_hash, i.stream_url, i.headers_json, i.user_agent, i.referer
                       FROM iptv_items i
                       WHERE i.kind = 'live' AND (
                           i.stable_hash IN (SELECT stable_hash FROM favorites WHERE item_kind = 'live')
                           OR i.stable_hash IN (
                               SELECT stable_hash FROM watch_history
                               ORDER BY last_watched_at DESC LIMIT 20
                           )
                       )
                       LIMIT 50";
            let mut stmt = conn.prepare(sql)?;
            let rows = stmt.query_map([], |row| {
                Ok(ProbeTarget {
                    source_id: row.get(0)?,
                    stable_hash: row.get(1)?,
                    stream_url: row.get(2)?,
                    headers_json: row.get(3)?,
                    user_agent: row.get(4)?,
                    referer: row.get(5)?,
                })
            })?;
            let mut list = Vec::new();
            for r in rows {
                list.push(r?);
            }
            Ok(list)
        })?;

        let mut probed_count = 0;

        for target in targets {
            if !running.load(Ordering::Relaxed) {
                break;
            }

            // Guardrail: check max_connections for the source
            let skip_due_to_limit = db.with_conn(|conn| {
                let mut stmt = conn.prepare(
                    "SELECT max_connections, active_cons FROM iptv_sources WHERE id = ?1",
                )?;
                let mut rows = stmt.query(rusqlite::params![target.source_id])?;
                if let Some(r) = rows.next()? {
                    let max_c: Option<i64> = r.get(0)?;
                    let active_c: Option<i64> = r.get(1)?;
                    if let (Some(max), Some(active)) = (max_c, active_c) {
                        if max > 0 && active >= max {
                            return Ok(true);
                        }
                    }
                }
                Ok(false)
            })?;

            if skip_due_to_limit {
                continue;
            }

            // Probe the stream
            let result = probe::probe_stream(
                &target.stream_url,
                target.headers_json.as_deref(),
                target.user_agent.as_deref(),
                target.referer.as_deref(),
            )
            .await;

            let prev = db.get_stream_health(&target.stable_hash)?;
            let now = db::chrono_now_ts();

            let (status, latency, failures, last_ok) = if result.is_success {
                // If succeeded, clear auto-flagged broken status (does not touch user flags)
                let _ = db.set_broken_with_origin(&target.stable_hash, "live", false, "auto");
                ("ok".to_string(), result.latency_ms, 0, Some(now))
            } else {
                let prev_f = prev.as_ref().map(|p| p.consecutive_failures).unwrap_or(0);
                let new_f = prev_f + 1;
                // Auto-flag as broken after 3 consecutive failures
                if new_f >= 3 {
                    let _ = db.set_broken_with_origin(&target.stable_hash, "live", true, "auto");
                }
                let prev_ok = prev.as_ref().and_then(|p| p.last_ok_at);
                (result.status.clone(), None, new_f, prev_ok)
            };

            let record = StreamHealthRecord {
                stable_hash: target.stable_hash,
                status,
                latency_ms: latency,
                checked_at: now,
                consecutive_failures: failures,
                last_ok_at: last_ok,
            };
            let _ = db.save_stream_health(&record);
            probed_count += 1;

            if throttle {
                tokio::time::sleep(Duration::from_secs(2)).await;
            }
        }

        Ok(probed_count)
    }
}
