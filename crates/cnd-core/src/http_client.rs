use crate::db::settings_repo::RuntimeSettings;
use crate::telemetry::{redact_text, LogLevel, TelemetryHub};
use crate::CndError;
use reqwest::header::{HeaderName, HeaderValue, COOKIE, REFERER, SET_COOKIE, USER_AGENT};
use std::collections::HashMap;
use std::sync::{Arc, RwLock};
use std::time::{Duration, Instant};

#[derive(Default)]
struct LightweightCookieJar {
    by_host: RwLock<HashMap<String, HashMap<String, String>>>,
}

impl LightweightCookieJar {
    fn store_from_response(&self, host: Option<&str>, headers: &reqwest::header::HeaderMap) {
        let Some(host_key) = host.map(|h| h.to_ascii_lowercase()) else {
            return;
        };
        let mut parsed = Vec::new();
        for val in headers.get_all(SET_COOKIE) {
            if let Ok(raw) = val.to_str() {
                let first_part = raw.split(';').next().unwrap_or("").trim();
                if let Some((k, v)) = first_part.split_once('=') {
                    let k = k.trim();
                    let v = v.trim();
                    if !k.is_empty() {
                        parsed.push((k.to_string(), v.to_string()));
                    }
                }
            }
        }
        if parsed.is_empty() {
            return;
        }
        if let Ok(mut guard) = self.by_host.write() {
            let entry = guard.entry(host_key).or_default();
            for (k, v) in parsed {
                entry.insert(k, v);
            }
        }
    }

    fn cookie_header_for_host(&self, host: Option<&str>) -> Option<String> {
        let host_key = host?.to_ascii_lowercase();
        let guard = self.by_host.read().ok()?;
        let cookies = guard.get(&host_key)?;
        if cookies.is_empty() {
            return None;
        }
        let joined: Vec<String> = cookies.iter().map(|(k, v)| format!("{k}={v}")).collect();
        Some(joined.join("; "))
    }
}

pub struct HttpClientPool {
    settings: Arc<RwLock<RuntimeSettings>>,
    client: RwLock<reqwest::Client>,
    cookies: LightweightCookieJar,
    telemetry: Arc<TelemetryHub>,
}

impl HttpClientPool {
    pub fn new(
        settings: Arc<RwLock<RuntimeSettings>>,
        telemetry: Arc<TelemetryHub>,
    ) -> Result<Self, CndError> {
        let initial_settings = settings
            .read()
            .map_err(|e| CndError::Internal {
                message: format!("Settings lock poisoned: {e}"),
            })?
            .clone();

        let client = Self::build_client(&initial_settings)?;
        Ok(Self {
            settings,
            client: RwLock::new(client),
            cookies: LightweightCookieJar::default(),
            telemetry,
        })
    }

    fn build_client(settings: &RuntimeSettings) -> Result<reqwest::Client, CndError> {
        let connect_ms = settings.connect_timeout_ms.max(500);
        let receive_ms = settings.receive_timeout_ms.max(1_000);
        let ua = if settings.default_user_agent.trim().is_empty() {
            "VLC/3.0.21 LibVLC/3.0.21"
        } else {
            settings.default_user_agent.trim()
        };

        reqwest::Client::builder()
            .pool_idle_timeout(Duration::from_secs(90))
            .pool_max_idle_per_host(16)
            .tcp_nodelay(true)
            .redirect(reqwest::redirect::Policy::limited(10))
            .connect_timeout(Duration::from_millis(connect_ms))
            .read_timeout(Duration::from_millis(receive_ms))
            .user_agent(ua)
            .build()
            .map_err(|e| CndError::Network {
                message: redact_text(&e.to_string()),
            })
    }

    pub fn on_settings_updated(
        &self,
        old_settings: &RuntimeSettings,
        new_settings: &RuntimeSettings,
    ) -> Result<(), CndError> {
        let needs_rebuild = old_settings.connect_timeout_ms != new_settings.connect_timeout_ms
            || old_settings.receive_timeout_ms != new_settings.receive_timeout_ms
            || old_settings.default_user_agent != new_settings.default_user_agent;

        if needs_rebuild {
            let new_client = Self::build_client(new_settings)?;
            let mut guard = self.client.write().map_err(|e| CndError::Internal {
                message: format!("HTTP client lock poisoned: {e}"),
            })?;
            *guard = new_client;
        }
        Ok(())
    }

    pub fn client(&self) -> Result<reqwest::Client, CndError> {
        let guard = self.client.read().map_err(|e| CndError::Internal {
            message: format!("HTTP client lock poisoned: {e}"),
        })?;
        Ok(guard.clone())
    }

    pub fn get(&self, url: &str) -> Result<reqwest::RequestBuilder, CndError> {
        Ok(self.client()?.get(url))
    }

    pub fn head(&self, url: &str) -> Result<reqwest::RequestBuilder, CndError> {
        Ok(self.client()?.head(url))
    }

    pub fn post(&self, url: &str) -> Result<reqwest::RequestBuilder, CndError> {
        Ok(self.client()?.post(url))
    }

    pub fn apply_optional_headers(
        mut req: reqwest::RequestBuilder,
        user_agent: Option<&str>,
        referer: Option<&str>,
        headers_json: Option<&str>,
    ) -> reqwest::RequestBuilder {
        if let Some(ua) = user_agent.map(str::trim).filter(|s| !s.is_empty()) {
            req = req.header(USER_AGENT, ua);
        }
        if let Some(rf) = referer.map(str::trim).filter(|s| !s.is_empty()) {
            req = req.header(REFERER, rf);
        }
        if let Some(raw_json) = headers_json.map(str::trim).filter(|s| !s.is_empty()) {
            if let Ok(map) = serde_json::from_str::<HashMap<String, String>>(raw_json) {
                for (k, v) in map {
                    if let (Ok(name), Ok(val)) = (
                        HeaderName::from_bytes(k.trim().as_bytes()),
                        HeaderValue::from_str(v.trim()),
                    ) {
                        req = req.header(name, val);
                    }
                }
            }
        }
        req
    }

    pub async fn send_logged(
        &self,
        category: &str,
        req: reqwest::RequestBuilder,
    ) -> Result<reqwest::Response, CndError> {
        let mut request = req.build().map_err(|e| CndError::Network {
            message: redact_text(&e.to_string()),
        })?;

        let (default_ua, default_referer) = {
            let guard = self.settings.read().map_err(|e| CndError::Internal {
                message: format!("Settings lock poisoned: {e}"),
            })?;
            (
                guard.default_user_agent.clone(),
                guard.default_referer.clone(),
            )
        };

        if !request.headers().contains_key(USER_AGENT) && !default_ua.trim().is_empty() {
            if let Ok(val) = HeaderValue::from_str(default_ua.trim()) {
                request.headers_mut().insert(USER_AGENT, val);
            }
        }

        if !request.headers().contains_key(REFERER) {
            if let Some(ref referer) = default_referer {
                let trimmed = referer.trim();
                if !trimmed.is_empty() {
                    if let Ok(val) = HeaderValue::from_str(trimmed) {
                        request.headers_mut().insert(REFERER, val);
                    }
                }
            }
        }

        let req_host = request.url().host_str().map(str::to_string);
        if !request.headers().contains_key(COOKIE) {
            if let Some(cookie_val) = self.cookies.cookie_header_for_host(req_host.as_deref()) {
                if let Ok(val) = HeaderValue::from_str(&cookie_val) {
                    request.headers_mut().insert(COOKIE, val);
                }
            }
        }

        let method = request.method().as_str().to_string();
        let raw_url = request.url().as_str().to_string();
        let client = self.client()?;

        let started = Instant::now();
        match client.execute(request).await {
            Ok(resp) => {
                let duration_ms = started.elapsed().as_millis() as u64;
                let resp_host = resp.url().host_str().or(req_host.as_deref());
                self.cookies.store_from_response(resp_host, resp.headers());

                let status = resp.status().as_u16();
                let level = if status >= 500 {
                    LogLevel::Error
                } else if status >= 400 {
                    LogLevel::Warn
                } else {
                    LogLevel::Info
                };

                let message = match resp.content_length() {
                    Some(bytes) => format!("HTTP {status} ({duration_ms} ms, {bytes} B)"),
                    None => format!("HTTP {status} ({duration_ms} ms)"),
                };

                self.telemetry.record(
                    level,
                    category,
                    Some(&method),
                    Some(&raw_url),
                    Some(status),
                    Some(duration_ms),
                    message,
                );

                Ok(resp)
            }
            Err(err) => {
                let duration_ms = started.elapsed().as_millis() as u64;
                let status = err.status().map(|s| s.as_u16());
                let safe_err = redact_text(&err.to_string());

                self.telemetry.record(
                    LogLevel::Error,
                    category,
                    Some(&method),
                    Some(&raw_url),
                    status,
                    Some(duration_ms),
                    format!("Request failed ({duration_ms} ms): {safe_err}"),
                );

                Err(CndError::Network { message: safe_err })
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;

    #[tokio::test]
    async fn test_http_client_pool_send_logged_cookies_and_header_injection() {
        let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
        let addr = listener.local_addr().expect("local addr");

        let server_handle = tokio::spawn(async move {
            // Request 1: sends Set-Cookie
            let (mut socket1, _) = listener.accept().await.expect("accept 1");
            let mut buf1 = vec![0u8; 2048];
            let n1 = socket1.read(&mut buf1).await.expect("read req 1");
            let req1_text = String::from_utf8_lossy(&buf1[..n1]).to_string();
            let resp1 = b"HTTP/1.1 200 OK\r\nSet-Cookie: session_id=xyz987; Path=/\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK";
            socket1.write_all(resp1).await.expect("write resp 1");

            // Request 2: verifies Cookie header is sent back
            let (mut socket2, _) = listener.accept().await.expect("accept 2");
            let mut buf2 = vec![0u8; 2048];
            let n2 = socket2.read(&mut buf2).await.expect("read req 2");
            let req2_text = String::from_utf8_lossy(&buf2[..n2]).to_string();
            let resp2 = b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK";
            socket2.write_all(resp2).await.expect("write resp 2");

            (req1_text, req2_text)
        });

        let settings = RuntimeSettings {
            default_user_agent: "CNDTestAgent/2.0".to_string(),
            default_referer: Some("http://ref.example.org/".to_string()),
            ..RuntimeSettings::default()
        };
        let settings_lock = Arc::new(RwLock::new(settings));
        let telemetry = Arc::new(TelemetryHub::new());
        let pool = HttpClientPool::new(settings_lock.clone(), telemetry.clone()).expect("pool");

        let url = format!("http://{addr}/get.php?username=demo&password=supersecret");
        let resp1 = pool
            .send_logged("HTTP", pool.get(&url).expect("get 1"))
            .await
            .expect("send 1");
        assert_eq!(resp1.status().as_u16(), 200);

        let resp2 = pool
            .send_logged("HTTP", pool.get(&url).expect("get 2"))
            .await
            .expect("send 2");
        assert_eq!(resp2.status().as_u16(), 200);

        let (req1_headers, req2_headers) = server_handle.await.expect("join server");
        let lower1 = req1_headers.to_ascii_lowercase();
        assert!(lower1.contains("user-agent: cndtestagent/2.0"));
        assert!(lower1.contains("referer: http://ref.example.org/"));
        assert!(req2_headers
            .to_ascii_lowercase()
            .contains("cookie: session_id=xyz987"));

        let logs = telemetry.get_logs_since(0, 10);
        assert_eq!(logs.len(), 2);
        assert_eq!(logs[0].category, "HTTP");
        assert_eq!(logs[0].method.as_deref(), Some("GET"));
        assert_eq!(logs[0].status_code, Some(200));
        let logged_url = logs[0].url_redacted.as_deref().unwrap_or("");
        assert!(!logged_url.contains("supersecret"));
        assert!(logged_url.contains("password=***"));
    }
}
