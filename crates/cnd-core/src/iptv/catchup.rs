//! Catch-up TV (Replay) and Time-Shifting URL resolution engine.
//!
//! Complies with PRD-15 for universal IPTV replay support:
//! - M3U placeholder template interpolation ({utc}, {lutc}, {start}, {end}, {duration}, {offset}, {Y}, {m}, {d}, {H}, {M}, {S})
//! - Xtream Codes `/timeshift/username/password/duration/start_time/stream_id.ext`
//! - Flussonic `/timeshift_abs-{utc}.m3u8`
//! - Time retention validation (`is_catchup_available`)

use thiserror::Error;

#[derive(Debug, Error, PartialEq, Eq)]
pub enum CatchupError {
    #[error("Item does not support catchup replay")]
    NotSupported,
    #[error("Catchup window expired: program is older than retention limit ({0} days)")]
    Expired(u32),
    #[error("Program has not started yet")]
    FutureProgram,
    #[error("Invalid stream URL: {0}")]
    InvalidUrl(String),
}

/// Howard Hinnant's civil date from epoch days algorithm.
/// Returns `(year, month, day)` in UTC.
#[inline]
pub fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u32;
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = y + i64::from(m <= 2);
    (year, m, d)
}

/// Days since 1970-01-01 of a civil date (inverse of `civil_from_days`).
pub fn days_from_civil(year: i64, month: u32, day: u32) -> i64 {
    let y = if month <= 2 { year - 1 } else { year };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let mp = (month as i64 + 9) % 12;
    let doy = (153 * mp + 2) / 5 + day as i64 - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// Offset in seconds between a Xtream server's local clock and UTC, from `server_info`:
/// `time_now` ("YYYY-MM-DD HH:MM:SS", server local time) and `timestamp_now` (Unix time).
/// Rounded to 15 minutes (the two values are read a moment apart) and bounded to a real zone.
pub fn server_utc_offset(time_now: &str, timestamp_now: i64) -> Option<i64> {
    let text = time_now.trim();
    let (date, clock) = text.split_once(' ')?;
    let mut d = date.split('-');
    let (year, month, day): (i64, u32, u32) = (d.next()?.parse().ok()?, d.next()?.parse().ok()?, d.next()?.parse().ok()?);
    let mut c = clock.split(':');
    let (hour, minute, second): (i64, i64, i64) = (c.next()?.parse().ok()?, c.next()?.parse().ok()?, c.next().unwrap_or("0").parse().ok()?);
    if !(1..=12).contains(&month) || !(1..=31).contains(&day) || hour > 23 || minute > 59 || second > 60 {
        return None;
    }
    let local_as_utc = days_from_civil(year, month, day) * 86_400 + hour * 3_600 + minute * 60 + second;
    let diff = local_as_utc - timestamp_now;
    let rounded = ((diff + 450).div_euclid(900)) * 900;
    (-14 * 3_600..=14 * 3_600).contains(&rounded).then_some(rounded)
}

/// Converts a Unix timestamp in seconds to UTC date/time components:
/// `(year, month, day, hour, minute, second)`
pub fn timestamp_to_utc_parts(ts: i64) -> (i64, u32, u32, u32, u32, u32) {
    let days = ts.div_euclid(86_400);
    let rem_secs = ts.rem_euclid(86_400);

    let (year, month, day) = civil_from_days(days);
    let hour = (rem_secs / 3_600) as u32;
    let minute = ((rem_secs % 3_600) / 60) as u32;
    let second = (rem_secs % 60) as u32;

    (year, month, day, hour, minute, second)
}

/// Checks whether catch-up metadata indicates replay capability.
pub fn is_catchup_supported(
    catchup_type: Option<&str>,
    catchup_source: Option<&str>,
) -> bool {
    let has_type = catchup_type
        .map(|s| !s.trim().is_empty() && s.trim().to_lowercase() != "false" && s.trim().to_lowercase() != "no")
        .unwrap_or(false);
    let has_source = catchup_source
        .map(|s| !s.trim().is_empty())
        .unwrap_or(false);
    has_type || has_source
}

/// Checks if catchup replay is available for a program given its start time,
/// retention limit, and current timestamp.
pub fn is_catchup_available(
    catchup_type: Option<&str>,
    catchup_source: Option<&str>,
    catchup_days: Option<u32>,
    start_ts: i64,
    now_ts: i64,
) -> bool {
    if !is_catchup_supported(catchup_type, catchup_source) {
        return false;
    }

    // Program must have started (or starting right now)
    if start_ts > now_ts {
        return false;
    }

    let retention_days = catchup_days.unwrap_or(7).max(1);
    let retention_secs = (retention_days as i64) * 86_400;

    let elapsed = now_ts.saturating_sub(start_ts);
    elapsed <= retention_secs
}

/// Resolves a catchup replay URL for an IPTV item and program time range.
// The channel (url, type, source, days) and the time window (start, end, now, server clock) travel as
// separate values because every caller already has them that way.
#[allow(clippy::too_many_arguments)]
pub fn build_catchup_url(
    stream_url: &str,
    catchup_type: Option<&str>,
    catchup_source: Option<&str>,
    catchup_days: Option<u32>,
    start_ts: i64,
    end_ts: i64,
    now_ts: i64,
    server_offset_secs: i64,
) -> Result<String, CatchupError> {
    if !is_catchup_supported(catchup_type, catchup_source) {
        return Err(CatchupError::NotSupported);
    }

    let retention_days = catchup_days.unwrap_or(7).max(1);
    let retention_secs = (retention_days as i64) * 86_400;

    if start_ts > now_ts {
        return Err(CatchupError::FutureProgram);
    }

    if now_ts.saturating_sub(start_ts) > retention_secs {
        return Err(CatchupError::Expired(retention_days));
    }

    let trimmed_stream = stream_url.trim();
    if trimmed_stream.is_empty() {
        return Err(CatchupError::InvalidUrl("Empty stream URL".to_string()));
    }

    // Check if custom catchup_source is specified
    if let Some(src) = catchup_source.map(str::trim).filter(|s| !s.is_empty()) {
        return interpolate_catchup_source(trimmed_stream, src, start_ts, end_ts, now_ts);
    }

    let c_type = catchup_type.unwrap_or("default").trim().to_lowercase();

    // 1. Try Xtream Codes Timeshift format if stream_url matches Xtream live format
    if let Some(xtream_url) = try_build_xtream_timeshift_url(trimmed_stream, start_ts, end_ts, server_offset_secs) {
        return Ok(xtream_url);
    }

    // 2. Flussonic format
    if c_type == "flussonic" || c_type == "fs" {
        return Ok(build_flussonic_url(trimmed_stream, start_ts, end_ts));
    }

    // 3. Shift format: ?timeshift={offset}
    if c_type == "shift" {
        let offset = (now_ts - start_ts).max(0);
        return Ok(append_query(trimmed_stream, &format!("timeshift={offset}")));
    }

    // 4. Default / Append format: ?utc={utc}&lutc={lutc}
    let query = format!("utc={start_ts}&lutc={now_ts}");
    Ok(append_query(trimmed_stream, &query))
}

/// Interpolates placeholders in a `catchup-source` string.
fn interpolate_catchup_source(
    stream_url: &str,
    source_template: &str,
    start_ts: i64,
    end_ts: i64,
    now_ts: i64,
) -> Result<String, CatchupError> {
    let (year, month, day, hour, minute, second) = timestamp_to_utc_parts(start_ts);
    let duration = (end_ts - start_ts).max(0);
    let duration_minutes = ((duration + 59) / 60).max(1);
    let offset = (now_ts - start_ts).max(0);

    let replaced = source_template
        .replace("{utc}", &start_ts.to_string())
        .replace("{start}", &start_ts.to_string())
        .replace("{timestamp}", &start_ts.to_string())
        .replace("{lutc}", &now_ts.to_string())
        .replace("{now}", &now_ts.to_string())
        .replace("{utcend}", &end_ts.to_string())
        .replace("{end}", &end_ts.to_string())
        .replace("{duration}", &duration.to_string())
        .replace("{duration_minutes}", &duration_minutes.to_string())
        .replace("{offset}", &offset.to_string())
        .replace("{Y}", &format!("{year:04}"))
        .replace("{m}", &format!("{month:02}"))
        .replace("{d}", &format!("{day:02}"))
        .replace("{H}", &format!("{hour:02}"))
        .replace("{M}", &format!("{minute:02}"))
        .replace("{S}", &format!("{second:02}"))
        .replace("{stream_url}", stream_url);

    // If result is already an absolute URL (e.g. http://... or https://...)
    if replaced.starts_with("http://") || replaced.starts_with("https://") {
        return Ok(replaced);
    }

    // If it's a query parameter fragment (?foo=bar or &foo=bar)
    if replaced.starts_with('?') || replaced.starts_with('&') {
        let query_part = &replaced[1..];
        return Ok(append_query(stream_url, query_part));
    }

    // If it's a relative path starting with /
    if replaced.starts_with('/') {
        if let Ok(mut url) = url::Url::parse(stream_url) {
            url.set_path(&replaced);
            return Ok(url.to_string());
        }
        return Ok(format!("{stream_url}{replaced}"));
    }

    // Otherwise, append with query parameter separator
    Ok(append_query(stream_url, &replaced))
}

/// Appends a query string correctly whether or not the URL already has `?`.
fn append_query(stream_url: &str, query: &str) -> String {
    let clean_query = query.trim_start_matches(['?', '&']);
    if stream_url.contains('?') {
        format!("{stream_url}&{clean_query}")
    } else {
        format!("{stream_url}?{clean_query}")
    }
}

/// Tries to construct an Xtream Codes `/timeshift/` URL if the URL conforms to the standard pattern.
/// Standard live pattern: `http://host:port/live/user/pass/stream_id.ext` or `http://host:port/user/pass/stream_id.ext`
/// Timeshift output: `http://host:port/timeshift/user/pass/{duration_minutes}/{YYYY-MM-DD:HH-MM}/{stream_id}.ext`
fn try_build_xtream_timeshift_url(
    stream_url: &str,
    start_ts: i64,
    end_ts: i64,
    server_offset_secs: i64,
) -> Option<String> {
    let Ok(url) = url::Url::parse(stream_url) else {
        return None;
    };

    let segments: Vec<&str> = url
        .path_segments()?
        .filter(|s| !s.is_empty())
        .collect();

    // Matching either:
    // ["live", user, pass, stream_filename] (4 segments)
    // or [user, pass, stream_filename] (3 segments)
    let (user, pass, stream_file) = match segments.as_slice() {
        ["live", u, p, file] => (*u, *p, *file),
        [u, p, file] if !matches!(*u, "movie" | "series" | "timeshift" | "player_api.php") => {
            (*u, *p, *file)
        }
        _ => return None,
    };

    // Xtream reads the start time on the server's own clock, not in UTC.
    let (year, month, day, hour, minute, _) = timestamp_to_utc_parts(start_ts + server_offset_secs);
    let time_str = format!("{year:04}-{month:02}-{day:02}:{hour:02}-{minute:02}");

    let duration_secs = (end_ts - start_ts).max(60);
    let duration_min = ((duration_secs + 59) / 60).max(1);

    let host_str = url.host_str()?;
    let scheme = url.scheme();
    let port_str = match url.port() {
        Some(p) => format!(":{p}"),
        None => String::new(),
    };

    Some(format!(
        "{scheme}://{host_str}{port_str}/timeshift/{user}/{pass}/{duration_min}/{time_str}/{stream_file}"
    ))
}

/// Flussonic HLS timeshift URL builder.
/// Replaces ending `.m3u8` or `/index.m3u8` / `/mono.m3u8` with `/timeshift_abs-{start_ts}.m3u8`.
fn build_flussonic_url(stream_url: &str, start_ts: i64, _end_ts: i64) -> String {
    if let Some(stripped) = stream_url.strip_suffix("/index.m3u8") {
        return format!("{stripped}/timeshift_abs-{start_ts}.m3u8");
    }
    if let Some(stripped) = stream_url.strip_suffix("/mono.m3u8") {
        return format!("{stripped}/timeshift_abs-{start_ts}.m3u8");
    }
    if let Some(idx) = stream_url.rfind(".m3u8") {
        let (prefix, _) = stream_url.split_at(idx);
        return format!("{prefix}/timeshift_abs-{start_ts}.m3u8");
    }
    append_query(stream_url, &format!("timeshift_abs={start_ts}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::iptv::epg::parse_xmltv_timestamp;

    #[test]
    fn test_civil_from_days_known_dates() {
        // 1970-01-01 is day 0
        assert_eq!(civil_from_days(0), (1970, 1, 1));

        // 2026-11-02 16:30:45 UTC
        let ts = parse_xmltv_timestamp(b"20261102163045").expect("valid ts");
        let (year, month, day, hour, minute, second) = timestamp_to_utc_parts(ts);
        assert_eq!(year, 2026);
        assert_eq!(month, 11);
        assert_eq!(day, 2);
        assert_eq!(hour, 16);
        assert_eq!(minute, 30);
        assert_eq!(second, 45);
    }

    #[test]
    fn test_is_catchup_available_retention() {
        let now_ts = 1_000_000;
        let start_future = now_ts + 60;
        let start_today = now_ts - 3600;
        let start_8_days_ago = now_ts - (8 * 86_400);

        // Not supported
        assert!(!is_catchup_available(None, None, Some(7), start_today, now_ts));
        assert!(!is_catchup_available(Some("false"), None, Some(7), start_today, now_ts));

        // Future program
        assert!(!is_catchup_available(Some("default"), None, Some(7), start_future, now_ts));

        // Within 7 days retention
        assert!(is_catchup_available(Some("default"), None, Some(7), start_today, now_ts));

        // Expired (8 days ago > 7 days retention)
        assert!(!is_catchup_available(Some("default"), None, Some(7), start_8_days_ago, now_ts));

        // Custom retention (14 days)
        assert!(is_catchup_available(Some("default"), None, Some(14), start_8_days_ago, now_ts));
    }

    #[test]
    fn test_xtream_codes_timeshift_url() {
        let live_url = "http://iptv.provider.com:8080/live/myuser/mypass/12345.ts";
        let start_ts = parse_xmltv_timestamp(b"20261102160000").expect("valid start");
        let end_ts = start_ts + 3600; // 1 hour -> 60 minutes
        let now_ts = end_ts + 1800; // 30 min after end

        let catchup_url = build_catchup_url(
            live_url,
            Some("default"),
            None,
            Some(7),
            start_ts,
            end_ts,
            now_ts,
            0,
        ).unwrap();

        assert_eq!(
            catchup_url,
            "http://iptv.provider.com:8080/timeshift/myuser/mypass/60/2026-11-02:16-00/12345.ts"
        );
    }

    #[test]
    fn test_m3u_template_interpolation() {
        let live_url = "http://cdn.stream.com/live/ch1.m3u8";
        let template = "?utc={utc}&lutc={lutc}&duration={duration}";
        let start_ts = 1700000000;
        let end_ts = 1700003600;
        let now_ts = 1700005000;

        let catchup_url = build_catchup_url(
            live_url,
            Some("default"),
            Some(template),
            Some(7),
            start_ts,
            end_ts,
            now_ts,
            0,
        ).unwrap();

        assert_eq!(
            catchup_url,
            "http://cdn.stream.com/live/ch1.m3u8?utc=1700000000&lutc=1700005000&duration=3600"
        );
    }

    #[test]
    fn test_flussonic_catchup_url() {
        let live_url = "http://flussonic.server.com/tvchannel/mono.m3u8";
        let start_ts = 1700000000;
        let end_ts = 1700003600;
        let now_ts = 1700005000;

        let catchup_url = build_catchup_url(
            live_url,
            Some("flussonic"),
            None,
            Some(7),
            start_ts,
            end_ts,
            now_ts,
            0,
        ).unwrap();

        assert_eq!(
            catchup_url,
            "http://flussonic.server.com/tvchannel/timeshift_abs-1700000000.m3u8"
        );
    }

    #[test]
    fn test_shift_catchup_url() {
        let live_url = "http://stream.net/live/ch.ts";
        let start_ts = 1700000000;
        let end_ts = 1700003600;
        let now_ts = 1700001000; // 1000s after start

        let catchup_url = build_catchup_url(
            live_url,
            Some("shift"),
            None,
            Some(7),
            start_ts,
            end_ts,
            now_ts,
            0,
        ).unwrap();

        assert_eq!(
            catchup_url,
            "http://stream.net/live/ch.ts?timeshift=1000"
        );
    }

    #[test]
    fn xtream_timeshift_uses_the_server_clock() {
        let live_url = "http://iptv.provider.com:8080/live/u/p/42.ts";
        let start_ts = parse_xmltv_timestamp(b"20261102160000").expect("valid start"); // 16:00 UTC
        let end_ts = start_ts + 1800;
        let now_ts = end_ts + 600;
        let url = |offset| build_catchup_url(live_url, Some("xc"), None, Some(3), start_ts, end_ts, now_ts, offset).unwrap();

        assert!(url(0).contains("/30/2026-11-02:16-00/"));
        assert!(url(3_600).contains("/30/2026-11-02:17-00/"), "a server one hour ahead of UTC");
        assert!(url(-18_000).contains("/30/2026-11-02:11-00/"), "a server five hours behind");
        assert!(url(19_800).contains("2026-11-02:21-30"), "half-hour zones too");
        assert!(url(28_800).contains("2026-11-03:00-00"), "the date rolls over");
    }

    #[test]
    fn civil_dates_round_trip() {
        for ts in [0i64, 86_399, 951_782_400, 1_793_000_000, 4_102_444_800] {
            let (y, m, d, ..) = timestamp_to_utc_parts(ts);
            assert_eq!(days_from_civil(y, m, d), ts.div_euclid(86_400), "{ts}");
        }
    }

    #[test]
    fn server_offset_from_server_info() {
        // Paris in winter: UTC+1.
        let utc = 1_793_000_000; // 2026-10-26 07:33:20 UTC
        let (y, mo, d, h, mi, s) = timestamp_to_utc_parts(utc + 3_600);
        let local = format!("{y:04}-{mo:02}-{d:02} {h:02}:{mi:02}:{s:02}");
        assert_eq!(server_utc_offset(&local, utc), Some(3_600));
        // The two clocks are read a few seconds apart: still the same zone.
        assert_eq!(server_utc_offset(&local, utc + 7), Some(3_600));
        assert_eq!(server_utc_offset(&local, utc - 5), Some(3_600));
        // India: UTC+5:30.
        let (y, mo, d, h, mi, s) = timestamp_to_utc_parts(utc + 19_800);
        assert_eq!(server_utc_offset(&format!("{y:04}-{mo:02}-{d:02} {h:02}:{mi:02}:{s:02}"), utc), Some(19_800));
        // New York in winter: UTC-5.
        let (y, mo, d, h, mi, s) = timestamp_to_utc_parts(utc - 18_000);
        assert_eq!(server_utc_offset(&format!("{y:04}-{mo:02}-{d:02} {h:02}:{mi:02}:{s:02}"), utc), Some(-18_000));
    }

    #[test]
    fn nonsense_server_time_gives_no_offset() {
        assert_eq!(server_utc_offset("", 0), None);
        assert_eq!(server_utc_offset("not a date", 0), None);
        assert_eq!(server_utc_offset("2026-13-40 99:99:99", 0), None);
        assert_eq!(server_utc_offset("2026-11-02 12:00:00", 0), None, "a server clock years off is not a time zone");
    }
}
