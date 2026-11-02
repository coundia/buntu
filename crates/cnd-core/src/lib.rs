pub mod db;
pub mod downloader;
pub mod http_client;
pub mod iptv;
pub mod metadata;
pub mod telemetry;

pub use db::catalog_repo::{CatalogFilter, FacetCount, SeasonSummary, SeriesRecord, SortField};
pub use db::download_repo::{
    DownloadLogRecord, DownloadPartRecord, DownloadTaskRecord, NewDownloadRequest,
};
pub use db::epg_repo::{ChannelNowNext, EpgProgramRecord};
pub use db::ingestion_writer::SyncSummary;
pub use db::settings_repo::RuntimeSettings;
pub use db::sync_repo::{
    SyncDelta, SyncFavorite, SyncImportSummary, SyncSource, SyncTombstone, SyncWatchProgress,
};
pub use iptv::xtream::XtreamAccountInfo;
pub use metadata::MediaMetadata;
pub use telemetry::{LogLevel, NetworkLogEntry, TelemetryHub};

use futures_util::TryStreamExt;
use http_client::HttpClientPool;
use std::path::Path;
use std::sync::{Arc, RwLock};
use std::time::Instant;
use thiserror::Error;
use tokio::io::BufReader;
use tokio_util::io::StreamReader;

uniffi::setup_scaffolding!();

#[derive(Error, Debug, uniffi::Error)]
pub enum CndError {
    #[error("Database error: {message}")]
    Database { message: String },
    #[error("Network error: {message}")]
    Network { message: String },
    #[error("Parse error: {message}")]
    Parse { message: String },
    #[error("IO error: {message}")]
    Io { message: String },
    #[error("Internal error: {message}")]
    Internal { message: String },
}

impl From<db::DbError> for CndError {
    fn from(err: db::DbError) -> Self {
        CndError::Database {
            message: err.to_string(),
        }
    }
}

impl From<std::io::Error> for CndError {
    fn from(err: std::io::Error) -> Self {
        CndError::Io {
            message: err.to_string(),
        }
    }
}

#[derive(uniffi::Object)]
pub struct CndEngine {
    db: Arc<db::DatabaseManager>,
    settings: Arc<RwLock<RuntimeSettings>>,
    telemetry: Arc<TelemetryHub>,
    http_pool: Arc<HttpClientPool>,
    downloads: Arc<downloader::DownloadManager>,
}

impl CndEngine {
    fn from_db(db: db::DatabaseManager) -> Result<Arc<Self>, CndError> {
        let initial_settings = db.load_settings()?;
        let settings = Arc::new(RwLock::new(initial_settings));
        let telemetry = Arc::new(TelemetryHub::new());
        let http_pool = Arc::new(HttpClientPool::new(
            Arc::clone(&settings),
            Arc::clone(&telemetry),
        )?);
        let recovered = db.reset_running_tasks_on_startup()?;
        let db = Arc::new(db);
        let downloads = downloader::DownloadManager::new(
            Arc::clone(&db),
            Arc::clone(&settings),
            Arc::clone(&telemetry),
            Arc::clone(&http_pool),
        );
        telemetry.info(
            "DB",
            "CndEngine initialized (SQLite WAL + FTS5 + HttpClientPool)",
        );
        if recovered > 0 {
            telemetry.info(
                "DL",
                format!("Recovered {recovered} interrupted download(s) as paused"),
            );
        }

        Ok(Arc::new(Self {
            db,
            settings,
            telemetry,
            http_pool,
            downloads,
        }))
    }

    pub fn http_pool(&self) -> &Arc<HttpClientPool> {
        &self.http_pool
    }

    pub fn telemetry(&self) -> &Arc<TelemetryHub> {
        &self.telemetry
    }

    pub async fn ingest_m3u_reader<R>(
        &self,
        source_id: i64,
        source_uuid: &str,
        reader: R,
        started: Instant,
    ) -> Result<SyncSummary, CndError>
    where
        R: tokio::io::AsyncBufRead + Unpin,
    {
        let mut session =
            db::ingestion_writer::SourceIngestionSession::new(source_id, source_uuid);
        let header = iptv::m3u_parser::parse_m3u_stream(reader, source_uuid, |batch| {
            self.db.write_m3u_batch(&mut session, batch)?;
            Ok(())
        })
        .await?;

        let duration_ms = started.elapsed().as_millis() as u64;
        let summary = self
            .db
            .finalize_m3u_ingestion(&mut session, &header, duration_ms)?;

        self.telemetry.info(
            "M3U",
            format!(
                "Synced source id={source_id}: {} items (live={}, movies={}, series={}, episodes={}) in {} ms",
                summary.total_items,
                summary.live_count,
                summary.movie_count,
                summary.series_count,
                summary.episode_count,
                summary.duration_ms
            ),
        );

        Ok(summary)
    }

    async fn ingest_m3u_from_file(
        &self,
        source_id: i64,
        source_uuid: &str,
        file_path: &Path,
        started: Instant,
    ) -> Result<SyncSummary, CndError> {
        let file = tokio::fs::File::open(file_path).await?;
        let reader = BufReader::with_capacity(64 * 1024, file);
        self.ingest_m3u_reader(source_id, source_uuid, reader, started)
            .await
    }

    async fn ingest_m3u_from_http(
        &self,
        source_id: i64,
        source_uuid: &str,
        url: &str,
        started: Instant,
    ) -> Result<SyncSummary, CndError> {
        let req = self.http_pool.get(url)?;
        let resp = self.http_pool.send_logged("M3U", req).await?;
        let status = resp.status();
        if !status.is_success() {
            return Err(CndError::Network {
                message: format!("M3U HTTP error status {}", status.as_u16()),
            });
        }

        let byte_stream = resp
            .bytes_stream()
            .map_err(std::io::Error::other);
        let stream_reader = StreamReader::new(byte_stream);
        let buf_reader = BufReader::with_capacity(64 * 1024, stream_reader);

        self.ingest_m3u_reader(source_id, source_uuid, buf_reader, started)
            .await
    }
}

#[uniffi::export(async_runtime = "tokio")]
impl CndEngine {
    #[uniffi::constructor]
    pub fn new(db_path: String) -> Result<Arc<Self>, CndError> {
        let db = db::DatabaseManager::open(db_path)?;
        Self::from_db(db)
    }

    #[uniffi::constructor]
    pub fn in_memory() -> Result<Arc<Self>, CndError> {
        let db = db::DatabaseManager::open_in_memory()?;
        Self::from_db(db)
    }

    pub fn version(&self) -> String {
        "1.0.0-native-rust".to_string()
    }

    pub fn get_stats(&self) -> Result<db::DbStats, CndError> {
        Ok(self.db.get_stats()?)
    }

    pub fn get_settings(&self) -> RuntimeSettings {
        self.settings.read().map(|g| g.clone()).unwrap_or_default()
    }

    pub fn update_settings(&self, settings: RuntimeSettings) -> Result<(), CndError> {
        self.db.save_settings(&settings)?;
        let old_settings = {
            let mut guard = self.settings.write().map_err(|e| CndError::Internal {
                message: format!("Settings lock poisoned: {e}"),
            })?;
            let prev = guard.clone();
            *guard = settings.clone();
            prev
        };
        self.http_pool
            .on_settings_updated(&old_settings, &settings)?;
        self.telemetry.info(
            "DB",
            format!(
                "RuntimeSettings updated (segments={}, max_active={})",
                settings.segments_per_file, settings.max_active_files
            ),
        );
        Ok(())
    }

    pub fn get_logs_since(&self, after_seq_id: u64, limit: u32) -> Vec<NetworkLogEntry> {
        self.telemetry.get_logs_since(after_seq_id, limit)
    }

    pub fn clear_logs(&self) {
        self.telemetry.clear_logs();
    }

    pub fn add_source(
        &self,
        name: String,
        source_type: String,
        url: Option<String>,
        server: Option<String>,
        username: Option<String>,
        password_ref: Option<String>,
    ) -> Result<i64, CndError> {
        let id = self.db.add_source(
            &name,
            &source_type,
            url.as_deref(),
            server.as_deref(),
            username.as_deref(),
            password_ref.as_deref(),
        )?;
        self.telemetry.record(
            LogLevel::Info,
            "DB",
            None,
            url.as_deref().or(server.as_deref()),
            None,
            None,
            format!("Added IPTV source '{name}' ({source_type}) -> id={id}"),
        );
        Ok(id)
    }

    pub fn update_source(
        &self,
        source_id: i64,
        name: String,
        url: Option<String>,
        epg_url: Option<String>,
    ) -> Result<(), CndError> {
        self.db
            .update_source(source_id, &name, url.as_deref(), epg_url.as_deref())?;
        self.telemetry.record(
            LogLevel::Info,
            "DB",
            None,
            url.as_deref(),
            None,
            None,
            format!("Updated IPTV source id={source_id} ('{name}')"),
        );
        Ok(())
    }

    pub fn update_xtream_source(
        &self,
        source_id: i64,
        name: String,
        server: String,
        username: String,
        password_ref: Option<String>,
        epg_url: Option<String>,
    ) -> Result<(), CndError> {
        let normalized_srv = iptv::xtream::normalize_server_base(&server);
        self.db.update_xtream_source(
            source_id,
            &name,
            &normalized_srv,
            &username,
            password_ref.as_deref(),
            epg_url.as_deref(),
        )?;
        self.telemetry.record(
            LogLevel::Info,
            "DB",
            None,
            Some(&normalized_srv),
            None,
            None,
            format!("Updated Xtream source id={source_id} ('{name}')"),
        );
        Ok(())
    }

    pub fn delete_source(&self, source_id: i64) -> Result<(), CndError> {
        self.db.delete_source(source_id)?;
        self.telemetry
            .info("DB", format!("Deleted IPTV source id={source_id}"));
        Ok(())
    }

    pub fn list_sources(&self) -> Result<Vec<db::IptvSourceRecord>, CndError> {
        Ok(self.db.list_sources()?)
    }

    pub async fn refresh_source(&self, source_id: i64) -> Result<SyncSummary, CndError> {
        let started = Instant::now();
        let src = self.db.get_source_by_id(source_id)?;
        let raw_url = src.url.ok_or_else(|| CndError::Parse {
            message: format!("Source id={source_id} ('{}') has no M3U URL", src.name),
        })?;

        if raw_url.starts_with("http://") || raw_url.starts_with("https://") {
            self.ingest_m3u_from_http(source_id, &src.uuid, &raw_url, started)
                .await
        } else {
            let local_path = raw_url.strip_prefix("file://").unwrap_or(&raw_url);
            self.ingest_m3u_from_file(source_id, &src.uuid, Path::new(local_path), started)
                .await
        }
    }

    pub async fn import_local_m3u(
        &self,
        name: String,
        file_path: String,
    ) -> Result<SyncSummary, CndError> {
        let started = Instant::now();
        let clean_path = file_path.strip_prefix("file://").unwrap_or(&file_path);
        let path_obj = Path::new(clean_path);
        if !tokio::fs::try_exists(path_obj).await.unwrap_or(false) {
            return Err(CndError::Io {
                message: format!("Local M3U file does not exist: {clean_path}"),
            });
        }

        let source_id = self.db.add_source(
            &name,
            "m3u",
            Some(&format!("file://{clean_path}")),
            None,
            None,
            None,
        )?;
        let src = self.db.get_source_by_id(source_id)?;
        self.ingest_m3u_from_file(source_id, &src.uuid, path_obj, started)
            .await
    }

    pub async fn verify_xtream_account(
        &self,
        server: String,
        username: String,
        password: String,
    ) -> Result<XtreamAccountInfo, CndError> {
        iptv::xtream::verify_xtream_account(&self.http_pool, &server, &username, &password).await
    }

    pub async fn refresh_xtream_source(
        &self,
        source_id: i64,
        password: String,
    ) -> Result<SyncSummary, CndError> {
        let started = Instant::now();
        let src = self.db.get_source_by_id(source_id)?;
        let server = src.server.ok_or_else(|| CndError::Parse {
            message: format!("Source id={source_id} ('{}') missing Xtream server URL", src.name),
        })?;
        let username = src.username.ok_or_else(|| CndError::Parse {
            message: format!("Source id={source_id} ('{}') missing Xtream username", src.name),
        })?;

        match iptv::xtream::probe_xtream_account(&self.http_pool, &server, &username, &password)
            .await?
        {
            iptv::xtream::XtreamAuthProbe::Authenticated(account_info) => {
                iptv::xtream::sync_xtream_native_catalog(
                    &self.db,
                    &self.http_pool,
                    &self.telemetry,
                    source_id,
                    &src.uuid,
                    &server,
                    &username,
                    &password,
                    &account_info,
                    started,
                )
                .await
            }
            iptv::xtream::XtreamAuthProbe::InvalidCredentials(msg) => {
                Err(CndError::Network { message: msg })
            }
            iptv::xtream::XtreamAuthProbe::FallbackM3uPlus(reason) => {
                self.telemetry.warn(
                    "XTREAM",
                    format!(
                        "Source id={source_id}: falling back to M3U+ streaming ({reason})"
                    ),
                );
                let fallback_url =
                    iptv::xtream::build_m3u_plus_fallback_url(&server, &username, &password);
                let default_epg = iptv::xtream::build_xtream_epg_template_url(&server);
                if src.epg_url.as_deref().unwrap_or("").trim().is_empty() {
                    let _ = self
                        .db
                        .update_source(source_id, &src.name, src.url.as_deref(), Some(&default_epg));
                }
                self.ingest_m3u_from_http(source_id, &src.uuid, &fallback_url, started)
                    .await
            }
        }
    }

    pub async fn ensure_xtream_series_episodes(
        &self,
        series_db_id: i64,
        password: String,
    ) -> Result<u32, CndError> {
        iptv::xtream::ensure_xtream_series_episodes(
            &self.db,
            &self.http_pool,
            &self.telemetry,
            series_db_id,
            &password,
        )
        .await
    }

    pub async fn refresh_source_epg(
        &self,
        source_id: i64,
        password: Option<String>,
    ) -> Result<u32, CndError> {
        let started = Instant::now();
        let src = self.db.get_source_by_id(source_id)?;

        let raw_epg_list = match src.epg_url.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
            Some(s) => s.to_string(),
            None if src.source_type == "xtream" => {
                if let Some(ref srv) = src.server {
                    iptv::xtream::build_xtream_epg_template_url(srv)
                } else {
                    return Ok(0);
                }
            }
            None => return Ok(0),
        };

        let now_ts = db::chrono_now_ts();
        let _ = self.db.purge_expired_epg(now_ts - 86_400)?;
        let known_channels = self.db.load_known_tvg_channels(None)?;

        let mut total_imported = 0u32;
        for part in raw_epg_list.split(',') {
            let trimmed = part.trim();
            if trimmed.is_empty() {
                continue;
            }

            let resolved_url = if src.source_type == "xtream"
                && trimmed.ends_with("/xmltv.php")
                && !trimmed.contains('?')
            {
                if let (Some(ref u), Some(ref p)) = (&src.username, &password) {
                    let u_enc = iptv::xtream::encode_param(u);
                    let p_enc = iptv::xtream::encode_param(p);
                    format!("{trimmed}?username={u_enc}&password={p_enc}")
                } else {
                    trimmed.to_string()
                }
            } else {
                trimmed.to_string()
            };

            if resolved_url.starts_with("http://") || resolved_url.starts_with("https://") {
                let req = self.http_pool.get(&resolved_url)?;
                let resp = self.http_pool.send_logged("EPG", req).await?;
                if !resp.status().is_success() {
                    self.telemetry.warn(
                        "EPG",
                        format!(
                            "EPG endpoint returned HTTP {} for source id={source_id}",
                            resp.status().as_u16()
                        ),
                    );
                    continue;
                }
                let byte_stream = resp.bytes_stream().map_err(std::io::Error::other);
                let stream_reader = StreamReader::new(byte_stream);
                let buf_reader = BufReader::with_capacity(64 * 1024, stream_reader);
                let count = iptv::epg::parse_xmltv_auto_gzip(
                    buf_reader,
                    Some(&known_channels),
                    now_ts,
                    |batch| {
                        self.db.insert_epg_batch(batch)?;
                        Ok(())
                    },
                )
                .await?;
                total_imported += count;
            } else {
                let clean_path = resolved_url.strip_prefix("file://").unwrap_or(&resolved_url);
                let file = tokio::fs::File::open(clean_path).await?;
                let buf_reader = BufReader::with_capacity(64 * 1024, file);
                let count = iptv::epg::parse_xmltv_auto_gzip(
                    buf_reader,
                    Some(&known_channels),
                    now_ts,
                    |batch| {
                        self.db.insert_epg_batch(batch)?;
                        Ok(())
                    },
                )
                .await?;
                total_imported += count;
            }
        }

        let elapsed_ms = started.elapsed().as_millis() as u64;
        self.telemetry.info(
            "EPG",
            format!(
                "Synced EPG for source id={source_id}: {total_imported} programmes indexed in {elapsed_ms} ms"
            ),
        );

        Ok(total_imported)
    }

    pub fn get_epg_now_next(&self, tvg_ids: Vec<String>) -> Result<Vec<ChannelNowNext>, CndError> {
        Ok(self.db.get_epg_now_next(&tvg_ids)?)
    }

    pub fn get_channel_epg(
        &self,
        tvg_id: String,
        from_ts: i64,
        to_ts: i64,
    ) -> Result<Vec<EpgProgramRecord>, CndError> {
        Ok(self.db.get_channel_epg(&tvg_id, from_ts, to_ts)?)
    }

    pub fn toggle_favorite(
        &self,
        stable_hash: String,
        item_kind: String,
    ) -> Result<bool, CndError> {
        Ok(self.db.toggle_favorite(&stable_hash, &item_kind)?)
    }

    pub fn get_groups(
        &self,
        kind: String,
        source_id: Option<i64>,
    ) -> Result<Vec<FacetCount>, CndError> {
        Ok(self.db.get_groups(&kind, source_id)?)
    }

    pub fn get_hosts(
        &self,
        kind: String,
        source_id: Option<i64>,
    ) -> Result<Vec<FacetCount>, CndError> {
        Ok(self.db.get_hosts(&kind, source_id)?)
    }

    pub fn query_catalog(&self, filter: CatalogFilter) -> Result<Vec<db::IptvItemRecord>, CndError> {
        Ok(self.db.query_catalog(&filter)?)
    }

    pub fn query_series(&self, filter: CatalogFilter) -> Result<Vec<SeriesRecord>, CndError> {
        Ok(self.db.query_series(&filter)?)
    }

    pub fn get_series_seasons(&self, series_id: i64) -> Result<Vec<SeasonSummary>, CndError> {
        Ok(self.db.get_series_seasons(series_id)?)
    }

    pub fn get_series_episodes(
        &self,
        series_id: i64,
        season_num: Option<u32>,
    ) -> Result<Vec<db::IptvItemRecord>, CndError> {
        Ok(self.db.get_series_episodes(series_id, season_num)?)
    }

    pub fn get_item_by_id(&self, item_id: i64) -> Result<Option<db::IptvItemRecord>, CndError> {
        Ok(self.db.get_item_by_id(item_id)?)
    }

    pub fn get_series_by_id(&self, series_id: i64) -> Result<Option<SeriesRecord>, CndError> {
        Ok(self.db.get_series_by_id(series_id)?)
    }

    pub fn list_favorite_items(&self, kind: String) -> Result<Vec<db::IptvItemRecord>, CndError> {
        Ok(self.db.list_favorite_items(&kind)?)
    }

    pub fn list_favorite_series(&self) -> Result<Vec<SeriesRecord>, CndError> {
        Ok(self.db.list_favorite_series()?)
    }

    pub fn record_watch_progress(
        &self,
        stable_hash: String,
        position_ms: i64,
        duration_ms: i64,
    ) -> Result<(), CndError> {
        Ok(self
            .db
            .record_watch_progress(&stable_hash, position_ms, duration_ms)?)
    }

    pub fn list_recent_items(
        &self,
        kind: String,
        limit: u32,
    ) -> Result<Vec<db::IptvItemRecord>, CndError> {
        Ok(self.db.list_recent_items(&kind, limit)?)
    }

    pub fn list_recent_series(&self, limit: u32) -> Result<Vec<SeriesRecord>, CndError> {
        Ok(self.db.list_recent_series(limit)?)
    }

    pub async fn fetch_item_metadata(
        &self,
        item_id: i64,
        api_key: String,
        force_refresh: bool,
    ) -> Result<Option<MediaMetadata>, CndError> {
        metadata::fetch_item_metadata(
            &self.db,
            &self.http_pool,
            &self.telemetry,
            item_id,
            &api_key,
            force_refresh,
        )
        .await
    }

    pub async fn fetch_series_metadata(
        &self,
        series_id: i64,
        api_key: String,
        force_refresh: bool,
    ) -> Result<Option<MediaMetadata>, CndError> {
        metadata::fetch_series_metadata(
            &self.db,
            &self.http_pool,
            &self.telemetry,
            series_id,
            &api_key,
            force_refresh,
        )
        .await
    }

    pub async fn enqueue_download(&self, req: NewDownloadRequest) -> Result<i64, CndError> {
        self.downloads.enqueue(req).await
    }

    pub async fn start_download(&self, task_id: i64) -> Result<(), CndError> {
        self.downloads.start(task_id)
    }

    pub async fn pause_download(&self, task_id: i64) -> Result<(), CndError> {
        self.downloads.pause(task_id).await
    }

    pub async fn retry_download(&self, task_id: i64) -> Result<(), CndError> {
        self.downloads.retry(task_id).await
    }

    pub async fn remove_download(&self, task_id: i64, delete_files: bool) -> Result<(), CndError> {
        self.downloads.remove(task_id, delete_files).await
    }

    pub async fn start_all_downloads(&self) -> Result<(), CndError> {
        self.downloads.start_all().await
    }

    pub async fn pause_all_downloads(&self) -> Result<(), CndError> {
        self.downloads.pause_all().await
    }

    pub fn list_downloads(&self, query: Option<String>) -> Result<Vec<DownloadTaskRecord>, CndError> {
        self.downloads.list(query.as_deref())
    }

    pub fn get_download_logs(
        &self,
        task_id: i64,
        limit: u32,
    ) -> Result<Vec<DownloadLogRecord>, CndError> {
        self.downloads.logs(task_id, limit)
    }

    /// Changes made after `since_ts` (Unix seconds) to sources, favorites and watch progress.
    pub fn export_sync_delta(&self, since_ts: i64) -> Result<SyncDelta, CndError> {
        Ok(self.db.export_sync_delta(since_ts)?)
    }

    /// Merges a delta received from another device (Last-Write-Wins).
    pub fn import_sync_delta(&self, delta: SyncDelta) -> Result<SyncImportSummary, CndError> {
        let summary = self.db.import_sync_delta(&delta)?;
        self.telemetry.info(
            "SYNC",
            format!(
                "Imported delta: {} applied, {} skipped",
                summary.applied(),
                summary.skipped
            ),
        );
        Ok(summary)
    }

    pub fn query_items(
        &self,
        kind: String,
        query: String,
        group: Option<String>,
        host: Option<String>,
        limit: u32,
        offset: u32,
    ) -> Result<Vec<db::IptvItemRecord>, CndError> {
        Ok(self.db.query_items(
            &kind,
            &query,
            group.as_deref(),
            host.as_deref(),
            limit,
            offset,
        )?)
    }
}

#[uniffi::export]
pub fn cnd_core_version() -> String {
    "1.0.0-native-rust".to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::pin::Pin;
    use std::task::{Context, Poll};
    use tokio::io::{AsyncRead, AsyncReadExt, AsyncWriteExt, ReadBuf};
    use tokio::net::TcpListener;

    #[test]
    fn test_engine_init() {
        let engine = CndEngine::in_memory().expect("engine init");
        assert_eq!(engine.version(), "1.0.0-native-rust");

        let stats = engine.get_stats().expect("get stats");
        assert_eq!(stats.total_sources, 0);

        let src_id = engine
            .add_source(
                "Freebox TV".to_string(),
                "m3u".to_string(),
                Some(
                    "http://mafreebox.freebox.fr/freeboxtv/playlist.m3u?password=secret"
                        .to_string(),
                ),
                None,
                None,
                None,
            )
            .expect("add source");

        assert!(src_id > 0);

        let sources = engine.list_sources().expect("list sources");
        assert_eq!(sources.len(), 1);
        assert_eq!(sources[0].name, "Freebox TV");

        let mut settings = engine.get_settings();
        assert_eq!(settings.segments_per_file, 4);
        settings.segments_per_file = 6;
        settings.default_user_agent = "CustomUA/1.0".to_string();
        engine.update_settings(settings).expect("update settings");
        assert_eq!(engine.get_settings().segments_per_file, 6);

        let logs = engine.get_logs_since(0, 50);
        assert!(logs.len() >= 2);
        for entry in &logs {
            if let Some(ref u) = entry.url_redacted {
                assert!(!u.contains("secret"));
            }
        }
        engine.clear_logs();
        assert!(engine.get_logs_since(0, 50).is_empty());
    }

    #[tokio::test]
    async fn test_m3u_refresh_preserves_favorites_and_groups_series() {
        let sample_m3u = r#"#EXTM3U x-tvg-url="http://epg.local/tv.xml.gz"
#EXTINF:-1 tvg-id="f24.fr" group-title="News",France 24 HD
http://iptv.local:8080/live/u/p/10.ts
#EXTINF:-1 group-title="Films",Inception (2010) 1080p
http://iptv.local:8080/movie/u/p/20.mkv
#EXTINF:-1 group-title="Séries",|FR| Severance S01E01 VOSTFR
http://iptv.local:8080/series/u/p/301.mkv
#EXTINF:-1 group-title="Séries",|FR| Severance S01E02 VOSTFR
http://iptv.local:8080/series/u/p/302.mkv
#EXTINF:-1 group-title="Séries",[VF] Severance S02E01 FHD
http://iptv.local:8080/series/u/p/401.mkv
"#;

        let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
        let addr = listener.local_addr().expect("addr");
        let body = sample_m3u.to_string();

        let srv = tokio::spawn(async move {
            for _ in 0..2 {
                let (mut sock, _) = listener.accept().await.expect("accept");
                let mut req_buf = vec![0u8; 1024];
                let _ = sock.read(&mut req_buf).await;
                let resp = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: audio/x-mpegurl\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    body.len(),
                    body
                );
                sock.write_all(resp.as_bytes()).await.expect("write");
            }
        });

        let engine = CndEngine::in_memory().expect("engine");
        let src_id = engine
            .add_source(
                "Local Test IPTV".to_string(),
                "m3u".to_string(),
                Some(format!("http://{addr}/playlist.m3u")),
                None,
                None,
                None,
            )
            .expect("add source");

        let summary1 = engine.refresh_source(src_id).await.expect("refresh 1");
        assert_eq!(summary1.total_items, 5);
        assert_eq!(summary1.live_count, 1);
        assert_eq!(summary1.movie_count, 1);
        assert_eq!(summary1.series_count, 1);
        assert_eq!(summary1.episode_count, 3);

        // Verify series_catalog has 1 series with season_count = 2 and episode_count = 3
        let (sc_seasons, sc_episodes): (u32, u32) = engine
            .db
            .with_conn(|conn| {
                Ok(conn.query_row(
                    "SELECT season_count, episode_count FROM series_catalog WHERE source_id = ?1",
                    rusqlite::params![src_id],
                    |r| Ok((r.get(0)?, r.get(1)?)),
                )?)
            })
            .expect("series counts");
        assert_eq!(sc_seasons, 2);
        assert_eq!(sc_episodes, 3);

        // Verify EPG URL auto-populated from #EXTM3U header
        let sources = engine.list_sources().expect("sources");
        assert_eq!(
            sources[0].epg_url.as_deref(),
            Some("http://epg.local/tv.xml.gz")
        );

        // Mark France 24 as favorite, then re-refresh and verify is_favorite stays true!
        let live_items = engine
            .query_items("live".to_string(), "".to_string(), None, None, 10, 0)
            .expect("query live");
        assert_eq!(live_items.len(), 1);
        let fav_hash = live_items[0].stable_hash.clone();
        assert!(engine
            .toggle_favorite(fav_hash, "live".to_string())
            .expect("fav"));

        let summary2 = engine.refresh_source(src_id).await.expect("refresh 2");
        assert_eq!(summary2.total_items, 5);

        let live_after = engine
            .query_items("live".to_string(), "".to_string(), None, None, 10, 0)
            .expect("query live after");
        assert_eq!(live_after.len(), 1);
        assert!(live_after[0].is_favorite);

        srv.await.expect("server join");
    }

    /// Streaming synthetic generator yielding 50,000 #EXTINF entries on the fly without pre-allocating a giant String.
    struct SyntheticM3uStream {
        current_idx: usize,
        total_items: usize,
        pending: Vec<u8>,
        pending_pos: usize,
    }

    impl SyntheticM3uStream {
        fn new(total_items: usize) -> Self {
            Self {
                current_idx: 0,
                total_items,
                pending: b"#EXTM3U\n".to_vec(),
                pending_pos: 0,
            }
        }
    }

    impl AsyncRead for SyntheticM3uStream {
        fn poll_read(
            mut self: Pin<&mut Self>,
            _cx: &mut Context<'_>,
            buf: &mut ReadBuf<'_>,
        ) -> Poll<std::io::Result<()>> {
            while buf.remaining() > 0 {
                if self.pending_pos < self.pending.len() {
                    let avail = &self.pending[self.pending_pos..];
                    let to_copy = avail.len().min(buf.remaining());
                    buf.put_slice(&avail[..to_copy]);
                    self.pending_pos += to_copy;
                } else if self.current_idx < self.total_items {
                    self.pending.clear();
                    self.pending_pos = 0;
                    // Fill ~64 entries per chunk to simulate realistic TCP socket buffers
                    let chunk_end = (self.current_idx + 64).min(self.total_items);
                    for i in self.current_idx..chunk_end {
                        use std::io::Write;
                        let _ = writeln!(
                            self.pending,
                            "#EXTINF:-1 tvg-id=\"ch{i}.tv\" group-title=\"Group {}\",Channel {i} FHD\nhttp://cdn.iptv.test/live/u/p/{i}.ts",
                            i % 25
                        );
                    }
                    self.current_idx = chunk_end;
                } else {
                    break;
                }
            }
            Poll::Ready(Ok(()))
        }
    }

    #[tokio::test]
    async fn test_50k_streaming_m3u_ingestion_sla() {
        let engine = CndEngine::in_memory().expect("engine");
        let src_id = engine
            .add_source(
                "Bench 50k".to_string(),
                "m3u".to_string(),
                Some("http://cdn.iptv.test/50k.m3u".to_string()),
                None,
                None,
                None,
            )
            .expect("add bench source");
        let src = engine.db.get_source_by_id(src_id).expect("get src");

        let started = Instant::now();
        let stream = SyntheticM3uStream::new(50_000);
        let reader = BufReader::with_capacity(64 * 1024, stream);
        let summary = engine
            .ingest_m3u_reader(src_id, &src.uuid, reader, started)
            .await
            .expect("ingest 50k");

        assert_eq!(summary.total_items, 50_000);
        assert_eq!(summary.live_count, 50_000);

        // SLA: < 1.5s in release mode (allow generous headroom only in unoptimized debug builds)
        #[cfg(not(debug_assertions))]
        assert!(
            summary.duration_ms < 1_500,
            "50k ingestion took {} ms (SLA < 1500 ms)",
            summary.duration_ms
        );
        #[cfg(debug_assertions)]
        assert!(
            summary.duration_ms < 8_000,
            "50k debug ingestion took {} ms",
            summary.duration_ms
        );
    }

    #[tokio::test]
    async fn test_xtream_native_sync_lazy_episodes_and_m3u_fallback() {
        let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
        let addr = listener.local_addr().expect("addr");

        let srv = tokio::spawn(async move {
            loop {
                let Ok((mut sock, _)) = listener.accept().await else {
                    break;
                };
                tokio::spawn(async move {
                    let mut buf = vec![0u8; 2048];
                    let n = sock.read(&mut buf).await.unwrap_or(0);
                    let req = String::from_utf8_lossy(&buf[..n]);
                    let first_line = req.lines().next().unwrap_or("");

                    let (status, content_type, body) = if first_line.contains("username=fallback_user")
                        && first_line.contains("player_api.php")
                    {
                        ("404 Not Found", "text/plain", "Not Found".to_string())
                    } else if first_line.contains("get.php") {
                        (
                            "200 OK",
                            "audio/x-mpegurl",
                            "#EXTM3U\n#EXTINF:-1 group-title=\"News\",BFM TV\nhttp://srv/live/fallback_user/top_secret_pw/1.ts\n".to_string(),
                        )
                    } else if first_line.contains("action=get_live_categories") {
                        ("200 OK", "application/json", r#"[{"category_id":"1","category_name":"France HD"}]"#.to_string())
                    } else if first_line.contains("action=get_vod_categories") {
                        ("200 OK", "application/json", r#"[{"category_id":"10","category_name":"Sci-Fi"}]"#.to_string())
                    } else if first_line.contains("action=get_series_categories") {
                        ("200 OK", "application/json", r#"[{"category_id":"20","category_name":"Apple TV+"}]"#.to_string())
                    } else if first_line.contains("action=get_live_streams") {
                        ("200 OK", "application/json", r#"[{"stream_id":101,"num":1,"name":"TF1 HD","epg_channel_id":"tf1.fr","category_id":"1","tv_archive":1,"tv_archive_duration":7}]"#.to_string())
                    } else if first_line.contains("action=get_vod_streams") {
                        ("200 OK", "application/json", r#"[{"stream_id":"202","name":"Blade Runner 2049 (2017)","rating":"8.0","category_id":"10","container_extension":"mkv"}]"#.to_string())
                    } else if first_line.contains("action=get_series_info") {
                        ("200 OK", "application/json", r#"{"info":{"plot":"Dystopian silo"},"episodes":{"1":[{"id":"5001","episode_num":1,"season":1,"title":"Freedom Day","container_extension":"mkv"},{"id":"5002","episode_num":2,"season":1,"title":"Holston's Pick","container_extension":"mkv"}]}}"#.to_string())
                    } else if first_line.contains("action=get_series") {
                        ("200 OK", "application/json", r#"[{"series_id":303,"name":"Silo","cover":"http://img/silo.jpg","rating":"8.1","category_id":"20"}]"#.to_string())
                    } else {
                        (
                            "200 OK",
                            "application/json",
                            r#"{"user_info":{"auth":1,"status":"Active","exp_date":"1900000000","is_trial":"0","active_cons":1,"max_connections":3},"server_info":{"timezone":"UTC"}}"#.to_string(),
                        )
                    };

                    let resp = format!(
                        "HTTP/1.1 {status}\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                        body.len()
                    );
                    let _ = sock.write_all(resp.as_bytes()).await;
                });
            }
        });

        let engine = CndEngine::in_memory().expect("engine");
        let server_url = format!("http://{addr}");

        // 1. Verify account
        let acc = engine
            .verify_xtream_account(
                server_url.clone(),
                "alice".to_string(),
                "top_secret_pw".to_string(),
            )
            .await
            .expect("verify xtream");
        assert_eq!(acc.status, "Active");
        assert_eq!(acc.max_connections, 3);

        // 2. Add & sync native Xtream source (only password_ref stored in SQLite!)
        let src_id = engine
            .add_source(
                "My Xtream".to_string(),
                "xtream".to_string(),
                None,
                Some(server_url.clone()),
                Some("alice".to_string()),
                Some("cnd.xtream.keychain_1".to_string()),
            )
            .expect("add xtream source");

        let sync = engine
            .refresh_xtream_source(src_id, "top_secret_pw".to_string())
            .await
            .expect("refresh xtream");
        assert_eq!(sync.live_count, 1);
        assert_eq!(sync.movie_count, 1);
        assert_eq!(sync.series_count, 1);

        // Ensure iptv_sources NEVER contains plaintext password
        let stored_src = engine.db.get_source_by_id(src_id).expect("stored src");
        assert_eq!(
            stored_src.password_ref.as_deref(),
            Some("cnd.xtream.keychain_1")
        );
        assert!(!stored_src
            .epg_url
            .as_deref()
            .unwrap_or("")
            .contains("top_secret_pw"));

        // Lazy hydrate episodes for series
        let series_db_id: i64 = engine
            .db
            .with_conn(|conn| {
                Ok(conn.query_row(
                    "SELECT id FROM series_catalog WHERE source_id = ?1",
                    rusqlite::params![src_id],
                    |r| r.get(0),
                )?)
            })
            .expect("series db id");

        let ep_count = engine
            .ensure_xtream_series_episodes(series_db_id, "top_secret_pw".to_string())
            .await
            .expect("hydrate episodes");
        assert_eq!(ep_count, 2);

        // 3. Test automatic M3U+ fallback when player_api.php returns 404
        let fb_id = engine
            .add_source(
                "Fallback Xtream".to_string(),
                "xtream".to_string(),
                None,
                Some(server_url),
                Some("fallback_user".to_string()),
                Some("cnd.xtream.keychain_2".to_string()),
            )
            .expect("add fb source");
        let fb_sync = engine
            .refresh_xtream_source(fb_id, "top_secret_pw".to_string())
            .await
            .expect("fallback sync");
        assert_eq!(fb_sync.live_count, 1);

        // Verify TelemetryHub NEVER leaked `top_secret_pw`
        for entry in engine.get_logs_since(0, 500) {
            assert!(!entry.message.contains("top_secret_pw"));
            if let Some(ref u) = entry.url_redacted {
                assert!(!u.contains("top_secret_pw"));
            }
        }

        srv.abort();
    }
}
