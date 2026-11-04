//! Local HTTP server for downloader tests: supports `HEAD`, `Range: bytes=start-end`, a
//! configurable `HEAD` rejection (405), throttling and request recording.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::task::JoinHandle;

#[derive(Debug, Clone)]
pub struct ServerConfig {
    /// Status returned to `HEAD` requests (`200` = served normally, `405` = rejected).
    pub head_status: u16,
    pub ranges: bool,
    pub chunk_size: usize,
    pub chunk_delay_ms: u64,
    pub content_disposition: Option<String>,
}

impl Default for ServerConfig {
    fn default() -> Self {
        Self {
            head_status: 200,
            ranges: true,
            chunk_size: 64 * 1024,
            chunk_delay_ms: 0,
            content_disposition: None,
        }
    }
}

#[derive(Debug, Clone)]
pub struct RecordedRequest {
    pub method: String,
    pub path: String,
    pub range: Option<String>,
}

/// Counts the body transfers (GET) in flight, to check how many connections a download opens.
#[derive(Default)]
pub struct Concurrency {
    active: AtomicUsize,
    peak: AtomicUsize,
}

struct ActiveTransfer(Arc<Concurrency>);

impl ActiveTransfer {
    fn begin(c: &Arc<Concurrency>) -> Self {
        let now = c.active.fetch_add(1, Ordering::SeqCst) + 1;
        c.peak.fetch_max(now, Ordering::SeqCst);
        Self(Arc::clone(c))
    }
}

impl Drop for ActiveTransfer {
    fn drop(&mut self) {
        self.0.active.fetch_sub(1, Ordering::SeqCst);
    }
}

pub struct TestServer {
    addr: std::net::SocketAddr,
    requests: Arc<Mutex<Vec<RecordedRequest>>>,
    concurrency: Arc<Concurrency>,
    accept_task: JoinHandle<()>,
}

impl TestServer {
    pub fn url(&self, path: &str) -> String {
        format!("http://{}{path}", self.addr)
    }

    pub fn requests(&self) -> Vec<RecordedRequest> {
        self.requests.lock().map(|r| r.clone()).unwrap_or_default()
    }

    /// Most body transfers that were in flight at once since the last `reset_peak`.
    pub fn peak_concurrent_gets(&self) -> usize {
        self.concurrency.peak.load(Ordering::SeqCst)
    }

    pub fn reset_peak(&self) {
        self.concurrency.peak.store(0, Ordering::SeqCst);
    }

    pub fn clear_requests(&self) {
        if let Ok(mut r) = self.requests.lock() {
            r.clear();
        }
    }

    pub fn shutdown(&self) {
        self.accept_task.abort();
    }
}

/// Deterministic xorshift64 payload (no external RNG crate needed).
pub fn random_payload(len: usize, seed: u64) -> Vec<u8> {
    let mut state = seed.max(1);
    let mut out = Vec::with_capacity(len);
    while out.len() < len {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        out.extend_from_slice(&state.to_le_bytes());
    }
    out.truncate(len);
    out
}

pub async fn spawn_test_server(payload: Arc<Vec<u8>>, config: ServerConfig) -> TestServer {
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let addr = listener.local_addr().expect("addr");
    let requests = Arc::new(Mutex::new(Vec::new()));
    let log = Arc::clone(&requests);
    let concurrency = Arc::new(Concurrency::default());
    let shared = Arc::clone(&concurrency);

    let accept_task = tokio::spawn(async move {
        loop {
            let Ok((sock, _)) = listener.accept().await else {
                break;
            };
            let payload = Arc::clone(&payload);
            let config = config.clone();
            let log = Arc::clone(&log);
            let concurrency = Arc::clone(&shared);
            tokio::spawn(async move {
                let _ = handle_connection(sock, payload, config, log, concurrency).await;
            });
        }
    });

    TestServer {
        addr,
        requests,
        concurrency,
        accept_task,
    }
}

fn parse_range(value: &str, total: u64) -> Option<(u64, u64)> {
    let spec = value.trim().strip_prefix("bytes=")?;
    let (a, b) = spec.split_once('-')?;
    let start: u64 = a.trim().parse().ok()?;
    let end: u64 = match b.trim() {
        "" => total - 1,
        v => v.parse::<u64>().ok()?.min(total - 1),
    };
    (start <= end && start < total).then_some((start, end))
}

async fn handle_connection(
    mut sock: TcpStream,
    payload: Arc<Vec<u8>>,
    config: ServerConfig,
    log: Arc<Mutex<Vec<RecordedRequest>>>,
    concurrency: Arc<Concurrency>,
) -> std::io::Result<()> {
    let mut raw = Vec::new();
    let mut tmp = [0u8; 2048];
    while !raw.windows(4).any(|w| w == b"\r\n\r\n") {
        let n = sock.read(&mut tmp).await?;
        if n == 0 {
            return Ok(());
        }
        raw.extend_from_slice(&tmp[..n]);
    }
    let text = String::from_utf8_lossy(&raw).into_owned();
    let mut lines = text.lines();
    let mut first = lines.next().unwrap_or("").split_whitespace();
    let method = first.next().unwrap_or("").to_string();
    let path = first.next().unwrap_or("").to_string();
    let range = lines
        .filter_map(|l| l.split_once(':'))
        .find(|(k, _)| k.trim().eq_ignore_ascii_case("range"))
        .map(|(_, v)| v.trim().to_string());

    if let Ok(mut r) = log.lock() {
        r.push(RecordedRequest {
            method: method.clone(),
            path: path.clone(),
            range: range.clone(),
        });
    }

    let total = payload.len() as u64;
    let disposition = config
        .content_disposition
        .as_ref()
        .map(|d| format!("Content-Disposition: {d}\r\n"))
        .unwrap_or_default();
    let accept = if config.ranges { "Accept-Ranges: bytes\r\n" } else { "" };

    if path.starts_with("/missing") {
        sock.write_all(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            .await?;
        return Ok(());
    }

    if method == "HEAD" {
        if config.head_status != 200 {
            let head = format!(
                "HTTP/1.1 {} Method Not Allowed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                config.head_status
            );
            sock.write_all(head.as_bytes()).await?;
        } else {
            let head = format!(
                "HTTP/1.1 200 OK\r\nContent-Length: {total}\r\n{accept}{disposition}Connection: close\r\n\r\n"
            );
            sock.write_all(head.as_bytes()).await?;
        }
        return Ok(());
    }

    let _transfer = ActiveTransfer::begin(&concurrency);
    let (status_line, start, end, content_range) = match range
        .as_deref()
        .filter(|_| config.ranges)
        .and_then(|v| parse_range(v, total))
    {
        Some((s, e)) => (
            "206 Partial Content",
            s,
            e,
            format!("Content-Range: bytes {s}-{e}/{total}\r\n"),
        ),
        None => ("200 OK", 0, total - 1, String::new()),
    };
    let head = format!(
        "HTTP/1.1 {status_line}\r\nContent-Length: {}\r\n{content_range}{accept}{disposition}Connection: close\r\n\r\n",
        end - start + 1
    );
    sock.write_all(head.as_bytes()).await?;

    let mut pos = start as usize;
    let last = end as usize + 1;
    while pos < last {
        let next = (pos + config.chunk_size.max(1)).min(last);
        sock.write_all(&payload[pos..next]).await?;
        pos = next;
        if config.chunk_delay_ms > 0 && pos < last {
            tokio::time::sleep(Duration::from_millis(config.chunk_delay_ms)).await;
        }
    }
    // Everything is written: the transfer is over for the concurrency count, whatever the close takes.
    drop(_transfer);
    sock.shutdown().await.ok();
    Ok(())
}
