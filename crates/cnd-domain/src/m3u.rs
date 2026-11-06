use crate::normalizer::{
    classify_and_normalize, extract_imdb_id, normalize_imdb_rating, ItemKind, SeriesInfo,
};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

pub const M3U_BATCH_SIZE: usize = 2_500;

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct M3uHeaderInfo {
    pub epg_url: Option<String>,
    pub catchup_type: Option<String>,
    pub catchup_source: Option<String>,
    pub provider_name: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ParsedM3uItem {
    pub stable_hash: String,
    pub kind: ItemKind,
    pub series_info: Option<SeriesInfo>,
    pub name: String,
    pub name_clean: String,
    pub year: Option<u32>,
    pub group_title: Option<String>,
    pub tvg_id: Option<String>,
    pub tvg_name: Option<String>,
    pub logo_url: Option<String>,
    pub chno: Option<u32>,
    pub country: Option<String>,
    pub language: Option<String>,
    pub catchup_type: Option<String>,
    pub catchup_source: Option<String>,
    pub catchup_days: Option<u32>,
    pub epg_shift: Option<String>,
    pub user_agent: Option<String>,
    pub referer: Option<String>,
    pub headers_json: Option<String>,
    pub host: String,
    pub container_ext: Option<String>,
    pub stream_url: String,
    pub imdb_id: Option<String>,
    pub imdb_rating: Option<f64>,
    pub plot: Option<String>,
}

#[derive(Default)]
pub struct EntryAccumulator {
    pub has_extinf: bool,
    pub raw_name: String,
    pub group_title: Option<String>,
    pub tvg_id: Option<String>,
    pub tvg_name: Option<String>,
    pub logo_url: Option<String>,
    pub chno: Option<u32>,
    pub country: Option<String>,
    pub language: Option<String>,
    pub catchup_type: Option<String>,
    pub catchup_source: Option<String>,
    pub catchup_days: Option<u32>,
    pub epg_shift: Option<String>,
    pub user_agent: Option<String>,
    pub referer: Option<String>,
    pub extra_headers: BTreeMap<String, String>,
    pub imdb_id: Option<String>,
    pub imdb_rating: Option<f64>,
    pub plot: Option<String>,
}

impl EntryAccumulator {
    pub fn reset(&mut self) {
        self.has_extinf = false;
        self.raw_name.clear();
        self.group_title = None;
        self.tvg_id = None;
        self.tvg_name = None;
        self.logo_url = None;
        self.chno = None;
        self.country = None;
        self.language = None;
        self.catchup_type = None;
        self.catchup_source = None;
        self.catchup_days = None;
        self.epg_shift = None;
        self.user_agent = None;
        self.referer = None;
        self.extra_headers.clear();
        self.imdb_id = None;
        self.imdb_rating = None;
        self.plot = None;
    }
}

pub fn strip_prefix_ignore_case<'a>(line: &'a str, prefix: &str) -> Option<&'a str> {
    if line.len() >= prefix.len() && line[..prefix.len()].eq_ignore_ascii_case(prefix) {
        Some(&line[prefix.len()..])
    } else {
        None
    }
}

pub fn parse_extm3u_header(rest: &str, header: &mut M3uHeaderInfo) {
    scan_attributes(rest, |key, val| {
        if val.is_empty() {
            return;
        }
        match key.as_str() {
            "x-tvg-url" | "url-tvg" | "tvg-url" => {
                header.epg_url = Some(val.to_string());
            }
            "catchup" | "catchup-type" => {
                header.catchup_type = Some(val.to_string());
            }
            "catchup-source" => {
                header.catchup_source = Some(val.to_string());
            }
            "provider-name" | "pltv-name" => {
                header.provider_name = Some(val.to_string());
            }
            _ => {}
        }
    });
}

pub fn parse_extinf_line(rest: &str, _header: &M3uHeaderInfo, acc: &mut EntryAccumulator) {
    acc.has_extinf = true;

    let (attrs_part, title_part) = split_extinf_attrs_and_title(rest);
    acc.raw_name = title_part.trim().to_string();

    scan_attributes(attrs_part, |key, val| {
        let trimmed = val.trim();
        if trimmed.is_empty() {
            return;
        }
        match key.as_str() {
            "tvg-id" => acc.tvg_id = Some(trimmed.to_string()),
            "tvg-name" => acc.tvg_name = Some(trimmed.to_string()),
            "tvg-logo" | "logo" => acc.logo_url = Some(trimmed.to_string()),
            "group-title" | "pltv-subgroup" => acc.group_title = Some(trimmed.to_string()),
            "tvg-country" | "country" => acc.country = Some(trimmed.to_string()),
            "tvg-language" | "language" => acc.language = Some(trimmed.to_string()),
            "tvg-chno" | "channel-id" | "tvg-num" => {
                acc.chno = trimmed.parse::<u32>().ok();
            }
            "catchup" | "catchup-type" => acc.catchup_type = Some(trimmed.to_string()),
            "catchup-source" => acc.catchup_source = Some(trimmed.to_string()),
            "catchup-days" | "timeshift" | "tvg-rec" => {
                acc.catchup_days = trimmed.parse::<u32>().ok();
            }
            "epg-shift" | "tvg-shift" => acc.epg_shift = Some(trimmed.to_string()),
            "imdb-id" | "tvg-imdb" => {
                acc.imdb_id = extract_imdb_id(trimmed).or_else(|| Some(trimmed.to_string()));
            }
            "imdb-rating" | "rating" => {
                acc.imdb_rating = normalize_imdb_rating(trimmed);
            }
            "plot" | "tvg-description" | "description" => {
                acc.plot = Some(trimmed.to_string());
            }
            "user-agent" | "http-user-agent" => {
                acc.user_agent = Some(trimmed.to_string());
            }
            "referer" | "referrer" | "http-referer" | "http-referrer" => {
                acc.referer = Some(trimmed.to_string());
            }
            _ => {}
        }
    });
}

pub fn split_extinf_attrs_and_title(rest: &str) -> (&str, &str) {
    let bytes = rest.as_bytes();
    let mut in_quotes = false;
    let mut quote_char = b'"';
    let mut unquoted_commas: Vec<usize> = Vec::with_capacity(2);

    let mut i = 0;
    while i < bytes.len() {
        let b = bytes[i];
        if in_quotes {
            if b == b'\\' && i + 1 < bytes.len() {
                i += 2;
                continue;
            }
            if b == quote_char {
                in_quotes = false;
            }
        } else if b == b'"' || b == b'\'' {
            in_quotes = true;
            quote_char = b;
        } else if b == b',' {
            unquoted_commas.push(i);
        }
        i += 1;
    }

    if unquoted_commas.is_empty() {
        return (rest, "");
    }

    let first = unquoted_commas[0];
    if unquoted_commas.len() >= 2 {
        let after_first = rest[first + 1..unquoted_commas[1]].trim_start();
        if looks_like_attribute_start(after_first) {
            let second = unquoted_commas[1];
            return (&rest[..second], &rest[second + 1..]);
        }
    }

    (&rest[..first], &rest[first + 1..])
}

fn looks_like_attribute_start(s: &str) -> bool {
    let lower = s.to_ascii_lowercase();
    lower.starts_with("tvg-")
        || lower.starts_with("group-title=")
        || lower.starts_with("logo=")
        || lower.starts_with("catchup")
        || lower.starts_with("imdb-")
}

pub fn scan_attributes<F>(input: &str, mut on_attr: F)
where
    F: FnMut(String, &str),
{
    let bytes = input.as_bytes();
    let len = bytes.len();
    let mut i = 0;

    while i < len {
        while i < len && (bytes[i].is_ascii_whitespace() || bytes[i] == b',') {
            i += 1;
        }
        if i >= len {
            break;
        }

        let key_start = i;
        while i < len
            && !bytes[i].is_ascii_whitespace()
            && bytes[i] != b'='
            && bytes[i] != b'"'
            && bytes[i] != b'\''
        {
            i += 1;
        }
        let key_end = i;

        while i < len && bytes[i].is_ascii_whitespace() {
            i += 1;
        }

        if key_start == key_end {
            i += 1;
            continue;
        }

        if i >= len || bytes[i] != b'=' {
            continue;
        }

        let key = input[key_start..key_end].to_ascii_lowercase();
        i += 1;

        while i < len && bytes[i].is_ascii_whitespace() {
            i += 1;
        }
        if i >= len {
            break;
        }

        if bytes[i] == b'"' || bytes[i] == b'\'' {
            let q = bytes[i];
            i += 1;
            let val_start = i;
            while i < len && bytes[i] != q {
                i += 1;
            }
            let val_end = i;
            if i < len && bytes[i] == q {
                i += 1;
            }
            on_attr(key, &input[val_start..val_end]);
        } else {
            let val_start = i;
            while i < len && !bytes[i].is_ascii_whitespace() && bytes[i] != b',' {
                i += 1;
            }
            let val_end = i;
            on_attr(key, &input[val_start..val_end]);
        }
    }
}

pub fn parse_vlcopt_line(rest: &str, acc: &mut EntryAccumulator) {
    let Some((raw_k, raw_v)) = rest.trim().split_once('=') else {
        return;
    };
    let key = raw_k.trim().to_ascii_lowercase();
    let val = raw_v.trim().trim_matches('"');
    if val.is_empty() {
        return;
    }

    match key.as_str() {
        "http-user-agent" | "user-agent" => {
            acc.user_agent = Some(val.to_string());
        }
        "http-referrer" | "http-referer" | "referer" | "referrer" => {
            acc.referer = Some(val.to_string());
        }
        _ => {
            acc.extra_headers.insert(raw_k.trim().to_string(), val.to_string());
        }
    }
}

pub fn parse_kodiprop_line(rest: &str, acc: &mut EntryAccumulator) {
    let Some((raw_k, raw_v)) = rest.trim().split_once('=') else {
        return;
    };
    let key = raw_k.trim().to_ascii_lowercase();
    let val = raw_v.trim();
    if val.is_empty() {
        return;
    }

    match key.as_str() {
        "inputstream.adaptive.stream_headers" | "http-headers" => {
            parse_amp_headers(val, acc);
        }
        "imdb" | "imdb-id" | "imdbnumber" => {
            acc.imdb_id = extract_imdb_id(val).or_else(|| Some(val.to_string()));
        }
        "rating" | "imdb-rating" => {
            acc.imdb_rating = normalize_imdb_rating(val);
        }
        "plot" | "description" => {
            acc.plot = Some(val.to_string());
        }
        _ => {
            acc.extra_headers
                .insert(format!("kodi:{}", raw_k.trim()), val.to_string());
        }
    }
}

pub fn parse_amp_headers(raw: &str, acc: &mut EntryAccumulator) {
    for pair in raw.split('&') {
        if let Some((hk, hv)) = pair.split_once('=') {
            let k_trim = hk.trim();
            let v_trim = hv.trim();
            if k_trim.is_empty() || v_trim.is_empty() {
                continue;
            }
            match k_trim.to_ascii_lowercase().as_str() {
                "user-agent" => acc.user_agent = Some(v_trim.to_string()),
                "referer" | "referrer" => acc.referer = Some(v_trim.to_string()),
                _ => {
                    acc.extra_headers
                        .insert(k_trim.to_string(), v_trim.to_string());
                }
            }
        }
    }
}

pub fn split_url_pipe_headers(line: &str) -> (&str, Option<&str>) {
    if let Some((url_part, headers_part)) = line.split_once('|') {
        (url_part.trim(), Some(headers_part.trim()))
    } else {
        (line.trim(), None)
    }
}

pub fn extract_url_host_and_ext(stream_url: &str) -> (String, Option<String>) {
    if let Ok(parsed) = url::Url::parse(stream_url) {
        let host = parsed.host_str().unwrap_or("local").to_ascii_lowercase();
        let ext = parsed
            .path_segments()
            .and_then(|mut s| s.next_back())
            .and_then(extract_clean_ext);
        (host, ext)
    } else {
        let ext = stream_url
            .rsplit('/')
            .next()
            .and_then(|seg| seg.split('?').next())
            .and_then(extract_clean_ext);
        ("local".to_string(), ext)
    }
}

fn extract_clean_ext(segment: &str) -> Option<String> {
    let (_, ext) = segment.rsplit_once('.')?;
    let lower = ext.trim().to_ascii_lowercase();
    if lower.len() >= 2 && lower.len() <= 5 && lower.chars().all(|c| c.is_ascii_alphanumeric()) {
        Some(lower)
    } else {
        None
    }
}

pub fn fallback_name_from_url(stream_url: &str) -> String {
    stream_url
        .split('?')
        .next()
        .unwrap_or(stream_url)
        .rsplit('/')
        .next()
        .filter(|s| !s.is_empty())
        .unwrap_or("Unnamed Stream")
        .to_string()
}

/// Parses an M3U text chunk or playlist completely without I/O.
pub fn parse_m3u_chunk(content: &str, source_uuid: &str) -> (M3uHeaderInfo, Vec<ParsedM3uItem>) {
    let mut header = M3uHeaderInfo::default();
    let mut acc = EntryAccumulator::default();
    let mut items = Vec::new();
    let mut is_first_line = true;

    for raw_line in content.lines() {
        let mut line = raw_line.trim_end_matches(['\r', '\n']).trim();
        if is_first_line {
            line = line.trim_start_matches('\u{feff}');
            is_first_line = false;
        }

        if line.is_empty() {
            continue;
        }

        if let Some(rest) = strip_prefix_ignore_case(line, "#EXTM3U") {
            parse_extm3u_header(rest, &mut header);
            continue;
        }

        if let Some(rest) = strip_prefix_ignore_case(line, "#EXTINF:") {
            parse_extinf_line(rest, &header, &mut acc);
            continue;
        }

        if let Some(rest) = strip_prefix_ignore_case(line, "#EXTGRP:") {
            let grp = rest.trim();
            if !grp.is_empty() {
                acc.group_title = Some(grp.to_string());
            }
            continue;
        }

        if let Some(rest) = strip_prefix_ignore_case(line, "#EXTVLCOPT:") {
            parse_vlcopt_line(rest, &mut acc);
            continue;
        }

        if let Some(rest) = strip_prefix_ignore_case(line, "#KODIPROP:") {
            parse_kodiprop_line(rest, &mut acc);
            continue;
        }

        if line.starts_with('#') {
            continue;
        }

        let (clean_url, pipe_headers) = split_url_pipe_headers(line);
        if clean_url.is_empty() {
            acc.reset();
            continue;
        }
        if let Some(h_str) = pipe_headers {
            parse_amp_headers(h_str, &mut acc);
        }

        let (host, container_ext) = extract_url_host_and_ext(clean_url);
        let display_name = if !acc.raw_name.is_empty() {
            acc.raw_name.clone()
        } else {
            fallback_name_from_url(clean_url)
        };

        let normalized = classify_and_normalize(
            &display_name,
            acc.group_title.as_deref(),
            clean_url,
            container_ext.as_deref(),
        );

        let stable_hash = blake3::hash(format!("{source_uuid}:{clean_url}").as_bytes())
            .to_hex()
            .to_string();

        let imdb_id = acc.imdb_id.take().or_else(|| extract_imdb_id(&display_name));
        let headers_json = if acc.extra_headers.is_empty() {
            None
        } else {
            serde_json::to_string(&acc.extra_headers).ok()
        };

        let catchup_type = acc
            .catchup_type
            .take()
            .or_else(|| header.catchup_type.clone());
        let catchup_source = acc
            .catchup_source
            .take()
            .or_else(|| header.catchup_source.clone());

        items.push(ParsedM3uItem {
            stable_hash,
            kind: normalized.kind,
            series_info: normalized.series,
            name: display_name,
            name_clean: normalized.name_clean,
            year: normalized.year,
            group_title: acc.group_title.take(),
            tvg_id: acc.tvg_id.take(),
            tvg_name: acc.tvg_name.take(),
            logo_url: acc.logo_url.take(),
            chno: acc.chno.take(),
            country: acc.country.take(),
            language: acc.language.take(),
            catchup_type,
            catchup_source,
            catchup_days: acc.catchup_days.take(),
            epg_shift: acc.epg_shift.take(),
            user_agent: acc.user_agent.take(),
            referer: acc.referer.take(),
            headers_json,
            host,
            container_ext,
            stream_url: clean_url.to_string(),
            imdb_id,
            imdb_rating: acc.imdb_rating.take(),
            plot: acc.plot.take(),
        });

        acc.reset();
    }

    (header, items)
}

