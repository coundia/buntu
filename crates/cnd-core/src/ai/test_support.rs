//! A tiny HTTP server standing in for a model provider: scripted answers, recorded requests.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use tokio::task::JoinHandle;

#[derive(Debug, Clone)]
pub struct MockResponse {
    pub status: u16,
    pub body: String,
    pub delay_ms: u64,
    pub headers: Vec<(String, String)>,
}

impl MockResponse {
    pub fn ok(body: impl Into<String>) -> Self {
        Self { status: 200, body: body.into(), delay_ms: 0, headers: Vec::new() }
    }

    pub fn status(status: u16, body: impl Into<String>) -> Self {
        Self { status, body: body.into(), delay_ms: 0, headers: Vec::new() }
    }

    pub fn delayed(mut self, delay_ms: u64) -> Self {
        self.delay_ms = delay_ms;
        self
    }

    pub fn header(mut self, name: &str, value: &str) -> Self {
        self.headers.push((name.to_string(), value.to_string()));
        self
    }
}

#[derive(Debug, Clone)]
pub struct RecordedCall {
    pub method: String,
    pub path: String,
    /// Lower-cased header names.
    pub headers: HashMap<String, String>,
    pub body: String,
}

pub struct MockProvider {
    pub base_url: String,
    calls: Arc<Mutex<Vec<RecordedCall>>>,
    task: JoinHandle<()>,
}

impl MockProvider {
    /// Answers requests in order; the last response repeats.
    pub async fn start(responses: Vec<MockResponse>) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
        let addr = listener.local_addr().expect("addr");
        let calls = Arc::new(Mutex::new(Vec::new()));
        let queue = Arc::new(Mutex::new(responses));
        let calls_task = Arc::clone(&calls);
        let task = tokio::spawn(async move {
            loop {
                let Ok((mut socket, _)) = listener.accept().await else { break };
                let calls = Arc::clone(&calls_task);
                let queue = Arc::clone(&queue);
                tokio::spawn(async move {
                    let mut raw = Vec::new();
                    let mut buf = [0u8; 4096];
                    let (head_end, content_length) = loop {
                        let n = match socket.read(&mut buf).await {
                            Ok(0) | Err(_) => return,
                            Ok(n) => n,
                        };
                        raw.extend_from_slice(&buf[..n]);
                        if let Some(pos) = raw.windows(4).position(|w| w == b"\r\n\r\n") {
                            let head = String::from_utf8_lossy(&raw[..pos]).to_ascii_lowercase();
                            let length = head
                                .lines()
                                .find_map(|l| l.strip_prefix("content-length:"))
                                .and_then(|v| v.trim().parse::<usize>().ok())
                                .unwrap_or(0);
                            break (pos + 4, length);
                        }
                    };
                    while raw.len() < head_end + content_length {
                        match socket.read(&mut buf).await {
                            Ok(0) | Err(_) => break,
                            Ok(n) => raw.extend_from_slice(&buf[..n]),
                        }
                    }
                    let head = String::from_utf8_lossy(&raw[..head_end]).to_string();
                    let mut lines = head.lines();
                    let mut first = lines.next().unwrap_or("").split_whitespace();
                    let method = first.next().unwrap_or("").to_string();
                    let path = first.next().unwrap_or("").to_string();
                    let headers = lines
                        .filter_map(|l| l.split_once(':'))
                        .map(|(k, v)| (k.trim().to_ascii_lowercase(), v.trim().to_string()))
                        .collect();
                    let body = String::from_utf8_lossy(&raw[head_end..]).to_string();
                    calls.lock().unwrap().push(RecordedCall { method, path, headers, body });

                    let response = {
                        let mut q = queue.lock().unwrap();
                        if q.len() > 1 { q.remove(0) } else { q.first().cloned().unwrap_or_else(|| MockResponse::ok("{}")) }
                    };
                    if response.delay_ms > 0 {
                        tokio::time::sleep(Duration::from_millis(response.delay_ms)).await;
                    }
                    let mut out = format!(
                        "HTTP/1.1 {} X\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n",
                        response.status,
                        response.body.len()
                    );
                    for (k, v) in &response.headers {
                        out.push_str(&format!("{k}: {v}\r\n"));
                    }
                    out.push_str("\r\n");
                    out.push_str(&response.body);
                    let _ = socket.write_all(out.as_bytes()).await;
                    let _ = socket.shutdown().await;
                });
            }
        });
        Self { base_url: format!("http://{addr}"), calls, task }
    }

    pub fn calls(&self) -> Vec<RecordedCall> {
        self.calls.lock().unwrap().clone()
    }
}

impl Drop for MockProvider {
    fn drop(&mut self) {
        self.task.abort();
    }
}
