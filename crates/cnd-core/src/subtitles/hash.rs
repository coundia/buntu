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
mod tests {
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
}
