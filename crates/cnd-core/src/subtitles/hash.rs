use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;
use thiserror::Error;

pub const HASH_CHUNK_SIZE: usize = 65536; // 64 KB

#[derive(Debug, Error)]
pub enum HashError {
    #[error("File too small to compute moviehash (size: {0} bytes, minimum: {HASH_CHUNK_SIZE})")]
    FileTooSmall(u64),
    #[error("I/O error computing moviehash: {0}")]
    Io(#[from] std::io::Error),
}

/// Computes the 64-bit OpenSubtitles `moviehash` from first 64KB, last 64KB, and file size.
///
/// Returns the 16-hex-digit lowercase string representation (e.g. "8e245d9679d31e12").
pub fn compute_moviehash_from_chunks(file_size: u64, head_64k: &[u8], tail_64k: &[u8]) -> Result<String, HashError> {
    if file_size < HASH_CHUNK_SIZE as u64 {
        return Err(HashError::FileTooSmall(file_size));
    }

    let mut hash: u64 = file_size;

    // Sum first 64 KB as 64-bit little-endian words
    let head_words = head_64k.len() / 8;
    for i in 0..head_words {
        let chunk = &head_64k[i * 8..(i + 1) * 8];
        let val = u64::from_le_bytes(chunk.try_into().unwrap());
        hash = hash.wrapping_add(val);
    }

    // Sum last 64 KB as 64-bit little-endian words
    let tail_words = tail_64k.len() / 8;
    for i in 0..tail_words {
        let chunk = &tail_64k[i * 8..(i + 1) * 8];
        let val = u64::from_le_bytes(chunk.try_into().unwrap());
        hash = hash.wrapping_add(val);
    }

    Ok(format!("{hash:016x}"))
}

/// Computes the `moviehash` of a remote file with two small `Range` requests (the first and the last
/// 64 KiB), without downloading the file. Fails when the server ignores `Range` (it would answer with the
/// whole file) or does not say how long the file is.
pub async fn compute_remote_moviehash(
    url: &str,
    headers: reqwest::header::HeaderMap,
) -> Result<String, crate::CndError> {
    use reqwest::header::{CONTENT_RANGE, RANGE};
    let net = |message: String| crate::CndError::Network { message };
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(8))
        .redirect(reqwest::redirect::Policy::limited(5))
        .build()
        .map_err(|e| net(format!("Failed to build client: {e}")))?;
    let chunk = HASH_CHUNK_SIZE as u64;

    async fn fetch(
        client: &reqwest::Client,
        url: &str,
        headers: &reqwest::header::HeaderMap,
        range: String,
    ) -> Result<(Vec<u8>, Option<u64>), crate::CndError> {
        let resp = client
            .get(url)
            .headers(headers.clone())
            .header(RANGE, range)
            .send()
            .await
            .map_err(|e| crate::CndError::Network { message: format!("range request failed: {e}") })?;
        if resp.status() != reqwest::StatusCode::PARTIAL_CONTENT {
            // Dropping the response here closes the connection without reading the body.
            return Err(crate::CndError::Network {
                message: format!("the server does not support range requests ({})", resp.status()),
            });
        }
        let total = resp
            .headers()
            .get(CONTENT_RANGE)
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.rsplit('/').next())
            .and_then(|t| t.trim().parse::<u64>().ok());
        let body = resp
            .bytes()
            .await
            .map_err(|e| crate::CndError::Network { message: format!("range body failed: {e}") })?;
        Ok((body.to_vec(), total))
    }

    let (head, total) = fetch(&client, url, &headers, format!("bytes=0-{}", chunk - 1)).await?;
    let total = total.ok_or_else(|| net("the server did not report the file size".to_string()))?;
    if total < chunk || head.len() as u64 != chunk {
        return Err(net(format!("file too small to hash ({total} bytes)")));
    }
    let (tail, _) = fetch(&client, url, &headers, format!("bytes={}-{}", total - chunk, total - 1)).await?;
    if tail.len() as u64 != chunk {
        return Err(net("the end of the file could not be read".to_string()));
    }
    compute_moviehash_from_chunks(total, &head, &tail).map_err(|e| net(e.to_string()))
}

/// Computes the OpenSubtitles `moviehash` for a local file on disk.
pub fn compute_file_moviehash<P: AsRef<Path>>(path: P) -> Result<String, HashError> {
    let mut file = File::open(path)?;
    let file_size = file.metadata()?.len();

    if file_size < HASH_CHUNK_SIZE as u64 {
        return Err(HashError::FileTooSmall(file_size));
    }

    let mut head = vec![0u8; HASH_CHUNK_SIZE];
    file.read_exact(&mut head)?;

    let mut tail = vec![0u8; HASH_CHUNK_SIZE];
    file.seek(SeekFrom::End(-(HASH_CHUNK_SIZE as i64)))?;
    file.read_exact(&mut tail)?;

    compute_moviehash_from_chunks(file_size, &head, &tail)
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn test_file_too_small() {
        let small_data = vec![0u8; 1000];
        let res = compute_moviehash_from_chunks(1000, &small_data, &small_data);
        assert!(matches!(res, Err(HashError::FileTooSmall(1000))));
    }

    #[test]
    fn test_known_zero_buffer() {
        // If file is 128 KB of zeroes:
        // file_size = 131072, all words are 0, so hash = 131072 (0x0000000000020000)
        let zeros = vec![0u8; HASH_CHUNK_SIZE];
        let hash = compute_moviehash_from_chunks(131072, &zeros, &zeros).unwrap();
        assert_eq!(hash, "0000000000020000");
    }

    #[test]
    fn test_file_hash_roundtrip() {
        let path = std::env::temp_dir().join(format!("cnd_test_hash_{}.bin", std::process::id()));
        // Write 200 KB
        let data = vec![0x42u8; 200 * 1024];
        let mut f = File::create(&path).unwrap();
        f.write_all(&data).unwrap();
        f.flush().unwrap();
        drop(f);

        let hash = compute_file_moviehash(&path).unwrap();
        assert_eq!(hash.len(), 16);
        // Verify deterministic
        let hash2 = compute_file_moviehash(&path).unwrap();
        assert_eq!(hash, hash2);

        let _ = std::fs::remove_file(path);
    }

    // MARK: remote hash

    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;

    /// A tiny HTTP server for one file. With `ranges` it answers `Range` requests like a real media server,
    /// otherwise it ignores them and answers 200 with the whole file.
    pub(crate) async fn serve(data: Vec<u8>, ranges: bool) -> (String, std::sync::Arc<std::sync::atomic::AtomicUsize>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
        let url = format!("http://{}/movie.mkv", listener.local_addr().expect("addr"));
        let hits = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let counter = hits.clone();
        tokio::spawn(async move {
            loop {
                let Ok((mut socket, _)) = listener.accept().await else { return };
                let data = data.clone();
                let counter = counter.clone();
                tokio::spawn(async move {
                    let mut buf = vec![0u8; 4096];
                    let n = socket.read(&mut buf).await.unwrap_or(0);
                    counter.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                    let request = String::from_utf8_lossy(&buf[..n]).to_lowercase();
                    let range = request
                        .lines()
                        .find_map(|l| l.strip_prefix("range: bytes="))
                        .and_then(|r| r.split_once('-'))
                        .and_then(|(a, b)| Some((a.trim().parse::<usize>().ok()?, b.trim().parse::<usize>().ok()?)));
                    let response: Vec<u8> = match (ranges, range) {
                        (true, Some((start, end))) => {
                            let body = &data[start..=end];
                            let mut head = format!(
                                "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes {start}-{end}/{}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                                data.len(),
                                body.len()
                            )
                            .into_bytes();
                            head.extend_from_slice(body);
                            head
                        }
                        _ => {
                            let mut head = format!(
                                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                                data.len()
                            )
                            .into_bytes();
                            head.extend_from_slice(&data);
                            head
                        }
                    };
                    let _ = socket.write_all(&response).await;
                });
            }
        });
        (url, hits)
    }

    pub(crate) fn sample(len: usize) -> Vec<u8> {
        (0..len).map(|i| (i * 31 % 251) as u8).collect()
    }

    #[tokio::test]
    async fn the_remote_hash_equals_the_hash_of_the_same_bytes_on_disk() {
        let data = sample(300_000);
        let expected = compute_moviehash_from_chunks(
            data.len() as u64,
            &data[..HASH_CHUNK_SIZE],
            &data[data.len() - HASH_CHUNK_SIZE..],
        )
        .unwrap();
        let (url, hits) = serve(data, true).await;

        let hash = compute_remote_moviehash(&url, reqwest::header::HeaderMap::new()).await.expect("remote hash");

        assert_eq!(hash, expected);
        assert_eq!(hits.load(std::sync::atomic::Ordering::SeqCst), 2, "exactly two short requests");
    }

    #[tokio::test]
    async fn a_server_without_range_support_is_refused_without_reading_the_file() {
        let (url, _) = serve(sample(300_000), false).await;
        let err = compute_remote_moviehash(&url, reqwest::header::HeaderMap::new()).await.expect_err("no ranges");
        assert!(err.to_string().contains("range"), "{err}");
    }

    #[tokio::test]
    async fn a_file_smaller_than_the_hash_window_is_refused() {
        let (url, _) = serve(sample(1_000), true).await;
        assert!(compute_remote_moviehash(&url, reqwest::header::HeaderMap::new()).await.is_err());
    }
}
