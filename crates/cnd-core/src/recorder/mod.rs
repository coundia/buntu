pub mod hls_capture;
pub mod ts_capture;

pub use hls_capture::capture_hls_stream;
pub use ts_capture::{capture_ts_stream, CaptureResult};

use crate::db::recording_repo::{NewRecordingRequest, RecordingRecord, SeriesRuleRecord};
use crate::db::DatabaseManager;
use crate::downloader::prober::sanitize_file_name;
use crate::http_client::HttpClientPool;
use crate::telemetry::TelemetryHub;
use crate::CndError;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tokio_util::sync::CancellationToken;

pub struct PvrManager {
    db: Arc<DatabaseManager>,
    http_pool: Arc<HttpClientPool>,
    telemetry: Arc<TelemetryHub>,
    active_tokens: Arc<Mutex<HashMap<i64, CancellationToken>>>,
    running: Arc<AtomicBool>,
    download_dir: Arc<Mutex<PathBuf>>,
}

fn now_epoch_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}

impl PvrManager {
    pub fn new(
        db: Arc<DatabaseManager>,
        http_pool: Arc<HttpClientPool>,
        telemetry: Arc<TelemetryHub>,
        default_dir: PathBuf,
    ) -> Arc<Self> {
        let manager = Arc::new(Self {
            db,
            http_pool,
            telemetry,
            active_tokens: Arc::new(Mutex::new(HashMap::new())),
            running: Arc::new(AtomicBool::new(true)),
            download_dir: Arc::new(Mutex::new(default_dir)),
        });

        manager.start_scheduler();
        manager
    }

    pub fn set_download_dir(&self, dir: PathBuf) {
        if let Ok(mut lock) = self.download_dir.lock() {
            *lock = dir;
        }
    }

    pub fn get_download_dir(&self) -> PathBuf {
        self.download_dir.lock().unwrap().clone()
    }

    fn start_scheduler(self: &Arc<Self>) {
        let this = Arc::clone(self);
        std::thread::Builder::new()
            .name("cnd-pvr-scheduler".to_string())
            .spawn(move || {
                let rt = match tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build()
                {
                    Ok(rt) => rt,
                    Err(e) => {
                        eprintln!("Failed to initialize tokio runtime for PVR scheduler: {e}");
                        return;
                    }
                };

                rt.block_on(async move {
                    // Initial startup reap
                    let now = now_epoch_secs();
                    if let Ok(reaped) = this.db.reap_missed_recordings(now) {
                        if reaped > 0 {
                            this.telemetry.info(
                                "PVR",
                                format!("{reaped} enregistrement(s) manqué(s) pendant la fermeture de l'application"),
                            );
                        }
                    }

                    while this.running.load(Ordering::Relaxed) {
                        this.scheduler_cycle().await;
                        tokio::time::sleep(Duration::from_millis(2000)).await;
                    }
                });
            })
            .expect("PVR scheduler thread spawn failed");
    }

    async fn scheduler_cycle(&self) {
        let now = now_epoch_secs();
        // Check for missed
        let _ = self.db.reap_missed_recordings(now);

        // Fetch due
        let due_list = match self.db.get_due_recordings(now) {
            Ok(list) => list,
            Err(_) => return,
        };

        for rec in due_list {
            let mut active = self.active_tokens.lock().unwrap();
            if active.contains_key(&rec.id) {
                continue;
            }

            let token = CancellationToken::new();
            active.insert(rec.id, token.clone());
            drop(active);

            let pvr = self.clone_for_task();
            tokio::spawn(async move {
                pvr.run_recording(rec, token).await;
            });
        }
    }

    fn clone_for_task(&self) -> Self {
        Self {
            db: Arc::clone(&self.db),
            http_pool: Arc::clone(&self.http_pool),
            telemetry: Arc::clone(&self.telemetry),
            active_tokens: Arc::clone(&self.active_tokens),
            running: Arc::clone(&self.running),
            download_dir: Arc::clone(&self.download_dir),
        }
    }

    async fn run_recording(&self, rec: RecordingRecord, token: CancellationToken) {
        let target_dir = self.get_download_dir();
        let safe_channel = sanitize_file_name(&rec.channel_name);
        let safe_title = sanitize_file_name(&rec.title);
        let file_name = format!("{safe_title}_{}.ts", rec.start_ts);
        let final_path = target_dir
            .join("Enregistrements")
            .join(safe_channel)
            .join(file_name);

        let final_path_str = final_path.to_string_lossy().to_string();
        self.telemetry.info(
            "PVR",
            format!("Démarrage de l'enregistrement #{} : {}", rec.id, rec.title),
        );

        let _ = self.db.update_recording_state(
            rec.id,
            "recording",
            0,
            Some(&final_path_str),
            None,
        );

        // Calculate deadline
        let now = now_epoch_secs();
        let total_duration_secs = (rec.end_ts + rec.post_padding_s as i64) - now;
        let deadline = if total_duration_secs > 0 {
            Instant::now() + Duration::from_secs(total_duration_secs as u64)
        } else {
            Instant::now() + Duration::from_secs(60)
        };

        let db = Arc::clone(&self.db);
        let rec_id = rec.id;
        let progress_cb = Box::new(move |bytes: u64| {
            let _ = db.update_recording_state(rec_id, "recording", bytes, None, None);
        });

        let client = match self.http_pool.client() {
            Ok(c) => c,
            Err(e) => {
                let err_msg = e.to_string();
                let _ = self.db.update_recording_state(rec.id, "failed", 0, None, Some(&err_msg));
                return;
            }
        };
        let is_hls = rec.stream_url.to_lowercase().contains(".m3u8");

        let capture_res = if is_hls {
            capture_hls_stream(
                &client,
                &rec.stream_url,
                None,
                None,
                &final_path,
                deadline,
                token.clone(),
                Some(progress_cb),
            )
            .await
        } else {
            capture_ts_stream(
                &client,
                &rec.stream_url,
                None,
                None,
                &final_path,
                deadline,
                token.clone(),
                Some(progress_cb),
            )
            .await
        };

        // Remove from active map
        let mut active = self.active_tokens.lock().unwrap();
        active.remove(&rec.id);
        drop(active);

        match capture_res {
            Ok(result) => {
                let state = if token.is_cancelled() {
                    "cancelled"
                } else if result.is_partial {
                    "partial"
                } else {
                    "completed"
                };

                let _ = self.db.update_recording_state(
                    rec.id,
                    state,
                    result.bytes_written,
                    Some(&result.final_path.to_string_lossy()),
                    None,
                );

                self.telemetry.info(
                    "PVR",
                    format!(
                        "Enregistrement #{} terminé ({state}) : {} octets",
                        rec.id, result.bytes_written
                    ),
                );
            }
            Err(e) => {
                let err_msg = e.to_string();
                let _ = self.db.update_recording_state(
                    rec.id,
                    "failed",
                    0,
                    None,
                    Some(&err_msg),
                );
                self.telemetry.error(
                    "PVR",
                    format!("Échec enregistrement #{}: {err_msg}", rec.id),
                );
            }
        }
    }

    pub fn schedule_recording(&self, req: NewRecordingRequest) -> Result<i64, CndError> {
        let id = self.db.insert_recording(&req)?;
        self.telemetry.info(
            "PVR",
            format!("Programmation de l'enregistrement #{} : {}", id, req.title),
        );
        Ok(id)
    }

    pub fn record_now(
        &self,
        item_id: i64,
        duration_minutes: u32,
    ) -> Result<i64, CndError> {
        let item = self
            .db
            .get_item_by_id(item_id)?
            .ok_or_else(|| CndError::Database {
                message: format!("Channel item {item_id} not found"),
            })?;

        let now = now_epoch_secs();
        let end = now + (duration_minutes.clamp(5, 360) as i64 * 60);

        let req = NewRecordingRequest {
            item_id,
            channel_tvg_id: item.tvg_id,
            channel_name: item.name.clone(),
            title: format!("Direct - {}", item.name),
            subtitle: None,
            stream_url: item.stream_url,
            start_ts: now,
            end_ts: end,
            pre_padding_s: Some(0),
            post_padding_s: Some(0),
            rule_id: None,
        };

        self.schedule_recording(req)
    }

    pub fn cancel_recording(&self, id: i64) -> Result<bool, CndError> {
        let active = self.active_tokens.lock().unwrap();
        if let Some(token) = active.get(&id) {
            token.cancel();
        }
        drop(active);

        Ok(self.db.cancel_recording(id)?)
    }

    pub fn delete_recording(&self, id: i64, delete_file: bool) -> Result<bool, CndError> {
        self.cancel_recording(id)?;
        if let Some(path_str) = self.db.delete_recording(id)? {
            if delete_file {
                let _ = std::fs::remove_file(path_str);
            }
        }
        Ok(true)
    }

    pub fn list_recordings(&self, state_filter: Option<String>) -> Result<Vec<RecordingRecord>, CndError> {
        Ok(self.db.list_recordings(state_filter.as_deref())?)
    }

    pub fn add_series_rule(&self, channel_tvg_id: Option<String>, title: String) -> Result<i64, CndError> {
        let id = self.db.add_series_rule(channel_tvg_id.as_deref(), &title)?;
        self.telemetry.info(
            "PVR",
            format!("Nouvelle règle Series-Link #{id} : '{title}'"),
        );
        Ok(id)
    }

    pub fn remove_series_rule(&self, id: i64) -> Result<bool, CndError> {
        Ok(self.db.remove_series_rule(id)?)
    }

    pub fn list_series_rules(&self) -> Result<Vec<SeriesRuleRecord>, CndError> {
        Ok(self.db.list_series_rules()?)
    }
}
