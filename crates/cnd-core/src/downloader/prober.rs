use crate::http_client::HttpClientPool;
use crate::CndError;
use reqwest::header::{HeaderMap, ACCEPT_RANGES, CONTENT_DISPOSITION, CONTENT_LENGTH, CONTENT_RANGE, RANGE};

#[derive(Debug, Clone)]
pub struct ProbeResult {
    pub final_url: String,
    pub total_bytes: u64,
    pub accept_ranges: bool,
    pub real_file_name: String,
}

fn header_u64(headers: &HeaderMap, name: reqwest::header::HeaderName) -> Option<u64> {
    headers
        .get(name)?
        .to_str()
        .ok()?
        .trim()
        .parse::<u64>()
        .ok()
}

/// `Content-Range: bytes 0-0/123456789` -> `123456789` (`*` means unknown).
fn total_from_content_range(headers: &HeaderMap) -> Option<u64> {
    let raw = headers.get(CONTENT_RANGE)?.to_str().ok()?;
    let total = raw.rsplit('/').next()?.trim();
    total.parse::<u64>().ok()
}

fn percent_decode(input: &str) -> String {
    let bytes = input.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            let hex = std::str::from_utf8(&bytes[i + 1..i + 3]).unwrap_or("");
            if let Ok(b) = u8::from_str_radix(hex, 16) {
                out.push(b);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// Strips path separators and reserved characters (`/\:*?"<>|`) plus control chars and
/// leading/trailing dots or spaces. Never returns an empty name nor `.` / `..`.
pub fn sanitize_file_name(raw: &str) -> String {
    let cleaned: String = raw
        .chars()
        .map(|c| match c {
            '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|' => '_',
            c if c.is_control() => '_',
            c => c,
        })
        .collect();
    let trimmed = cleaned.trim_matches(|c: char| c == '.' || c.is_whitespace());
    if trimmed.is_empty() {
        "download.bin".to_string()
    } else {
        trimmed.to_string()
    }
}

fn file_name_from_content_disposition(headers: &HeaderMap) -> Option<String> {
    let raw = headers.get(CONTENT_DISPOSITION)?.to_str().ok()?;
    let lower = raw.to_ascii_lowercase();

    if let Some(pos) = lower.find("filename*=") {
        let rest = raw[pos + "filename*=".len()..].split(';').next()?.trim();
        // RFC 5987: charset'lang'percent-encoded-value
        let encoded = rest.splitn(3, '\'').nth(2).unwrap_or(rest);
        let decoded = percent_decode(encoded.trim_matches('"'));
        if !decoded.trim().is_empty() {
            return Some(decoded);
        }
    }

    let mut search_from = 0;
    while let Some(rel) = lower[search_from..].find("filename=") {
        let pos = search_from + rel;
        search_from = pos + "filename=".len();
        // skip the `filename*=` variant (already handled) matched as `name*=`
        if pos > 0 && lower.as_bytes()[pos - 1] == b'*' {
            continue;
        }
        let rest = raw[pos + "filename=".len()..].trim_start();
        let value = if let Some(stripped) = rest.strip_prefix('"') {
            stripped.split('"').next().unwrap_or("")
        } else {
            rest.split(';').next().unwrap_or("").trim()
        };
        if !value.is_empty() {
            return Some(value.to_string());
        }
    }
    None
}

fn file_name_from_url(final_url: &str) -> Option<String> {
    let parsed = url::Url::parse(final_url).ok()?;
    let last = parsed
        .path_segments()?
        .rfind(|s| !s.is_empty())?
        .to_string();
    Some(percent_decode(&last))
}

pub fn file_name_from_url_or_default(url: &str) -> String {
    sanitize_file_name(&file_name_from_url(url).unwrap_or_default())
}

pub async fn probe_download_url(
    http_pool: &HttpClientPool,
    url: &str,
    user_agent: Option<&str>,
    referer: Option<&str>,
    headers_json: Option<&str>,
) -> Result<ProbeResult, CndError> {
    let head_req = HttpClientPool::apply_optional_headers(
        http_pool.head(url)?,
        user_agent,
        referer,
        headers_json,
    );
    let head_outcome = http_pool.send_logged("DL", head_req).await;

    if let Ok(resp) = head_outcome {
        let usable = resp.status().as_u16() < 400
            && header_u64(resp.headers(), CONTENT_LENGTH).is_some();
        if usable {
            let status = resp.status().as_u16();
            let accept_ranges = status == 206
                || resp
                    .headers()
                    .get(ACCEPT_RANGES)
                    .and_then(|v| v.to_str().ok())
                    .is_some_and(|v| v.to_ascii_lowercase().contains("bytes"));
            let total_bytes = total_from_content_range(resp.headers())
                .or_else(|| header_u64(resp.headers(), CONTENT_LENGTH))
                .unwrap_or(0);
            let final_url = resp.url().to_string();
            let real_file_name = file_name_from_content_disposition(resp.headers())
                .or_else(|| file_name_from_url(&final_url))
                .map(|n| sanitize_file_name(&n))
                .unwrap_or_else(|| "download.bin".to_string());
            return Ok(ProbeResult {
                final_url,
                total_bytes,
                accept_ranges,
                real_file_name,
            });
        }
    }

    // Fallback: many IPTV VOD servers reject HEAD or only expose the real size on GET.
    let get_req = HttpClientPool::apply_optional_headers(
        http_pool.get(url)?,
        user_agent,
        referer,
        headers_json,
    )
    .header(RANGE, "bytes=0-0");
    let resp = http_pool.send_logged("DL", get_req).await?;
    let status = resp.status().as_u16();
    if status >= 400 {
        return Err(CndError::Network {
            message: format!("Download probe failed: HTTP {status}"),
        });
    }

    let accept_ranges = status == 206
        || resp
            .headers()
            .get(ACCEPT_RANGES)
            .and_then(|v| v.to_str().ok())
            .is_some_and(|v| v.to_ascii_lowercase().contains("bytes"));
    // A 206 without Content-Range carries a 1-byte Content-Length, which is not the file size.
    let total_bytes = total_from_content_range(resp.headers())
        .or_else(|| {
            if status == 206 {
                None
            } else {
                header_u64(resp.headers(), CONTENT_LENGTH)
            }
        })
        .unwrap_or(0);
    let final_url = resp.url().to_string();
    let real_file_name = file_name_from_content_disposition(resp.headers())
        .or_else(|| file_name_from_url(&final_url))
        .map(|n| sanitize_file_name(&n))
        .unwrap_or_else(|| "download.bin".to_string());
    // Dropping `resp` here closes the connection without reading the body.
    drop(resp);

    Ok(ProbeResult {
        final_url,
        total_bytes,
        accept_ranges,
        real_file_name,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use reqwest::header::HeaderValue;

    #[test]
    fn test_sanitize_and_content_disposition() {
        assert_eq!(sanitize_file_name("a/b\\c:d*e?f\"g<h>i|j.mkv"), "a_b_c_d_e_f_g_h_i_j.mkv");
        assert_eq!(sanitize_file_name(".."), "download.bin");
        assert_eq!(sanitize_file_name("  "), "download.bin");

        let mut h = HeaderMap::new();
        h.insert(
            CONTENT_DISPOSITION,
            HeaderValue::from_static("attachment; filename=\"fallback.mkv\"; filename*=UTF-8''Caf%C3%A9%20Film.mkv"),
        );
        assert_eq!(
            file_name_from_content_disposition(&h).as_deref(),
            Some("Café Film.mkv")
        );
        h.insert(
            CONTENT_DISPOSITION,
            HeaderValue::from_static("attachment; filename=plain.mp4"),
        );
        assert_eq!(
            file_name_from_content_disposition(&h).as_deref(),
            Some("plain.mp4")
        );
        assert_eq!(
            file_name_from_url("http://h/path/My%20Movie.mkv?token=1").as_deref(),
            Some("My Movie.mkv")
        );
    }
}
