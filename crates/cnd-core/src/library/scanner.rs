use crate::db::library_repo::LibraryScanReport;
use crate::db::DatabaseManager;
use crate::library::classify::{
    classify_by_extension, is_cover_file, is_subtitle_file, match_subtitle_to_video, MediaKind,
};
use crate::library::fingerprint::compute_file_fingerprint;
use crate::CndError;
use rusqlite::params;
use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Instant;

const MAX_DEPTH: usize = 32;
const MAX_FILES_PER_FOLDER: usize = 200_000;

pub struct ScannerOptions {
    pub include_subfolders: bool,
    pub allowed_kinds: HashSet<MediaKind>,
    pub cancel_flag: Arc<AtomicBool>,
}

impl Default for ScannerOptions {
    fn default() -> Self {
        let mut kinds = HashSet::new();
        kinds.insert(MediaKind::Video);
        kinds.insert(MediaKind::Audio);
        kinds.insert(MediaKind::Image);
        Self {
            include_subfolders: true,
            allowed_kinds: kinds,
            cancel_flag: Arc::new(AtomicBool::new(false)),
        }
    }
}

pub fn should_skip_directory(name: &str) -> bool {
    let lower = name.to_ascii_lowercase();
    // Hidden directories
    if lower.starts_with('.') || lower.starts_with('$') {
        return true;
    }
    // Trash & System directories
    if matches!(
        lower.as_str(),
        "$recycle.bin" | "system volume information" | ".trashes" | ".fseventsd" | ".spotlight-v100"
    ) {
        return true;
    }
    // Apple package / bundle bundles
    if lower.ends_with(".app")
        || lower.ends_with(".photoslibrary")
        || lower.ends_with(".photolibrary")
        || lower.ends_with(".fcpbundle")
        || lower.ends_with(".framework")
        || lower.ends_with(".plugin")
        || lower.ends_with(".bundle")
        || lower.ends_with(".pkg")
    {
        return true;
    }
    false
}

pub fn should_skip_file(name: &str) -> bool {
    let lower = name.to_ascii_lowercase();
    // Hidden files & AppleDouble resource forks
    if lower.starts_with('.') || lower.starts_with("._") {
        return true;
    }
    // System files
    if matches!(
        lower.as_str(),
        "thumbs.db" | "desktop.ini" | ".ds_store"
    ) {
        return true;
    }
    false
}

#[derive(Debug)]
struct DiscoveredMedia {
    rel_path: String,
    full_path: PathBuf,
    kind: MediaKind,
    size: u64,
    mtime: i64,
    parent_rel_dir: String,
    stem: String,
}

#[derive(Debug)]
struct DiscoveredCompanion {
    rel_path: String,
    parent_rel_dir: String,
    stem: String,
}

pub fn scan_library_folder(
    db: &DatabaseManager,
    folder_id: i64,
    root_path_str: &str,
    options: &ScannerOptions,
) -> Result<LibraryScanReport, CndError> {
    let start_time = Instant::now();
    let root_path = PathBuf::from(root_path_str);
    if !root_path.exists() || !root_path.is_dir() {
        return Err(CndError::Validation {
            message: format!("Folder path does not exist or is not a directory: {root_path_str}"),
        });
    }

    // Canonicalize root to detect symlink escapes
    let canonical_root = fs::canonicalize(&root_path).unwrap_or_else(|_| root_path.clone());

    let mut media_files: Vec<DiscoveredMedia> = Vec::new();
    let mut subtitle_files: Vec<DiscoveredCompanion> = Vec::new();
    let mut ignored_count = 0u32;

    // 1. Recursive directory walk
    let mut dir_queue: Vec<(PathBuf, usize)> = vec![(root_path.clone(), 0)];
    let mut visited_canonical = HashSet::new();
    visited_canonical.insert(canonical_root.clone());

    while let Some((dir, depth)) = dir_queue.pop() {
        if options.cancel_flag.load(Ordering::Relaxed) {
            break;
        }

        if depth > MAX_DEPTH {
            ignored_count += 1;
            continue;
        }

        let entries = match fs::read_dir(&dir) {
            Ok(e) => e,
            Err(_) => {
                ignored_count += 1;
                continue;
            }
        };

        for entry in entries.flatten() {
            if options.cancel_flag.load(Ordering::Relaxed) {
                break;
            }

            if (media_files.len() + subtitle_files.len()) >= MAX_FILES_PER_FOLDER {
                ignored_count += 1;
                continue;
            }

            let path = entry.path();
            let file_name = match entry.file_name().into_string() {
                Ok(n) => n,
                Err(_) => {
                    ignored_count += 1;
                    continue;
                }
            };

            // Check symlink targets
            let file_type = match entry.file_type() {
                Ok(ft) => ft,
                Err(_) => {
                    ignored_count += 1;
                    continue;
                }
            };

            if file_type.is_symlink() {
                if let Ok(target) = fs::canonicalize(&path) {
                    if !target.starts_with(&canonical_root) {
                        // Points outside root, skip
                        ignored_count += 1;
                        continue;
                    }
                } else {
                    ignored_count += 1;
                    continue;
                }
            }

            if file_type.is_dir() {
                if !options.include_subfolders && depth > 0 {
                    continue;
                }
                if should_skip_directory(&file_name) {
                    ignored_count += 1;
                    continue;
                }

                if let Ok(canon) = fs::canonicalize(&path) {
                    if visited_canonical.insert(canon) {
                        dir_queue.push((path, depth + 1));
                    } else {
                        // Circular symlink
                        ignored_count += 1;
                    }
                }
            } else if file_type.is_file() {
                if should_skip_file(&file_name) {
                    ignored_count += 1;
                    continue;
                }

                let meta = match entry.metadata() {
                    Ok(m) => m,
                    Err(_) => {
                        ignored_count += 1;
                        continue;
                    }
                };

                let size = meta.len();
                let mtime = meta
                    .modified()
                    .ok()
                    .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                    .map(|d| d.as_secs() as i64)
                    .unwrap_or(0);

                let rel_path = match path.strip_prefix(&root_path) {
                    Ok(p) => p.to_string_lossy().replace('\\', "/"),
                    Err(_) => continue,
                };

                let parent_dir = path
                    .parent()
                    .and_then(|p| p.strip_prefix(&root_path).ok())
                    .map(|p| p.to_string_lossy().replace('\\', "/"))
                    .unwrap_or_default();

                let stem = path
                    .file_stem()
                    .map(|s| s.to_string_lossy().to_string())
                    .unwrap_or_default();

                if is_subtitle_file(&path) {
                    subtitle_files.push(DiscoveredCompanion {
                        rel_path,
                        parent_rel_dir: parent_dir,
                        stem,
                    });
                } else if is_cover_file(&path) {
                    // Handled as cover companion
                    ignored_count += 1;
                } else if let Some(kind) = classify_by_extension(&path) {
                    if options.allowed_kinds.contains(&kind) {
                        media_files.push(DiscoveredMedia {
                            rel_path,
                            full_path: path,
                            kind,
                            size,
                            mtime,
                            parent_rel_dir: parent_dir,
                            stem,
                        });
                    } else {
                        ignored_count += 1;
                    }
                } else {
                    ignored_count += 1;
                }
            }
        }
    }

    // 2. Group subtitles by parent directory and bind them to corresponding video items
    let mut dir_video_stems: HashMap<String, Vec<String>> = HashMap::new();
    for m in &media_files {
        if m.kind == MediaKind::Video {
            dir_video_stems
                .entry(m.parent_rel_dir.clone())
                .or_default()
                .push(m.stem.clone());
        }
    }

    let mut video_subtitles: HashMap<String, Vec<String>> = HashMap::new();
    for sub in subtitle_files {
        if let Some(stems) = dir_video_stems.get(&sub.parent_rel_dir) {
            let stem_refs: Vec<&str> = stems.iter().map(|s| s.as_str()).collect();
            if let Some(matched_stem) = match_subtitle_to_video(&sub.stem, &stem_refs) {
                let video_key = if sub.parent_rel_dir.is_empty() {
                    matched_stem.to_string()
                } else {
                    format!("{}/{}", sub.parent_rel_dir, matched_stem)
                };
                video_subtitles.entry(video_key).or_default().push(sub.rel_path);
            }
        }
    }

    // 3. Database reconciliation: load existing DB records for this folder
    struct DbItemInfo {
        id: i64,
        size: u64,
        mtime: i64,
    }

    let mut db_items_by_path: HashMap<String, DbItemInfo> = HashMap::new();
    let mut db_items_by_fp: HashMap<String, Vec<(i64, String)>> = HashMap::new();

    db.with_conn(|conn| {
        let mut stmt = conn.prepare(
            "SELECT id, rel_path, size, mtime, fingerprint FROM library_items WHERE folder_id = ?1",
        )?;
        let mut rows = stmt.query(params![folder_id])?;
        while let Some(r) = rows.next()? {
            let id: i64 = r.get(0)?;
            let rel_path: String = r.get(1)?;
            let size = r.get::<_, i64>(2)? as u64;
            let mtime: i64 = r.get(3)?;
            let fingerprint: String = r.get(4)?;

            db_items_by_path.insert(
                rel_path.clone(),
                DbItemInfo {
                    id,
                    size,
                    mtime,
                },
            );
            db_items_by_fp.entry(fingerprint).or_default().push((id, rel_path));
        }
        Ok(())
    })
    .map_err(|e| CndError::Internal {
        message: format!("Failed reading library items: {e}"),
    })?;

    let mut added = 0u32;
    let mut updated = 0u32;
    let mut unchanged = 0u32;

    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64;

    // 4. Reconcile discovered media
    for m in media_files {
        if options.cancel_flag.load(Ordering::Relaxed) {
            break;
        }

        // Subtitles array for this video
        let video_key = if m.parent_rel_dir.is_empty() {
            m.stem.clone()
        } else {
            format!("{}/{}", m.parent_rel_dir, m.stem)
        };
        let subs = video_subtitles.get(&video_key).cloned().unwrap_or_default();
        let subs_json = if subs.is_empty() {
            None
        } else {
            serde_json::to_string(&subs).ok()
        };

        if let Some(existing) = db_items_by_path.remove(&m.rel_path) {
            // Already known at this path
            if existing.size == m.size && existing.mtime == m.mtime {
                // Completely unchanged
                unchanged += 1;
                // If subtitle list changed, update it
                let _ = db.with_conn(|conn| {
                    conn.execute(
                        "UPDATE library_items SET subtitles_json = ?1 WHERE id = ?2",
                        params![subs_json, existing.id],
                    )?;
                    Ok(())
                });
            } else {
                // Size or mtime changed: recompute fingerprint
                let fp = compute_file_fingerprint(&m.full_path, m.size)
                    .unwrap_or_else(|_| format!("{}:mod_{}", m.size, m.mtime));
                let _ = db.with_conn(|conn| {
                    conn.execute(
                        "UPDATE library_items
                         SET size = ?1, mtime = ?2, fingerprint = ?3, subtitles_json = ?4, metadata_state = 'pending', updated_at = ?5
                         WHERE id = ?6",
                        params![m.size as i64, m.mtime, fp, subs_json, now, existing.id],
                    )?;
                    Ok(())
                });
                updated += 1;
            }
        } else {
            // New path on disk. Compute fingerprint to detect if it's a renamed/moved file
            let fp = compute_file_fingerprint(&m.full_path, m.size)
                .unwrap_or_else(|_| format!("{}:new_{}", m.size, m.mtime));

            // Check if a removed item shared this fingerprint
            let matched_rename = db_items_by_fp.get_mut(&fp).and_then(|candidates| {
                candidates.pop().map(|(id, old_rel)| {
                    db_items_by_path.remove(&old_rel);
                    id
                })
            });

            if let Some(renamed_id) = matched_rename {
                // It was moved/renamed! Update rel_path and keep all metadata & progress
                let _ = db.with_conn(|conn| {
                    conn.execute(
                        "UPDATE library_items
                         SET rel_path = ?1, subtitles_json = ?2, updated_at = ?3
                         WHERE id = ?4",
                        params![m.rel_path, subs_json, now, renamed_id],
                    )?;
                    Ok(())
                });
                updated += 1;
            } else {
                // Genuinely new file
                let title = m.stem.replace(['.', '_'], " ");
                let _ = db.with_conn(|conn| {
                    conn.execute(
                        "INSERT INTO library_items (folder_id, rel_path, kind, size, mtime, fingerprint, title, subtitles_json, metadata_state, added_at, updated_at)
                         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, 'pending', ?9, ?9)",
                        params![
                            folder_id,
                            m.rel_path,
                            m.kind.as_str(),
                            m.size as i64,
                            m.mtime,
                            fp,
                            title,
                            subs_json,
                            now
                        ],
                    )?;
                    Ok(())
                });
                added += 1;
            }
        }
    }

    // 5. Delete items that were in DB but no longer on disk
    let mut removed = 0u32;
    for (_path, item) in db_items_by_path {
        let _ = db.with_conn(|conn| {
            conn.execute("DELETE FROM library_items WHERE id = ?1", params![item.id])?;
            Ok(())
        });
        removed += 1;
    }

    // 6. Update folder item count and last_scan_at
    let _ = db.with_conn(|conn| {
        conn.execute(
            "UPDATE library_folders
             SET item_count = (SELECT COUNT(*) FROM library_items WHERE folder_id = ?1),
                 last_scan_at = ?2,
                 updated_at = ?2
             WHERE id = ?1",
            params![folder_id, now],
        )?;
        Ok(())
    });

    let duration_ms = start_time.elapsed().as_millis() as u64;

    Ok(LibraryScanReport {
        added,
        updated,
        removed,
        unchanged,
        ignored: ignored_count,
        duration_ms,
    })
}
