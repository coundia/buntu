use crate::telemetry::redact_text;
use reqwest::header::{HeaderMap, HeaderName, HeaderValue, RANGE, REFERER, USER_AGENT};
use std::collections::HashMap;
use std::time::{Duration, Instant};

const MAX_PROBE_BYTES: usize = 65_536; // 64 KiB
const PROBE_TIMEOUT_SECS: u64 = 5;

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ProbeResultRecord {
    pub is_success: bool,
    pub status: String, // "ok", "http_error", "timeout", "dns_error", "invalid"
    pub http_code: Option<u16>,
    pub latency_ms: Option<u32>,
    pub error_message: Option<String>,
}

pub async fn probe_stream(
    url: &str,
    headers_json: Option<&str>,
    user_agent: Option<&str>,
    referer: Option<&str>,
) -> ProbeResultRecord {
    let start = Instant::now();

    let client = match reqwest::Client::builder()
        .timeout(Duration::from_secs(PROBE_TIMEOUT_SECS))
        .redirect(reqwest::redirect::Policy::limited(5))
        .build()
    {
        Ok(c) => c,
        Err(e) => {
            return ProbeResultRecord {
                is_success: false,
                status: "invalid".to_string(),
                http_code: None,
                latency_ms: None,
                error_message: Some(format!("Failed to build client: {e}")),
            }
        }
    };

    let headers = build_headers(headers_json, user_agent, referer);

    let is_hls = url.contains(".m3u8");

    if is_hls {
        probe_hls(&client, url, headers, start).await
    } else {
        probe_ts_or_direct(&client, url, headers, start).await
    }
}

fn build_headers(
    headers_json: Option<&str>,
    user_agent: Option<&str>,
    referer: Option<&str>,
) -> HeaderMap {
    let mut map = HeaderMap::new();

    let ua = user_agent.unwrap_or(
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    );
    if let Ok(v) = HeaderValue::from_str(ua) {
        map.insert(USER_AGENT, v);
    }

    if let Some(ref_val) = referer {
        if let Ok(v) = HeaderValue::from_str(ref_val) {
            map.insert(REFERER, v);
        }
    }

    if let Some(json_str) = headers_json {
        if let Ok(parsed) = serde_json::from_str::<HashMap<String, String>>(json_str) {
            for (k, v) in parsed {
                if let (Ok(hn), Ok(hv)) = (HeaderName::from_bytes(k.as_bytes()), HeaderValue::from_str(&v)) {
                    map.insert(hn, hv);
                }
            }
        }
    }

    map
}

async fn probe_hls(
    client: &reqwest::Client,
    url: &str,
    headers: HeaderMap,
    start: Instant,
) -> ProbeResultRecord {
    let resp = match client.get(url).headers(headers.clone()).send().await {
        Ok(r) => r,
        Err(err) => return map_reqwest_error(err),
    };

    let status = resp.status();
    if !status.is_success() {
        return ProbeResultRecord {
            is_success: false,
            status: "http_error".to_string(),
            http_code: Some(status.as_u16()),
            latency_ms: None,
            error_message: Some(format!("HTTP error {}", status.as_u16())),
        };
    }

    let bytes = match resp.bytes().await {
        Ok(b) => b,
        Err(err) => return map_reqwest_error(err),
    };

    let text = String::from_utf8_lossy(&bytes[..bytes.len().min(MAX_PROBE_BYTES)]);
    if !text.contains("#EXTM3U") {
        return ProbeResultRecord {
            is_success: false,
            status: "invalid".to_string(),
            http_code: Some(status.as_u16()),
            latency_ms: None,
            error_message: Some("Response is not an HLS playlist".to_string()),
        };
    }

    // Check if master playlist
    let media_playlist_url = if text.contains("#EXT-X-STREAM-INF") {
        // Find first variant URI
        let mut variant_uri = None;
        let mut prev_is_stream_inf = false;
        for line in text.lines() {
            let line = line.trim();
            if line.starts_with("#EXT-X-STREAM-INF") {
                prev_is_stream_inf = true;
            } else if prev_is_stream_inf && !line.is_empty() && !line.starts_with('#') {
                variant_uri = Some(line.to_string());
                break;
            }
        }

        match variant_uri {
            Some(v) => resolve_relative_url(url, &v),
            None => {
                return ProbeResultRecord {
                    is_success: false,
                    status: "invalid".to_string(),
                    http_code: Some(status.as_u16()),
                    latency_ms: None,
                    error_message: Some("Master playlist has no variant streams".to_string()),
                }
            }
        }
    } else {
        url.to_string()
    };

    // If we resolved a variant playlist, fetch it
    let (variant_text, base_for_segments) = if media_playlist_url != url {
        let v_resp = match client
            .get(&media_playlist_url)
            .headers(headers.clone())
            .send()
            .await
        {
            Ok(r) => r,
            Err(err) => return map_reqwest_error(err),
        };
        if !v_resp.status().is_success() {
            return ProbeResultRecord {
                is_success: false,
                status: "http_error".to_string(),
                http_code: Some(v_resp.status().as_u16()),
                latency_ms: None,
                error_message: Some(format!(
                    "Variant playlist HTTP error {}",
                    v_resp.status().as_u16()
                )),
            };
        }
        let v_bytes = match v_resp.bytes().await {
            Ok(b) => b,
            Err(err) => return map_reqwest_error(err),
        };
        (
            String::from_utf8_lossy(&v_bytes[..v_bytes.len().min(MAX_PROBE_BYTES)]).to_string(),
            media_playlist_url,
        )
    } else {
        (text.to_string(), url.to_string())
    };

    // Find first segment URI
    let mut segment_uri = None;
    for line in variant_text.lines() {
        let line = line.trim();
        if !line.is_empty() && !line.starts_with('#') {
            segment_uri = Some(line.to_string());
            break;
        }
    }

    let segment_url = match segment_uri {
        Some(s) => resolve_relative_url(&base_for_segments, &s),
        None => {
            return ProbeResultRecord {
                is_success: false,
                status: "invalid".to_string(),
                http_code: Some(status.as_u16()),
                latency_ms: None,
                error_message: Some("Media playlist has no segments".to_string()),
            }
        }
    };

    // Probe the segment with partial GET (Range 0-1024) or HEAD
    let seg_resp = match client
        .get(&segment_url)
        .headers(headers)
        .header(RANGE, "bytes=0-1024")
        .send()
        .await
    {
        Ok(r) => r,
        Err(err) => return map_reqwest_error(err),
    };

    let seg_status = seg_resp.status();
    if seg_status.is_success() || seg_status.is_redirection() {
        let latency = start.elapsed().as_millis().min(u32::MAX as u128) as u32;
        ProbeResultRecord {
            is_success: true,
            status: "ok".to_string(),
            http_code: Some(seg_status.as_u16()),
            latency_ms: Some(latency),
            error_message: None,
        }
    } else {
        ProbeResultRecord {
            is_success: false,
            status: "http_error".to_string(),
            http_code: Some(seg_status.as_u16()),
            latency_ms: None,
            error_message: Some(format!("Segment probe HTTP error {}", seg_status.as_u16())),
        }
    }
}

async fn probe_ts_or_direct(
    client: &reqwest::Client,
    url: &str,
    mut headers: HeaderMap,
    start: Instant,
) -> ProbeResultRecord {
    headers.insert(RANGE, HeaderValue::from_static("bytes=0-65535"));

    let resp = match client.get(url).headers(headers).send().await {
        Ok(r) => r,
        Err(err) => return map_reqwest_error(err),
    };

    let status = resp.status();
    if !status.is_success() && status.as_u16() != 206 {
        return ProbeResultRecord {
            is_success: false,
            status: "http_error".to_string(),
            http_code: Some(status.as_u16()),
            latency_ms: None,
            error_message: Some(format!("HTTP error {}", status.as_u16())),
        };
    }

    let bytes = match resp.bytes().await {
        Ok(b) => b,
        Err(err) => return map_reqwest_error(err),
    };

    let read_len = bytes.len().min(MAX_PROBE_BYTES);
    let slice = &bytes[..read_len];

    if slice.is_empty() {
        return ProbeResultRecord {
            is_success: false,
            status: "invalid".to_string(),
            http_code: Some(status.as_u16()),
            latency_ms: None,
            error_message: Some("Empty response body".to_string()),
        };
    }

    // Verify MPEG-TS sync bytes: at least 3 sync bytes 0x47 separated by 188 bytes
    let is_ts = verify_mpeg_ts_sync(slice);
    if is_ts {
        let latency = start.elapsed().as_millis().min(u32::MAX as u128) as u32;
        return ProbeResultRecord {
            is_success: true,
            status: "ok".to_string(),
            http_code: Some(status.as_u16()),
            latency_ms: Some(latency),
            error_message: None,
        };
    }

    // If URL has .ts extension but failed TS sync bytes -> invalid
    if url.ends_with(".ts") || url.contains(".ts?") {
        return ProbeResultRecord {
            is_success: false,
            status: "invalid".to_string(),
            http_code: Some(status.as_u16()),
            latency_ms: None,
            error_message: Some("Missing MPEG-TS 0x47 sync bytes".to_string()),
        };
    }

    // Generic direct stream: success on 2xx with payload
    let latency = start.elapsed().as_millis().min(u32::MAX as u128) as u32;
    ProbeResultRecord {
        is_success: true,
        status: "ok".to_string(),
        http_code: Some(status.as_u16()),
        latency_ms: Some(latency),
        error_message: None,
    }
}

pub fn verify_mpeg_ts_sync(buffer: &[u8]) -> bool {
    if buffer.len() < 377 {
        return false;
    }
    let max_search = 188.min(buffer.len().saturating_sub(376));
    for i in 0..max_search {
        if buffer[i] == 0x47 && buffer[i + 188] == 0x47 && buffer[i + 376] == 0x47 {
            return true;
        }
    }
    false
}

fn map_reqwest_error(err: reqwest::Error) -> ProbeResultRecord {
    let sanitized = redact_text(&err.to_string());
    if err.is_timeout() {
        ProbeResultRecord {
            is_success: false,
            status: "timeout".to_string(),
            http_code: None,
            latency_ms: None,
            error_message: Some("Connection timed out".to_string()),
        }
    } else if err.is_connect() {
        ProbeResultRecord {
            is_success: false,
            status: "dns_error".to_string(),
            http_code: None,
            latency_ms: None,
            error_message: Some(sanitized),
        }
    } else if let Some(status) = err.status() {
        ProbeResultRecord {
            is_success: false,
            status: "http_error".to_string(),
            http_code: Some(status.as_u16()),
            latency_ms: None,
            error_message: Some(format!("HTTP error {}", status.as_u16())),
        }
    } else {
        ProbeResultRecord {
            is_success: false,
            status: "invalid".to_string(),
            http_code: None,
            latency_ms: None,
            error_message: Some(sanitized),
        }
    }
}

fn resolve_relative_url(base: &str, relative: &str) -> String {
    if relative.starts_with("http://") || relative.starts_with("https://") {
        return relative.to_string();
    }
    if let Ok(base_url) = url::Url::parse(base) {
        if let Ok(joined) = base_url.join(relative) {
            return joined.to_string();
        }
    }
    relative.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_verify_mpeg_ts_sync() {
        let mut valid_ts = vec![0u8; 188 * 4];
        valid_ts[0] = 0x47;
        valid_ts[188] = 0x47;
        valid_ts[376] = 0x47;
        valid_ts[564] = 0x47;
        assert!(verify_mpeg_ts_sync(&valid_ts));

        let invalid_ts = vec![0u8; 188 * 4];
        assert!(!verify_mpeg_ts_sync(&invalid_ts));

        // Offset sync byte (e.g. initial garbage bytes)
        let mut offset_ts = vec![0u8; 188 * 4 + 10];
        offset_ts[10] = 0x47;
        offset_ts[10 + 188] = 0x47;
        offset_ts[10 + 376] = 0x47;
        assert!(verify_mpeg_ts_sync(&offset_ts));
    }

    #[test]
    fn test_resolve_relative_url() {
        assert_eq!(
            resolve_relative_url("http://server/live/playlist.m3u8", "segment0.ts"),
            "http://server/live/segment0.ts"
        );
        assert_eq!(
            resolve_relative_url("http://server/live/playlist.m3u8", "/other/segment0.ts"),
            "http://server/other/segment0.ts"
        );
        assert_eq!(
            resolve_relative_url("http://server/live/playlist.m3u8", "http://cdn/seg.ts"),
            "http://cdn/seg.ts"
        );
    }
}
