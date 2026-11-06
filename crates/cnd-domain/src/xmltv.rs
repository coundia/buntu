use quick_xml::events::Event;
use quick_xml::Reader;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
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

pub fn parse_xmltv_timestamp(raw: &[u8]) -> Option<i64> {
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
            return ((sign as f64) * hours * 3_600.0).round() as i64;
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

#[inline]
fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let y = year - i64::from(month <= 2);
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let m_adj = if month > 2 { month - 3 } else { month + 9 };
    let doy = (153 * m_adj + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// Parses a string containing XMLTV chunk into a vector of programmes.
pub fn parse_xmltv_chunk(xml_content: &str, cutoff_ts: i64) -> Result<Vec<ParsedEpgProgram>, String> {
    let mut xml = Reader::from_str(xml_content);
    xml.config_mut().trim_text(true);

    let mut programmes = Vec::new();
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
        match xml.read_event() {
            Ok(Event::Eof) => break,
            Ok(Event::Start(ref e)) => {
                let qname = e.name();
                if !in_programme {
                    if qname.as_ref().eq_ignore_ascii_case(b"programme") {
                        let mut channel = None;
                        let mut start = None;
                        let mut stop = None;
                        for attr in e.attributes().flatten() {
                            match attr.key.as_ref() {
                                b"channel" => {
                                    if let Ok(v) = attr.decode_and_unescape_value(xml.decoder()) {
                                        channel = Some(v.into_owned());
                                    }
                                }
                                b"start" => {
                                    start = parse_xmltv_timestamp(&attr.value);
                                }
                                b"stop" => {
                                    stop = parse_xmltv_timestamp(&attr.value);
                                }
                                _ => {}
                            }
                        }
                        if let (Some(ch), Some(s), Some(e)) = (channel, start, stop) {
                            if e >= cutoff_ts && e > s {
                                in_programme = true;
                                cur_channel = ch;
                                cur_start = s;
                                cur_end = e;
                                cur_title.clear();
                                cur_subtitle = None;
                                cur_desc = None;
                                cur_category = None;
                            }
                        }
                    }
                } else {
                    cur_subtag = match qname.as_ref() {
                        b"title" => SubTag::Title,
                        b"sub-title" => SubTag::SubTitle,
                        b"desc" => SubTag::Desc,
                        b"category" => SubTag::Category,
                        _ => SubTag::None,
                    };
                }
            }
            Ok(Event::Text(ref e)) => {
                if in_programme {
                    if let Ok(txt) = e.unescape() {
                        match cur_subtag {
                            SubTag::Title => {
                                if cur_title.is_empty() {
                                    cur_title = txt.trim().to_string();
                                }
                            }
                            SubTag::SubTitle => {
                                if cur_subtitle.is_none() {
                                    cur_subtitle = Some(txt.trim().to_string());
                                }
                            }
                            SubTag::Desc => {
                                if cur_desc.is_none() {
                                    cur_desc = Some(txt.trim().to_string());
                                }
                            }
                            SubTag::Category => {
                                if cur_category.is_none() {
                                    cur_category = Some(txt.trim().to_string());
                                }
                            }
                            SubTag::None => {}
                        }
                    }
                }
            }
            Ok(Event::End(ref e)) => {
                let qname = e.name();
                if in_programme {
                    if qname.as_ref().eq_ignore_ascii_case(b"programme") {
                        if !cur_title.is_empty() && !cur_channel.is_empty() {
                            programmes.push(ParsedEpgProgram {
                                channel_tvg_id: cur_channel.clone(),
                                start_ts: cur_start,
                                end_ts: cur_end,
                                title: cur_title.clone(),
                                subtitle: cur_subtitle.take(),
                                description: cur_desc.take(),
                                category: cur_category.take(),
                            });
                        }
                        in_programme = false;
                        cur_subtag = SubTag::None;
                    } else {
                        cur_subtag = SubTag::None;
                    }
                }
            }
            Err(e) => return Err(format!("XMLTV parse error: {e}")),
            _ => {}
        }
    }

    Ok(programmes)
}

