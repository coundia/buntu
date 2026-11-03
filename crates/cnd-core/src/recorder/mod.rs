pub mod hls_capture;
pub mod limits;
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
    /// Source of each running recording, to count the connections they use.
    active_sources: Arc<Mutex<HashMap<i64, i64>>>,
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
            active_sources: Arc::new(Mutex::new(HashMap::new())),
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

            let source_id = match self.check_can_start(&rec, now) {
                Ok(source_id) => source_id,
                Err(reason) => {
                    drop(active);
                    let _ = self.db.update_recording_state(rec.id, "failed", 0, None, Some(&reason));
                    self.telemetry.warn("PVR", format!("Enregistrement #{} refusé : {reason}", rec.id));
                    continue;
                }
            };

            let token = CancellationToken::new();
            active.insert(rec.id, token.clone());
            if let Some(source_id) = source_id {
                self.active_sources.lock().unwrap().insert(rec.id, source_id);
            }
            drop(active);

            let pvr = self.clone_for_task();
            tokio::spawn(async move {
                pvr.run_recording(rec, token).await;
            });
        }
    }

    /// The source of the recording's channel and its connection limit, when known.
    fn source_limit(&self, item_id: i64) -> Option<(i64, Option<u32>)> {
        self.db.source_limit_for_item(item_id)
    }

    /// PRD-19 guards before a recording starts: it uses one connection of the subscription, and the
    /// disk must hold it. Returns the source id on success, the reason (shown to the user) otherwise.
    fn check_can_start(&self, rec: &RecordingRecord, now: i64) -> Result<Option<i64>, String> {
        let source = self.source_limit(rec.item_id);
        if let Some((source_id, max)) = source {
            let running = self
                .active_sources
                .lock()
                .unwrap()
                .values()
                .filter(|&&s| s == source_id)
                .count();
            if limits::connection_limit_reached(max, running) {
                return Err(format!(
                    "Limite de connexions de l'abonnement atteinte ({} simultanée(s)) : un autre enregistrement utilise déjà la connexion. Regarder une chaîne de la même source en compte aussi.",
                    max.unwrap_or(0)
                ));
            }
        }

        let start = now.max(rec.start_ts - rec.pre_padding_s as i64);
        let duration = rec.end_ts + rec.post_padding_s as i64 - start;
        if let Some(free) = limits::available_space(&self.get_download_dir()) {
            if !limits::enough_space_to_start(free, duration) {
                return Err(format!(
                    "Espace disque insuffisant : {} Mo libres, {} Mo nécessaires (estimation 4 Go par heure, plus 1 Go de marge).",
                    free / (1024 * 1024),
                    limits::required_free_bytes(duration) / (1024 * 1024)
                ));
            }
        }
        Ok(source.map(|(id, _)| id))
    }

    /// Forgets a recording that is no longer running.
    fn release(&self, id: i64) {
        self.active_tokens.lock().unwrap().remove(&id);
        self.active_sources.lock().unwrap().remove(&id);
    }

    fn clone_for_task(&self) -> Self {
        Self {
            db: Arc::clone(&self.db),
            http_pool: Arc::clone(&self.http_pool),
            telemetry: Arc::clone(&self.telemetry),
            active_tokens: Arc::clone(&self.active_tokens),
            active_sources: Arc::clone(&self.active_sources),
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
        // Stops the capture cleanly when the disk is almost full (checked every 10 s at most).
        let disk_low = Arc::new(AtomicBool::new(false));
        let last_disk_check = Arc::new(Mutex::new(Instant::now()));
        let disk_flag = Arc::clone(&disk_low);
        let disk_token = token.clone();
        let disk_dir = target_dir.clone();
        let progress_cb = Box::new(move |bytes: u64| {
            let _ = db.update_recording_state(rec_id, "recording", bytes, None, None);
            let mut last = last_disk_check.lock().unwrap();
            if last.elapsed() >= Duration::from_secs(10) {
                *last = Instant::now();
                if let Some(free) = limits::available_space(&disk_dir) {
                    if free < limits::MIN_FREE_BYTES {
                        disk_flag.store(true, Ordering::Relaxed);
                        disk_token.cancel();
                    }
                }
            }
        });

        let client = match self.http_pool.client() {
            Ok(c) => c,
            Err(e) => {
                let err_msg = e.to_string();
                let _ = self.db.update_recording_state(rec.id, "failed", 0, None, Some(&err_msg));
                self.release(rec.id);
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

        self.release(rec.id);
        let stopped_for_disk = disk_low.load(Ordering::Relaxed);

        match capture_res {
            Ok(result) => {
                let state = if stopped_for_disk {
                    "partial"
                } else if token.is_cancelled() {
                    "cancelled"
                } else if result.is_partial {
                    "partial"
                } else {
                    "completed"
                };
                let note = stopped_for_disk
                    .then_some("Disque presque plein (moins de 1 Go libre) : enregistrement arrêté, ce qui a été capturé est conservé.");

                let _ = self.db.update_recording_state(
                    rec.id,
                    state,
                    result.bytes_written,
                    Some(&result.final_path.to_string_lossy()),
                    note,
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::RwLock;

    struct Fixture {
        pvr: Arc<PvrManager>,
        db: Arc<DatabaseManager>,
    }

    fn fixture() -> Fixture {
        let db = DatabaseManager::open_in_memory().expect("in-memory db");
        let settings = Arc::new(RwLock::new(db.load_settings().expect("settings")));
        let db = Arc::new(db);
        let telemetry = Arc::new(TelemetryHub::new());
        let pool = Arc::new(HttpClientPool::new(settings, Arc::clone(&telemetry)).expect("pool"));
        let pvr = PvrManager::new(Arc::clone(&db), pool, telemetry, std::env::temp_dir().join("cnd_pvr_tests"));
        Fixture { pvr, db }
    }

    /// A channel on a new source with the given connection limit; returns (source id, item id).
    fn channel(db: &DatabaseManager, name: &str, max_connections: Option<i64>) -> (i64, i64) {
        let source = db.add_source(name, "xtream", None, Some("http://srv"), Some("u"), None).expect("source");
        let item = db
            .with_conn(|conn| {
                conn.execute(
                    "UPDATE iptv_sources SET max_connections = ?1 WHERE id = ?2",
                    rusqlite::params![max_connections, source],
                )?;
                conn.execute(
                    "INSERT INTO iptv_items (source_id, stable_hash, kind, name, name_clean, host, stream_url, created_at, updated_at)
                     VALUES (?1, ?2, 'live', 'Chaîne', 'chaine', 'srv', 'http://srv/live/u/p/1.ts', 0, 0)",
                    rusqlite::params![source, format!("hash-{name}")],
                )?;
                Ok(conn.last_insert_rowid())
            })
            .expect("item");
        (source, item)
    }

    fn recording(id: i64, item_id: i64, now: i64, secs: i64) -> RecordingRecord {
        RecordingRecord {
            id,
            item_id,
            channel_tvg_id: None,
            channel_name: "Chaîne".into(),
            title: "Journal".into(),
            subtitle: None,
            stream_url: "http://srv/live/u/p/1.ts".into(),
            start_ts: now,
            end_ts: now + secs,
            pre_padding_s: 0,
            post_padding_s: 0,
            state: "scheduled".into(),
            file_path: None,
            bytes_written: 0,
            rule_id: None,
            error: None,
            created_at: now,
        }
    }

    #[test]
    fn a_second_recording_on_a_one_connection_source_is_refused() {
        let f = fixture();
        let (source, item) = channel(&f.db, "un", Some(1));
        let now = now_epoch_secs();
        let first = recording(1, item, now, 600);
        assert_eq!(f.pvr.check_can_start(&first, now), Ok(Some(source)));

        // The first one is now running on that source.
        f.pvr.active_sources.lock().unwrap().insert(1, source);
        let second = recording(2, item, now, 600);
        let refused = f.pvr.check_can_start(&second, now).expect_err("limit of 1 reached");
        assert!(refused.contains("Limite de connexions"), "{refused}");

        // Once the first one is released the connection is free again.
        f.pvr.release(1);
        assert_eq!(f.pvr.check_can_start(&second, now), Ok(Some(source)));
    }

    #[test]
    fn recordings_on_other_sources_or_without_a_known_limit_are_not_counted() {
        let f = fixture();
        let (source_a, item_a) = channel(&f.db, "a", Some(1));
        let (_, item_b) = channel(&f.db, "b", None);
        let now = now_epoch_secs();
        f.pvr.active_sources.lock().unwrap().insert(10, source_a);

        assert!(f.pvr.check_can_start(&recording(2, item_b, now, 600), now).is_ok(), "no known limit on b");
        let (_, item_c) = channel(&f.db, "c", Some(1));
        assert!(f.pvr.check_can_start(&recording(3, item_c, now, 600), now).is_ok(), "a's recording is on another source");
        assert!(f.pvr.check_can_start(&recording(4, item_a, now, 600), now).is_err());
    }

    #[test]
    fn a_recording_longer_than_the_free_disk_is_refused_with_the_numbers() {
        let f = fixture();
        let (_, item) = channel(&f.db, "disk", None);
        let now = now_epoch_secs();
        // About 31 years of TV: no disk holds that.
        let refused = f.pvr.check_can_start(&recording(1, item, now, 1_000_000_000), now).expect_err("too big");
        assert!(refused.contains("Espace disque insuffisant"), "{refused}");
        assert!(refused.contains("Mo libres"), "{refused}");
    }

    #[test]
    fn release_forgets_both_maps() {
        let f = fixture();
        f.pvr.active_tokens.lock().unwrap().insert(5, CancellationToken::new());
        f.pvr.active_sources.lock().unwrap().insert(5, 1);
        f.pvr.release(5);
        assert!(f.pvr.active_tokens.lock().unwrap().is_empty());
        assert!(f.pvr.active_sources.lock().unwrap().is_empty());
    }
}
