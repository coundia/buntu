use crate::db::{chrono_now_ts, DatabaseManager, DbError};
use crate::http_client::HttpClientPool;
use crate::iptv::xtream::encode_param;
use crate::telemetry::TelemetryHub;
use crate::CndError;
use regex::Regex;
use rusqlite::{params, OptionalExtension};
use serde::Deserialize;
use std::sync::LazyLock;

const METADATA_CACHE_TTL_SECS: i64 = 30 * 86_400;
const DEFAULT_OMDB_BASE_URL: &str = "https://www.omdbapi.com/";

static LEADING_PIPE_TAG_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)^(?:\s*\|[^|]{1,16}\|\s*)+").expect("valid regex"));

static BRACKET_BLOCK_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(\([^\)]*\)|\[[^\]]*\]|\{[^\}]*\})").expect("valid bracket regex")
});

static SEGMENT_SPLIT_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\s*(?:\||·|•|–|—)\s*|\s+-\s+").expect("valid split regex"));

static MULTI_SPACE_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\s{2,}").expect("valid space regex"));

const BLACKLIST_TOKENS: &[&str] = &[
    "FR",
    "VF",
    "VFF",
    "VFQ",
    "VFI",
    "VOSTFR",
    "VOST",
    "TRUEFRENCH",
    "FRENCH",
    "MULTI",
    "MULTILANG",
    "EN",
    "ENG",
    "VO",
    "SUBFRENCH",
    "HD",
    "FHD",
    "UHD",
    "SD",
    "1080P",
    "720P",
    "2160P",
    "480P",
    "4K",
    "8K",
    "HDR",
    "HDR10",
    "DV",
    "DOVI",
    "HEVC",
    "X264",
    "X265",
    "H264",
    "H265",
    "WEBDL",
    "WEB-DL",
    "WEBRIP",
    "BLURAY",
    "BDRIP",
    "BRRIP",
    "DVDRIP",
    "REMUX",
    "AAC",
    "AC3",
    "EAC3",
    "DTS",
    "ATMOS",
    "VIP",
];

#[derive(Debug, Clone, uniffi::Record)]
pub struct MediaMetadata {
    pub imdb_id: Option<String>,
    pub title: String,
    pub year: Option<String>,
    pub rated: Option<String>,
    pub runtime: Option<String>,
    pub genres: Option<String>,
    pub director: Option<String>,
    pub actors: Option<String>,
    pub plot: Option<String>,
    pub poster_url: Option<String>,
    pub imdb_rating: Option<f64>,
    pub imdb_votes: Option<String>,
    pub metascore: Option<String>,
    pub from_cache: bool,
}

#[derive(Debug, Clone)]
struct CachedMetadataRow {
    imdb_id: Option<String>,
    title: String,
    year: Option<String>,
    rated: Option<String>,
    released: Option<String>,
    runtime: Option<String>,
    genres: Option<String>,
    director: Option<String>,
    actors: Option<String>,
    plot: Option<String>,
    language: Option<String>,
    country: Option<String>,
    awards: Option<String>,
    poster_url: Option<String>,
    imdb_rating: Option<f64>,
    imdb_votes: Option<String>,
    metascore: Option<String>,
    media_type: Option<String>,
    fetched_at: i64,
}

impl CachedMetadataRow {
    fn into_public(self, from_cache: bool) -> MediaMetadata {
        MediaMetadata {
            imdb_id: self.imdb_id,
            title: self.title,
            year: self.year,
            rated: self.rated,
            runtime: self.runtime,
            genres: self.genres,
            director: self.director,
            actors: self.actors,
            plot: self.plot,
            poster_url: self.poster_url,
            imdb_rating: self.imdb_rating,
            imdb_votes: self.imdb_votes,
            metascore: self.metascore,
            from_cache,
        }
    }
}

#[derive(Debug, Deserialize)]
struct OmdbApiResponse {
    #[serde(rename = "Response", default)]
    response: String,
    #[serde(rename = "Title", default)]
    title: Option<String>,
    #[serde(rename = "Year", default)]
    year: Option<String>,
    #[serde(rename = "Rated", default)]
    rated: Option<String>,
    #[serde(rename = "Released", default)]
    released: Option<String>,
    #[serde(rename = "Runtime", default)]
    runtime: Option<String>,
    #[serde(rename = "Genre", default)]
    genre: Option<String>,
    #[serde(rename = "Director", default)]
    director: Option<String>,
    #[serde(rename = "Actors", default)]
    actors: Option<String>,
    #[serde(rename = "Plot", default)]
    plot: Option<String>,
    #[serde(rename = "Language", default)]
    language: Option<String>,
    #[serde(rename = "Country", default)]
    country: Option<String>,
    #[serde(rename = "Awards", default)]
    awards: Option<String>,
    #[serde(rename = "Poster", default)]
    poster: Option<String>,
    #[serde(rename = "imdbRating", default)]
    imdb_rating: Option<String>,
    #[serde(rename = "imdbVotes", default)]
    imdb_votes: Option<String>,
    #[serde(rename = "Metascore", default)]
    metascore: Option<String>,
    #[serde(rename = "imdbID", default)]
    imdb_id: Option<String>,
    #[serde(rename = "Type", default)]
    media_type: Option<String>,
}

fn parse_valid_year(token: &str) -> Option<u32> {
    let trimmed = token.trim();
    if trimmed.len() == 4 && trimmed.bytes().all(|b| b.is_ascii_digit()) {
        if let Ok(yr) = trimmed.parse::<u32>() {
            if (1900..=2035).contains(&yr) {
                return Some(yr);
            }
        }
    }
    None
}

fn is_blacklisted_word(word: &str) -> bool {
    let cleaned = word.trim_matches(|c: char| !c.is_ascii_alphanumeric() && c != '-');
    if cleaned.is_empty() {
        return false;
    }
    let upper = cleaned.to_ascii_uppercase();
    BLACKLIST_TOKENS.contains(&upper.as_str())
}

/// Extracts a clean `(title, year)` pair from complex IPTV VOD / Series titles.
pub fn explode_title_year(raw: &str) -> (String, Option<u32>) {
    let mut working = LEADING_PIPE_TAG_RE.replace(raw.trim(), "").to_string();
    let mut bracket_year: Option<u32> = None;

    // 1. Strip bracketed blocks (...), [...], {...} while capturing any valid 4-digit year inside.
    working = BRACKET_BLOCK_RE
        .replace_all(&working, |caps: &regex::Captures<'_>| {
            let full = &caps[0];
            let inner = &full[1..full.len() - 1];
            if let Some(yr) = parse_valid_year(inner) {
                bracket_year = Some(yr);
            }
            " "
        })
        .to_string();

    // 2. Strip leading "<LANG/TAG>:" prefix (e.g., "FR: The Lord of the Rings: The Two Towers")
    // while preserving legitimate colons in movie titles ("2001: A Space Odyssey", "Dune: Part Two").
    if let Some(colon_idx) = working.find(':') {
        let prefix = working[..colon_idx].trim();
        if !prefix.contains(' ') && is_blacklisted_word(prefix) {
            working = working[colon_idx + 1..].trim_start().to_string();
        }
    }

    // 3. Normalize dot-separated scene release names ("Blade.Runner.2049.2017.1080p.WEBDL")
    let dot_count = working.chars().filter(|&c| c == '.').count();
    let space_count = working.chars().filter(|&c| c == ' ').count();
    if dot_count >= 3 && space_count <= 1 {
        working = working.replace('.', " ");
    }

    // 4. Split on major structural separators (|, ·, •, –, —, or spaced hyphen " - ")
    // while keeping in-word hyphens ("Spider-Man") and legitimate subtitles ("Mission: Impossible - Dead Reckoning").
    let mut detected_year = bracket_year;
    let mut kept_segments: Vec<String> = Vec::new();

    for raw_seg in SEGMENT_SPLIT_RE.split(&working) {
        let mut words: Vec<&str> = raw_seg
            .split_whitespace()
            .filter(|w| !is_blacklisted_word(w))
            .collect();

        if words.is_empty() {
            continue;
        }

        // Pure standalone year segment (e.g., "FR - Inception - 2010 - 1080p")
        if words.len() == 1 {
            if let Some(yr) = parse_valid_year(words[0]) {
                if detected_year.is_none() {
                    detected_year = Some(yr);
                }
                continue;
            }
        }

        // Trailing year at the end of a multi-word segment when no bracketed year was present
        if detected_year.is_none() && words.len() >= 2 {
            if let Some(last_word) = words.last() {
                if let Some(yr) = parse_valid_year(last_word) {
                    detected_year = Some(yr);
                    words.pop();
                }
            }
        }

        if !words.is_empty() {
            kept_segments.push(words.join(" "));
        }
    }

    let joined = kept_segments.join(" - ");
    let collapsed = MULTI_SPACE_RE.replace_all(joined.trim(), " ");
    let clean = collapsed
        .trim_matches(|c: char| matches!(c, '-' | '|' | ':' | ',' | ' '))
        .trim()
        .to_string();

    let final_title = if clean.is_empty() {
        raw.trim().to_string()
    } else {
        clean
    };

    (final_title, detected_year)
}

fn clean_omdb_str(opt: Option<String>) -> Option<String> {
    let s = opt?;
    let trimmed = s.trim();
    if trimmed.is_empty() || trimmed.eq_ignore_ascii_case("N/A") {
        None
    } else {
        Some(trimmed.to_string())
    }
}

fn make_title_lookup_key(media_type: &str, title: &str, year: Option<u32>) -> String {
    let norm_title = title.trim().to_lowercase();
    match year {
        Some(y) => format!("{media_type}:{norm_title}:{y}"),
        None => format!("{media_type}:{norm_title}"),
    }
}

impl DatabaseManager {
    fn get_cached_metadata(&self, lookup_key: &str) -> Result<Option<CachedMetadataRow>, DbError> {
        self.with_conn(|conn| {
            let mut stmt = conn.prepare_cached(
                "SELECT imdb_id, title, year, rated, released, runtime, genres, director,
                        actors, plot, language, country, awards, poster_url, imdb_rating,
                        imdb_votes, metascore, media_type, fetched_at
                 FROM media_metadata_cache
                 WHERE lookup_key = ?1",
            )?;
            let row = stmt
                .query_row(params![lookup_key], |r| {
                    Ok(CachedMetadataRow {
                        imdb_id: r.get(0)?,
                        title: r.get(1)?,
                        year: r.get(2)?,
                        rated: r.get(3)?,
                        released: r.get(4)?,
                        runtime: r.get(5)?,
                        genres: r.get(6)?,
                        director: r.get(7)?,
                        actors: r.get(8)?,
                        plot: r.get(9)?,
                        language: r.get(10)?,
                        country: r.get(11)?,
                        awards: r.get(12)?,
                        poster_url: r.get(13)?,
                        imdb_rating: r.get(14)?,
                        imdb_votes: r.get(15)?,
                        metascore: r.get(16)?,
                        media_type: r.get(17)?,
                        fetched_at: r.get(18)?,
                    })
                })
                .optional()?;
            Ok(row)
        })
    }

    fn save_cached_metadata(
        &self,
        keys: &[String],
        row: &CachedMetadataRow,
    ) -> Result<(), DbError> {
        self.with_conn_mut(|conn| {
            let tx = conn.transaction()?;
            {
                let mut stmt = tx.prepare_cached(
                    "INSERT INTO media_metadata_cache (
                        lookup_key, imdb_id, title, year, rated, released, runtime, genres,
                        director, actors, plot, language, country, awards, poster_url,
                        imdb_rating, imdb_votes, metascore, media_type, fetched_at
                     ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20)
                     ON CONFLICT(lookup_key) DO UPDATE SET
                        imdb_id = excluded.imdb_id,
                        title = excluded.title,
                        year = excluded.year,
                        rated = excluded.rated,
                        released = excluded.released,
                        runtime = excluded.runtime,
                        genres = excluded.genres,
                        director = excluded.director,
                        actors = excluded.actors,
                        plot = excluded.plot,
                        language = excluded.language,
                        country = excluded.country,
                        awards = excluded.awards,
                        poster_url = excluded.poster_url,
                        imdb_rating = excluded.imdb_rating,
                        imdb_votes = excluded.imdb_votes,
                        metascore = excluded.metascore,
                        media_type = excluded.media_type,
                        fetched_at = excluded.fetched_at",
                )?;
                for key in keys {
                    if !key.is_empty() {
                        stmt.execute(params![
                            key,
                            row.imdb_id,
                            row.title,
                            row.year,
                            row.rated,
                            row.released,
                            row.runtime,
                            row.genres,
                            row.director,
                            row.actors,
                            row.plot,
                            row.language,
                            row.country,
                            row.awards,
                            row.poster_url,
                            row.imdb_rating,
                            row.imdb_votes,
                            row.metascore,
                            row.media_type,
                            row.fetched_at,
                        ])?;
                    }
                }
            }
            tx.commit()?;
            Ok(())
        })
    }

    fn apply_metadata_to_item(&self, item_id: i64, meta: &CachedMetadataRow) -> Result<(), DbError> {
        let now = chrono_now_ts();
        self.with_conn(|conn| {
            conn.execute(
                "UPDATE iptv_items
                 SET imdb_id = COALESCE(?2, imdb_id),
                     imdb_rating = COALESCE(?3, imdb_rating),
                     plot = COALESCE(?4, plot),
                     logo_url = CASE
                         WHEN (logo_url IS NULL OR TRIM(logo_url) = '') AND ?5 IS NOT NULL THEN ?5
                         ELSE logo_url
                     END,
                     updated_at = ?6
                 WHERE id = ?1",
                params![
                    item_id,
                    meta.imdb_id,
                    meta.imdb_rating,
                    meta.plot,
                    meta.poster_url,
                    now
                ],
            )?;
            Ok(())
        })
    }

    fn apply_metadata_to_series(
        &self,
        series_id: i64,
        meta: &CachedMetadataRow,
    ) -> Result<(), DbError> {
        let now = chrono_now_ts();
        self.with_conn(|conn| {
            conn.execute(
                "UPDATE series_catalog
                 SET imdb_id = COALESCE(?2, imdb_id),
                     imdb_rating = COALESCE(?3, imdb_rating),
                     plot = COALESCE(?4, plot),
                     poster_url = CASE
                         WHEN (poster_url IS NULL OR TRIM(poster_url) = '') AND ?5 IS NOT NULL THEN ?5
                         ELSE poster_url
                     END,
                     updated_at = ?6
                 WHERE id = ?1",
                params![
                    series_id,
                    meta.imdb_id,
                    meta.imdb_rating,
                    meta.plot,
                    meta.poster_url,
                    now
                ],
            )?;
            Ok(())
        })
    }
}

async fn query_omdb_url(
    http_pool: &HttpClientPool,
    url: &str,
) -> Result<Option<CachedMetadataRow>, CndError> {
    let req = http_pool.get(url)?;
    let resp = http_pool.send_logged("METADATA", req).await?;
    if !resp.status().is_success() {
        return Err(CndError::Network {
            message: format!("OMDb HTTP error {}", resp.status().as_u16()),
        });
    }

    let parsed: OmdbApiResponse = resp.json().await.map_err(|e| CndError::Parse {
        message: format!("Invalid OMDb JSON payload: {e}"),
    })?;

    if !parsed.response.eq_ignore_ascii_case("True") {
        return Ok(None);
    }

    let title = clean_omdb_str(parsed.title).unwrap_or_default();
    if title.is_empty() {
        return Ok(None);
    }

    let rating_str = clean_omdb_str(parsed.imdb_rating);
    let imdb_rating = rating_str
        .as_deref()
        .and_then(|s| s.parse::<f64>().ok())
        .filter(|&v| (0.0..=10.0).contains(&v));

    Ok(Some(CachedMetadataRow {
        imdb_id: clean_omdb_str(parsed.imdb_id),
        title,
        year: clean_omdb_str(parsed.year),
        rated: clean_omdb_str(parsed.rated),
        released: clean_omdb_str(parsed.released),
        runtime: clean_omdb_str(parsed.runtime),
        genres: clean_omdb_str(parsed.genre),
        director: clean_omdb_str(parsed.director),
        actors: clean_omdb_str(parsed.actors),
        plot: clean_omdb_str(parsed.plot),
        language: clean_omdb_str(parsed.language),
        country: clean_omdb_str(parsed.country),
        awards: clean_omdb_str(parsed.awards),
        poster_url: clean_omdb_str(parsed.poster),
        imdb_rating,
        imdb_votes: clean_omdb_str(parsed.imdb_votes),
        metascore: clean_omdb_str(parsed.metascore),
        media_type: clean_omdb_str(parsed.media_type),
        fetched_at: chrono_now_ts(),
    }))
}

#[allow(clippy::too_many_arguments)]
async fn resolve_omdb_cascade(
    db: &DatabaseManager,
    http_pool: &HttpClientPool,
    telemetry: &TelemetryHub,
    base_url: &str,
    media_type: &str,
    raw_title: &str,
    known_year: Option<u32>,
    known_imdb_id: Option<&str>,
    api_key: &str,
    force_refresh: bool,
) -> Result<Option<(CachedMetadataRow, bool)>, CndError> {
    let trimmed_key = api_key.trim();
    if trimmed_key.is_empty() {
        return Ok(None);
    }

    let (clean_title, parsed_year) = explode_title_year(raw_title);
    let effective_year = parsed_year.or(known_year);
    let title_key = make_title_lookup_key(media_type, &clean_title, effective_year);
    let fallback_title_key = make_title_lookup_key(media_type, &clean_title, None);
    let imdb_key = known_imdb_id
        .map(str::trim)
        .filter(|id| id.starts_with("tt"))
        .map(|id| format!("imdb:{id}"));

    let now = chrono_now_ts();
    if !force_refresh {
        let mut candidate_keys = Vec::with_capacity(3);
        if let Some(ref ik) = imdb_key {
            candidate_keys.push(ik.as_str());
        }
        candidate_keys.push(title_key.as_str());
        if fallback_title_key != title_key {
            candidate_keys.push(fallback_title_key.as_str());
        }

        for ck in candidate_keys {
            if let Some(cached) = db.get_cached_metadata(ck)? {
                if now - cached.fetched_at <= METADATA_CACHE_TTL_SECS {
                    return Ok(Some((cached, true)));
                }
            }
        }
    }

    let base = base_url.trim_end_matches('/');
    let enc_key = encode_param(trimmed_key);
    let mut fetched: Option<CachedMetadataRow> = None;

    // Step 1: Lookup by exact IMDb ID if already known
    if let Some(imdb_id) = known_imdb_id.map(str::trim).filter(|s| s.starts_with("tt")) {
        let url = format!(
            "{base}/?i={}&plot=full&r=json&apikey={enc_key}",
            encode_param(imdb_id)
        );
        fetched = query_omdb_url(http_pool, &url).await?;
    }

    // Step 2: Lookup by clean title + year + media_type
    if fetched.is_none() && !clean_title.is_empty() {
        if let Some(yr) = effective_year {
            let url = format!(
                "{base}/?t={}&y={yr}&type={media_type}&plot=full&r=json&apikey={enc_key}",
                encode_param(&clean_title)
            );
            fetched = query_omdb_url(http_pool, &url).await?;
        }
    }

    // Step 3: Fallback lookup by clean title without year (handles 1-year IPTV VOD drift)
    if fetched.is_none() && !clean_title.is_empty() {
        let url = format!(
            "{base}/?t={}&type={media_type}&plot=full&r=json&apikey={enc_key}",
            encode_param(&clean_title)
        );
        fetched = query_omdb_url(http_pool, &url).await?;
    }

    if let Some(row) = fetched {
        let mut keys_to_save = vec![title_key];
        if fallback_title_key != keys_to_save[0] {
            keys_to_save.push(fallback_title_key);
        }
        if let Some(ref id) = row.imdb_id {
            keys_to_save.push(format!("imdb:{id}"));
        } else if let Some(ik) = imdb_key {
            keys_to_save.push(ik);
        }

        db.save_cached_metadata(&keys_to_save, &row)?;
        telemetry.info(
            "METADATA",
            format!(
                "Enriched {media_type} '{}' -> '{}' (IMDb: {:?}, rating: {:?})",
                raw_title, row.title, row.imdb_id, row.imdb_rating
            ),
        );
        return Ok(Some((row, false)));
    }

    Ok(None)
}

pub async fn fetch_item_metadata_with_base(
    db: &DatabaseManager,
    http_pool: &HttpClientPool,
    telemetry: &TelemetryHub,
    base_url: &str,
    item_id: i64,
    api_key: &str,
    force_refresh: bool,
) -> Result<Option<MediaMetadata>, CndError> {
    if api_key.trim().is_empty() {
        return Ok(None);
    }

    let Some(item) = db.get_item_by_id(item_id)? else {
        return Ok(None);
    };

    let media_type = if item.kind == "episode" {
        "series"
    } else {
        "movie"
    };

    let res = resolve_omdb_cascade(
        db,
        http_pool,
        telemetry,
        base_url,
        media_type,
        &item.name,
        item.year,
        item.imdb_id.as_deref(),
        api_key,
        force_refresh,
    )
    .await?;

    if let Some((cached_row, from_cache)) = res {
        db.apply_metadata_to_item(item_id, &cached_row)?;
        return Ok(Some(cached_row.into_public(from_cache)));
    }

    Ok(None)
}

pub async fn fetch_series_metadata_with_base(
    db: &DatabaseManager,
    http_pool: &HttpClientPool,
    telemetry: &TelemetryHub,
    base_url: &str,
    series_id: i64,
    api_key: &str,
    force_refresh: bool,
) -> Result<Option<MediaMetadata>, CndError> {
    if api_key.trim().is_empty() {
        return Ok(None);
    }

    let Some(series) = db.get_series_by_id(series_id)? else {
        return Ok(None);
    };

    let res = resolve_omdb_cascade(
        db,
        http_pool,
        telemetry,
        base_url,
        "series",
        &series.title,
        None,
        series.imdb_id.as_deref(),
        api_key,
        force_refresh,
    )
    .await?;

    if let Some((cached_row, from_cache)) = res {
        db.apply_metadata_to_series(series_id, &cached_row)?;
        return Ok(Some(cached_row.into_public(from_cache)));
    }

    Ok(None)
}

pub async fn fetch_item_metadata(
    db: &DatabaseManager,
    http_pool: &HttpClientPool,
    telemetry: &TelemetryHub,
    item_id: i64,
    api_key: &str,
    force_refresh: bool,
) -> Result<Option<MediaMetadata>, CndError> {
    fetch_item_metadata_with_base(
        db,
        http_pool,
        telemetry,
        DEFAULT_OMDB_BASE_URL,
        item_id,
        api_key,
        force_refresh,
    )
    .await
}

pub async fn fetch_series_metadata(
    db: &DatabaseManager,
    http_pool: &HttpClientPool,
    telemetry: &TelemetryHub,
    series_id: i64,
    api_key: &str,
    force_refresh: bool,
) -> Result<Option<MediaMetadata>, CndError> {
    fetch_series_metadata_with_base(
        db,
        http_pool,
        telemetry,
        DEFAULT_OMDB_BASE_URL,
        series_id,
        api_key,
        force_refresh,
    )
    .await
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::CndEngine;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;

    #[test]
    fn test_explode_title_year_on_12_complex_iptv_formats() {
        let cases: &[(&str, &str, Option<u32>)] = &[
            (
                "|FR| Oppenheimer (2023) MULTi TRUEFRENCH 4K HDR",
                "Oppenheimer",
                Some(2023),
            ),
            (
                "FR - Inception - 2010 - 1080p",
                "Inception",
                Some(2010),
            ),
            (
                "The Dark Knight [2008] VOSTFR",
                "The Dark Knight",
                Some(2008),
            ),
            (
                "[VF] Dune: Part Two (2024) {UHD} HEVC X265",
                "Dune: Part Two",
                Some(2024),
            ),
            (
                "EN | Spider-Man: No Way Home | 2021 | FHD | WEB-DL",
                "Spider-Man: No Way Home",
                Some(2021),
            ),
            (
                "FR: The Lord of the Rings: The Two Towers (2002) BLURAY",
                "The Lord of the Rings: The Two Towers",
                Some(2002),
            ),
            (
                "MULTI • Interstellar • 2014 • 2160p HDR",
                "Interstellar",
                Some(2014),
            ),
            (
                "VFQ - Mission: Impossible - Dead Reckoning (2023) BDRIP",
                "Mission: Impossible - Dead Reckoning",
                Some(2023),
            ),
            (
                "|VOSTFR| Severance (2022) MULTILANG",
                "Severance",
                Some(2022),
            ),
            (
                "Monsters, Inc. {2001} [FRENCH] 720p x264",
                "Monsters, Inc.",
                Some(2001),
            ),
            (
                "2001: A Space Odyssey (1968) FHD",
                "2001: A Space Odyssey",
                Some(1968),
            ),
            (
                "Blade.Runner.2049.2017.1080p.WEBDL.x264",
                "Blade Runner 2049",
                Some(2017),
            ),
        ];

        for (raw, expected_title, expected_year) in cases {
            let (title, year) = explode_title_year(raw);
            assert_eq!(title, *expected_title, "Failed title on input: {raw}");
            assert_eq!(year, *expected_year, "Failed year on input: {raw}");
        }
    }

    #[tokio::test]
    async fn test_omdb_cascade_sqlite_cache_and_catalog_rating_update() {
        let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
        let addr = listener.local_addr().expect("addr");
        let http_hits = Arc::new(AtomicUsize::new(0));
        let hits_clone = Arc::clone(&http_hits);

        // Mock OMDb server:
        // Request 1 (with wrong IPTV year y=2011) -> {"Response":"False","Error":"Movie not found!"}
        // Request 2 (fallback without y) -> {"Response":"True","Title":"Inception","Year":"2010","imdbRating":"8.8",...}
        let srv = tokio::spawn(async move {
            for _ in 0..2 {
                let (mut sock, _) = listener.accept().await.expect("accept");
                hits_clone.fetch_add(1, Ordering::SeqCst);
                let mut buf = vec![0u8; 2048];
                let n = sock.read(&mut buf).await.expect("read");
                let req_str = String::from_utf8_lossy(&buf[..n]);

                let body = if req_str.contains("y=2011") {
                    r#"{"Response":"False","Error":"Movie not found!"}"#
                } else {
                    r#"{
                        "Response": "True",
                        "Title": "Inception",
                        "Year": "2010",
                        "Rated": "PG-13",
                        "Runtime": "148 min",
                        "Genre": "Action, Adventure, Sci-Fi",
                        "Director": "Christopher Nolan",
                        "Actors": "Leonardo DiCaprio, Joseph Gordon-Levitt",
                        "Plot": "A thief who steals corporate secrets through dream-sharing technology.",
                        "Poster": "https://img.omdb.test/inception.jpg",
                        "imdbRating": "8.8",
                        "imdbVotes": "2,500,000",
                        "Metascore": "74",
                        "imdbID": "tt1375666",
                        "Type": "movie"
                    }"#
                };

                let resp = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    body.len(),
                    body
                );
                sock.write_all(resp.as_bytes()).await.expect("write");
            }
        });

        let engine = CndEngine::in_memory().expect("engine");
        let src_id = engine
            .add_source("VOD Test".into(), "m3u".into(), None, None, None, None)
            .expect("source");

        let item_id: i64 = engine
            .db
            .with_conn(|conn| {
                conn.execute(
                    "INSERT INTO iptv_items (source_id, stable_hash, kind, name, name_clean, year, host, stream_url, created_at, updated_at)
                     VALUES (?1, 'vod_inc', 'movie', '|FR| Inception (2011) TRUEFRENCH 1080p', 'Inception', 2011, 'vod.test', 'http://vod.test/inc.mkv', 1, 1)",
                    params![src_id],
                )?;
                Ok(conn.last_insert_rowid())
            })
            .expect("insert movie");

        // Empty API key returns Ok(None) immediately with zero HTTP calls
        let none_res = fetch_item_metadata_with_base(
            &engine.db,
            engine.http_pool(),
            engine.telemetry(),
            &format!("http://{addr}"),
            item_id,
            "   ",
            false,
        )
        .await
        .expect("empty key");
        assert!(none_res.is_none());
        assert_eq!(http_hits.load(Ordering::SeqCst), 0);

        // Cold call: cascades from y=2011 (miss) -> without y (hit)
        let meta1 = fetch_item_metadata_with_base(
            &engine.db,
            engine.http_pool(),
            engine.telemetry(),
            &format!("http://{addr}"),
            item_id,
            "superSecretOmdbKey999",
            false,
        )
        .await
        .expect("fetch 1")
        .expect("meta present");

        assert!(!meta1.from_cache);
        assert_eq!(meta1.title, "Inception");
        assert_eq!(meta1.imdb_id.as_deref(), Some("tt1375666"));
        assert_eq!(meta1.imdb_rating, Some(8.8));
        assert_eq!(meta1.director.as_deref(), Some("Christopher Nolan"));
        assert_eq!(http_hits.load(Ordering::SeqCst), 2);

        // Verify iptv_items table was enriched (imdb_rating, imdb_id, plot, logo_url)
        let updated_item = engine
            .get_item_by_id(item_id)
            .expect("get item")
            .expect("exists");
        assert_eq!(updated_item.imdb_rating, Some(8.8));
        assert_eq!(updated_item.imdb_id.as_deref(), Some("tt1375666"));
        assert_eq!(
            updated_item.logo_url.as_deref(),
            Some("https://img.omdb.test/inception.jpg")
        );

        // Second call MUST return from SQLite cache (< 1 ms, zero additional HTTP requests!)
        let meta2 = fetch_item_metadata_with_base(
            &engine.db,
            engine.http_pool(),
            engine.telemetry(),
            &format!("http://{addr}"),
            item_id,
            "superSecretOmdbKey999",
            false,
        )
        .await
        .expect("fetch 2")
        .expect("meta cached");
        assert!(meta2.from_cache);
        assert_eq!(meta2.imdb_rating, Some(8.8));
        assert_eq!(http_hits.load(Ordering::SeqCst), 2);

        // Verify apikey=... is masked in TelemetryHub!
        let logs = engine.get_logs_since(0, 100);
        for entry in &logs {
            if let Some(ref u) = entry.url_redacted {
                assert!(
                    !u.contains("superSecretOmdbKey999"),
                    "Leaked OMDb API key in URL: {u}"
                );
            }
            assert!(
                !entry.message.contains("superSecretOmdbKey999"),
                "Leaked OMDb API key in message: {}",
                entry.message
            );
        }

        srv.await.expect("join mock omdb");
    }
}

