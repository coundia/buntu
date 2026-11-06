pub mod prober;
#[cfg(test)]
mod test_support;
pub mod worker;

use crate::db::download_repo::{
    DownloadLogRecord, DownloadPartRecord, DownloadTaskRecord, NewDownloadRequest, NewPart,
    PartProgress,
};
use crate::db::settings_repo::RuntimeSettings;
use crate::db::DatabaseManager;
use crate::http_client::HttpClientPool;
use crate::telemetry::{redact_url, TelemetryHub};
use crate::CndError;
use prober::{file_name_from_url_or_default, probe_download_url, sanitize_file_name};
use std::collections::HashMap;
use std::fs::OpenOptions;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use std::time::{Duration, Instant};
use tokio::sync::Semaphore;
use tokio::task::{JoinHandle, JoinSet};
use tokio_util::sync::CancellationToken;
use worker::{run_segment, SegmentSpec, UNBOUNDED_END};

/// Below this size a file is fetched as a single sequential stream.
const MULTI_SEGMENT_MIN_BYTES: u64 = 2 * 1024 * 1024;
const TICK_INTERVAL: Duration = Duration::from_millis(250);
/// SQLite is flushed every `PERSIST_EVERY_TICKS * TICK_INTERVAL` (500 ms).
const PERSIST_EVERY_TICKS: u32 = 2;

enum RunOutcome {
    Completed,
    Cancelled,
    Failed(String),
}

/// Lock-free live view of a running task, read by `list_downloads` at UI refresh rate.
struct LiveProgress {
    parts: Vec<Arc<AtomicU64>>,
    lens: Vec<u64>,
    size_known: bool,
    speed_bits: AtomicU64,
    eta_seconds: AtomicU64,
}

struct ActiveRun {
    run_id: u64,
    token: CancellationToken,
    handle: JoinHandle<()>,
}

pub struct DownloadManager {
    db: Arc<DatabaseManager>,
    settings: Arc<RwLock<RuntimeSettings>>,
    telemetry: Arc<TelemetryHub>,
    http_pool: Arc<HttpClientPool>,
    semaphore: Arc<Semaphore>,
    capacity: Mutex<u32>,
    active: Mutex<HashMap<i64, ActiveRun>>,
    live: Mutex<HashMap<i64, Arc<LiveProgress>>>,
    run_counter: AtomicU64,
}

fn io_err(context: &str, e: impl std::fmt::Display) -> CndError {
    CndError::Io {
        message: format!("{context}: {e}"),
    }
}

/// `film.mkv` -> `film (1).mkv`, `film (2).mkv`, ... until `is_taken` is false.
pub fn unique_path(dir: &Path, file_name: &str, is_taken: impl Fn(&Path) -> bool) -> PathBuf {
    let first = dir.join(file_name);
    if !is_taken(&first) {
        return first;
    }
    let as_path = Path::new(file_name);
    let stem = as_path
        .file_stem()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_else(|| file_name.to_string());
    let ext = as_path
        .extension()
        .map(|e| format!(".{}", e.to_string_lossy()));
    let mut n = 1u32;
    loop {
        let candidate = dir.join(format!("{stem} ({n}){}", ext.as_deref().unwrap_or("")));
        if !is_taken(&candidate) {
            return candidate;
        }
        n += 1;
    }
}

fn part_path(save_path: &Path) -> PathBuf {
    let mut s = save_path.as_os_str().to_os_string();
    s.push(".part");
    PathBuf::from(s)
}

fn plan_parts(total: u64, ranged: bool, segments: u32) -> Vec<NewPart> {
    if total == 0 {
        return vec![NewPart {
            part_index: 0,
            byte_start: 0,
            byte_end: 0,
        }];
    }
    let count = if ranged && total > MULTI_SEGMENT_MIN_BYTES {
        u64::from(segments.max(1)).min(total)
    } else {
        1
    };
    let base = total / count;
    let extra = total % count;
    let mut parts = Vec::with_capacity(count as usize);
    let mut start = 0u64;
    for i in 0..count {
        let len = base + u64::from(i < extra);
        parts.push(NewPart {
            part_index: i as u32,
            byte_start: start,
            byte_end: start + len - 1,
        });
        start += len;
    }
    parts
}

/// Existing parts can be resumed only when they tile `[0, total)` exactly.
fn parts_cover(parts: &[DownloadPartRecord], total: u64) -> bool {
    if parts.is_empty() || total == 0 {
        return false;
    }
    let mut expected_start = 0u64;
    for (i, p) in parts.iter().enumerate() {
        if p.part_index as usize != i
            || p.byte_start != expected_start
            || p.byte_end < p.byte_start
            || p.downloaded_bytes > p.byte_end - p.byte_start + 1
        {
            return false;
        }
        expected_start = p.byte_end + 1;
    }
    expected_start == total
}

impl DownloadManager {
    pub fn new(
        db: Arc<DatabaseManager>,
        settings: Arc<RwLock<RuntimeSettings>>,
        telemetry: Arc<TelemetryHub>,
        http_pool: Arc<HttpClientPool>,
    ) -> Arc<Self> {
        let max_active = settings
            .read()
            .map(|s| s.max_active_files)
            .unwrap_or(2)
            .max(1);
        Arc::new(Self {
            db,
            settings,
            telemetry,
            http_pool,
            semaphore: Arc::new(Semaphore::new(max_active as usize)),
            capacity: Mutex::new(max_active),
            active: Mutex::new(HashMap::new()),
            live: Mutex::new(HashMap::new()),
            run_counter: AtomicU64::new(0),
        })
    }

    /// Aligns the semaphore with `settings.max_active_files` (permits held by running tasks
    /// are never revoked; a shrink completes as they finish).
    fn sync_capacity(&self) {
        let wanted = self
            .settings
            .read()
            .map(|s| s.max_active_files)
            .unwrap_or(2)
            .max(1);
        let Ok(mut current) = self.capacity.lock() else {
            return;
        };
        if wanted > *current {
            self.semaphore.add_permits((wanted - *current) as usize);
            *current = wanted;
        } else if wanted < *current {
            let forgotten = self.semaphore.forget_permits((*current - wanted) as usize);
            *current -= forgotten as u32;
        }
    }

    fn log(&self, task_id: i64, level: &str, message: impl Into<String>) {
        let message = message.into();
        let _ = self.db.insert_download_log(task_id, level, &message);
        let line = format!("task {task_id}: {message}");
        match level {
            "error" => self.telemetry.error("DL", line),
            "warn" => self.telemetry.warn("DL", line),
            _ => self.telemetry.info("DL", line),
        };
    }

    pub async fn enqueue(self: &Arc<Self>, req: NewDownloadRequest) -> Result<i64, CndError> {
        let url = req.url.trim().to_string();
        if !(url.starts_with("http://") || url.starts_with("https://")) {
            return Err(CndError::Parse {
                message: "Download URL must start with http:// or https://".to_string(),
            });
        }
        let save_dir = PathBuf::from(req.save_dir.trim());
        if req.save_dir.trim().is_empty() {
            return Err(CndError::Parse {
                message: "Download directory is empty".to_string(),
            });
        }
        tokio::fs::create_dir_all(&save_dir)
            .await
            .map_err(|e| io_err("cannot create download directory", e))?;

        let probe = probe_download_url(
            &self.http_pool,
            &url,
            req.user_agent.as_deref(),
            req.referer.as_deref(),
            req.headers_json.as_deref(),
        )
        .await;
        let (last_real_url, total_bytes, accept_ranges, probed_name, probe_error) = match probe {
            Ok(p) => (
                Some(p.final_url),
                p.total_bytes,
                p.accept_ranges,
                Some(p.real_file_name),
                None,
            ),
            Err(e) => (None, 0, false, None, Some(e.to_string())),
        };

        let file_name = req
            .file_name
            .as_deref()
            .map(str::trim)
            .filter(|n| !n.is_empty())
            .map(sanitize_file_name)
            .or(probed_name)
            .unwrap_or_else(|| file_name_from_url_or_default(&url));

        let db = &self.db;
        let save_path = unique_path(&save_dir, &file_name, |p| {
            let temp = part_path(p);
            p.exists()
                || temp.exists()
                || db
                    .is_download_path_taken(&p.to_string_lossy())
                    .unwrap_or(false)
        });
        let temp_path = part_path(&save_path);
        let final_name = save_path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or(file_name);

        let task_id = self.db.create_download_task(
            &url,
            last_real_url.as_deref(),
            req.referer.as_deref(),
            req.user_agent.as_deref(),
            req.headers_json.as_deref(),
            &final_name,
            &save_path.to_string_lossy(),
            &temp_path.to_string_lossy(),
            total_bytes,
            accept_ranges,
        )?;
        self.log(
            task_id,
            "info",
            format!(
                "Enqueued {} ({} bytes, ranges={})",
                redact_url(&url),
                total_bytes,
                accept_ranges
            ),
        );
        if let Some(err) = probe_error {
            self.log(
                task_id,
                "warn",
                format!("Initial probe failed, will retry on start: {err}"),
            );
        }

        if req.auto_start {
            self.start(task_id)?;
        }
        Ok(task_id)
    }

    pub fn start(self: &Arc<Self>, task_id: i64) -> Result<(), CndError> {
        let row = self.db.get_download_task_row(task_id)?;
        if row.state == "completed" {
            return Ok(());
        }
        let mut active = self.active.lock().map_err(|e| CndError::Internal {
            message: format!("Download registry poisoned: {e}"),
        })?;
        if active.contains_key(&task_id) {
            return Ok(());
        }

        self.sync_capacity();
        self.db.set_download_state(task_id, "queued")?;

        let token = CancellationToken::new();
        let run_id = self.run_counter.fetch_add(1, Ordering::Relaxed);
        let manager = Arc::clone(self);
        let run_token = token.clone();
        let handle = tokio::spawn(async move {
            manager.run_queued(task_id, run_id, run_token).await;
        });
        active.insert(
            task_id,
            ActiveRun {
                run_id,
                token,
                handle,
            },
        );
        Ok(())
    }

    /// Stops the task and waits until its workers flushed their progress to SQLite.
    async fn stop_active(&self, task_id: i64) {
        let entry = self
            .active
            .lock()
            .ok()
            .and_then(|mut active| active.remove(&task_id));
        if let Some(run) = entry {
            run.token.cancel();
            let _ = run.handle.await;
        }
    }

    pub async fn pause(&self, task_id: i64) -> Result<(), CndError> {
        self.stop_active(task_id).await;
        self.db.pause_download_state(task_id)?;
        if self
            .db
            .get_download_task_row(task_id)
            .is_ok_and(|r| r.state == "paused")
        {
            self.log(task_id, "info", "Paused");
        }
        Ok(())
    }

    pub async fn retry(self: &Arc<Self>, task_id: i64) -> Result<(), CndError> {
        let row = self.db.get_download_task_row(task_id)?;
        if row.state == "completed" {
            self.db.clear_download_parts(task_id)?;
            let _ = tokio::fs::remove_file(&row.temp_path).await;
        }
        self.log(task_id, "info", "Retry requested");
        self.start(task_id)
    }

    pub async fn remove(&self, task_id: i64, delete_files: bool) -> Result<(), CndError> {
        self.stop_active(task_id).await;
        let row = self.db.get_download_task_row(task_id)?;
        let _ = tokio::fs::remove_file(&row.temp_path).await;
        if delete_files {
            let _ = tokio::fs::remove_file(&row.save_path).await;
        }
        self.db.delete_download_task(task_id)?;
        self.telemetry
            .info("DL", format!("Removed download task {task_id}"));
        Ok(())
    }

    pub async fn start_all(self: &Arc<Self>) -> Result<(), CndError> {
        for row in self.db.list_download_task_rows()?.into_iter().rev() {
            if row.state == "queued" || row.state == "paused" {
                self.start(row.id)?;
            }
        }
        Ok(())
    }

        pub async fn pause_all(&self) -> Result<(), CndError> {
        let ids: Vec<i64> = self
            .active
            .lock()
            .map(|a| a.keys().copied().collect())
            .unwrap_or_default();
        for id in ids {
            self.pause(id).await?;
        }
        Ok(())
    }

    pub fn claim_next_queued_for_platform(
        &self,
        max_concurrent: u32,
    ) -> Result<Vec<crate::db::download_repo::DownloadPlatformTicket>, CndError> {
        Ok(self.db.claim_next_queued_for_platform(max_concurrent)?)
    }

    pub async fn probe_for_platform(
        &self,
        task_id: i64,
    ) -> Result<crate::db::download_repo::DownloadPlatformTicket, CndError> {
        let row = self.db.get_download_task_row(task_id)?;
        let probe = prober::probe_download_url(
            &self.http_pool,
            &row.url,
            row.user_agent.as_deref(),
            row.referer.as_deref(),
            row.headers_json.as_deref(),
        )
        .await?;
        self.db.update_download_probe(
            task_id,
            &probe.final_url,
            probe.total_bytes,
            probe.accept_ranges,
        )?;
        Ok(crate::db::download_repo::DownloadPlatformTicket {
            id: task_id,
            url: row.url,
            final_url: Some(probe.final_url),
            file_name: row.file_name,
            save_path: row.save_path,
            temp_path: row.temp_path,
            total_bytes: probe.total_bytes,
            downloaded_bytes: row.downloaded_bytes,
            accept_ranges: probe.accept_ranges,
            user_agent: row.user_agent,
            referer: row.referer,
            headers_json: row.headers_json,
            platform_resume_data: row.platform_resume_data,
        })
    }

    pub fn update_platform_progress(
        &self,
        task_id: i64,
        downloaded_bytes: u64,
        total_bytes: u64,
        speed_bps: f64,
        eta_seconds: u64,
        flush_db: bool,
    ) -> Result<(), CndError> {
        if let Ok(mut map) = self.live.lock() {
            let entry = map.entry(task_id).or_insert_with(|| {
                Arc::new(LiveProgress {
                    parts: vec![Arc::new(AtomicU64::new(downloaded_bytes))],
                    lens: vec![total_bytes],
                    size_known: total_bytes > 0,
                    speed_bits: AtomicU64::new(speed_bps.to_bits()),
                    eta_seconds: AtomicU64::new(eta_seconds),
                })
            });
            if !entry.parts.is_empty() {
                entry.parts[0].store(downloaded_bytes, Ordering::Release);
            }
            entry.speed_bits.store(speed_bps.to_bits(), Ordering::Release);
            entry.eta_seconds.store(eta_seconds, Ordering::Release);
        }
        self.db.update_platform_download_progress(
            task_id,
            downloaded_bytes,
            total_bytes,
            speed_bps,
            eta_seconds,
            flush_db,
        )?;
        Ok(())
    }

    pub fn save_platform_resume_data(
        &self,
        task_id: i64,
        state: &str,
        downloaded_bytes: u64,
        resume_data: Option<&[u8]>,
        error_message: Option<&str>,
    ) -> Result<(), CndError> {
        if let Ok(mut map) = self.live.lock() {
            map.remove(&task_id);
        }
        self.db.save_platform_resume_data(
            task_id,
            state,
            downloaded_bytes,
            resume_data,
            error_message,
        )?;
        Ok(())
    }

    pub fn complete_platform_download(
        &self,
        task_id: i64,
        final_size: u64,
    ) -> Result<(), CndError> {
        if let Ok(mut map) = self.live.lock() {
            map.remove(&task_id);
        }
        self.db.complete_platform_download(task_id, final_size)?;
        Ok(())
    }

    pub async fn suspend_downloads_for_system_sleep(&self) -> Result<u32, CndError> {
        let ids: Vec<i64> = self
            .active
            .lock()
            .map(|a| a.keys().copied().collect())
            .unwrap_or_default();
        for id in ids {
            self.stop_active(id).await;
        }
        if let Ok(mut map) = self.live.lock() {
            map.clear();
        }
        let count = self.db.suspend_downloads_for_system_sleep()?;
        self.telemetry.info("DL", format!("Suspended {count} downloads for system sleep"));
        Ok(count)
    }

    pub async fn resume_downloads_after_system_wake(self: &Arc<Self>) -> Result<u32, CndError> {
        let count = self.db.resume_downloads_after_system_wake()?;
        let mut started = 0;
        if let Ok(rows) = self.db.list_download_task_rows() {
            for row in rows {
                if row.state == "queued" && row.driver == "rust" {
                    let _ = self.start(row.id);
                    started += 1;
                }
            }
        }
        self.telemetry.info(
            "DL",
            format!("Resumed {count} downloads after system wake (started {started} Rust tasks)"),
        );
        Ok(count)
    }

    pub fn list(&self, query: Option<&str>) -> Result<Vec<DownloadTaskRecord>, CndError> {
        let mut tasks = self.db.list_downloads_with_parts(query)?;
        let live = self.live.lock().map(|l| l.clone()).unwrap_or_default();
        for task in &mut tasks {
            let Some(progress) = live.get(&task.id) else {
                continue;
            };
            let mut sum = 0u64;
            for part in &mut task.parts {
                if let Some(counter) = progress.parts.get(part.part_index as usize) {
                    part.downloaded_bytes = counter.load(Ordering::Acquire);
                    let len = part.byte_end - part.byte_start + 1;
                    part.state = if progress.size_known && part.downloaded_bytes >= len {
                        "completed".to_string()
                    } else {
                        "running".to_string()
                    };
                }
                sum += part.downloaded_bytes;
            }
            task.downloaded_bytes = sum;
            task.speed_bps = f64::from_bits(progress.speed_bits.load(Ordering::Relaxed));
            task.eta_seconds = progress.eta_seconds.load(Ordering::Relaxed);
        }
        Ok(tasks)
    }

    pub fn logs(&self, task_id: i64, limit: u32) -> Result<Vec<DownloadLogRecord>, CndError> {
        let mut logs = self.db.get_download_logs(task_id, limit)?;
        logs.reverse();
        Ok(logs)
    }

    async fn run_queued(self: Arc<Self>, task_id: i64, run_id: u64, token: CancellationToken) {
        let permit = tokio::select! {
            biased;
            _ = token.cancelled() => None,
            p = Arc::clone(&self.semaphore).acquire_owned() => p.ok(),
        };

        if let Some(permit) = permit {
            if !token.is_cancelled() {
                let _ = self.db.set_download_state(task_id, "running");
                match self.run_task(task_id, &token).await {
                    RunOutcome::Completed | RunOutcome::Cancelled => {}
                    RunOutcome::Failed(message) => {
                        let _ = self.db.set_download_state(task_id, "error");
                        self.log(task_id, "error", format!("Download failed: {message}"));
                    }
                }
            }
            drop(permit);
        }

        if let Ok(mut live) = self.live.lock() {
            live.remove(&task_id);
        }
        if let Ok(mut active) = self.active.lock() {
            if active.get(&task_id).map(|r| r.run_id) == Some(run_id) {
                active.remove(&task_id);
            }
        }
    }

    async fn run_task(&self, task_id: i64, token: &CancellationToken) -> RunOutcome {
        match self.run_task_inner(task_id, token).await {
            Ok(outcome) => outcome,
            Err(e) => RunOutcome::Failed(e.to_string()),
        }
    }

    fn persist(&self, task_id: i64, live: &LiveProgress, stopped: bool, speed: f64, eta: u64) {
        let mut total = 0u64;
        let parts: Vec<PartProgress> = live
            .parts
            .iter()
            .zip(&live.lens)
            .enumerate()
            .map(|(i, (counter, len))| {
                let done = counter.load(Ordering::Acquire);
                total += done;
                let state = if live.size_known && done >= *len {
                    "completed"
                } else if stopped {
                    "idle"
                } else {
                    "running"
                };
                PartProgress {
                    part_index: i as u32,
                    downloaded_bytes: done,
                    state,
                }
            })
            .collect();
        if let Err(e) = self
            .db
            .save_download_progress(task_id, total, speed, eta, &parts)
        {
            self.telemetry
                .warn("DL", format!("task {task_id}: progress flush failed: {e}"));
        }
    }

    async fn run_task_inner(
        &self,
        task_id: i64,
        token: &CancellationToken,
    ) -> Result<RunOutcome, CndError> {
        let row = self.db.get_download_task_row(task_id)?;
        let (segments, alpha) = {
            let s = self.settings.read().map_err(|e| CndError::Internal {
                message: format!("Settings lock poisoned: {e}"),
            })?;
            (s.segments_per_file.max(1), s.speed_smoothing.clamp(0.01, 1.0))
        };
        self.log(task_id, "info", "Starting");

        // Re-probe on every start: redirect tokens on IPTV CDNs expire or change host.
        let probe = tokio::select! {
            biased;
            _ = token.cancelled() => return Ok(RunOutcome::Cancelled),
            p = probe_download_url(
                &self.http_pool,
                &row.url,
                row.user_agent.as_deref(),
                row.referer.as_deref(),
                row.headers_json.as_deref(),
            ) => p?,
        };
        let total = probe.total_bytes;
        let ranged = probe.accept_ranges;
        self.db
            .update_download_probe(task_id, &probe.final_url, total, ranged)?;
        self.log(
            task_id,
            "info",
            format!("Probe: {total} bytes, ranges={ranged}, url={}", redact_url(&probe.final_url)),
        );

        let save_path = PathBuf::from(&row.save_path);
        let temp_path = PathBuf::from(&row.temp_path);
        if let Some(parent) = temp_path.parent() {
            tokio::fs::create_dir_all(parent)
                .await
                .map_err(|e| io_err("cannot create download directory", e))?;
        }

        let existing = self.db.list_download_parts(task_id)?;
        let temp_len = tokio::fs::metadata(&temp_path).await.map(|m| m.len()).ok();
        let resume = ranged && parts_cover(&existing, total) && temp_len == Some(total);

        let parts = if resume {
            self.log(
                task_id,
                "info",
                format!(
                    "Resuming from {} bytes",
                    existing.iter().map(|p| p.downloaded_bytes).sum::<u64>()
                ),
            );
            existing
        } else {
            if !existing.is_empty() {
                self.log(task_id, "warn", "Cannot resume, restarting from byte 0");
            }
            self.db
                .replace_download_parts(task_id, &plan_parts(total, ranged, segments))?;
            self.db.list_download_parts(task_id)?
        };

        let file = {
            let temp = temp_path.clone();
            let fresh = !resume;
            tokio::task::spawn_blocking(move || -> std::io::Result<std::fs::File> {
                let f = OpenOptions::new()
                    .create(true)
                    .write(true)
                    .read(true)
                    .truncate(false)
                    .open(&temp)?;
                if fresh {
                    f.set_len(0)?;
                }
                if total > 0 {
                    f.set_len(total)?;
                }
                Ok(f)
            })
            .await
            .map_err(|e| CndError::Internal {
                message: format!("file open task failed: {e}"),
            })?
            .map_err(|e| io_err("cannot preallocate temp file", e))?
        };
        let file = Arc::new(file);

        let size_known = total > 0;
        let counters: Vec<Arc<AtomicU64>> = parts
            .iter()
            .map(|p| Arc::new(AtomicU64::new(if resume { p.downloaded_bytes } else { 0 })))
            .collect();
        let lens: Vec<u64> = parts.iter().map(|p| p.byte_end - p.byte_start + 1).collect();

        let live = Arc::new(LiveProgress {
            parts: counters.clone(),
            lens: lens.clone(),
            size_known,
            speed_bits: AtomicU64::new(0f64.to_bits()),
            eta_seconds: AtomicU64::new(0),
        });
        if let Ok(mut map) = self.live.lock() {
            map.insert(task_id, Arc::clone(&live));
        }

        let segment_token = token.child_token();
        let mut set: JoinSet<Result<(), worker::SegmentError>> = JoinSet::new();
        // The parts of a resumed download keep the layout it was created with (4 segments, say), but never
        // more of them than the current setting run at once: a provider that allows one connection answers
        // 502 to the others, which failed the whole download.
        let gate = Arc::new(Semaphore::new(segments as usize));
        let pending = parts
            .iter()
            .enumerate()
            .filter(|(i, _)| !(size_known && counters[*i].load(Ordering::Acquire) >= lens[*i]))
            .count();
        if pending > segments as usize {
            self.log(
                task_id,
                "info",
                format!("{pending} parts to finish, {segments} at a time"),
            );
        }
        let shared_url = Arc::new(RwLock::new(probe.final_url.clone()));
        for (i, part) in parts.iter().enumerate() {
            if size_known && counters[i].load(Ordering::Acquire) >= lens[i] {
                continue;
            }
            let gate = Arc::clone(&gate);
            let gate_token = segment_token.clone();
            let spec = SegmentSpec {
                http_pool: Arc::clone(&self.http_pool),
                url: Arc::clone(&shared_url),
                source_url: Some(row.url.clone()),
                user_agent: row.user_agent.clone(),
                referer: row.referer.clone(),
                headers_json: row.headers_json.clone(),
                file: Arc::clone(&file),
                start: part.byte_start,
                end: if size_known { part.byte_end } else { UNBOUNDED_END },
                ranged,
                progress: Arc::clone(&counters[i]),
                token: segment_token.clone(),
            };
            set.spawn(async move {
                let _permit = tokio::select! {
                    biased;
                    _ = gate_token.cancelled() => return Ok(()),
                    permit = gate.acquire_owned() => match permit {
                        Ok(permit) => permit,
                        Err(_) => return Ok(()),
                    },
                };
                run_segment(spec).await
            });
        }

        let sum = |c: &[Arc<AtomicU64>]| c.iter().map(|a| a.load(Ordering::Acquire)).sum::<u64>();

        let mut ticker = tokio::time::interval(TICK_INTERVAL);
        ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        let mut prev_bytes = sum(&counters);
        let mut prev_at = Instant::now();
        let mut ema_bps = 0.0f64;
        let mut first_sample = true;
        let mut tick = 0u32;
        let mut failure: Option<String> = None;

        loop {
            tokio::select! {
                _ = ticker.tick() => {
                    let now = Instant::now();
                    let dt = now.duration_since(prev_at).as_secs_f64();
                    let current = sum(&counters);
                    if dt > 0.0 {
                        let instant_bps = current.saturating_sub(prev_bytes) as f64 / dt;
                        ema_bps = if first_sample {
                            first_sample = false;
                            instant_bps
                        } else {
                            alpha * instant_bps + (1.0 - alpha) * ema_bps
                        };
                    }
                    prev_bytes = current;
                    prev_at = now;
                    let eta = if size_known && ema_bps > 1.0 {
                        (total.saturating_sub(current) as f64 / ema_bps).ceil() as u64
                    } else {
                        0
                    };
                    live.speed_bits.store(ema_bps.to_bits(), Ordering::Relaxed);
                    live.eta_seconds.store(eta, Ordering::Relaxed);

                    tick += 1;
                    if tick.is_multiple_of(PERSIST_EVERY_TICKS) {
                        self.persist(task_id, &live, false, ema_bps, eta);
                    }
                }
                joined = set.join_next() => match joined {
                    None => break,
                    Some(Ok(Ok(()))) => {}
                    Some(Ok(Err(e))) => {
                        if failure.is_none() {
                            failure = Some(e.message);
                            segment_token.cancel();
                        }
                    }
                    Some(Err(join_err)) => {
                        if failure.is_none() {
                            failure = Some(format!("segment task failed: {join_err}"));
                            segment_token.cancel();
                        }
                    }
                },
            }
        }

        let all_complete = size_known
            && counters
                .iter()
                .zip(&lens)
                .all(|(c, len)| c.load(Ordering::Acquire) >= *len);
        let finished_unbounded = !size_known && failure.is_none() && !token.is_cancelled();

        if let Some(message) = failure {
            self.persist(task_id, &live, true, 0.0, 0);
            return Ok(RunOutcome::Failed(message));
        }
        if !all_complete && !finished_unbounded {
            self.persist(task_id, &live, true, 0.0, 0);
            if token.is_cancelled() {
                return Ok(RunOutcome::Cancelled);
            }
            return Ok(RunOutcome::Failed(
                "download ended before all segments completed".to_string(),
            ));
        }

        // Atomic finalisation: flush file data, then rename the `.part` into place.
        let final_total = if size_known { total } else { sum(&counters) };
        self.persist(task_id, &live, true, 0.0, 0);
        {
            let f = Arc::clone(&file);
            tokio::task::spawn_blocking(move || f.sync_data())
                .await
                .map_err(|e| CndError::Internal {
                    message: format!("sync task failed: {e}"),
                })?
                .map_err(|e| io_err("fsync failed", e))?;
        }
        let on_disk = tokio::fs::metadata(&temp_path)
            .await
            .map_err(|e| io_err("temp file missing", e))?
            .len();
        if on_disk != final_total {
            return Err(CndError::Io {
                message: format!("size mismatch: expected {final_total} bytes, found {on_disk}"),
            });
        }

        let final_path = if save_path.exists() {
            let dir = save_path.parent().unwrap_or_else(|| Path::new("."));
            unique_path(dir, &row.file_name, |p| p.exists())
        } else {
            save_path
        };
        tokio::fs::rename(&temp_path, &final_path)
            .await
            .map_err(|e| io_err("cannot move completed file into place", e))?;
        let final_name = final_path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| row.file_name.clone());
        self.db.complete_download_task(
            task_id,
            final_total,
            &final_name,
            &final_path.to_string_lossy(),
        )?;
        self.log(
            task_id,
            "info",
            format!("Completed: {final_total} bytes -> {final_name}"),
        );
        Ok(RunOutcome::Completed)
    }
}

#[cfg(test)]
mod tests {
    use super::test_support::{random_payload, spawn_test_server, ServerConfig};
    use super::*;
    use crate::CndEngine;

    fn scratch_dir(tag: &str) -> PathBuf {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!("cnd_dl_{tag}_{}_{nanos}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("scratch dir");
        dir
    }

    fn set_segments(engine: &CndEngine, n: u32) {
        let mut s = engine.get_settings();
        s.segments_per_file = n;
        engine.update_settings(s).expect("settings");
    }

    async fn wait_for_state(engine: &CndEngine, id: i64, want: &str) -> DownloadTaskRecord {
        for _ in 0..1_000 {
            let task = engine
                .list_downloads(None)
                .expect("list")
                .into_iter()
                .find(|t| t.id == id)
                .expect("task");
            if task.state == want {
                return task;
            }
            assert_ne!(task.state, "error", "task failed: {:?}", engine.get_download_logs(id, 20));
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        panic!("timeout waiting for state {want}");
    }

    fn req(url: String, dir: &Path, name: Option<&str>) -> NewDownloadRequest {
        NewDownloadRequest {
            url,
            file_name: name.map(str::to_string),
            save_dir: dir.to_string_lossy().into_owned(),
            user_agent: None,
            referer: None,
            headers_json: None,
            auto_start: false,
        }
    }

    #[test]
    fn test_plan_parts_balanced_and_unique_path() {
        let parts = plan_parts(10, true, 3);
        assert_eq!(parts.len(), 1, "small files stay single segment");

        let total = 8 * 1024 * 1024 + 5;
        let parts = plan_parts(total, true, 8);
        assert_eq!(parts.len(), 8);
        assert_eq!(parts[0].byte_start, 0);
        assert_eq!(parts[7].byte_end, total - 1);
        for w in parts.windows(2) {
            assert_eq!(w[1].byte_start, w[0].byte_end + 1);
        }
        assert_eq!(plan_parts(total, false, 8).len(), 1);

        let dir = scratch_dir("unique");
        std::fs::write(dir.join("film.mkv"), b"x").expect("write");
        std::fs::write(dir.join("film (1).mkv"), b"x").expect("write");
        let p = unique_path(&dir, "film.mkv", |p| p.exists());
        assert_eq!(p.file_name().and_then(|n| n.to_str()), Some("film (2).mkv"));
        let _ = std::fs::remove_dir_all(dir);
    }

    #[tokio::test]
    async fn test_download_8_segments_blake3_identical() {
        let payload = Arc::new(random_payload(8 * 1024 * 1024, 0xC0FFEE));
        let server = spawn_test_server(Arc::clone(&payload), ServerConfig::default()).await;
        let dir = scratch_dir("full");

        let engine = CndEngine::in_memory().expect("engine");
        set_segments(&engine, 8);
        let mut request = req(server.url("/files/movie.bin"), &dir, None);
        request.auto_start = true;
        let id = engine.enqueue_download(request).await.expect("enqueue");

        let task = wait_for_state(&engine, id, "completed").await;
        assert_eq!(task.total_bytes, payload.len() as u64);
        assert_eq!(task.downloaded_bytes, payload.len() as u64);
        assert_eq!(task.parts.len(), 8);
        assert!(task.parts.iter().all(|p| p.state == "completed"));
        assert_eq!(task.file_name, "movie.bin");

        let written = std::fs::read(&task.save_path).expect("read result");
        assert_eq!(blake3::hash(&written), blake3::hash(&payload));
        assert!(!Path::new(&format!("{}.part", task.save_path)).exists());

        // The same URL again must not overwrite: collision handling yields `movie (1).bin`.
        let id2 = engine
            .enqueue_download(req(server.url("/files/movie.bin"), &dir, None))
            .await
            .expect("enqueue 2");
        let second = engine
            .list_downloads(None)
            .expect("list")
            .into_iter()
            .find(|t| t.id == id2)
            .expect("task 2");
        assert_eq!(second.file_name, "movie (1).bin");
        assert_eq!(second.state, "paused");

        let logs = engine.get_download_logs(id, 50).expect("logs");
        assert!(logs.iter().any(|l| l.message.starts_with("Completed")));

        server.shutdown();
        let _ = std::fs::remove_dir_all(dir);
    }

    #[tokio::test]
    async fn test_pause_reopen_sqlite_resume_blake3_identical() {
        let payload = Arc::new(random_payload(8 * 1024 * 1024, 0xBADC0DE));
        let server = spawn_test_server(
            Arc::clone(&payload),
            ServerConfig {
                chunk_size: 32 * 1024,
                chunk_delay_ms: 8,
                ..ServerConfig::default()
            },
        )
        .await;
        let dir = scratch_dir("resume");
        let db_path = dir.join("cnd.sqlite").to_string_lossy().into_owned();
        let save_dir = dir.join("out");

        let engine = CndEngine::new(db_path.clone()).expect("engine");
        set_segments(&engine, 8);
        let mut request = req(server.url("/vod/film.mkv"), &save_dir, None);
        request.auto_start = true;
        let id = engine.enqueue_download(request).await.expect("enqueue");

        // Pause at roughly 50 %.
        let half = payload.len() as u64 / 2;
        for _ in 0..2_000 {
            let t = engine.list_downloads(None).expect("list");
            if t[0].downloaded_bytes >= half {
                break;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        engine.pause_download(id).await.expect("pause");
        let paused = engine.list_downloads(None).expect("list").remove(0);
        assert_eq!(paused.state, "paused");
        assert!(paused.downloaded_bytes >= half);
        assert!(paused.downloaded_bytes < payload.len() as u64, "paused too late");
        drop(engine);

        // Reopen the SQLite file in a fresh engine and resume with Range requests.
        let engine = CndEngine::new(db_path).expect("reopen engine");
        let reopened = engine.list_downloads(None).expect("list").remove(0);
        assert_eq!(reopened.state, "paused");
        assert_eq!(reopened.downloaded_bytes, paused.downloaded_bytes);
        let resumable: Vec<_> = reopened
            .parts
            .iter()
            .filter(|p| p.downloaded_bytes > 0 && p.downloaded_bytes < p.byte_end - p.byte_start + 1)
            .cloned()
            .collect();
        assert!(!resumable.is_empty(), "expected partially downloaded segments");

        server.clear_requests();
        engine.start_download(id).await.expect("resume");
        let done = wait_for_state(&engine, id, "completed").await;
        assert_eq!(done.downloaded_bytes, payload.len() as u64);

        let seen = server.requests();
        for p in &resumable {
            let expected = format!("bytes={}-{}", p.byte_start + p.downloaded_bytes, p.byte_end);
            assert!(
                seen.iter().any(|r| r.range.as_deref() == Some(expected.as_str())),
                "missing resume request {expected}; saw {seen:?}"
            );
        }

        let written = std::fs::read(&done.save_path).expect("read result");
        assert_eq!(blake3::hash(&written), blake3::hash(&payload));

        server.shutdown();
        let _ = std::fs::remove_dir_all(dir);
    }

    #[tokio::test]
    async fn test_resumed_download_never_opens_more_connections_than_the_setting() {
        let payload = Arc::new(random_payload(24 * 1024 * 1024, 11));
        let server = spawn_test_server(
            Arc::clone(&payload),
            ServerConfig {
                chunk_size: 32 * 1024,
                chunk_delay_ms: 8,
                ..ServerConfig::default()
            },
        )
        .await;
        let dir = scratch_dir("resume-one-connection");
        let db_path = dir.join("cnd.sqlite").to_string_lossy().into_owned();
        let save_dir = dir.join("out");

        // Created with 4 segments (what an install made before the connection limit saved)...
        let engine = CndEngine::new(db_path.clone()).expect("engine");
        set_segments(&engine, 4);
        let mut request = req(server.url("/vod/film.mkv"), &save_dir, None);
        request.auto_start = true;
        let id = engine.enqueue_download(request).await.expect("enqueue");
        let third = payload.len() as u64 / 3;
        for _ in 0..2_000 {
            let t = engine.list_downloads(None).expect("list");
            if t[0].downloaded_bytes >= third {
                break;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        engine.pause_download(id).await.expect("pause");
        drop(engine);

        // ...resumed with one: the four parts finish one after another.
        let engine = CndEngine::new(db_path).expect("reopen engine");
        set_segments(&engine, 1);
        // Let the transfers of the first engine end before counting.
        tokio::time::sleep(Duration::from_millis(600)).await;
        server.reset_peak();
        server.clear_requests();
        engine.start_download(id).await.expect("resume");
        let done = wait_for_state(&engine, id, "completed").await;
        assert_eq!(done.downloaded_bytes, payload.len() as u64);
        assert_eq!(server.peak_concurrent_gets(), 1, "one connection at a time");

        let written = std::fs::read(&done.save_path).expect("read result");
        assert_eq!(blake3::hash(&written), blake3::hash(&payload));

        server.shutdown();
        let _ = std::fs::remove_dir_all(dir);
    }

    #[tokio::test]
    async fn test_prober_falls_back_to_ranged_get_when_head_is_405() {
        let payload = Arc::new(random_payload(3 * 1024 * 1024, 7));
        let server = spawn_test_server(
            Arc::clone(&payload),
            ServerConfig {
                head_status: 405,
                content_disposition: Some("attachment; filename=\"Sauvegarde: 1.mkv\"".to_string()),
                ..ServerConfig::default()
            },
        )
        .await;

        let engine = CndEngine::in_memory().expect("engine");
        let probe = probe_download_url(
            engine.http_pool(),
            &server.url("/dl?token=abc"),
            None,
            None,
            None,
        )
        .await
        .expect("probe");
        assert_eq!(probe.total_bytes, payload.len() as u64);
        assert!(probe.accept_ranges);
        assert_eq!(probe.real_file_name, "Sauvegarde_ 1.mkv");

        let seen = server.requests();
        assert_eq!(seen[0].method, "HEAD");
        assert_eq!(seen[0].path, "/dl?token=abc");
        assert_eq!(seen[1].method, "GET");
        assert_eq!(seen[1].range.as_deref(), Some("bytes=0-0"));

        // Full flow still downloads a byte-identical file through the 405 server.
        let dir = scratch_dir("head405");
        let mut request = req(server.url("/dl?token=abc"), &dir, None);
        request.auto_start = true;
        let id = engine.enqueue_download(request).await.expect("enqueue");
        let done = wait_for_state(&engine, id, "completed").await;
        assert_eq!(done.file_name, "Sauvegarde_ 1.mkv");
        let written = std::fs::read(&done.save_path).expect("read");
        assert_eq!(blake3::hash(&written), blake3::hash(&payload));

        server.shutdown();
        let _ = std::fs::remove_dir_all(dir);
    }

    #[tokio::test]
    async fn test_no_range_support_streams_single_segment_and_http_error_state() {
        let payload = Arc::new(random_payload(3 * 1024 * 1024, 99));
        let server = spawn_test_server(
            Arc::clone(&payload),
            ServerConfig {
                ranges: false,
                ..ServerConfig::default()
            },
        )
        .await;
        let dir = scratch_dir("norange");
        let engine = CndEngine::in_memory().expect("engine");
        set_segments(&engine, 8);

        let mut request = req(server.url("/plain.bin"), &dir, Some("plain.bin"));
        request.auto_start = true;
        let id = engine.enqueue_download(request).await.expect("enqueue");
        let done = wait_for_state(&engine, id, "completed").await;
        assert_eq!(done.parts.len(), 1);
        let written = std::fs::read(&done.save_path).expect("read");
        assert_eq!(blake3::hash(&written), blake3::hash(&payload));

        // A 404 ends in the `error` state with a log entry, and `remove_download` cleans up.
        let mut bad = req(server.url("/missing/404"), &dir, Some("bad.bin"));
        bad.auto_start = true;
        let bad_id = engine.enqueue_download(bad).await.expect("enqueue bad");
        for _ in 0..500 {
            let t = engine.list_downloads(None).expect("list");
            if t.iter().any(|t| t.id == bad_id && t.state == "error") {
                break;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        let bad_task = engine
            .list_downloads(Some("bad".to_string()))
            .expect("list")
            .remove(0);
        assert_eq!(bad_task.state, "error");
        assert!(engine
            .get_download_logs(bad_id, 20)
            .expect("logs")
            .iter()
            .any(|l| l.level == "error"));
        engine.remove_download(bad_id, true).await.expect("remove");
        assert_eq!(engine.list_downloads(None).expect("list").len(), 1);

        server.shutdown();
        let _ = std::fs::remove_dir_all(dir);
    }
}
