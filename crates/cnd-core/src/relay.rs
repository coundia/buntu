//! Single-connection relay for files read by mpv (films, episodes).
//!
//! Many IPTV subscriptions allow ONE connection. To read an MKV, mpv (ffmpeg) seeks: it reads the
//! headers, jumps to the index near the end, comes back. ffmpeg opens the new HTTP connection of a
//! seek **before** closing the old one, so for an instant there are two: the provider answers
//! `429 Connection limit reached` and the film never starts.
//!
//! mpv reads `http://127.0.0.1:<port>/s/<token>` instead. For every request the relay first ends the
//! previous upstream download (the old connection is closed before the new one is opened), then
//! forwards the request with its `Range`. A `429` that comes while the provider has not yet freed the
//! previous slot is retried a few times before being passed on.
//!
//! The address of a film usually redirects (`tv.example` → a token server → the file server). Each
//! pass through the first address opens a NEW session on the provider, refused while the previous
//! one is alive. So the final address is kept after the first answer and every seek goes straight
//! to it; only when it stops working is the original address asked again.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::Notify;

/// What a token stands for: the real address and the headers the source needs.
#[derive(Debug, Clone)]
struct Target {
    url: String,
    headers: Vec<(String, String)>,
}

/// Retries of a `429` from the provider (it frees the previous slot with a small delay).
/// Few and short: a long burst of retries makes the provider block the account for longer.
const RETRY_DELAYS_MS: [u64; 3] = [300, 800, 1_500];
const MAX_HEAD_BYTES: usize = 16 * 1024;

pub struct StreamRelay {
    port: u16,
    targets: Arc<Mutex<HashMap<String, Target>>>,
    counter: AtomicU64,
}

struct Shared {
    targets: Arc<Mutex<HashMap<String, Target>>>,
    client: reqwest::Client,
    /// Bumped by each new request: every older transfer stops at once.
    generation: AtomicU64,
    changed: Notify,
    /// Held while talking to the provider: a new request waits until the previous one has let go.
    upstream: tokio::sync::Mutex<()>,
    /// Where the redirections of a film's address ended, by original address. Kept across tokens, so a
    /// reconnection or reopening the same film reuses the provider's session instead of opening another.
    resolved: Mutex<HashMap<String, String>>,
}

impl StreamRelay {
    /// Starts the relay on its own thread and runtime (independent of the caller's).
    pub fn start(default_user_agent: String) -> Result<Arc<Self>, String> {
        let std_listener = std::net::TcpListener::bind("127.0.0.1:0").map_err(|e| e.to_string())?;
        std_listener.set_nonblocking(true).map_err(|e| e.to_string())?;
        let port = std_listener.local_addr().map_err(|e| e.to_string())?.port();
        let client = reqwest::Client::builder()
            // No idle connection kept: an idle keep-alive socket still counts as "in use" for the provider.
            .pool_max_idle_per_host(0)
            .redirect(reqwest::redirect::Policy::limited(10))
            .connect_timeout(Duration::from_secs(10))
            .read_timeout(Duration::from_secs(30))
            .tcp_nodelay(true)
            .user_agent(if default_user_agent.trim().is_empty() { "VLC/3.0.21 LibVLC/3.0.21".to_string() } else { default_user_agent })
            .build()
            .map_err(|e| e.to_string())?;
        let targets = Arc::new(Mutex::new(HashMap::new()));
        let shared = Arc::new(Shared {
            targets: Arc::clone(&targets),
            client,
            generation: AtomicU64::new(0),
            changed: Notify::new(),
            upstream: tokio::sync::Mutex::new(()),
            resolved: Mutex::new(HashMap::new()),
        });
        std::thread::Builder::new()
            .name("cnd-stream-relay".into())
            .spawn(move || {
                let Ok(rt) = tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build() else { return };
                rt.block_on(async move {
                    let Ok(listener) = TcpListener::from_std(std_listener) else { return };
                    loop {
                        let Ok((socket, _)) = listener.accept().await else { continue };
                        let shared = Arc::clone(&shared);
                        tokio::spawn(async move {
                            let _ = handle(shared, socket).await;
                        });
                    }
                });
            })
            .map_err(|e| e.to_string())?;
        Ok(Arc::new(Self { port, targets, counter: AtomicU64::new(0) }))
    }

    /// A local address for `url`; the headers travel with each upstream request.
    pub fn register(&self, url: &str, headers: Vec<(String, String)>) -> String {
        let n = self.counter.fetch_add(1, Ordering::Relaxed) + 1;
        let token = format!("{n:x}{:x}", std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_nanos() & 0xffff_ffff);
        // Keep the extension: mpv and ffmpeg use it as a hint for the format.
        let ext = url
            .split(['?', '#'])
            .next()
            .and_then(|p| p.rsplit('/').next())
            .and_then(|name| name.rsplit_once('.').map(|(_, e)| e.to_ascii_lowercase()))
            .filter(|e| !e.is_empty() && e.len() <= 5 && e.chars().all(|c| c.is_ascii_alphanumeric()));
        if let Ok(mut map) = self.targets.lock() {
            // A handful of recent titles is enough (one plays at a time).
            if map.len() > 32 {
                map.clear();
            }
            map.insert(token.clone(), Target { url: url.to_string(), headers });
        }
        match ext {
            Some(e) => format!("http://127.0.0.1:{}/s/{token}.{e}", self.port),
            None => format!("http://127.0.0.1:{}/s/{token}", self.port),
        }
    }
}

/// Reads the request head: method, path, and the `Range` header.
async fn read_head(socket: &mut TcpStream) -> Option<(String, String, Option<String>)> {
    let mut buf = Vec::with_capacity(1024);
    let mut chunk = [0u8; 2048];
    loop {
        let n = socket.read(&mut chunk).await.ok()?;
        if n == 0 {
            return None;
        }
        buf.extend_from_slice(&chunk[..n]);
        if buf.windows(4).any(|w| w == b"\r\n\r\n") {
            break;
        }
        if buf.len() > MAX_HEAD_BYTES {
            return None;
        }
    }
    let text = String::from_utf8_lossy(&buf);
    let mut lines = text.split("\r\n");
    let mut first = lines.next()?.split_whitespace();
    let method = first.next()?.to_string();
    let path = first.next()?.to_string();
    let range = lines
        .take_while(|l| !l.is_empty())
        .filter_map(|l| l.split_once(':'))
        .find(|(k, _)| k.trim().eq_ignore_ascii_case("range"))
        .map(|(_, v)| v.trim().to_string());
    Some((method, path, range))
}

fn token_of(path: &str) -> Option<String> {
    let rest = path.strip_prefix("/s/")?;
    let rest = rest.split(['?', '#']).next()?;
    Some(rest.split('.').next()?.to_string())
}

async fn respond_plain(socket: &mut TcpStream, status: &str) {
    let _ = socket
        .write_all(format!("HTTP/1.1 {status}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").as_bytes())
        .await;
}

fn debug(msg: impl AsRef<str>) {
    if std::env::var_os("CND_RELAY_DEBUG").is_some() {
        eprintln!("[relay {:?}] {}", std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_millis() % 100_000, msg.as_ref());
    }
}

async fn handle(shared: Arc<Shared>, mut socket: TcpStream) -> Option<()> {
    let (method, path, range) = read_head(&mut socket).await?;
    debug(format!("{method} range={range:?}"));
    let token = token_of(&path)?;
    let target = shared.targets.lock().ok()?.get(&token).cloned();
    let Some(target) = target else {
        respond_plain(&mut socket, "404 Not Found").await;
        return None;
    };
    let head_only = method.eq_ignore_ascii_case("HEAD");

    // This request replaces every older one: they stop, and their upstream connection is dropped
    // before ours is opened.
    let mine = shared.generation.fetch_add(1, Ordering::SeqCst) + 1;
    shared.changed.notify_waiters();
    let _upstream = shared.upstream.lock().await;
    if shared.generation.load(Ordering::SeqCst) != mine {
        // An even newer request came while we waited.
        return None;
    }

    let mut attempt = 0;
    let kept = shared.resolved.lock().ok().and_then(|m| m.get(&target.url).cloned());
    let mut address = kept.unwrap_or_else(|| target.url.clone());
    let response = loop {
        let mut request = if head_only { shared.client.head(&address) } else { shared.client.get(&address) };
        for (k, v) in &target.headers {
            request = request.header(k.as_str(), v.as_str());
        }
        if let Some(r) = &range {
            request = request.header("Range", r.as_str());
        }
        let replaced = shared.changed.notified();
        tokio::pin!(replaced);
        replaced.as_mut().enable();
        if shared.generation.load(Ordering::SeqCst) != mine {
            return None;
        }
        let resp = tokio::select! {
            r = request.send() => r,
            _ = &mut replaced => return None,
        };
        let using_resolved = address != target.url;
        match resp {
            Ok(r) if r.status().is_success() || r.status().as_u16() == 416 => {
                // Keep where the redirections ended: the next requests (seeks) go straight there.
                if !using_resolved {
                    let final_url = r.url().to_string();
                    if final_url != target.url {
                        if let Ok(mut map) = shared.resolved.lock() {
                            if map.len() > 64 {
                                map.clear();
                            }
                            map.insert(target.url.clone(), final_url);
                        }
                    }
                }
                break r;
            }
            // The kept address expired: ask the original one again (new redirection), once.
            Ok(r) if using_resolved && r.status().as_u16() != 429 => {
                drop(r);
                if let Ok(mut map) = shared.resolved.lock() {
                    map.remove(&target.url);
                }
                address = target.url.clone();
            }
            Err(_) if using_resolved => {
                address = target.url.clone();
            }
            Ok(r) if r.status().as_u16() == 429 && attempt < RETRY_DELAYS_MS.len() => {
                drop(r);
                tokio::time::sleep(Duration::from_millis(RETRY_DELAYS_MS[attempt])).await;
                attempt += 1;
                if shared.generation.load(Ordering::SeqCst) != mine {
                    return None;
                }
            }
            Ok(r) => break r,
            Err(_) => {
                respond_plain(&mut socket, "502 Bad Gateway").await;
                return None;
            }
        }
    };

    let status = response.status();
    debug(format!("upstream {} via {} len={:?}", status, if response.url().as_str() == target.url { "original" } else { "resolved" }, response.headers().get("content-length")));
    let mut head = format!("HTTP/1.1 {} {}\r\n", status.as_u16(), status.canonical_reason().unwrap_or(""));
    for name in ["content-length", "content-range", "content-type", "accept-ranges", "last-modified", "etag"] {
        if let Some(value) = response.headers().get(name).and_then(|v| v.to_str().ok()) {
            head.push_str(&format!("{name}: {value}\r\n"));
        }
    }
    head.push_str("Connection: close\r\n\r\n");
    socket.write_all(head.as_bytes()).await.ok()?;
    if head_only {
        return Some(());
    }

    let mut response = response;
    loop {
        // Armed before the check, so a replacement that arrives in between is not missed. Writing to mpv
        // can block (it stops reading the old connection without closing it): the wait covers it too.
        let replaced = shared.changed.notified();
        tokio::pin!(replaced);
        replaced.as_mut().enable();
        if shared.generation.load(Ordering::SeqCst) != mine {
            // Replaced: dropping `response` closes the provider connection.
            debug("replaced");
            return None;
        }
        let step = async {
            match response.chunk().await {
                Ok(Some(bytes)) => socket.write_all(&bytes).await.map(|_| true).map_err(|_| ()),
                Ok(None) => Ok(false),
                Err(_) => Err(()),
            }
        };
        tokio::select! {
            outcome = step => match outcome {
                Ok(true) => continue,
                Ok(false) => return Some(()),
                Err(()) => return None,
            },
            _ = &mut replaced => return None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicUsize;

    /// A provider with ONE connection: a second open connection gets `429`, like the real one.
    async fn one_connection_server(body: Vec<u8>) -> (String, Arc<AtomicUsize>, Arc<AtomicUsize>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let open = Arc::new(AtomicUsize::new(0));
        let refused = Arc::new(AtomicUsize::new(0));
        let (open_c, refused_c) = (Arc::clone(&open), Arc::clone(&refused));
        let body = Arc::new(body);
        tokio::spawn(async move {
            loop {
                let Ok((mut s, _)) = listener.accept().await else { break };
                let (open, refused, body) = (Arc::clone(&open_c), Arc::clone(&refused_c), Arc::clone(&body));
                tokio::spawn(async move {
                    let Some((_, _, range)) = read_head(&mut s).await else { return };
                    if open.fetch_add(1, Ordering::SeqCst) >= 1 {
                        open.fetch_sub(1, Ordering::SeqCst);
                        refused.fetch_add(1, Ordering::SeqCst);
                        let msg = "Connection limit reached.";
                        let _ = s.write_all(format!("HTTP/1.1 429 Too Many Requests\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{msg}", msg.len()).as_bytes()).await;
                        return;
                    }
                    let start: usize = range
                        .as_deref()
                        .and_then(|r| r.strip_prefix("bytes="))
                        .and_then(|r| r.split('-').next())
                        .and_then(|v| v.parse().ok())
                        .unwrap_or(0);
                    let part = &body[start.min(body.len())..];
                    let head = format!(
                        "HTTP/1.1 206 Partial Content\r\nContent-Length: {}\r\nContent-Range: bytes {start}-{}/{}\r\nAccept-Ranges: bytes\r\n\r\n",
                        part.len(),
                        body.len() - 1,
                        body.len()
                    );
                    let _ = s.write_all(head.as_bytes()).await;
                    // Slow body: the connection stays open as a film download does.
                    for piece in part.chunks(4096) {
                        if s.write_all(piece).await.is_err() {
                            break;
                        }
                        tokio::time::sleep(Duration::from_millis(5)).await;
                    }
                    open.fetch_sub(1, Ordering::SeqCst);
                });
            }
        });
        (format!("http://{addr}/movie/u/p/1.mkv"), open, refused)
    }

    async fn get(url: &str, range: &str) -> (u16, Vec<u8>, TcpStream) {
        let addr = url.trim_start_matches("http://").split('/').next().unwrap().to_string();
        let path = format!("/{}", url.trim_start_matches("http://").split_once('/').unwrap().1);
        let mut s = TcpStream::connect(addr).await.unwrap();
        s.write_all(format!("GET {path} HTTP/1.1\r\nHost: x\r\nRange: {range}\r\n\r\n").as_bytes()).await.unwrap();
        let mut head = Vec::new();
        let mut b = [0u8; 1];
        while !head.ends_with(b"\r\n\r\n") {
            if s.read(&mut b).await.unwrap() == 0 {
                break;
            }
            head.push(b[0]);
        }
        let status = String::from_utf8_lossy(&head).split_whitespace().nth(1).unwrap_or("0").parse().unwrap_or(0);
        let mut first = vec![0u8; 16];
        let n = s.read(&mut first).await.unwrap_or(0);
        first.truncate(n);
        (status, first, s)
    }

    #[tokio::test]
    async fn a_seek_works_on_a_one_connection_provider() {
        let body: Vec<u8> = (0..400_000u32).map(|i| (i % 251) as u8).collect();
        let (url, _open, refused) = one_connection_server(body.clone()).await;
        let relay = StreamRelay::start(String::new()).unwrap();
        let local = relay.register(&url, vec![]);
        assert!(local.ends_with(".mkv"), "{local}");

        // Like ffmpeg: the first connection is still open when the seek opens the second.
        let (s1, first, _keep_open) = get(&local, "bytes=0-").await;
        assert_eq!(s1, 206);
        assert_eq!(first[..], body[..first.len()]);
        let (s2, at_end, _keep) = get(&local, "bytes=300000-").await;
        assert_eq!(s2, 206, "the seek gets its data");
        assert_eq!(at_end[..], body[300_000..300_000 + at_end.len()]);
        let (s3, back, _k) = get(&local, "bytes=7000-").await;
        assert_eq!(s3, 206, "and so does the way back");
        assert_eq!(back[..], body[7_000..7_000 + back.len()]);
        // The provider notices a closed connection a moment late (like the real one): its refusals in
        // that window are retried by the relay, never passed to mpv.
        assert!(refused.load(Ordering::SeqCst) <= 4, "{}", refused.load(Ordering::SeqCst));
    }

    /// The real provider: the film's address redirects to a file server, and passing through the film's
    /// address again (a new session) is refused while the first session is alive.
    async fn redirecting_server(body: Vec<u8>) -> (String, Arc<AtomicUsize>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let entry_hits = Arc::new(AtomicUsize::new(0));
        let hits = Arc::clone(&entry_hits);
        let body = Arc::new(body);
        tokio::spawn(async move {
            loop {
                let Ok((mut s, _)) = listener.accept().await else { break };
                let (hits, body) = (Arc::clone(&hits), Arc::clone(&body));
                tokio::spawn(async move {
                    let Some((_, path, range)) = read_head(&mut s).await else { return };
                    if path.starts_with("/movie/") {
                        let reply = if hits.fetch_add(1, Ordering::SeqCst) == 0 {
                            format!("HTTP/1.1 302 Found\r\nLocation: http://{addr}/file/session1.mkv\r\nContent-Length: 0\r\n\r\n")
                        } else {
                            "HTTP/1.1 429 Too Many Requests\r\nContent-Length: 0\r\n\r\n".to_string()
                        };
                        let _ = s.write_all(reply.as_bytes()).await;
                        return;
                    }
                    let start: usize = range
                        .as_deref()
                        .and_then(|r| r.strip_prefix("bytes="))
                        .and_then(|r| r.split('-').next())
                        .and_then(|v| v.parse().ok())
                        .unwrap_or(0);
                    let part = &body[start.min(body.len())..];
                    let head = format!(
                        "HTTP/1.1 206 Partial Content\r\nContent-Length: {}\r\nContent-Range: bytes {start}-{}/{}\r\n\r\n",
                        part.len(),
                        body.len() - 1,
                        body.len()
                    );
                    let _ = s.write_all(head.as_bytes()).await;
                    let _ = s.write_all(part).await;
                });
            }
        });
        (format!("http://{addr}/movie/u/p/1.mkv"), entry_hits)
    }

    #[tokio::test]
    async fn seeks_go_straight_to_the_redirected_address() {
        let body: Vec<u8> = (0..200_000u32).map(|i| (i % 241) as u8).collect();
        let (url, entry_hits) = redirecting_server(body.clone()).await;
        let relay = StreamRelay::start(String::new()).unwrap();
        let local = relay.register(&url, vec![]);
        let (s1, first, _a) = get(&local, "bytes=0-").await;
        assert_eq!(s1, 206);
        assert_eq!(first[..], body[..first.len()]);
        let (s2, end, _b) = get(&local, "bytes=150000-").await;
        assert_eq!(s2, 206, "the seek is not sent through the film's address again");
        assert_eq!(end[..], body[150_000..150_000 + end.len()]);
        let (s3, _, _c) = get(&local, "bytes=7000-").await;
        assert_eq!(s3, 206);
        assert_eq!(entry_hits.load(Ordering::SeqCst), 1, "one session only");
        // The player reconnects (a new local address for the same film): still the same session.
        let again = relay.register(&url, vec![]);
        assert_ne!(again, local);
        let (s4, _, _d) = get(&again, "bytes=0-").await;
        assert_eq!(s4, 206);
        assert_eq!(entry_hits.load(Ordering::SeqCst), 1, "a reconnection reuses the session");
    }

    #[tokio::test]
    async fn an_unknown_token_is_not_found() {
        let relay = StreamRelay::start(String::new()).unwrap();
        let local = relay.register("http://127.0.0.1:9/x.mkv", vec![]);
        let wrong = local.replace("/s/", "/s/zz");
        let (status, _, _) = get(&wrong, "bytes=0-").await;
        assert_eq!(status, 404);
    }

    #[test]
    fn the_extension_is_kept_and_tokens_differ() {
        let relay = StreamRelay::start(String::new()).unwrap();
        let a = relay.register("http://h/movie/u/p/1.mkv?x=1", vec![]);
        let b = relay.register("http://h/movie/u/p/1.mkv", vec![]);
        assert!(a.ends_with(".mkv") && b.ends_with(".mkv"));
        assert_ne!(a, b);
        assert!(relay.register("http://h/live/u/p/1", vec![]).rsplit('/').next().is_some_and(|t| !t.contains('.')));
    }
}
