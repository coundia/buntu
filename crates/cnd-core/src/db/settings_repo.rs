use crate::db::{chrono_now_ts, DatabaseManager, DbError};
use rusqlite::params;

#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize, uniffi::Record)]
#[serde(default)]
pub struct RuntimeSettings {
    pub segments_per_file: u32,
    pub part_size_bytes: u64,
    pub max_active_files: u32,
    pub default_user_agent: String,
    pub default_referer: Option<String>,
    pub download_dir: Option<String>,
    pub connect_timeout_ms: u64,
    pub receive_timeout_ms: u64,
    pub speed_smoothing: f64,
    pub omdb_api_key_ref: Option<String>,
    pub show_network_console: bool,
}

impl Default for RuntimeSettings {
    fn default() -> Self {
        Self {
            segments_per_file: 4,
            part_size_bytes: 10 * 1024 * 1024,
            max_active_files: 2,
            default_user_agent: "VLC/3.0.21 LibVLC/3.0.21".to_string(),
            default_referer: None,
            download_dir: None,
            connect_timeout_ms: 10_000,
            receive_timeout_ms: 30_000,
            speed_smoothing: 0.2,
            omdb_api_key_ref: None,
            show_network_console: false,
        }
    }
}

impl DatabaseManager {
    pub fn load_settings(&self) -> Result<RuntimeSettings, DbError> {
        self.with_conn(|conn| {
            let mut stmt = conn.prepare("SELECT key, value FROM app_settings")?;
            let rows = stmt.query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })?;

            let mut base_value = serde_json::to_value(RuntimeSettings::default())
                .map_err(|e| DbError::Serialization(e.to_string()))?;

            if let serde_json::Value::Object(ref mut map) = base_value {
                for row in rows {
                    let (key, raw_val) = row?;
                    if let Ok(parsed_val) = serde_json::from_str::<serde_json::Value>(&raw_val) {
                        map.insert(key, parsed_val);
                    }
                }
            }

            let settings: RuntimeSettings = serde_json::from_value(base_value)
                .map_err(|e| DbError::Serialization(e.to_string()))?;
            Ok(settings)
        })
    }

    pub fn save_settings(&self, settings: &RuntimeSettings) -> Result<(), DbError> {
        let serialized = serde_json::to_value(settings)
            .map_err(|e| DbError::Serialization(e.to_string()))?;

        self.with_conn_mut(|conn| {
            let tx = conn.transaction()?;
            let now = chrono_now_ts();
            {
                let mut stmt = tx.prepare_cached(
                    "INSERT OR REPLACE INTO app_settings (key, value, updated_at) VALUES (?1, ?2, ?3)",
                )?;
                if let serde_json::Value::Object(map) = serialized {
                    for (key, val) in map {
                        let val_str = serde_json::to_string(&val)
                            .map_err(|e| DbError::Serialization(e.to_string()))?;
                        stmt.execute(params![key, val_str, now])?;
                    }
                }
            }
            tx.commit()?;
            Ok(())
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_settings_default_and_persistence_roundtrip() {
        let tempfile = std::env::temp_dir().join(format!(
            "cnd_settings_test_{}.db",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&tempfile);

        {
            let db = DatabaseManager::open(&tempfile).expect("open temp db");
            let initial = db.load_settings().expect("load defaults");
            assert_eq!(initial, RuntimeSettings::default());
            assert_eq!(initial.segments_per_file, 4);
            assert_eq!(initial.part_size_bytes, 10 * 1024 * 1024);
            assert_eq!(initial.default_user_agent, "VLC/3.0.21 LibVLC/3.0.21");

            let custom = RuntimeSettings {
                segments_per_file: 8,
                part_size_bytes: 16 * 1024 * 1024,
                max_active_files: 4,
                default_user_agent: "CNDNative/1.0".to_string(),
                default_referer: Some("https://iptv.example.org/".to_string()),
                download_dir: Some("/Users/test/Downloads".to_string()),
                connect_timeout_ms: 5_000,
                receive_timeout_ms: 45_000,
                speed_smoothing: 0.35,
                omdb_api_key_ref: Some("cnd.omdb.apikey".to_string()),
                show_network_console: true,
            };
            db.save_settings(&custom).expect("save custom settings");
        }

        // Reopen SQLite file from disk and verify persistence
        {
            let db_reopened = DatabaseManager::open(&tempfile).expect("reopen temp db");
            let loaded = db_reopened.load_settings().expect("load persisted settings");
            assert_eq!(loaded.segments_per_file, 8);
            assert_eq!(loaded.part_size_bytes, 16 * 1024 * 1024);
            assert_eq!(loaded.max_active_files, 4);
            assert_eq!(loaded.default_user_agent, "CNDNative/1.0");
            assert_eq!(
                loaded.default_referer.as_deref(),
                Some("https://iptv.example.org/")
            );
            assert_eq!(loaded.download_dir.as_deref(), Some("/Users/test/Downloads"));
            assert_eq!(loaded.connect_timeout_ms, 5_000);
            assert_eq!(loaded.receive_timeout_ms, 45_000);
            assert!((loaded.speed_smoothing - 0.35).abs() < f64::EPSILON);
            assert_eq!(loaded.omdb_api_key_ref.as_deref(), Some("cnd.omdb.apikey"));
            assert!(loaded.show_network_console);
        }

        let _ = std::fs::remove_file(&tempfile);
    }
}

