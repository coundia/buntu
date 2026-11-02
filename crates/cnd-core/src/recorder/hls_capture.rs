use super::ts_capture::CaptureResult;
use crate::CndError;
use std::collections::HashSet;
use std::path::Path;
use std::time::{Duration, Instant};
use tokio::fs::OpenOptions;
use tokio::io::AsyncWriteExt;
use tokio_util::sync::CancellationToken;
use url::Url;

#[allow(clippy::too_many_arguments)]
pub async fn capture_hls_stream(
    client: &reqwest::Client,
    playlist_url: &str,
    user_agent: Option<&str>,
    referer: Option<&str>,
    target_path: &Path,
    deadline: Instant,
    cancel_token: CancellationToken,
    progress_callback: Option<Box<dyn Fn(u64) + Send + Sync>>,
) -> Result<CaptureResult, CndError> {
    if let Some(parent) = target_path.parent() {
        tokio::fs::create_dir_all(parent).await.map_err(|e| CndError::Internal {
            message: format!("Cannot create recording directory: {e}"),
        })?;
    }

    let part_path = target_path.with_extension("ts.part");
    let mut file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(&part_path)
        .await
        .map_err(|e| CndError::Internal {
            message: format!("Cannot open recording file {part_path:?}: {e}"),
        })?;

    let mut bytes_written: u64 = file.metadata().await.map(|m| m.len()).unwrap_or(0);
    let mut seen_sequences: HashSet<u64> = HashSet::new();
    let mut current_playlist_url = playlist_url.to_string();
    let mut consecutive_dropout_start: Option<Instant> = None;
    let mut is_partial = false;
    let mut stream_ended = false;

    while Instant::now() < deadline && !cancel_token.is_cancelled() && !stream_ended {
        let mut req = client.get(&current_playlist_url);
        if let Some(ua) = user_agent {
            req = req.header("User-Agent", ua);
        }
        if let Some(ref_) = referer {
            req = req.header("Referer", ref_);
        }

        let resp = match req.send().await {
            Ok(r) if r.status().is_success() => {
                consecutive_dropout_start = None;
                r
            }
            _ => {
                let dropout = consecutive_dropout_start.get_or_insert_with(Instant::now);
                if dropout.elapsed() > Duration::from_secs(60) {
                    is_partial = true;
                    break;
                }
                tokio::time::sleep(Duration::from_millis(1500)).await;
                continue;
            }
        };

        let body = match resp.text().await {
            Ok(b) => b,
            Err(_) => {
                tokio::time::sleep(Duration::from_millis(1000)).await;
                continue;
            }
        };

        // Master playlist check: if it points to variant playlists
        if body.contains("#EXT-X-STREAM-INF") {
            if let Some(sub_url) = extract_first_variant_url(&current_playlist_url, &body) {
                current_playlist_url = sub_url;
                continue;
            }
        }

        // Check encryption
        for line in body.lines() {
            if line.starts_with("#EXT-X-KEY:") {
                let upper = line.to_uppercase();
                if !upper.contains("METHOD=NONE") {
                    let _ = file.flush().await;
                    drop(file);
                    let _ = tokio::fs::remove_file(&part_path).await;
                    return Err(CndError::Parse {
                        message: "Les flux HLS chiffrés (EXT-X-KEY) ne sont pas pris en charge pour le PVR".to_string(),
                    });
                }
            }
            if line.starts_with("#EXT-X-ENDLIST") {
                stream_ended = true;
            }
        }

        let target_duration_secs = extract_target_duration(&body).unwrap_or(2.0);
        let media_seq = extract_media_sequence(&body).unwrap_or(0);
        let segments = extract_segment_uris(&current_playlist_url, &body);

        for (idx, seg_url) in segments.into_iter().enumerate() {
            let seq = media_seq + idx as u64;
            if seen_sequences.contains(&seq) {
                continue;
            }

            if Instant::now() >= deadline || cancel_token.is_cancelled() {
                break;
            }

            let mut seg_req = client.get(&seg_url);
            if let Some(ua) = user_agent {
                seg_req = seg_req.header("User-Agent", ua);
            }
            if let Some(ref_) = referer {
                seg_req = seg_req.header("Referer", ref_);
            }

            if let Ok(seg_resp) = seg_req.send().await {
                if seg_resp.status().is_success() {
                    if let Ok(seg_bytes) = seg_resp.bytes().await {
                        if file.write_all(&seg_bytes).await.is_ok() {
                            bytes_written += seg_bytes.len() as u64;
                            seen_sequences.insert(seq);
                            if let Some(ref cb) = progress_callback {
                                cb(bytes_written);
                            }
                        }
                    }
                }
            }
        }

        let sleep_duration = Duration::from_secs_f64((target_duration_secs / 2.0).clamp(1.0, 5.0));
        tokio::time::sleep(sleep_duration).await;
    }

    let _ = file.flush().await;
    drop(file);

    if bytes_written > 0 {
        let _ = tokio::fs::rename(&part_path, target_path).await;
    } else {
        let _ = tokio::fs::remove_file(&part_path).await;
    }

    Ok(CaptureResult {
        bytes_written,
        is_partial,
        final_path: target_path.to_path_buf(),
    })
}

fn extract_target_duration(body: &str) -> Option<f64> {
    for line in body.lines() {
        if line.starts_with("#EXT-X-TARGETDURATION:") {
            let raw = line.trim_start_matches("#EXT-X-TARGETDURATION:").trim();
            if let Ok(secs) = raw.parse::<f64>() {
                return Some(secs);
            }
        }
    }
    None
}

fn extract_media_sequence(body: &str) -> Option<u64> {
    for line in body.lines() {
        if line.starts_with("#EXT-X-MEDIA-SEQUENCE:") {
            let raw = line.trim_start_matches("#EXT-X-MEDIA-SEQUENCE:").trim();
            if let Ok(seq) = raw.parse::<u64>() {
                return Some(seq);
            }
        }
    }
    None
}

fn extract_segment_uris(base_url: &str, body: &str) -> Vec<String> {
    let mut uris = Vec::new();
    let base = Url::parse(base_url).ok();

    let mut is_next_segment = false;
    for line in body.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }

        if trimmed.starts_with("#EXTINF:") {
            is_next_segment = true;
            continue;
        }

        if is_next_segment && !trimmed.starts_with('#') {
            is_next_segment = false;
            let full_url = if trimmed.starts_with("http://") || trimmed.starts_with("https://") {
                trimmed.to_string()
            } else if let Some(ref b) = base {
                b.join(trimmed).map(|u| u.to_string()).unwrap_or_else(|_| trimmed.to_string())
            } else {
                trimmed.to_string()
            };
            uris.push(full_url);
        }
    }

    uris
}

fn extract_first_variant_url(base_url: &str, body: &str) -> Option<String> {
    let base = Url::parse(base_url).ok();
    let mut is_next_variant = false;

    for line in body.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with("#EXT-X-STREAM-INF:") {
            is_next_variant = true;
            continue;
        }

        if is_next_variant && !trimmed.starts_with('#') {
            let full_url = if trimmed.starts_with("http://") || trimmed.starts_with("https://") {
                trimmed.to_string()
            } else if let Some(ref b) = base {
                b.join(trimmed).map(|u| u.to_string()).unwrap_or_else(|_| trimmed.to_string())
            } else {
                trimmed.to_string()
            };
            return Some(full_url);
        }
    }

    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_extract_hls_metadata() {
        let manifest = r#"#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:6
#EXT-X-MEDIA-SEQUENCE:105
#EXTINF:6.0,
segment105.ts
#EXTINF:6.0,
segment106.ts
#EXT-X-ENDLIST
"#;
        assert_eq!(extract_target_duration(manifest), Some(6.0));
        assert_eq!(extract_media_sequence(manifest), Some(105));
        let segs = extract_segment_uris("http://live.com/hls/index.m3u8", manifest);
        assert_eq!(segs.len(), 2);
        assert_eq!(segs[0], "http://live.com/hls/segment105.ts");
        assert_eq!(segs[1], "http://live.com/hls/segment106.ts");
    }

    #[test]
    fn test_extract_first_variant() {
        let master = r#"#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=1280000,RESOLUTION=1280x720
720p.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2560000,RESOLUTION=1920x1080
1080p.m3u8
"#;
        let variant = extract_first_variant_url("http://live.com/hls/master.m3u8", master);
        assert_eq!(variant, Some("http://live.com/hls/720p.m3u8".to_string()));
    }
}
