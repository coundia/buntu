use regex::Regex;
use std::collections::VecDeque;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{LazyLock, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

pub const MAX_LOG_ENTRIES: usize = 1_000;

static URL_IN_TEXT_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r#"https?://[^\s"'<>]+"#).expect("valid URL regex"));

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum LogLevel {
    Debug,
    Info,
    Warn,
    Error,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct NetworkLogEntry {
    pub seq_id: u64,
    pub timestamp_ms: i64,
    pub level: LogLevel,
    pub category: String,
    pub method: Option<String>,
    pub url_redacted: Option<String>,
    pub status_code: Option<u16>,
    pub duration_ms: Option<u64>,
    pub message: String,
}

pub struct TelemetryHub {
    entries: Mutex<VecDeque<NetworkLogEntry>>,
    next_seq_id: AtomicU64,
}

impl Default for TelemetryHub {
    fn default() -> Self {
        Self::new()
    }
}

impl TelemetryHub {
    pub fn new() -> Self {
        Self {
            entries: Mutex::new(VecDeque::with_capacity(MAX_LOG_ENTRIES)),
            next_seq_id: AtomicU64::new(1),
        }
    }

    #[allow(clippy::too_many_arguments)]
    pub fn record(
        &self,
        level: LogLevel,
        category: &str,
        method: Option<&str>,
        raw_url: Option<&str>,
        status_code: Option<u16>,
        duration_ms: Option<u64>,
        message: impl Into<String>,
    ) -> u64 {
        let seq_id = self.next_seq_id.fetch_add(1, Ordering::Relaxed);
        let timestamp_ms = now_timestamp_ms();
        let url_redacted = raw_url.map(redact_url);
        let raw_msg = message.into();
        let safe_message = redact_text(&raw_msg);

        let entry = NetworkLogEntry {
            seq_id,
            timestamp_ms,
            level,
            category: category.to_string(),
            method: method.map(str::to_string),
            url_redacted,
            status_code,
            duration_ms,
            message: safe_message,
        };

        if let Ok(mut guard) = self.entries.lock() {
            while guard.len() >= MAX_LOG_ENTRIES {
                guard.pop_front();
            }
            guard.push_back(entry);
        }

        seq_id
    }

    pub fn info(&self, category: &str, message: impl Into<String>) -> u64 {
        self.record(LogLevel::Info, category, None, None, None, None, message)
    }

    pub fn warn(&self, category: &str, message: impl Into<String>) -> u64 {
        self.record(LogLevel::Warn, category, None, None, None, None, message)
    }

    pub fn error(&self, category: &str, message: impl Into<String>) -> u64 {
        self.record(LogLevel::Error, category, None, None, None, None, message)
    }

    pub fn get_logs_since(&self, after_seq_id: u64, limit: u32) -> Vec<NetworkLogEntry> {
        if limit == 0 {
            return Vec::new();
        }
        let max_take = (limit as usize).min(MAX_LOG_ENTRIES);
        let Ok(guard) = self.entries.lock() else {
            return Vec::new();
        };

        // Entries are strictly ordered by ascending seq_id; find first entry > after_seq_id
        let start_idx = guard.partition_point(|e| e.seq_id <= after_seq_id);
        guard
            .iter()
            .skip(start_idx)
            .take(max_take)
            .cloned()
            .collect()
    }

    pub fn clear_logs(&self) {
        if let Ok(mut guard) = self.entries.lock() {
            guard.clear();
        }
    }

    pub fn len(&self) -> usize {
        self.entries.lock().map(|g| g.len()).unwrap_or(0)
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

fn is_sensitive_query_key(key: &str) -> bool {
    matches!(
        key.trim().to_ascii_lowercase().as_str(),
        "key"
            | "password"
            | "pass"
            | "passwd"
            | "pwd"
            | "apikey"
            | "api_key"
            | "api-key"
            | "token"
            | "access_token"
            | "refresh_token"
            | "auth"
            | "auth_token"
            | "secret"
    )
}

fn is_xtream_media_prefix(seg: &str) -> bool {
    matches!(
        seg.to_ascii_lowercase().as_str(),
        "live" | "movie" | "series" | "timeshift"
    )
}

/// Masks sensitive credentials in query parameters, URL userinfo, and Xtream stream paths.
pub fn redact_url(raw_url: &str) -> String {
    let (without_fragment, fragment) = match raw_url.split_once('#') {
        Some((before, frag)) => (before, Some(frag)),
        None => (raw_url, None),
    };

    let (base_and_path, query) = match without_fragment.split_once('?') {
        Some((before, q)) => (before, Some(q)),
        None => (without_fragment, None),
    };

    let redacted_base_and_path = redact_authority_and_path(base_and_path);

    let mut out = String::with_capacity(raw_url.len());
    out.push_str(&redacted_base_and_path);

    if let Some(q) = query {
        out.push('?');
        for (idx, pair) in q.split('&').enumerate() {
            if idx > 0 {
                out.push('&');
            }
            if let Some((k, _v)) = pair.split_once('=') {
                if is_sensitive_query_key(k) {
                    out.push_str(k);
                    out.push_str("=***");
                } else {
                    out.push_str(pair);
                }
            } else {
                out.push_str(pair);
            }
        }
    }

    if let Some(frag) = fragment {
        out.push('#');
        out.push_str(frag);
    }

    out
}

fn redact_authority_and_path(base_and_path: &str) -> String {
    let Some((scheme, rest)) = base_and_path.split_once("://") else {
        return base_and_path.to_string();
    };

    let (authority, path) = match rest.find('/') {
        Some(slash_idx) => (&rest[..slash_idx], &rest[slash_idx..]),
        None => (rest, ""),
    };

    let redacted_authority = if let Some((userinfo, hostport)) = authority.rsplit_once('@') {
        if let Some((user, _pass)) = userinfo.split_once(':') {
            format!("{user}:***@{hostport}")
        } else {
            authority.to_string()
        }
    } else {
        authority.to_string()
    };

    let redacted_path = redact_xtream_path(path);
    format!("{scheme}://{redacted_authority}{redacted_path}")
}

fn redact_xtream_path(path: &str) -> String {
    if !path.starts_with('/') {
        return path.to_string();
    }

    let segments: Vec<&str> = path[1..].split('/').collect();
    // Standard Xtream stream paths: /{live|movie|series|timeshift}/{username}/{password}/{stream_id...}
    if segments.len() >= 4
        && is_xtream_media_prefix(segments[0])
        && !segments[1].is_empty()
        && !segments[2].is_empty()
    {
        let mut rebuilt = String::with_capacity(path.len());
        for (i, seg) in segments.iter().enumerate() {
            rebuilt.push('/');
            if i == 2 {
                rebuilt.push_str("***");
            } else {
                rebuilt.push_str(seg);
            }
        }
        return rebuilt;
    }

    path.to_string()
}

/// Redacts any embedded HTTP/HTTPS URLs inside free-form error or log messages.
pub fn redact_text(input: &str) -> String {
    if !input.contains("http://") && !input.contains("https://") {
        return input.to_string();
    }
    URL_IN_TEXT_RE
        .replace_all(input, |caps: &regex::Captures| redact_url(&caps[0]))
        .into_owned()
}

fn now_timestamp_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_redact_url_hides_service_api_keys() {
        // OMDb (`apikey`), Gemini (`key`) and the other spellings a default key may travel under (PRD 28).
        for (raw, secret) in [
            ("https://www.omdbapi.com/?apikey=SECRETKEY99&t=Alien", "SECRETKEY99"),
            ("https://generativelanguage.googleapis.com/v1beta/models/m:generateContent?key=AIzaSECRET", "AIzaSECRET"),
            ("https://api.example.com/v1?api_key=SECRETKEY99", "SECRETKEY99"),
            ("https://api.example.com/v1?api-key=SECRETKEY99", "SECRETKEY99"),
            ("https://api.themoviedb.org/3/movie/1?api_key=SECRETKEY99&language=fr", "SECRETKEY99"),
        ] {
            let redacted = redact_url(raw);
            assert!(!redacted.contains(secret), "{redacted}");
            assert!(redacted.contains("***"), "{redacted}");
        }
        let text = redact_text("GET https://www.omdbapi.com/?apikey=SECRETKEY99&t=Alien failed");
        assert!(!text.contains("SECRETKEY99"), "{text}");
    }

    #[test]
    fn test_redact_url_query_params() {
        let raw = "http://srv:8080/get.php?username=bob&password=secret123&apikey=abcd";
        let redacted = redact_url(raw);
        assert_eq!(
            redacted,
            "http://srv:8080/get.php?username=bob&password=***&apikey=***"
        );
        assert!(!redacted.contains("secret123"));
        assert!(!redacted.contains("abcd"));

        let extra = "https://api.example.com/v1?pass=p1&TOKEN=tok99&type=m3u_plus#section";
        assert_eq!(
            redact_url(extra),
            "https://api.example.com/v1?pass=***&TOKEN=***&type=m3u_plus#section"
        );
    }

    #[test]
    fn test_redact_url_userinfo_and_xtream_paths() {
        assert_eq!(
            redact_url("http://alice:hunter2@iptv.host:8080/playlist.m3u8"),
            "http://alice:***@iptv.host:8080/playlist.m3u8"
        );
        assert_eq!(
            redact_url("http://iptv.host:8080/live/bob/mySecretPass/4412.ts"),
            "http://iptv.host:8080/live/bob/***/4412.ts"
        );
        assert_eq!(
            redact_url("http://iptv.host:8080/movie/bob/mySecretPass/9988.mkv"),
            "http://iptv.host:8080/movie/bob/***/9988.mkv"
        );
    }

    #[test]
    fn test_ring_buffer_rotation_and_incremental_polling() {
        let hub = TelemetryHub::new();

        for i in 1..=1_250 {
            hub.record(
                LogLevel::Info,
                "HTTP",
                Some("GET"),
                Some(&format!("http://srv:8080/item/{i}?password=hidden")),
                Some(200),
                Some(12),
                format!("Fetched item {i}"),
            );
        }

        // Strict bound of 1,000 entries
        assert_eq!(hub.len(), MAX_LOG_ENTRIES);

        // Oldest 250 entries (1..=250) must have rotated out; first available is 251
        let first_batch = hub.get_logs_since(0, 10);
        assert_eq!(first_batch.len(), 10);
        assert_eq!(first_batch[0].seq_id, 251);
        assert_eq!(
            first_batch[0].url_redacted.as_deref(),
            Some("http://srv:8080/item/251?password=***")
        );

        // Incremental polling from seq_id 1_245
        let tail = hub.get_logs_since(1_245, 100);
        assert_eq!(tail.len(), 5);
        assert_eq!(tail[0].seq_id, 1_246);
        assert_eq!(tail[4].seq_id, 1_250);

        // Polling at latest seq_id returns empty
        assert!(hub.get_logs_since(1_250, 50).is_empty());

        hub.clear_logs();
        assert!(hub.is_empty());
    }
}

