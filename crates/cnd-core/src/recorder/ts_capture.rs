use crate::CndError;
use futures_util::StreamExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};
use tokio::fs::OpenOptions;
use tokio::io::AsyncWriteExt;
use tokio_util::sync::CancellationToken;

pub struct CaptureResult {
    pub bytes_written: u64,
    pub is_partial: bool,
    pub final_path: PathBuf,
}

#[allow(clippy::too_many_arguments)]
pub async fn capture_ts_stream(
    client: &reqwest::Client,
    url: &str,
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
    let mut consecutive_dropout_start: Option<Instant> = None;
    let mut is_partial = false;

    while Instant::now() < deadline && !cancel_token.is_cancelled() {
        let mut req = client.get(url);
        if let Some(ua) = user_agent {
            req = req.header("User-Agent", ua);
        }
        if let Some(ref_) = referer {
            req = req.header("Referer", ref_);
        }

        let resp_result = req.send().await;
        let resp = match resp_result {
            Ok(r) if r.status().is_success() => {
                consecutive_dropout_start = None;
                r
            }
            Ok(r) => {
                let _err_status = r.status();
                let dropout = consecutive_dropout_start.get_or_insert_with(Instant::now);
                if dropout.elapsed() > Duration::from_secs(60) {
                    is_partial = true;
                    break;
                }
                tokio::time::sleep(Duration::from_millis(1000)).await;
                continue;
            }
            Err(_) => {
                let dropout = consecutive_dropout_start.get_or_insert_with(Instant::now);
                if dropout.elapsed() > Duration::from_secs(60) {
                    is_partial = true;
                    break;
                }
                tokio::time::sleep(Duration::from_millis(1000)).await;
                continue;
            }
        };

        let mut stream = resp.bytes_stream();
        while let Some(chunk_res) = stream.next().await {
            if Instant::now() >= deadline || cancel_token.is_cancelled() {
                break;
            }

            match chunk_res {
                Ok(chunk) => {
                    if let Err(e) = file.write_all(&chunk).await {
                        return Err(CndError::Internal {
                            message: format!("Failed writing TS recording chunk: {e}"),
                        });
                    }
                    bytes_written += chunk.len() as u64;
                    if let Some(ref cb) = progress_callback {
                        cb(bytes_written);
                    }
                }
                Err(_) => {
                    // Stream disconnected mid-chunk, try reconnecting
                    break;
                }
            }
        }
    }

    let _ = file.flush().await;
    drop(file);

    // Rename .part to .ts
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

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::net::TcpListener;

    #[tokio::test]
    async fn test_ts_capture_bounded_by_deadline() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();

        tokio::spawn(async move {
            if let Ok((mut socket, _)) = listener.accept().await {
                let head = "HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\n\r\n";
                let _ = socket.write_all(head.as_bytes()).await;
                let chunk = vec![0x47u8; 188 * 10];
                for _ in 0..10 {
                    let _ = socket.write_all(&chunk).await;
                    tokio::time::sleep(Duration::from_millis(50)).await;
                }
            }
        });

        let client = reqwest::Client::new();
        let tmp_file = std::env::temp_dir().join(format!("cnd_rec_ts_{}.ts", std::process::id()));
        let cancel = CancellationToken::new();

        // 300ms deadline
        let deadline = Instant::now() + Duration::from_millis(300);
        let res = capture_ts_stream(
            &client,
            &format!("http://127.0.0.1:{port}/stream.ts"),
            None,
            None,
            &tmp_file,
            deadline,
            cancel,
            None,
        )
        .await
        .unwrap();

        assert!(res.bytes_written > 0);
        assert!(tmp_file.exists());
        let _ = tokio::fs::remove_file(tmp_file).await;
    }
}
