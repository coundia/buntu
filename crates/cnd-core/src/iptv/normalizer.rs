use regex::Regex;
use std::sync::LazyLock;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ItemKind {
    Live,
    Movie,
    Episode,
}

impl ItemKind {
    pub fn as_str(self) -> &'static str {
        match self {
            ItemKind::Live => "live",
            ItemKind::Movie => "movie",
            ItemKind::Episode => "episode",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SeriesInfo {
    pub series_title: String,
    pub canonical_key: String,
    pub season_num: u32,
    pub episode_num: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NormalizedMedia {
    pub kind: ItemKind,
    pub name_clean: String,
    pub year: Option<u32>,
    pub series: Option<SeriesInfo>,
}

static EP_SE_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)\bS(\d{1,2})[\s._-]*E(\d{1,3})\b").expect("valid SxxExx regex")
});

static EP_X_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)\b(\d{1,2})x(\d{1,3})\b").expect("valid NxM regex"));

static EP_SEASON_WORD_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)\b(?:Season|Saison)\s*(\d{1,2})\D*?(?:Ep|Episode|Épisode|E)\s*(\d{1,3})\b")
        .expect("valid Season Episode regex")
});

static IMDB_ID_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)\b(tt\d{7,9})\b").expect("valid imdb id regex"));

static YEAR_BRACKET_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"[\(\[\{]\s*(19\d{2}|20\d{2})\s*[\)\]\}]").expect("valid bracket year regex")
});

static YEAR_TRAILING_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?:[\s._-]+)(19\d{2}|20\d{2})\s*$").expect("valid trailing year regex")
});

static LEADING_PREFIX_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"^(?:\s*(?:\|[^|]{1,14}\||\[[^\]]{1,14}\]|\((?:[A-Za-z]{2,6}|VF[A-Z0-9]*|VOSTFR|MULTI|4K|FHD|HD|UHD)\)|[A-Za-z]{2,4}\s*[-:|•])\s*)+",
    )
    .expect("valid leading prefix regex")
});

static BRACKET_TAG_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"(?i)[\(\[\{]\s*(?:FR|EN|US|UK|AR|ES|DE|IT|PT|VF|VFF|VFQ|VFI|VF2|VOSTFR|VOST|MULTI|MULTILANG|TRUEFRENCH|FRENCH|SUBFRENCH|FHD|UHD|4K|8K|HD|SD|HEVC|H\.?265|H\.?264|X265|X264|1080P|720P|2160P|HDR|WEB-?DL|BLURAY)\s*[\)\]\}]",
    )
    .expect("valid bracket tag regex")
});

static NOISE_WORDS_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"(?i)\b(?:FHD|UHD|4K|8K|HEVC|H\.?265|H\.?264|X265|X264|1080P|720P|2160P|480P|HDR10\+?|HDR|VOSTFR|TRUEFRENCH|SUBFRENCH|FRENCH|MULTILANG|MULTI|VFF|VFQ|VFI|VF2|VF|WEBDL|WEB-DL|WEBRIP|BLURAY|BDRIP|HDTV|RAW|VIP|HEAAC|AAC|AC3|EAC3)\b",
    )
    .expect("valid noise words regex")
});

pub fn extract_imdb_id(raw: &str) -> Option<String> {
    IMDB_ID_RE
        .captures(raw)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().to_ascii_lowercase())
}

pub fn normalize_imdb_rating(raw: &str) -> Option<f64> {
    let trimmed = raw.trim();
    if trimmed.is_empty() || trimmed.eq_ignore_ascii_case("n/a") || trimmed == "0" {
        return None;
    }

    let replaced = trimmed.replace(',', ".");
    let value = if let Some(pct_str) = replaced.strip_suffix('%') {
        pct_str.trim().parse::<f64>().ok()? / 10.0
    } else if let Some((num_s, den_s)) = replaced.split_once('/') {
        let num = num_s.trim().parse::<f64>().ok()?;
        let den = den_s.trim().parse::<f64>().ok()?;
        if den <= 0.0 {
            return None;
        }
        (num / den) * 10.0
    } else {
        replaced.parse::<f64>().ok()?
    };

    if !value.is_finite() || value <= 0.0 {
        return None;
    }
    Some(value.clamp(0.0, 10.0))
}

pub fn extract_episode_numbers(name: &str) -> Option<(usize, u32, u32)> {
    if let Some(caps) = EP_SE_RE.captures(name) {
        let m = caps.get(0)?;
        let s = caps.get(1)?.as_str().parse::<u32>().ok()?;
        let e = caps.get(2)?.as_str().parse::<u32>().ok()?;
        return Some((m.start(), s, e));
    }
    if let Some(caps) = EP_SEASON_WORD_RE.captures(name) {
        let m = caps.get(0)?;
        let s = caps.get(1)?.as_str().parse::<u32>().ok()?;
        let e = caps.get(2)?.as_str().parse::<u32>().ok()?;
        return Some((m.start(), s, e));
    }
    if let Some(caps) = EP_X_RE.captures(name) {
        let m = caps.get(0)?;
        let s = caps.get(1)?.as_str().parse::<u32>().ok()?;
        let e = caps.get(2)?.as_str().parse::<u32>().ok()?;
        // Avoid matching resolutions like "1920x1080" (already guarded by \d{1,2}x\d{1,3}, also ensure s <= 60)
        if s > 0 && s <= 60 {
            return Some((m.start(), s, e));
        }
    }
    None
}

fn is_series_group(group: Option<&str>) -> bool {
    let Some(g) = group else { return false };
    let folded = fold_diacritics_ascii(g).to_ascii_lowercase();
    folded.contains("series") || folded.contains("serie")
}

fn is_movie_group(group: Option<&str>) -> bool {
    let Some(g) = group else { return false };
    let folded = fold_diacritics_ascii(g).to_ascii_lowercase();
    folded.contains("vod")
        || folded.contains("movie")
        || folded.contains("film")
        || folded.contains("cinema")
}

fn is_vod_extension(container_ext: Option<&str>) -> bool {
    let Some(ext) = container_ext else {
        return false;
    };
    matches!(
        ext.to_ascii_lowercase().as_str(),
        "mkv" | "mp4" | "avi" | "mov" | "m4v" | "wmv" | "divx" | "flv"
    )
}

pub fn clean_title_and_year(raw: &str) -> (String, Option<u32>) {
    let mut working = raw.trim().to_string();
    let mut extracted_year: Option<u32> = None;

    // 1. Extract bracketed year first e.g. "(2023)" or "[2010]" before stripping brackets
    if let Some(caps) = YEAR_BRACKET_RE.captures(&working) {
        if let Some(ym) = caps.get(1) {
            extracted_year = ym.as_str().parse::<u32>().ok();
        }
        working = YEAR_BRACKET_RE.replace_all(&working, " ").into_owned();
    }

    // 2. Strip leading country/provider prefixes like "|FR|", "[FR]", "FR - "
    working = LEADING_PREFIX_RE.replace(&working, "").into_owned();
    working = BRACKET_TAG_RE.replace_all(&working, " ").into_owned();

    // 3. Replace dots/underscores used as word separators when no spaces exist
    if !working.contains(' ') && (working.contains('.') || working.contains('_')) {
        working = working.replace(['.', '_'], " ");
    }

    // 4. Remove quality/language noise words
    working = NOISE_WORDS_RE.replace_all(&working, " ").into_owned();

    // 5. Extract trailing year if not already found
    let trimmed_for_year = working
        .trim_end_matches(['-', '|', ':', '•', ' '])
        .to_string();
    if extracted_year.is_none() {
        if let Some(caps) = YEAR_TRAILING_RE.captures(&trimmed_for_year) {
            if let Some(ym) = caps.get(1) {
                extracted_year = ym.as_str().parse::<u32>().ok();
            }
            working = YEAR_TRAILING_RE
                .replace(&trimmed_for_year, "")
                .into_owned();
        } else {
            working = trimmed_for_year;
        }
    } else {
        working = trimmed_for_year;
    }

    // 6. Collapse whitespace and trim stray punctuation
    let collapsed = collapse_whitespace(
        working.trim_matches(['-', '|', ':', '•', '_', ' ']),
    );

    let final_title = if collapsed.is_empty() {
        collapse_whitespace(raw)
    } else {
        collapsed
    };

    (final_title, extracted_year)
}

pub fn make_canonical_key(title: &str) -> String {
    let folded = fold_diacritics_ascii(title);
    let mut out = String::with_capacity(folded.len());
    let mut last_was_space = true;

    for ch in folded.chars() {
        if ch.is_ascii_alphanumeric() {
            out.push(ch.to_ascii_lowercase());
            last_was_space = false;
        } else if !last_was_space {
            out.push(' ');
            last_was_space = true;
        }
    }

    out.trim().to_string()
}

pub fn classify_and_normalize(
    raw_name: &str,
    group_title: Option<&str>,
    stream_url: &str,
    container_ext: Option<&str>,
) -> NormalizedMedia {
    let url_lower = stream_url.to_ascii_lowercase();
    let ep_match = extract_episode_numbers(raw_name);

    let is_episode = url_lower.contains("/series/")
        || is_series_group(group_title)
        || ep_match.is_some();

    if is_episode {
        let (season_num, episode_num, raw_series_prefix) = match ep_match {
            Some((idx, s, e)) => (s.max(1), e.max(1), &raw_name[..idx]),
            None => (1, 1, raw_name),
        };

        let (mut series_title, year) = clean_title_and_year(raw_series_prefix);
        if series_title.is_empty() {
            let (fallback, _) = clean_title_and_year(raw_name);
            series_title = fallback;
        }

        let mut canonical_key = make_canonical_key(&series_title);
        if canonical_key.is_empty() {
            canonical_key = make_canonical_key(raw_name);
        }

        let (name_clean, _) = clean_title_and_year(raw_name);

        return NormalizedMedia {
            kind: ItemKind::Episode,
            name_clean,
            year,
            series: Some(SeriesInfo {
                series_title,
                canonical_key,
                season_num,
                episode_num,
            }),
        };
    }

    let is_live_stream_hint = url_lower.contains("/live/")
        || matches!(
            container_ext.map(|e| e.to_ascii_lowercase()).as_deref(),
            Some("ts") | Some("m3u8")
        );

    let is_movie = url_lower.contains("/movie/")
        || is_movie_group(group_title)
        || (is_vod_extension(container_ext) && !is_live_stream_hint);

    let (name_clean, year) = clean_title_and_year(raw_name);
    let kind = if is_movie {
        ItemKind::Movie
    } else {
        ItemKind::Live
    };

    NormalizedMedia {
        kind,
        name_clean,
        year,
        series: None,
    }
}

pub fn fold_diacritics_ascii(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    for c in input.chars() {
        match c {
            'à' | 'á' | 'â' | 'ã' | 'ä' | 'å' | 'À' | 'Á' | 'Â' | 'Ã' | 'Ä' | 'Å' => out.push('a'),
            'ç' | 'Ç' => out.push('c'),
            'è' | 'é' | 'ê' | 'ë' | 'È' | 'É' | 'Ê' | 'Ë' => out.push('e'),
            'ì' | 'í' | 'î' | 'ï' | 'Ì' | 'Í' | 'Î' | 'Ï' => out.push('i'),
            'ñ' | 'Ñ' => out.push('n'),
            'ò' | 'ó' | 'ô' | 'õ' | 'ö' | 'ø' | 'Ò' | 'Ó' | 'Ô' | 'Õ' | 'Ö' | 'Ø' => out.push('o'),
            'ù' | 'ú' | 'û' | 'ü' | 'Ù' | 'Ú' | 'Û' | 'Ü' => out.push('u'),
            'ý' | 'ÿ' | 'Ý' | 'Ÿ' => out.push('y'),
            'œ' | 'Œ' => out.push_str("oe"),
            'æ' | 'Æ' => out.push_str("ae"),
            _ => out.push(c),
        }
    }
    out
}

fn collapse_whitespace(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut first = true;
    for word in s.split_whitespace() {
        if !first {
            out.push(' ');
        }
        out.push_str(word);
        first = false;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_classify_live_movie_episode() {
        let live = classify_and_normalize(
            "|FR| Canal+ Sport FHD HEVC",
            Some("FR Sports"),
            "http://srv:8080/live/u/p/123.ts",
            Some("ts"),
        );
        assert_eq!(live.kind, ItemKind::Live);
        assert_eq!(live.name_clean, "Canal+ Sport");

        let movie = classify_and_normalize(
            "|FR| Oppenheimer (2023) MULTi TRUEFRENCH 4K HDR",
            Some("VOD | Films Récents"),
            "http://srv:8080/movie/u/p/999.mkv",
            Some("mkv"),
        );
        assert_eq!(movie.kind, ItemKind::Movie);
        assert_eq!(movie.name_clean, "Oppenheimer");
        assert_eq!(movie.year, Some(2023));

        let ep1 = classify_and_normalize(
            "|FR| Les Anneaux de Pouvoir S01E02 VOSTFR 1080p",
            Some("Séries Fantastiques"),
            "http://srv:8080/series/u/p/501.mkv",
            Some("mkv"),
        );
        let ep2 = classify_and_normalize(
            "[VF] Les Anneaux De Pouvoir - S02E01 FHD",
            Some("Series"),
            "http://srv:8080/series/u/p/502.mkv",
            Some("mkv"),
        );
        assert_eq!(ep1.kind, ItemKind::Episode);
        assert_eq!(ep2.kind, ItemKind::Episode);
        let s1 = ep1.series.expect("series info 1");
        let s2 = ep2.series.expect("series info 2");
        assert_eq!(s1.canonical_key, s2.canonical_key);
        assert_eq!(s1.canonical_key, "les anneaux de pouvoir");
        assert_eq!(s1.season_num, 1);
        assert_eq!(s1.episode_num, 2);
        assert_eq!(s2.season_num, 2);
        assert_eq!(s2.episode_num, 1);
    }

    #[test]
    fn test_normalize_imdb_rating_formats() {
        assert_eq!(normalize_imdb_rating("7,4"), Some(7.4));
        assert_eq!(normalize_imdb_rating("8.2/10"), Some(8.2));
        assert_eq!(normalize_imdb_rating("75%"), Some(7.5));
        assert_eq!(normalize_imdb_rating("4/5"), Some(8.0));
        assert_eq!(normalize_imdb_rating("N/A"), None);
        assert_eq!(normalize_imdb_rating(""), None);
    }
}

