//! Resolution of content identity, fallback Xtream playback URLs, and profile restrictions (PRD-42 § 5.4, § 6).
//!
//! Pure decision logic: no direct disk or network I/O.

use crate::identity::{compute_content_key, normalize_xtream_server};
use crate::profiles::is_adult_category;

/// Verifies if a given item's deterministic content key matches an expected `content_key`.
pub fn verify_content_key_match(
    source_key: &str,
    item_kind: &str,
    provider_item_id: &str,
    expected_content_key: &str,
) -> bool {
    let computed = compute_content_key(source_key, item_kind, provider_item_id);
    computed.eq_ignore_ascii_case(expected_content_key.trim())
}

/// Reconstructs the playback URL for an Xtream item when the target database catalogue is not yet indexed (PRD-42 § 6.2).
///
/// Returns an empty string if essential parameters are missing.
pub fn reconstruct_xtream_url(
    server: &str,
    username: &str,
    password: &str,
    item_kind: &str,
    provider_ref: &str,
    container_ext: Option<&str>,
) -> String {
    let s = normalize_xtream_server(server);
    let u = username.trim();
    let p = password.trim();
    let r = provider_ref.trim();

    if s.is_empty() || u.is_empty() || p.is_empty() || r.is_empty() {
        return String::new();
    }

    let ext = container_ext.map(|e| e.trim_start_matches('.')).unwrap_or("mp4");

    match item_kind.to_ascii_lowercase().as_str() {
        "live" => format!("{s}/live/{u}/{p}/{r}.ts"),
        "movie" => format!("{s}/movie/{u}/{p}/{r}.{ext}"),
        "episode" => format!("{s}/series/{u}/{p}/{r}.{ext}"),
        _ => format!("{s}/live/{u}/{p}/{r}.ts"),
    }
}

/// Checks if an item is allowed under a Kids profile (PRD-42 § 5.4).
pub fn is_content_allowed_in_kids_mode(
    group_title: Option<&str>,
    is_explicit_adult: bool,
) -> bool {
    if is_explicit_adult {
        return false;
    }
    if let Some(grp) = group_title {
        if is_adult_category(grp) {
            return false;
        }
    }
    true
}

