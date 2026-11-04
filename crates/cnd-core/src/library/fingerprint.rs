use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

const CHUNK_SIZE: usize = 64 * 1024; // 64 KB

/// Computes a fast, non-blocking fingerprint for a file:
/// `"{size}:{blake3_of_first_and_last_64KB}"`
///
/// Bounded to reading at most 128 KB regardless of whether the file is 5 MB or 50 GB.
pub fn compute_file_fingerprint(path: &Path, file_size: u64) -> Result<String, std::io::Error> {
    let mut file = File::open(path)?;
    let mut hasher = blake3::Hasher::new();

    // 1. Read first 64 KB (or full file if smaller)
    let first_chunk_len = (file_size as usize).min(CHUNK_SIZE);
    let mut first_buf = vec![0u8; first_chunk_len];
    file.read_exact(&mut first_buf)?;
    hasher.update(&first_buf);

    // 2. Read last 64 KB if file is larger than 64 KB
    if file_size > CHUNK_SIZE as u64 {
        let last_offset = file_size.saturating_sub(CHUNK_SIZE as u64);
        let seek_pos = last_offset.max(CHUNK_SIZE as u64);
        let remaining_to_read = (file_size - seek_pos) as usize;

        if remaining_to_read > 0 {
            file.seek(SeekFrom::Start(seek_pos))?;
            let mut second_buf = vec![0u8; remaining_to_read];
            file.read_exact(&mut second_buf)?;
            hasher.update(&second_buf);
        }
    }

    let hash_hex = hasher.finalize().to_hex();
    Ok(format!("{file_size}:{hash_hex}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn test_fingerprint_small_file() {
        let dir = std::env::temp_dir().join(format!("cnd_fp_test_{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let file_path = dir.join("small.mp4");

        let mut f = File::create(&file_path).unwrap();
        f.write_all(b"Hello world IPTV test data small file").unwrap();
        drop(f);

        let size = std::fs::metadata(&file_path).unwrap().len();
        let fp1 = compute_file_fingerprint(&file_path, size).unwrap();
        let fp2 = compute_file_fingerprint(&file_path, size).unwrap();

        assert_eq!(fp1, fp2);
        assert!(fp1.starts_with(&format!("{size}:")));

        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn test_fingerprint_large_file() {
        let dir = std::env::temp_dir().join(format!("cnd_fp_test_lg_{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let file_path = dir.join("large.mkv");

        let mut f = File::create(&file_path).unwrap();
        // Write 200 KB
        let chunk = vec![0x42u8; 100 * 1024];
        f.write_all(&chunk).unwrap();
        f.write_all(&chunk).unwrap();
        drop(f);

        let size = std::fs::metadata(&file_path).unwrap().len();
        assert_eq!(size, 200 * 1024);

        let fp = compute_file_fingerprint(&file_path, size).unwrap();
        assert!(fp.starts_with("204800:"));

        let _ = std::fs::remove_dir_all(dir);
    }
}

