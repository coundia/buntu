pub mod hash;
pub mod srt;

pub use hash::{compute_file_moviehash, compute_moviehash_from_chunks, compute_remote_moviehash, HashError};
pub use srt::{find_active_cue, parse_srt, parse_timestamp, strip_tags, SubtitleCue};

use crate::CndError;
use reqwest::header::{HeaderMap, HeaderValue, ACCEPT, CONTENT_TYPE, USER_AGENT};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::time::Duration;

pub const DEFAULT_OPENSUBTITLES_API_BASE: &str = "https://api.opensubtitles.com/api/v1";
pub const DEFAULT_USER_AGENT: &str = "CndIPTV v1.0";

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct SubtitleSearchResult {
    pub id: String,
    pub file_id: i64,
    pub file_name: String,
    pub language: String,
    pub release: String,
    pub download_count: u32,
    pub rating: f64,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct SubtitleSearchQuery {
    pub query: Option<String>,
    pub imdb_id: Option<String>,
    /// IMDb id of the series, for an episode (with `season_number` and `episode_number`).
    pub parent_imdb_id: Option<String>,
    pub moviehash: Option<String>,
    pub season_number: Option<u32>,
    pub episode_number: Option<u32>,
    pub languages: Option<String>,
}

/// What a signed-in account can do, from OpenSubtitles' `/login` answer.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SubtitleAccount {
    /// Downloads allowed per day for this account (0 when the service does not say).
    pub allowed_downloads: u32,
    pub level: String,
}

#[derive(Debug, Deserialize)]
struct OsLoginResponse {
    #[serde(default)]
    token: String,
    #[serde(default)]
    base_url: String,
    #[serde(default)]
    user: Option<OsLoginUser>,
}

#[derive(Debug, Deserialize)]
struct OsLoginUser {
    #[serde(default)]
    allowed_downloads: u32,
    #[serde(default)]
    level: String,
}

/// A signed-in session, kept in memory only: the password is never stored here.
#[derive(Debug, Clone)]
struct Session {
    token: String,
    /// The API host the service asked this account to use (VIP accounts have their own).
    base: Option<String>,
}

#[derive(Debug, Deserialize)]
struct OsSearchResponse {
    #[serde(default)]
    data: Vec<OsSearchItem>,
}

#[derive(Debug, Deserialize)]
struct OsSearchItem {
    #[serde(default)]
    id: String,
    #[serde(default)]
    attributes: Option<OsAttributes>,
}

#[derive(Debug, Deserialize)]
struct OsAttributes {
    #[serde(default)]
    language: String,
    #[serde(default)]
    download_count: u32,
    #[serde(default)]
    ratings: f64,
    #[serde(default)]
    release: String,
    #[serde(default)]
    files: Vec<OsFileItem>,
}

#[derive(Debug, Deserialize)]
struct OsFileItem {
    #[serde(default)]
    file_id: i64,
    #[serde(default)]
    file_name: String,
}

#[derive(Debug, Serialize)]
struct OsDownloadRequest {
    file_id: i64,
}

#[derive(Debug, Deserialize)]
struct OsDownloadResponse {
    #[serde(default)]
    link: String,
    #[serde(default)]
    file_name: Option<String>,
    #[serde(default)]
    message: Option<String>,
}

pub struct SubtitleService {
    client: reqwest::Client,
    api_base: String,
    session: std::sync::Mutex<Option<Session>>,
}

impl Default for SubtitleService {
    fn default() -> Self {
        Self::new(DEFAULT_OPENSUBTITLES_API_BASE.to_string())
    }
}

impl SubtitleService {
    pub fn new(api_base: String) -> Self {
        let mut headers = HeaderMap::new();
        headers.insert(USER_AGENT, HeaderValue::from_static(DEFAULT_USER_AGENT));
        headers.insert(ACCEPT, HeaderValue::from_static("application/json"));
        headers.insert(CONTENT_TYPE, HeaderValue::from_static("application/json"));

        let client = reqwest::Client::builder()
            .default_headers(headers)
            .timeout(Duration::from_secs(10))
            .build()
            .unwrap_or_default();

        Self { client, api_base, session: std::sync::Mutex::new(None) }
    }

    /// Base address and bearer token to use: the account's own once signed in, the public one otherwise.
    fn endpoint(&self) -> (String, Option<String>) {
        match self.session.lock().ok().and_then(|s| s.clone()) {
            Some(Session { token, base }) => (base.unwrap_or_else(|| self.api_base.clone()), Some(token)),
            None => (self.api_base.clone(), None),
        }
    }

    pub fn is_signed_in(&self) -> bool {
        self.session.lock().map(|s| s.is_some()).unwrap_or(false)
    }

    pub fn sign_out(&self) {
        if let Ok(mut session) = self.session.lock() {
            *session = None;
        }
    }

    /// Signs in to lift the anonymous download quota. Only the token is kept, in memory.
    pub async fn sign_in(
        &self,
        username: &str,
        password: &str,
        api_key: Option<&str>,
    ) -> Result<SubtitleAccount, CndError> {
        let key = api_key
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .ok_or_else(|| CndError::Parse {
                message: "OpenSubtitles API key is required to sign in".to_string(),
            })?;
        let resp = self
            .client
            .post(format!("{}/login", self.api_base))
            .header("Api-Key", key)
            .json(&serde_json::json!({ "username": username, "password": password }))
            .send()
            .await
            .map_err(|e| CndError::Network { message: format!("OpenSubtitles login failed: {e}") })?;
        let status = resp.status();
        if status == reqwest::StatusCode::UNAUTHORIZED || status == reqwest::StatusCode::FORBIDDEN {
            return Err(CndError::Network {
                message: "OpenSubtitles refused the user name or password (or the API key)".to_string(),
            });
        }
        if !status.is_success() {
            return Err(CndError::Network { message: format!("OpenSubtitles login HTTP error: {status}") });
        }
        let parsed: OsLoginResponse = resp
            .json()
            .await
            .map_err(|e| CndError::Parse { message: format!("Failed to parse the login response: {e}") })?;
        if parsed.token.is_empty() {
            return Err(CndError::Network { message: "OpenSubtitles returned no session token".to_string() });
        }
        // The service names the host to use; only trusted for the real service (tests use a local one).
        let base = (self.api_base == DEFAULT_OPENSUBTITLES_API_BASE && !parsed.base_url.trim().is_empty())
            .then(|| format!("https://{}/api/v1", parsed.base_url.trim().trim_start_matches("https://").trim_end_matches('/')));
        if let Ok(mut session) = self.session.lock() {
            *session = Some(Session { token: parsed.token, base });
        }
        let user = parsed.user.unwrap_or(OsLoginUser { allowed_downloads: 0, level: String::new() });
        Ok(SubtitleAccount { allowed_downloads: user.allowed_downloads, level: user.level })
    }

    /// Searches subtitles via OpenSubtitles REST v1.
    ///
    /// Requires an OpenSubtitles API Key (passed in header `Api-Key: <key>`).
    pub async fn search(
        &self,
        query: &SubtitleSearchQuery,
        api_key: Option<&str>,
    ) -> Result<Vec<SubtitleSearchResult>, CndError> {
        let key = api_key
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .ok_or_else(|| CndError::Parse {
                message: "OpenSubtitles API key is required to search subtitles".to_string(),
            })?;

        let (base, token) = self.endpoint();
        let url = format!("{base}/subtitles");
        let mut req = self.client.get(&url).header("Api-Key", key);
        if let Some(token) = &token {
            req = req.bearer_auth(token);
        }

        if let Some(ref q) = query.query {
            if !q.trim().is_empty() {
                req = req.query(&[("query", q.trim())]);
            }
        }

        if let Some(ref imdb) = query.imdb_id {
            let clean = imdb.trim().trim_start_matches("tt");
            if !clean.is_empty() {
                req = req.query(&[("imdb_id", clean)]);
            }
        }

        if let Some(ref parent) = query.parent_imdb_id {
            let clean = parent.trim().trim_start_matches("tt");
            if !clean.is_empty() {
                req = req.query(&[("parent_imdb_id", clean)]);
            }
        }

        if let Some(ref hash) = query.moviehash {
            if !hash.trim().is_empty() {
                req = req.query(&[("moviehash", hash.trim())]);
            }
        }

        if let Some(season) = query.season_number {
            req = req.query(&[("season_number", season.to_string())]);
        }

        if let Some(episode) = query.episode_number {
            req = req.query(&[("episode_number", episode.to_string())]);
        }

        if let Some(ref langs) = query.languages {
            if !langs.trim().is_empty() {
                req = req.query(&[("languages", langs.trim())]);
            }
        }

        let resp = req.send().await.map_err(|e| CndError::Network {
            message: format!("OpenSubtitles search request failed: {e}"),
        })?;

        let status = resp.status();
        if status == reqwest::StatusCode::UNAUTHORIZED || status == reqwest::StatusCode::FORBIDDEN {
            if token.is_some() {
                // The session expired: forget it so the next call can sign in again.
                self.sign_out();
            }
            return Err(CndError::Network {
                message: "OpenSubtitles API key is invalid, the session expired or the quota is exceeded (401/403)".to_string(),
            });
        } else if status == reqwest::StatusCode::TOO_MANY_REQUESTS {
            return Err(CndError::Network {
                message: "OpenSubtitles rate limit exceeded (429)".to_string(),
            });
        } else if !status.is_success() {
            return Err(CndError::Network {
                message: format!("OpenSubtitles HTTP error: {status}"),
            });
        }

        let parsed: OsSearchResponse = resp.json().await.map_err(|e| CndError::Parse {
            message: format!("Failed to parse OpenSubtitles search response: {e}"),
        })?;

        let mut results = Vec::new();
        for item in parsed.data {
            if let Some(attr) = item.attributes {
                for file in attr.files {
                    results.push(SubtitleSearchResult {
                        id: item.id.clone(),
                        file_id: file.file_id,
                        file_name: file.file_name,
                        language: attr.language.clone(),
                        release: attr.release.clone(),
                        download_count: attr.download_count,
                        rating: attr.ratings,
                    });
                }
            }
        }

        Ok(results)
    }

    /// Requests download URL and fetches the SRT subtitle file, saving it into `target_dir`.
    ///
    /// Returns the absolute path of the downloaded file.
    pub async fn download(
        &self,
        file_id: i64,
        target_dir: &Path,
        api_key: Option<&str>,
    ) -> Result<PathBuf, CndError> {
        let key = api_key
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .ok_or_else(|| CndError::Parse {
                message: "OpenSubtitles API key is required to download subtitles".to_string(),
            })?;

        let (base, token) = self.endpoint();
        let download_endpoint = format!("{base}/download");
        let req_body = OsDownloadRequest { file_id };

        let mut request = self.client.post(&download_endpoint).header("Api-Key", key).json(&req_body);
        if let Some(token) = &token {
            request = request.bearer_auth(token);
        }
        let resp = request
            .send()
            .await
            .map_err(|e| CndError::Network {
                message: format!("OpenSubtitles download token request failed: {e}"),
            })?;

        let status = resp.status();
        if status == reqwest::StatusCode::TOO_MANY_REQUESTS || status == reqwest::StatusCode::NOT_ACCEPTABLE {
            return Err(CndError::Network {
                message: "OpenSubtitles download quota reached for today: sign in with an account (Réglages) or try tomorrow".to_string(),
            });
        }
        if (status == reqwest::StatusCode::UNAUTHORIZED) && token.is_some() {
            self.sign_out();
        }
        if !status.is_success() {
            return Err(CndError::Network {
                message: format!("OpenSubtitles download token HTTP error: {status}"),
            });
        }

        let dl_resp: OsDownloadResponse = resp.json().await.map_err(|e| CndError::Parse {
            message: format!("Failed to parse download link response: {e}"),
        })?;

        if dl_resp.link.is_empty() {
            return Err(CndError::Network {
                message: dl_resp
                    .message
                    .unwrap_or_else(|| "No download link returned by OpenSubtitles".to_string()),
            });
        }

        // Fetch actual SRT file
        let srt_resp = self
            .client
            .get(&dl_resp.link)
            .send()
            .await
            .map_err(|e| CndError::Network {
                message: format!("Failed to fetch subtitle file from link: {e}"),
            })?;

        if !srt_resp.status().is_success() {
            return Err(CndError::Network {
                message: format!("Failed to download SRT body: HTTP {}", srt_resp.status()),
            });
        }

        let bytes = srt_resp.bytes().await.map_err(|e| CndError::Network {
            message: format!("Failed to read SRT bytes: {e}"),
        })?;

        tokio::fs::create_dir_all(target_dir).await.map_err(|e| {
            CndError::Internal {
                message: format!("Cannot create subtitle cache dir: {e}"),
            }
        })?;

        let file_name = dl_resp
            .file_name
            .unwrap_or_else(|| format!("subtitle_{file_id}.srt"));
        let target_path = target_dir.join(file_name);

        tokio::fs::write(&target_path, bytes).await.map_err(|e| {
            CndError::Internal {
                message: format!("Cannot write subtitle file to disk: {e}"),
            }
        })?;

        Ok(target_path)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::net::TcpListener;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    #[tokio::test]
    async fn test_opensubtitles_search_and_download_mock() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();

        // Spawn mock server
        tokio::spawn(async move {
            loop {
                let Ok((mut socket, _)) = listener.accept().await else { break };
                let mut buf = [0u8; 4096];
                let n = socket.read(&mut buf).await.unwrap_or(0);
                let request = String::from_utf8_lossy(&buf[..n]);

                if request.contains("GET /subtitles") {
                    let body = r#"{
                        "data": [
                            {
                                "id": "sub_1",
                                "attributes": {
                                    "language": "fr",
                                    "download_count": 500,
                                    "ratings": 9.2,
                                    "release": "Movie.1080p",
                                    "files": [
                                        { "file_id": 12345, "file_name": "movie.fr.srt" }
                                    ]
                                }
                            }
                        ]
                    }"#;
                    let resp = format!(
                        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{}",
                        body.len(),
                        body
                    );
                    let _ = socket.write_all(resp.as_bytes()).await;
                } else if request.contains("POST /download") {
                    let dl_url = format!("http://127.0.0.1:{port}/file.srt");
                    let body = format!(
                        r#"{{"link": "{dl_url}", "file_name": "movie.fr.srt"}}"#
                    );
                    let resp = format!(
                        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{}",
                        body.len(),
                        body
                    );
                    let _ = socket.write_all(resp.as_bytes()).await;
                } else if request.contains("GET /file.srt") {
                    let srt = "1\n00:00:01,000 --> 00:00:03,000\nHello world!\n";
                    let resp = format!(
                        "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: {}\r\n\r\n{}",
                        srt.len(),
                        srt
                    );
                    let _ = socket.write_all(resp.as_bytes()).await;
                }
            }
        });

        let service = SubtitleService::new(format!("http://127.0.0.1:{port}"));
        let query = SubtitleSearchQuery {
            query: Some("Movie".to_string()),
            languages: Some("fr".to_string()),
            ..Default::default()
        };

        let results = service.search(&query, Some("test_api_key")).await.unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].file_id, 12345);
        assert_eq!(results[0].language, "fr");
        assert_eq!(results[0].file_name, "movie.fr.srt");

        let cache_dir = std::env::temp_dir().join(format!("cnd_test_sub_{}", std::process::id()));
        let downloaded = service.download(12345, &cache_dir, Some("test_api_key")).await.unwrap();
        assert!(downloaded.exists());

        let content = std::fs::read_to_string(&downloaded).unwrap();
        let cues = parse_srt(&content);
        assert_eq!(cues.len(), 1);
        assert_eq!(cues[0].text, "Hello world!");

        let _ = std::fs::remove_dir_all(&cache_dir);
    }

    #[tokio::test]
    async fn an_episode_search_sends_the_series_imdb_id_with_season_and_episode() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let (tx, rx) = tokio::sync::oneshot::channel::<String>();
        tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut buf = vec![0u8; 4096];
            let n = socket.read(&mut buf).await.unwrap();
            let _ = tx.send(String::from_utf8_lossy(&buf[..n]).lines().next().unwrap_or("").to_string());
            let body = r#"{"data": []}"#;
            let resp = format!("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{}", body.len(), body);
            let _ = socket.write_all(resp.as_bytes()).await;
        });

        let service = SubtitleService::new(format!("http://127.0.0.1:{port}"));
        let query = SubtitleSearchQuery {
            parent_imdb_id: Some("tt0944947".to_string()),
            season_number: Some(2),
            episode_number: Some(7),
            languages: Some("fr".to_string()),
            ..Default::default()
        };
        service.search(&query, Some("k")).await.unwrap();
        let line = rx.await.unwrap();
        assert!(line.contains("parent_imdb_id=0944947"), "{line}");
        assert!(line.contains("season_number=2") && line.contains("episode_number=7"), "{line}");
        assert!(!line.contains("&imdb_id=") && !line.contains("?imdb_id="), "the episode's own id is not mixed in: {line}");
    }

    /// A scripted local server: each request gets the next answer; the request heads are recorded.
    async fn scripted(answers: Vec<(&'static str, &'static str)>) -> (String, std::sync::Arc<std::sync::Mutex<Vec<String>>>) {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let seen = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let log = seen.clone();
        tokio::spawn(async move {
            for (status, body) in answers {
                let Ok((mut socket, _)) = listener.accept().await else { return };
                let mut buf = vec![0u8; 8192];
                let n = socket.read(&mut buf).await.unwrap_or(0);
                log.lock().unwrap().push(String::from_utf8_lossy(&buf[..n]).to_lowercase());
                let resp = format!(
                    "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
                let _ = socket.write_all(resp.as_bytes()).await;
            }
        });
        (base, seen)
    }

    #[tokio::test]
    async fn signing_in_gives_a_bearer_token_to_the_next_requests() {
        let (base, seen) = scripted(vec![
            ("200 OK", r#"{"token":"abc123","base_url":"vip-api.opensubtitles.com","user":{"allowed_downloads":1000,"level":"Sub leecher"}}"#),
            ("200 OK", r#"{"data": []}"#),
        ])
        .await;
        let service = SubtitleService::new(base);
        assert!(!service.is_signed_in());

        let account = service.sign_in("papa", "secret", Some("key")).await.expect("login");
        assert_eq!(account, SubtitleAccount { allowed_downloads: 1000, level: "Sub leecher".to_string() });
        assert!(service.is_signed_in());

        service.search(&SubtitleSearchQuery { query: Some("x".into()), ..Default::default() }, Some("key")).await.unwrap();
        let requests = seen.lock().unwrap().clone();
        assert!(requests[0].starts_with("post /login"), "{}", requests[0]);
        assert!(requests[0].contains("api-key: key"));
        assert!(requests[1].contains("authorization: bearer abc123"), "{}", requests[1]);
        assert!(requests[1].starts_with("get /subtitles"), "a test server keeps its own address, not the VIP host");

        service.sign_out();
        assert!(!service.is_signed_in());
    }

    #[tokio::test]
    async fn anonymous_requests_carry_no_token() {
        let (base, seen) = scripted(vec![("200 OK", r#"{"data": []}"#)]).await;
        let service = SubtitleService::new(base);
        service.search(&SubtitleSearchQuery { query: Some("x".into()), ..Default::default() }, Some("key")).await.unwrap();
        assert!(!seen.lock().unwrap()[0].contains("authorization"));
    }

    #[tokio::test]
    async fn a_refused_login_says_so_and_keeps_no_session() {
        let (base, _) = scripted(vec![("401 Unauthorized", r#"{"message":"bad"}"#)]).await;
        let service = SubtitleService::new(base);
        let err = service.sign_in("papa", "wrong", Some("key")).await.expect_err("refused");
        assert!(err.to_string().contains("refused the user name or password"), "{err}");
        assert!(!service.is_signed_in());
        assert!(service.sign_in("papa", "x", None).await.is_err(), "an API key is required");
    }

    #[tokio::test]
    async fn an_expired_session_is_forgotten_and_a_reached_quota_is_explained() {
        let (base, _) = scripted(vec![
            ("200 OK", r#"{"token":"t"}"#),
            ("401 Unauthorized", "{}"),
            ("406 Not Acceptable", r#"{"message":"You have downloaded your allowed 5 subtitles"}"#),
        ])
        .await;
        let service = SubtitleService::new(base);
        service.sign_in("u", "p", Some("k")).await.unwrap();
        assert!(service.search(&SubtitleSearchQuery::default(), Some("k")).await.is_err());
        assert!(!service.is_signed_in(), "a 401 on a signed-in call drops the session");

        let dir = std::env::temp_dir().join(format!("cnd_quota_{}", std::process::id()));
        let err = service.download(1, &dir, Some("k")).await.expect_err("quota");
        assert!(err.to_string().contains("quota"), "{err}");
    }
}
