use crate::http_client::HttpClientPool;
use futures_util::StreamExt;
use reqwest::header::RANGE;
use std::fs::File;
use std::os::unix::fs::FileExt;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;
use tokio_util::sync::CancellationToken;

/// Network chunks are accumulated up to this size before a single `pwrite`.
const FLUSH_THRESHOLD: usize = 256 * 1024;
const BUFFER_CAPACITY: usize = 512 * 1024;
const MAX_RETRIES: u32 = 5;
const BACKOFF_BASE_MS: u64 = 250;
const BACKOFF_MAX_MS: u64 = 8_000;

/// Sentinel `end` for a stream of unknown length.
pub const UNBOUNDED_END: u64 = u64::MAX;

pub struct SegmentSpec {
    pub http_pool: Arc<HttpClientPool>,
    pub url: String,
    pub user_agent: Option<String>,
    pub referer: Option<String>,
    pub headers_json: Option<String>,
    pub file: Arc<File>,
    /// First byte of the segment (absolute file offset).
    pub start: u64,
    /// Last byte (inclusive) of the segment, or [`UNBOUNDED_END`] when the size is unknown.
    pub end: u64,
    /// Whether the server honours `Range` requests.
    pub ranged: bool,
    /// Bytes of this segment already persisted in the file (shared with the orchestrator).
    pub progress: Arc<AtomicU64>,
    pub token: CancellationToken,
}

#[derive(Debug)]
pub struct SegmentError {
    pub message: String,
    pub retryable: bool,
}

enum PassEnd {
    Finished,
    Cancelled,
}

impl SegmentSpec {
    fn segment_len(&self) -> u64 {
        if self.end == UNBOUNDED_END {
            u64::MAX
        } else {
            self.end - self.start + 1
        }
    }

    fn is_complete(&self) -> bool {
        self.end != UNBOUNDED_END && self.progress.load(Ordering::Acquire) >= self.segment_len()
    }
}

/// Writes `buf` at the segment's current offset with `pwrite`, with no lock around the file.
async fn flush_buffer(
    spec: &SegmentSpec,
    buf: &mut Vec<u8>,
) -> Result<(), SegmentError> {
    if buf.is_empty() {
        return Ok(());
    }
    let offset = spec.start + spec.progress.load(Ordering::Acquire);
    let file = Arc::clone(&spec.file);
    let data = std::mem::take(buf);
    let (data, result) = tokio::task::spawn_blocking(move || {
        let res = file.write_all_at(&data, offset);
        (data, res)
    })
    .await
    .map_err(|e| SegmentError {
        message: format!("write task failed: {e}"),
        retryable: false,
    })?;
    let written = data.len() as u64;
    *buf = data;
    buf.clear();
    result.map_err(|e| SegmentError {
        message: format!("disk write failed: {e}"),
        retryable: false,
    })?;
    spec.progress.fetch_add(written, Ordering::AcqRel);
    Ok(())
}

async fn stream_pass(spec: &SegmentSpec, buf: &mut Vec<u8>) -> Result<PassEnd, SegmentError> {
    let done = spec.progress.load(Ordering::Acquire);
    let offset = spec.start + done;

    let mut req = HttpClientPool::apply_optional_headers(
        spec.http_pool.get(&spec.url).map_err(|e| SegmentError {
            message: e.to_string(),
            retryable: false,
        })?,
        spec.user_agent.as_deref(),
        spec.referer.as_deref(),
        spec.headers_json.as_deref(),
    );
    if spec.ranged {
        let range = if spec.end == UNBOUNDED_END {
            format!("bytes={offset}-")
        } else {
            format!("bytes={offset}-{}", spec.end)
        };
        req = req.header(RANGE, range);
    }

    let resp = tokio::select! {
        biased;
        _ = spec.token.cancelled() => return Ok(PassEnd::Cancelled),
        r = spec.http_pool.send_logged("DL", req) => r.map_err(|e| SegmentError {
            message: e.to_string(),
            retryable: true,
        })?,
    };

    let status = resp.status().as_u16();
    if status >= 400 {
        let retryable = status >= 500 || status == 408 || status == 429;
        return Err(SegmentError {
            message: format!("HTTP {status}"),
            retryable,
        });
    }
    // A 200 to a ranged request is only usable when it starts at byte 0 of the file.
    if spec.ranged && status != 206 && offset != 0 {
        return Err(SegmentError {
            message: format!("server ignored Range (HTTP {status})"),
            retryable: false,
        });
    }

    let mut stream = resp.bytes_stream();
    loop {
        let next = tokio::select! {
            biased;
            _ = spec.token.cancelled() => {
                // Persist what was already received so the resume offset is exact.
                flush_buffer(spec, buf).await?;
                return Ok(PassEnd::Cancelled);
            }
            n = stream.next() => n,
        };

        match next {
            None => {
                flush_buffer(spec, buf).await?;
                return Ok(PassEnd::Finished);
            }
            Some(Err(e)) => {
                flush_buffer(spec, buf).await?;
                return Err(SegmentError {
                    message: crate::telemetry::redact_text(&e.to_string()),
                    retryable: true,
                });
            }
            Some(Ok(chunk)) => {
                let pending = buf.len() as u64;
                let have = spec.progress.load(Ordering::Acquire) + pending;
                let remaining = spec.segment_len().saturating_sub(have);
                let take = (chunk.len() as u64).min(remaining) as usize;
                buf.extend_from_slice(&chunk[..take]);
                let reached_end = take as u64 == remaining;
                if buf.len() >= FLUSH_THRESHOLD || reached_end {
                    flush_buffer(spec, buf).await?;
                }
                if reached_end {
                    return Ok(PassEnd::Finished);
                }
            }
        }
    }
}

/// Downloads one segment into the shared file, retrying with exponential backoff and resuming
/// from the last persisted byte. Returns `Ok(())` both on completion and on cancellation; the
/// caller checks `progress` to tell them apart.
pub async fn run_segment(spec: SegmentSpec) -> Result<(), SegmentError> {
    let mut buf: Vec<u8> = Vec::with_capacity(BUFFER_CAPACITY);
    let mut attempt = 0u32;

    loop {
        if spec.is_complete() {
            return Ok(());
        }
        if !spec.ranged {
            // Without Range support a retry must restart the stream from the beginning.
            spec.progress.store(0, Ordering::Release);
        }
        let before = spec.progress.load(Ordering::Acquire);

        match stream_pass(&spec, &mut buf).await {
            Ok(PassEnd::Cancelled) => return Ok(()),
            Ok(PassEnd::Finished) => {
                if spec.end == UNBOUNDED_END || spec.is_complete() {
                    return Ok(());
                }
                // Premature EOF: treat as a retryable network error.
                if spec.progress.load(Ordering::Acquire) > before {
                    attempt = 0;
                }
                attempt += 1;
                if attempt > MAX_RETRIES {
                    return Err(SegmentError {
                        message: "connection closed before the end of the segment".to_string(),
                        retryable: false,
                    });
                }
            }
            Err(err) => {
                if !err.retryable {
                    return Err(err);
                }
                if spec.progress.load(Ordering::Acquire) > before {
                    attempt = 0;
                }
                attempt += 1;
                if attempt > MAX_RETRIES {
                    return Err(err);
                }
            }
        }

        let backoff = (BACKOFF_BASE_MS << (attempt - 1)).min(BACKOFF_MAX_MS);
        tokio::select! {
            biased;
            _ = spec.token.cancelled() => return Ok(()),
            _ = tokio::time::sleep(Duration::from_millis(backoff)) => {}
        }
    }
}
