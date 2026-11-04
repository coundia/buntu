pub mod classify;
pub mod fingerprint;
pub mod scanner;

use crate::db::library_repo::LibraryScanReport;
use crate::db::DatabaseManager;
use crate::library::classify::MediaKind;
use crate::library::scanner::{scan_library_folder, ScannerOptions};
use crate::CndError;
use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

pub struct LibraryManager {
    cancel_flags: Mutex<HashMap<i64, Arc<AtomicBool>>>,
}

impl Default for LibraryManager {
    fn default() -> Self {
        Self::new()
    }
}

impl LibraryManager {
    pub fn new() -> Self {
        Self {
            cancel_flags: Mutex::new(HashMap::new()),
        }
    }

    pub fn scan_folder(
        &self,
        db: &DatabaseManager,
        folder_id: i64,
        root_path: &str,
    ) -> Result<LibraryScanReport, CndError> {
        let flag = Arc::new(AtomicBool::new(false));
        {
            let mut map = self.cancel_flags.lock().unwrap();
            map.insert(folder_id, flag.clone());
        }

        let folder = db
            .get_library_folder(folder_id)
            .map_err(|e| CndError::Database {
                message: e.to_string(),
            })?
            .ok_or_else(|| CndError::NotFound {
                message: format!("Folder ID {folder_id} not found"),
            })?;

        let mut allowed_kinds = HashSet::new();
        for k in folder.kinds.split(',') {
            if let Some(kind) = MediaKind::parse_kind(k.trim()) {
                allowed_kinds.insert(kind);
            }
        }
        if allowed_kinds.is_empty() {
            allowed_kinds.insert(MediaKind::Video);
            allowed_kinds.insert(MediaKind::Audio);
            allowed_kinds.insert(MediaKind::Image);
        }

        let options = ScannerOptions {
            include_subfolders: folder.include_subfolders,
            allowed_kinds,
            cancel_flag: flag,
        };

        let result = scan_library_folder(db, folder_id, root_path, &options);

        {
            let mut map = self.cancel_flags.lock().unwrap();
            map.remove(&folder_id);
        }

        result
    }

    pub fn cancel_scan(&self, folder_id: i64) {
        let map = self.cancel_flags.lock().unwrap();
        if let Some(flag) = map.get(&folder_id) {
            flag.store(true, Ordering::Relaxed);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::library_repo::LibraryItemMetadataInput;
    use rusqlite::params;
    use std::fs::{self, File};
    use std::io::Write;
    use std::time::Instant;

    fn create_dummy_file(path: &std::path::Path, size: usize) {
        if let Some(p) = path.parent() {
            let _ = fs::create_dir_all(p);
        }
        let mut f = File::create(path).unwrap();
        let chunk = vec![0x47u8; size.min(4096)];
        let mut written = 0;
        while written < size {
            let to_write = (size - written).min(chunk.len());
            f.write_all(&chunk[..to_write]).unwrap();
            written += to_write;
        }
    }

    #[test]
    fn test_scanner_incremental_and_renames() {
        let db = DatabaseManager::open_in_memory().unwrap();
        let dir = std::env::temp_dir().join(format!("cnd_test_scan_{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();

        // 1. Create a folder in DB
        let folder = db
            .add_library_folder("TestDir", dir.to_str().unwrap(), None, true, "video,audio,image")
            .unwrap();

        // 2. Add video + subtitle + cover
        let video_path = dir.join("Movie.2023.mkv");
        create_dummy_file(&video_path, 100 * 1024);

        let sub_path = dir.join("Movie.2023.fr.srt");
        create_dummy_file(&sub_path, 2048);

        let cover_path = dir.join("cover.jpg");
        create_dummy_file(&cover_path, 5000);

        // Add hidden file and .DS_Store (should be ignored)
        create_dummy_file(&dir.join(".DS_Store"), 100);
        create_dummy_file(&dir.join("._Movie.2023.mkv"), 100);

        let mgr = LibraryManager::new();
        let report = mgr.scan_folder(&db, folder.id, dir.to_str().unwrap()).unwrap();

        assert_eq!(report.added, 1);
        assert_eq!(report.ignored, 3); // .DS_Store, ._Movie, cover.jpg

        let items = db
            .list_library_items(Some("video".to_string()), None, None, true, 0, 10)
            .unwrap();
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].rel_path, "Movie.2023.mkv");
        assert_eq!(items[0].subtitles, vec!["Movie.2023.fr.srt"]);

        // 3. Second scan without changes: unchanged == 1
        let report2 = mgr.scan_folder(&db, folder.id, dir.to_str().unwrap()).unwrap();
        assert_eq!(report2.unchanged, 1);
        assert_eq!(report2.added, 0);

        // 4. Rename file: Movie.2023.mkv -> Movie.Renamed.mkv
        let renamed_path = dir.join("Movie.Renamed.mkv");
        fs::rename(&video_path, &renamed_path).unwrap();

        let report3 = mgr.scan_folder(&db, folder.id, dir.to_str().unwrap()).unwrap();
        assert_eq!(report3.updated, 1);
        assert_eq!(report3.added, 0);
        assert_eq!(report3.removed, 0);

        let items3 = db
            .list_library_items(Some("video".to_string()), None, None, true, 0, 10)
            .unwrap();
        assert_eq!(items3.len(), 1);
        assert_eq!(items3[0].rel_path, "Movie.Renamed.mkv");

        // 5. Delete file
        fs::remove_file(&renamed_path).unwrap();
        let report4 = mgr.scan_folder(&db, folder.id, dir.to_str().unwrap()).unwrap();
        assert_eq!(report4.removed, 1);

        let items4 = db
            .list_library_items(Some("video".to_string()), None, None, true, 0, 10)
            .unwrap();
        assert_eq!(items4.len(), 0);

        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn test_fts5_library_search() {
        let db = DatabaseManager::open_in_memory().unwrap();
        let folder = db
            .add_library_folder("Music", "/tmp/music", None, true, "audio")
            .unwrap();

        let meta = LibraryItemMetadataInput {
            title: Some("Bohemian Rhapsody".to_string()),
            duration_ms: Some(354000),
            width: None,
            height: None,
            codec: Some("flac".to_string()),
            artist: Some("Queen".to_string()),
            album: Some("A Night at the Opera".to_string()),
            album_artist: Some("Queen".to_string()),
            track_no: Some(11),
            disc_no: Some(1),
            genre: Some("Rock".to_string()),
            year: Some(1975),
            taken_at: None,
            thumbnail_path: None,
        };

        // Insert item manually
        db.with_conn(|conn| {
            conn.execute(
                "INSERT INTO library_items (folder_id, rel_path, kind, size, mtime, fingerprint, title, added_at, updated_at)
                 VALUES (?1, 'Queen/bohemian.flac', 'audio', 40000000, 1700000000, 'fp1', 'Bohemian Rhapsody', 1700000000, 1700000000)",
                params![folder.id],
            )?;
            Ok(())
        }).unwrap();

        db.update_item_metadata(1, &meta).unwrap();

        // Search by artist
        let res_artist = db.search_library("Queen", None, 10).unwrap();
        assert_eq!(res_artist.len(), 1);
        assert_eq!(res_artist[0].title.as_deref(), Some("Bohemian Rhapsody"));

        // Search by title prefix
        let res_title = db.search_library("Bohem", None, 10).unwrap();
        assert_eq!(res_title.len(), 1);

        // Search by album
        let res_album = db.search_library("Opera", None, 10).unwrap();
        assert_eq!(res_album.len(), 1);
    }

    #[test]
    fn test_library_sla_50k_items_query() {
        let db = DatabaseManager::open_in_memory().unwrap();
        let folder = db
            .add_library_folder("BigDir", "/tmp/big", None, true, "video")
            .unwrap();

        db.with_conn(|conn| {
            conn.execute_batch("BEGIN")?;
            {
                let mut stmt = conn.prepare(
                    "INSERT INTO library_items (folder_id, rel_path, kind, size, mtime, fingerprint, title, added_at, updated_at)
                     VALUES (?1, ?2, 'video', 1000000, 1700000000, ?3, ?4, 1700000000, 1700000000)",
                )?;
                for i in 0..50_000 {
                    let rel = format!("sub_{}/movie_{i}.mp4", i % 100);
                    let fp = format!("fp_{i}");
                    let title = format!("Movie {i}");
                    stmt.execute(params![folder.id, rel, fp, title])?;
                }
            }
            conn.execute_batch("COMMIT")?;
            Ok(())
        })
        .unwrap();

        let start = Instant::now();
        let items = db
            .list_library_items(Some("video".to_string()), None, Some("title".to_string()), true, 0, 100)
            .unwrap();
        let elapsed = start.elapsed();

        assert_eq!(items.len(), 100);
        // PRD-32 SLA: Querying a 50k item library must be < 50ms
        let max_ms = if cfg!(debug_assertions) { 150 } else { 50 };
        assert!(
            elapsed.as_millis() < max_ms,
            "Listing 100 items from 50k library took {:?}",
            elapsed
        );
    }

    #[test]
    fn test_library_sla_10k_files_scan() {
        let db = DatabaseManager::open_in_memory().unwrap();
        let dir = std::env::temp_dir().join(format!("cnd_test_10k_{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();

        // Create 100 subdirectories with 100 files each = 10,000 files
        for s in 0..100 {
            let sub = dir.join(format!("sub_{s}"));
            fs::create_dir_all(&sub).unwrap();
            for f in 0..100 {
                let p = sub.join(format!("video_{f}.mp4"));
                let mut file = File::create(p).unwrap();
                file.write_all(b"dummy mp4 payload for sla benchmark").unwrap();
            }
        }

        let folder = db
            .add_library_folder("Bench10k", dir.to_str().unwrap(), None, true, "video")
            .unwrap();

        let mgr = LibraryManager::new();
        let start = Instant::now();
        let report = mgr.scan_folder(&db, folder.id, dir.to_str().unwrap()).unwrap();
        let elapsed = start.elapsed();

        assert_eq!(report.added, 10_000);
        // PRD-32 SLA: 10,000 files traversed and indexed in < 10 s
        let max_sec = if cfg!(debug_assertions) { 15 } else { 10 };
        assert!(
            elapsed.as_secs() < max_sec,
            "10,000 files scan took {:?} (SLA: < 10s)",
            elapsed
        );

        let _ = fs::remove_dir_all(dir);
    }
}
