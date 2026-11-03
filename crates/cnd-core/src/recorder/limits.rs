//! Guards for the recorder: the subscription's connection limit and the free disk space.

use std::path::Path;

/// Estimated size of a recording per hour of TV (PRD-19: 4 GiB/h by default).
pub const BYTES_PER_HOUR: u64 = 4 * 1024 * 1024 * 1024;
/// A recording stops cleanly when the disk goes under this much free space.
pub const MIN_FREE_BYTES: u64 = 1024 * 1024 * 1024;

/// A recording uses one connection of the subscription: refuse a new one when the recordings already
/// running on that source fill the limit. An unknown or zero limit means "no known limit".
pub fn connection_limit_reached(max_connections: Option<u32>, running_on_source: usize) -> bool {
    matches!(max_connections, Some(max) if max > 0 && running_on_source >= max as usize)
}

/// Space a recording of `duration_secs` is expected to need, plus the margin that must stay free.
pub fn required_free_bytes(duration_secs: i64) -> u64 {
    let secs = duration_secs.max(0) as u64;
    (secs.saturating_mul(BYTES_PER_HOUR) / 3600).saturating_add(MIN_FREE_BYTES)
}

pub fn enough_space_to_start(free_bytes: u64, duration_secs: i64) -> bool {
    free_bytes >= required_free_bytes(duration_secs)
}

/// Free space for the volume holding `path` (the nearest existing parent if it does not exist yet).
#[cfg(unix)]
pub fn available_space(path: &Path) -> Option<u64> {
    use std::ffi::CString;
    use std::os::unix::ffi::OsStrExt;

    let mut existing = path;
    while !existing.exists() {
        existing = existing.parent()?;
    }
    let c_path = CString::new(existing.as_os_str().as_bytes()).ok()?;
    // SAFETY: `stat` is plain data, zeroed before the call; `c_path` is a valid NUL-terminated string.
    let mut stat: libc::statvfs = unsafe { std::mem::zeroed() };
    if unsafe { libc::statvfs(c_path.as_ptr(), &mut stat) } != 0 {
        return None;
    }
    Some((stat.f_bavail as u64).saturating_mul(stat.f_frsize as u64))
}

#[cfg(not(unix))]
pub fn available_space(_path: &Path) -> Option<u64> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn connection_limit_follows_the_known_limit() {
        assert!(!connection_limit_reached(None, 5), "unknown limit: never refuse");
        assert!(!connection_limit_reached(Some(0), 5), "zero means unknown");
        assert!(!connection_limit_reached(Some(1), 0));
        assert!(connection_limit_reached(Some(1), 1));
        assert!(!connection_limit_reached(Some(2), 1));
        assert!(connection_limit_reached(Some(2), 2));
        assert!(connection_limit_reached(Some(2), 3));
    }

    #[test]
    fn space_needed_grows_with_duration_and_keeps_a_margin() {
        assert_eq!(required_free_bytes(0), MIN_FREE_BYTES);
        assert_eq!(required_free_bytes(3600), BYTES_PER_HOUR + MIN_FREE_BYTES);
        assert_eq!(required_free_bytes(7200), 2 * BYTES_PER_HOUR + MIN_FREE_BYTES);
        assert_eq!(required_free_bytes(-10), MIN_FREE_BYTES, "a negative duration never panics");
        assert!(enough_space_to_start(10 * BYTES_PER_HOUR, 3600));
        assert!(!enough_space_to_start(BYTES_PER_HOUR, 3600), "the 1 GiB margin must remain");
    }

    #[cfg(unix)]
    #[test]
    fn free_space_is_read_even_for_a_folder_that_does_not_exist_yet() {
        let dir = std::env::temp_dir().join("cnd-no-such-dir-yet").join("Enregistrements");
        let free = available_space(&dir).expect("statvfs on the nearest existing parent");
        assert!(free > 0);
    }
}
