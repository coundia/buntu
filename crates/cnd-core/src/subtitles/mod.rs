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
    pub moviehash: Option<String>,
    pub season_number: Option<u32>,
    pub episode_number: Option<u32>,
    pub languages: Option<String>,
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

        Self { client, api_base }
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

        let url = format!("{}/subtitles", self.api_base);
        let mut req = self.client.get(&url).header("Api-Key", key);

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
            return Err(CndError::Network {
                message: "OpenSubtitles API key is invalid or quota exceeded (401/403)".to_string(),
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

        let download_endpoint = format!("{}/download", self.api_base);
        let req_body = OsDownloadRequest { file_id };

        let resp = self
            .client
            .post(&download_endpoint)
            .header("Api-Key", key)
            .json(&req_body)
            .send()
            .await
            .map_err(|e| CndError::Network {
                message: format!("OpenSubtitles download token request failed: {e}"),
            })?;

        let status = resp.status();
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
}
