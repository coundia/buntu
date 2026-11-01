use crate::CndError;
use async_compression::tokio::bufread::GzipDecoder;
use quick_xml::events::{BytesStart, Event};
use quick_xml::Reader;
use std::collections::HashMap;
use tokio::io::{AsyncBufRead, AsyncBufReadExt, BufReader};

pub const EPG_BATCH_SIZE: usize = 5_000;
const EPG_RETENTION_PAST_SECS: i64 = 6 * 3_600;

#[derive(Debug, Clone)]
pub struct ParsedEpgProgram {
    pub channel_tvg_id: String,
    pub start_ts: i64,
    pub end_ts: i64,
    pub title: String,
    pub subtitle: Option<String>,
    pub description: Option<String>,
    pub category: Option<String>,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum SubTag {
    None,
    Title,
    SubTitle,
    Desc,
    Category,
}

/// Parses an XMLTV timestamp (`YYYYMMDDHHMMSS +HHMM`, `YYYYMMDDHHMMSS -HHMM`, or `YYYYMMDDHHMMSS`)
/// directly from ASCII bytes into a UTC Unix timestamp (`i64` seconds) without String allocations.
pub fn parse_xmltv_timestamp(raw: &[u8]) -> Option<i64> {
    // Trim leading/trailing ASCII whitespace
    let mut s = raw;
    while let Some((&first, rest)) = s.split_first() {
        if first.is_ascii_whitespace() {
            s = rest;
        } else {
            break;
        }
    }
    while let Some((&last, rest)) = s.split_last() {
        if last.is_ascii_whitespace() {
            s = rest;
        } else {
            break;
        }
    }

    if s.len() < 12 {
        return None;
    }

    let year = parse_digits(&s[0..4])?;
    let month = parse_digits(&s[4..6])?;
    let day = parse_digits(&s[6..8])?;
    let hour = parse_digits(&s[8..10])?;
    let minute = parse_digits(&s[10..12])?;

    let (second, rest_idx) = if s.len() >= 14 && s[12].is_ascii_digit() && s[13].is_ascii_digit() {
        (parse_digits(&s[12..14])?, 14)
    } else {
        (0, 12)
    };

    if !(1..=12).contains(&month)
        || !(1..=31).contains(&day)
        || hour > 23
        || minute > 59
        || second > 60
    {
        return None;
    }

    let days = days_from_civil(year, month, day);
    let local_epoch_secs = days * 86_400 + hour * 3_600 + minute * 60 + second;

    // Parse optional timezone offset (+HHMM, -HHMM, +HH:MM, Z, UTC)
    let mut tz_slice = &s[rest_idx..];
    while let Some((&first, rest)) = tz_slice.split_first() {
        if first.is_ascii_whitespace() {
            tz_slice = rest;
        } else {
            break;
        }
    }

    let tz_offset_secs = if tz_slice.is_empty()
        || tz_slice.eq_ignore_ascii_case(b"Z")
        || tz_slice.eq_ignore_ascii_case(b"UTC")
        || tz_slice.eq_ignore_ascii_case(b"GMT")
    {
        0
    } else if tz_slice[0] == b'+' || tz_slice[0] == b'-' {
        let sign: i64 = if tz_slice[0] == b'-' { -1 } else { 1 };
        let digits_part = &tz_slice[1..];
        let (tz_h, tz_m) = if digits_part.len() >= 5 && digits_part[2] == b':' {
            (
                parse_digits(&digits_part[0..2])?,
                parse_digits(&digits_part[3..5])?,
            )
        } else if digits_part.len() >= 4 {
            (
                parse_digits(&digits_part[0..2])?,
                parse_digits(&digits_part[2..4])?,
            )
        } else if digits_part.len() >= 2 {
            (parse_digits(&digits_part[0..2])?, 0)
        } else {
            (0, 0)
        };
        sign * (tz_h * 3_600 + tz_m * 60)
    } else {
        0
    };

    Some(local_epoch_secs - tz_offset_secs)
}

/// Parses channel `epg-shift` strings such as `"+2"`, `"-1"`, `"+01:30"`, or `"-90m"` into seconds.
pub fn parse_epg_shift_seconds(raw_shift: Option<&str>) -> i64 {
    let Some(s) = raw_shift.map(str::trim).filter(|s| !s.is_empty()) else {
        return 0;
    };
    let bytes = s.as_bytes();
    let (sign, rest) = match bytes[0] {
        b'-' => (-1i64, &s[1..]),
        b'+' => (1i64, &s[1..]),
        _ => (1i64, s),
    };
    if let Some((h_str, m_str)) = rest.split_once(':') {
        let h = h_str.trim().parse::<i64>().unwrap_or(0);
        let m = m_str.trim().parse::<i64>().unwrap_or(0);
        return sign * (h * 3_600 + m * 60);
    }
    if let Some(min_str) = rest.strip_suffix('m').or_else(|| rest.strip_suffix('M')) {
        let mins = min_str.trim().parse::<i64>().unwrap_or(0);
        return sign * mins * 60;
    }
    if let Ok(hours) = rest.trim().parse::<f64>() {
        if hours.is_finite() {
            return ( (sign as f64) * hours * 3_600.0 ).round() as i64;
        }
    }
    0
}

#[inline]
fn parse_digits(bytes: &[u8]) -> Option<i64> {
    let mut acc = 0i64;
    for &b in bytes {
        if !b.is_ascii_digit() {
            return None;
        }
        acc = acc * 10 + (b - b'0') as i64;
    }
    Some(acc)
}

/// Howard Hinnant's O(1) civil-to-days algorithm (days relative to 1970-01-01).
#[inline]
fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let y = year - i64::from(month <= 2);
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400; // [0, 399]
    let m_adj = if month > 2 { month - 3 } else { month + 9 }; // [0, 11]
    let doy = (153 * m_adj + 2) / 5 + day - 1; // [0, 365]
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy; // [0, 146096]
    era * 146_097 + doe - 719_468
}

/// Auto-detects Gzip magic bytes (`0x1f 0x8b`) at the start of `reader` and streams XMLTV events.
pub async fn parse_xmltv_auto_gzip<R, F>(
    mut reader: R,
    known_channels: Option<&HashMap<String, i64>>,
    now_ts: i64,
    on_batch: F,
) -> Result<u32, CndError>
where
    R: AsyncBufRead + Unpin,
    F: FnMut(&[ParsedEpgProgram]) -> Result<(), CndError>,
{
    let initial = reader.fill_buf().await.map_err(|e| CndError::Io {
        message: e.to_string(),
    })?;
    let is_gzip = initial.len() >= 2 && initial[0] == 0x1f && initial[1] == 0x8b;

    if is_gzip {
        let gz = GzipDecoder::new(reader);
        let decoded_reader = BufReader::with_capacity(64 * 1024, gz);
        parse_xmltv_plain_stream(decoded_reader, known_channels, now_ts, on_batch).await
    } else {
        parse_xmltv_plain_stream(reader, known_channels, now_ts, on_batch).await
    }
}

pub async fn parse_xmltv_plain_stream<R, F>(
    reader: R,
    known_channels: Option<&HashMap<String, i64>>,
    now_ts: i64,
    mut on_batch: F,
) -> Result<u32, CndError>
where
    R: AsyncBufRead + Unpin,
    F: FnMut(&[ParsedEpgProgram]) -> Result<(), CndError>,
{
    let mut xml = Reader::from_reader(reader);
    xml.config_mut().trim_text(true);

    let cutoff_ts = now_ts - EPG_RETENTION_PAST_SECS;
    let mut buf: Vec<u8> = Vec::with_capacity(4_096);
    let mut skip_buf: Vec<u8> = Vec::with_capacity(2_048);
    let mut batch: Vec<ParsedEpgProgram> = Vec::with_capacity(EPG_BATCH_SIZE);
    let mut total_count = 0u32;

    let mut in_programme = false;
    let mut cur_channel = String::new();
    let mut cur_start: i64 = 0;
    let mut cur_end: i64 = 0;
    let mut cur_title = String::new();
    let mut cur_subtitle: Option<String> = None;
    let mut cur_desc: Option<String> = None;
    let mut cur_category: Option<String> = None;
    let mut cur_subtag = SubTag::None;

    loop {
        buf.clear();
        let event = xml
            .read_event_into_async(&mut buf)
            .await
            .map_err(|e| CndError::Parse {
                message: format!("XMLTV parse error: {e}"),
            })?;

        match event {
            Event::Eof => break,
            Event::Start(ref e) => {
                let qname = e.name();
                if !in_programme {
                    if qname.as_ref().eq_ignore_ascii_case(b"programme") {
                        match inspect_programme_attrs(e, known_channels, cutoff_ts) {
                            Some((ch_id, s_ts, e_ts)) => {
                                in_programme = true;
                                cur_channel = ch_id;
                                cur_start = s_ts;
                                cur_end = e_ts;
                                cur_title.clear();
                                cur_subtitle = None;
                                cur_desc = None;
                                cur_category = None;
                                cur_subtag = SubTag::None;
                            }
                            None => {
                                // Fast skip unknown channel or expired programme without allocating sub-elements!
                                let end_name = e.to_end().into_owned();
                                skip_buf.clear();
                                xml.read_to_end_into_async(end_name.name(), &mut skip_buf)
                                    .await
                                    .map_err(|err| CndError::Parse {
                                        message: format!("XMLTV skip error: {err}"),
                                    })?;
                            }
                        }
                    }
                } else {
                    let local = qname.as_ref();
                    if local.eq_ignore_ascii_case(b"title") {
                        cur_subtag = SubTag::Title;
                    } else if local.eq_ignore_ascii_case(b"sub-title") {
                        cur_subtag = SubTag::SubTitle;
                    } else if local.eq_ignore_ascii_case(b"desc") {
                        cur_subtag = SubTag::Desc;
                    } else if local.eq_ignore_ascii_case(b"category") {
                        cur_subtag = SubTag::Category;
                    } else {
                        cur_subtag = SubTag::None;
                    }
                }
            }
            Event::Text(ref t) if in_programme && cur_subtag != SubTag::None => {
                let text = t
                    .unescape()
                    .map(|cow| cow.into_owned())
                    .unwrap_or_else(|_| String::from_utf8_lossy(t.as_ref()).into_owned());
                apply_subtag_text(
                    cur_subtag,
                    &text,
                    &mut cur_title,
                    &mut cur_subtitle,
                    &mut cur_desc,
                    &mut cur_category,
                );
            }
            Event::CData(ref c) if in_programme && cur_subtag != SubTag::None => {
                let text = String::from_utf8_lossy(c.as_ref());
                apply_subtag_text(
                    cur_subtag,
                    &text,
                    &mut cur_title,
                    &mut cur_subtitle,
                    &mut cur_desc,
                    &mut cur_category,
                );
            }
            Event::End(ref e) if in_programme => {
                let local = e.name();
                if local.as_ref().eq_ignore_ascii_case(b"programme") {
                    in_programme = false;
                    cur_subtag = SubTag::None;
                    if !cur_title.is_empty() && cur_end > cur_start {
                        batch.push(ParsedEpgProgram {
                            channel_tvg_id: std::mem::take(&mut cur_channel),
                            start_ts: cur_start,
                            end_ts: cur_end,
                            title: std::mem::take(&mut cur_title),
                            subtitle: cur_subtitle.take(),
                            description: cur_desc.take(),
                            category: cur_category.take(),
                        });
                        total_count += 1;

                        if batch.len() >= EPG_BATCH_SIZE {
                            on_batch(&batch)?;
                            batch.clear();
                        }
                    }
                } else {
                    cur_subtag = SubTag::None;
                }
            }
            _ => {}
        }
    }

    if !batch.is_empty() {
        on_batch(&batch)?;
        batch.clear();
    }

    Ok(total_count)
}

fn inspect_programme_attrs(
    e: &BytesStart<'_>,
    known_channels: Option<&HashMap<String, i64>>,
    cutoff_ts: i64,
) -> Option<(String, i64, i64)> {
    let mut raw_start: Option<i64> = None;
    let mut raw_stop: Option<i64> = None;
    let mut channel_id: Option<String> = None;
    let mut shift_secs: i64 = 0;

    for attr_res in e.attributes().with_checks(false) {
        let Ok(attr) = attr_res else { continue };
        let key = attr.key.as_ref();
        if key.eq_ignore_ascii_case(b"channel") {
            let ch_str = String::from_utf8_lossy(attr.value.as_ref());
            let trimmed = ch_str.trim();
            if trimmed.is_empty() {
                return None;
            }
            if let Some(map) = known_channels {
                if !map.is_empty() {
                    let &shift = map.get(trimmed)?;
                    shift_secs = shift;
                }
            }
            channel_id = Some(trimmed.to_string());
        } else if key.eq_ignore_ascii_case(b"start") {
            raw_start = parse_xmltv_timestamp(attr.value.as_ref());
        } else if key.eq_ignore_ascii_case(b"stop") {
            raw_stop = parse_xmltv_timestamp(attr.value.as_ref());
        }
    }

    let ch = channel_id?;
    let start_ts = raw_start? + shift_secs;
    let end_ts = raw_stop.unwrap_or(start_ts + 1_800) + shift_secs;

    if end_ts < cutoff_ts || end_ts <= start_ts {
        return None;
    }

    Some((ch, start_ts, end_ts))
}

fn apply_subtag_text(
    subtag: SubTag,
    text: &str,
    cur_title: &mut String,
    cur_subtitle: &mut Option<String>,
    cur_desc: &mut Option<String>,
    cur_category: &mut Option<String>,
) {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return;
    }
    match subtag {
        SubTag::Title if cur_title.is_empty() => {
            cur_title.push_str(trimmed);
        }
        SubTag::SubTitle if cur_subtitle.is_none() => {
            *cur_subtitle = Some(trimmed.to_string());
        }
        SubTag::Desc if cur_desc.is_none() => {
            *cur_desc = Some(trimmed.to_string());
        }
        SubTag::Category if cur_category.is_none() => {
            *cur_category = Some(trimmed.to_string());
        }
        _ => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use async_compression::tokio::write::GzipEncoder;
    use tokio::io::AsyncWriteExt;

    #[test]
    fn test_xmltv_timestamp_timezones() {
        // 1970-01-01 00:00:00 UTC
        assert_eq!(parse_xmltv_timestamp(b"19700101000000"), Some(0));
        assert_eq!(parse_xmltv_timestamp(b"19700101000000 +0000"), Some(0));

        // +0200 (2 hours ahead of UTC -> 02:00 local == 00:00 UTC)
        assert_eq!(parse_xmltv_timestamp(b"19700101020000 +0200"), Some(0));

        // -0500 (5 hours behind UTC -> 00:00 local == 05:00 UTC == 18000)
        assert_eq!(parse_xmltv_timestamp(b"19700101000000 -0500"), Some(18_000));

        // 2026-11-01 20:50:00 +0100 -> 2026-11-01 19:50:00 UTC
        let ts = parse_xmltv_timestamp(b"20261101205000 +0100").expect("valid 2026 ts");
        let ts_utc = parse_xmltv_timestamp(b"20261101195000").expect("valid 2026 utc");
        assert_eq!(ts, ts_utc);
    }

    #[tokio::test]
    async fn test_gzip_magic_bytes_xmltv_streaming_and_filtering() {
        let xml_raw = r#"<?xml version="1.0" encoding="UTF-8"?>
<tv generator-info-name="CNDTest">
  <programme start="20261101190000 +0000" stop="20261101200000 +0000" channel="tf1.fr">
    <title>Journal de 20h &amp; Météo</title>
    <sub-title>Édition du soir</sub-title>
    <desc>Actualités nationales et internationales.</desc>
    <category>News</category>
  </programme>
  <programme start="20261101190000 +0000" stop="20261101200000 +0000" channel="unknown.ch">
    <title>Should Be Skipped By Known Set</title>
  </programme>
  <programme start="20261101200000 +0000" stop="20261101220000 +0000" channel="tf1.fr">
    <title>Grand Film du Dimanche</title>
    <category>Movie</category>
  </programme>
</tv>"#;

        let mut encoder = GzipEncoder::new(Vec::new());
        encoder
            .write_all(xml_raw.as_bytes())
            .await
            .expect("gzip write");
        encoder.shutdown().await.expect("gzip shutdown");
        let gz_bytes = encoder.into_inner();
        assert_eq!(&gz_bytes[0..2], &[0x1f, 0x8b]);

        let mut known = HashMap::new();
        known.insert("tf1.fr".to_string(), 0i64);

        let now_ts = parse_xmltv_timestamp(b"20261101193000 +0000").unwrap();
        let mut parsed = Vec::new();
        let count = parse_xmltv_auto_gzip(
            BufReader::new(gz_bytes.as_slice()),
            Some(&known),
            now_ts,
            |batch| {
                parsed.extend_from_slice(batch);
                Ok(())
            },
        )
        .await
        .expect("parse gzipped xmltv");

        assert_eq!(count, 2);
        assert_eq!(parsed.len(), 2);
        assert_eq!(parsed[0].channel_tvg_id, "tf1.fr");
        assert_eq!(parsed[0].title, "Journal de 20h & Météo");
        assert_eq!(parsed[0].subtitle.as_deref(), Some("Édition du soir"));
        assert_eq!(parsed[1].title, "Grand Film du Dimanche");
    }
}
