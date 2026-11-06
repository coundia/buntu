//! The taste of a profile, one per kind (PRD 34 § 4): films, series and TV never share a weight.
//!
//! A taste is a bag of weighted features ("genre:thriller", "director:christopher nolan",
//! "group:kr | series", "channel:france 2", "slot:we-20"). It is computed on demand from the watch
//! history, the favorites and the "less like this" feedback; nothing here leaves the device.

use crate::db::catalog_repo::SeriesRecord;
use crate::db::recommend_repo::CachedItemMetadata;
use crate::db::IptvItemRecord;
use std::collections::HashMap;

/// Half-life of a watch: a film seen a month ago counts half as much as one seen today.
const HALF_LIFE_DAYS: f64 = 30.0;
/// Under two minutes of playback nothing is counted (zapping).
const ZAPPING_MS: i64 = 120_000;

/// How much a feature family says about the profile's taste.
fn family_factor(feature: &str) -> f64 {
    match feature.split(':').next().unwrap_or("") {
        "genre" => 1.0,
        "director" => 0.8,
        "category" => 0.9,
        "channel" => 0.9,
        "group" => 0.6,
        "actor" => 0.5,
        "slot" => 0.5,
        "lang" => 0.3,
        "decade" => 0.3,
        _ => 0.2,
    }
}

#[derive(Debug, Clone, Default)]
pub struct Taste {
    weights: HashMap<String, f64>,
    /// Number of watches that contributed (a profile with 0 has no taste yet).
    pub samples: u32,
}

impl Taste {
    /// Adds one watched content (or favorite) with its weight.
    pub fn add(&mut self, features: &[String], weight: f64) {
        if weight == 0.0 || features.is_empty() {
            return;
        }
        self.samples += 1;
        for f in features {
            *self.weights.entry(f.clone()).or_insert(0.0) += weight;
        }
    }

    /// Scales the weights to `[.., 1]`, then adds the signed feedback ("Moins de ce genre": each
    /// click is worth a whole top feature, so it is seen at once).
    pub fn finish(mut self, feedback: &HashMap<String, f64>) -> Self {
        let max = self.weights.values().cloned().fold(0.0_f64, f64::max);
        if max > 0.0 {
            for v in self.weights.values_mut() {
                *v /= max;
            }
        }
        for (feature, delta) in feedback {
            *self.weights.entry(feature.clone()).or_insert(0.0) += delta;
        }
        self
    }

    pub fn is_empty(&self) -> bool {
        self.samples == 0
    }

    pub fn weight(&self, feature: &str) -> f64 {
        self.weights.get(feature).copied().unwrap_or(0.0)
    }

    /// Affinity of a candidate: the weighted sum of its features.
    pub fn score(&self, features: &[String]) -> f64 {
        features.iter().map(|f| self.weight(f) * family_factor(f)).sum()
    }

    /// The feature that explains the score best, with its weight (only a positive one).
    pub fn best_feature<'a>(&self, features: &'a [String]) -> Option<(&'a String, f64)> {
        features
            .iter()
            .map(|f| (f, self.weight(f) * family_factor(f)))
            .filter(|(_, w)| *w > 0.0)
            .max_by(|a, b| a.1.partial_cmp(&b.1).unwrap_or(std::cmp::Ordering::Equal))
    }

    /// The `n` heaviest features of a family ("genre", "decade", "lang", "group", "channel").
    pub fn top(&self, family: &str, n: usize) -> Vec<(String, f64)> {
        let prefix = format!("{family}:");
        let mut v: Vec<(String, f64)> = self
            .weights
            .iter()
            .filter(|(k, w)| k.starts_with(&prefix) && **w > 0.0)
            .map(|(k, w)| (k[prefix.len()..].to_string(), *w))
            .collect();
        v.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal).then(a.0.cmp(&b.0)));
        v.truncate(n);
        v
    }

    /// Aggregated summary sent to an AI (PRD 34 § 6.4): no title, only weights of genres and the like.
    pub fn summary(&self) -> String {
        let mut parts = Vec::new();
        for (label, family, n) in [
            ("genres", "genre", 6),
            ("categories", "group", 3),
            ("decades", "decade", 2),
            ("languages", "lang", 3),
            ("categories of programmes", "category", 4),
        ] {
            let top = self.top(family, n);
            if !top.is_empty() {
                let list: Vec<String> = top.iter().map(|(k, w)| format!("{k} {w:.2}")).collect();
                parts.push(format!("{label}: {}", list.join(", ")));
            }
        }
        if parts.is_empty() {
            "no history yet".to_string()
        } else {
            parts.join("; ")
        }
    }
}

/// Weight of one watch: recency × how much of it was seen. Zero for a zapping.
pub fn watch_weight(position_ms: i64, duration_ms: i64, completed: bool, last_watched_at: i64, now: i64) -> f64 {
    let age_days = ((now - last_watched_at).max(0) as f64) / 86_400.0;
    let recency = 0.5_f64.powf(age_days / HALF_LIFE_DAYS);
    let completion = if completed {
        1.0
    } else if duration_ms > 0 {
        let ratio = position_ms.max(0) as f64 / duration_ms as f64;
        if position_ms < ZAPPING_MS && ratio < 0.1 {
            return 0.0;
        }
        if ratio < 0.3 {
            0.35
        } else {
            0.7
        }
    } else {
        // A live channel keeps no duration: opening it counts as a moderate signal.
        0.5
    };
    recency * completion
}

/// Weight of a series: more episodes seen means more taste; a series left after one or two episodes
/// (more remain, nothing watched for two weeks) counts against it.
pub fn series_weight(watched: u32, completed: u32, total_episodes: u32, last_watched_at: i64, now: i64) -> f64 {
    let age_days = ((now - last_watched_at).max(0) as f64) / 86_400.0;
    let recency = 0.5_f64.powf(age_days / HALF_LIFE_DAYS);
    if watched <= 2 && total_episodes > watched && age_days > 14.0 {
        return -0.5 * recency.max(0.3);
    }
    recency * (1.0 + (1.0 + completed as f64).ln()).min(3.0)
}

// ----------------------------------------------------------------------------- features

fn clean(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ").to_lowercase()
}

fn split_list(s: &str) -> impl Iterator<Item = String> + '_ {
    s.split(',').map(clean).filter(|v| !v.is_empty() && v != "n/a")
}

fn group_feature(group: Option<&str>) -> Option<String> {
    let g = clean(group?);
    if g.is_empty() {
        None
    } else {
        Some(format!("group:{g}"))
    }
}

fn year_features(year: Option<u32>, out: &mut Vec<String>) {
    if let Some(y) = year.filter(|y| (1900..2100).contains(y)) {
        out.push(format!("decade:{}", y / 10 * 10));
    }
}

fn meta_features(meta: Option<&CachedItemMetadata>, out: &mut Vec<String>) {
    let Some(m) = meta else { return };
    if let Some(g) = &m.genres {
        out.extend(split_list(g).take(4).map(|v| format!("genre:{v}")));
    }
    if let Some(d) = &m.director {
        out.extend(split_list(d).take(2).map(|v| format!("director:{v}")));
    }
    if let Some(a) = &m.actors {
        out.extend(split_list(a).take(3).map(|v| format!("actor:{v}")));
    }
}

/// Features of a film: genres, director, actors (cached OMDb), decade, language, category.
pub fn movie_features(item: &IptvItemRecord, meta: Option<&CachedItemMetadata>) -> Vec<String> {
    let mut out = Vec::new();
    meta_features(meta, &mut out);
    year_features(item.year, &mut out);
    out.extend(group_feature(item.group_title.as_deref()));
    out
}

/// Features of a series (never of one episode): the same families, read on the series record.
pub fn series_features(series: &SeriesRecord, meta: Option<&CachedItemMetadata>) -> Vec<String> {
    let mut out = Vec::new();
    meta_features(meta, &mut out);
    out.extend(group_feature(series.group_title.as_deref()));
    out
}

/// A channel name without its quality suffix ("France 2 FHD" and "France 2 SD" are one channel).
pub fn channel_family(name: &str) -> String {
    const QUALITY: [&str; 9] = ["hd", "fhd", "uhd", "4k", "sd", "hevc", "h265", "raw", "backup"];
    let lowered = clean(name);
    let words: Vec<&str> = lowered
        .split_whitespace()
        .filter(|w| !QUALITY.contains(w) && !w.starts_with('['))
        .collect();
    words.join(" ")
}

/// Features of a channel, plus the category of the programme that was on when it was watched.
pub fn live_features(channel: &IptvItemRecord, program_category: Option<&str>) -> Vec<String> {
    let mut out = Vec::new();
    let family = channel_family(&channel.name_clean);
    if !family.is_empty() {
        out.push(format!("channel:{family}"));
    }
    out.extend(group_feature(channel.group_title.as_deref()));
    if let Some(c) = program_category {
        out.extend(c.split([',', '/']).map(clean).filter(|v| !v.is_empty()).take(2).map(|v| format!("category:{v}")));
    }
    out
}

/// `we-20` / `wd-14`: weekend or weekday, and the start hour of the two-hour block, local time.
pub fn slot_of(ts: i64, utc_offset_minutes: i32) -> String {
    let local = ts + i64::from(utc_offset_minutes) * 60;
    let days = local.div_euclid(86_400);
    let secs = local.rem_euclid(86_400);
    // 1970-01-01 was a Thursday: 0 = Monday … 6 = Sunday.
    let weekday = (days + 3).rem_euclid(7);
    let block = (secs / 3_600) / 2 * 2;
    format!("{}-{block:02}", if weekday >= 5 { "we" } else { "wd" })
}

/// The feature that names a content best: its first genre, else its category.
pub fn primary_feature(features: &[String]) -> Option<&String> {
    features
        .iter()
        .find(|f| f.starts_with("genre:"))
        .or_else(|| features.iter().find(|f| f.starts_with("group:")))
        .or_else(|| features.first())
}

fn capitalise(s: &str) -> String {
    s.split_whitespace()
        .map(|w| {
            let mut c = w.chars();
            c.next().map(|f| f.to_uppercase().collect::<String>() + c.as_str()).unwrap_or_default()
        })
        .collect::<Vec<_>>()
        .join(" ")
}

/// Short French reason for a feature that matched ("Thriller · vos goûts").
pub fn reason_for(feature: &str) -> String {
    let (family, value) = feature.split_once(':').unwrap_or(("", feature));
    let v = capitalise(value);
    match family {
        "genre" => format!("{v} · vos goûts"),
        "director" => format!("Du réalisateur {v}"),
        "actor" => format!("Avec {v}"),
        "group" => format!("Catégorie {v} · vos goûts"),
        "decade" => format!("Années {value} · vos goûts"),
        "channel" => format!("Vous regardez souvent {v}"),
        "category" => format!("{v} · vos goûts"),
        "slot" => "Vos chaînes à cette heure-ci".to_string(),
        _ => "Recommandé pour vous".to_string(),
    }
}

/// Overlap between two contents, for "Parce que vous avez regardé X": the weighted shared features.
pub fn similarity(a: &[String], b: &[String]) -> (f64, Option<String>) {
    let mut total = 0.0;
    let mut best: Option<(String, f64)> = None;
    for f in a {
        if b.contains(f) {
            let w = family_factor(f);
            total += w;
            if best.as_ref().is_none_or(|(_, bw)| w > *bw) {
                best = Some((f.clone(), w));
            }
        }
    }
    (total, best.map(|(f, _)| f))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn zapping_counts_for_nothing_and_completion_counts_most() {
        let now = 1_000_000;
        assert_eq!(watch_weight(30_000, 7_200_000, false, now, now), 0.0);
        let finished = watch_weight(7_000_000, 7_200_000, true, now, now);
        let half = watch_weight(3_600_000, 7_200_000, false, now, now);
        assert!(finished > half && half > 0.0);
    }

    #[test]
    fn a_month_halves_the_weight() {
        let now = 100 * 86_400;
        let fresh = watch_weight(0, 0, true, now, now);
        let old = watch_weight(0, 0, true, now - 30 * 86_400, now);
        assert!((old / fresh - 0.5).abs() < 0.01);
    }

    #[test]
    fn abandoned_series_count_against_it() {
        let now = 100 * 86_400;
        assert!(series_weight(1, 1, 30, now - 20 * 86_400, now) < 0.0);
        // A one-episode series that was watched is not an abandoned one.
        assert!(series_weight(1, 1, 1, now - 20 * 86_400, now) > 0.0);
        assert!(series_weight(10, 8, 30, now, now) > series_weight(3, 2, 30, now, now));
    }

    #[test]
    fn feedback_lowers_a_genre_and_scores_scale_to_one() {
        let mut taste = Taste::default();
        taste.add(&["genre:thriller".into(), "genre:drama".into()], 2.0);
        taste.add(&["genre:thriller".into()], 1.0);
        let feedback = HashMap::from([("genre:thriller".to_string(), -10.0)]);
        let after = taste.clone().finish(&feedback);
        assert!(after.weight("genre:thriller") < 0.0);
        let plain = taste.finish(&HashMap::new());
        assert!((plain.weight("genre:thriller") - 1.0).abs() < 1e-9);
    }

    #[test]
    fn slots_follow_the_local_week() {
        // 2026-11-06 is a Friday; 20:00 Paris (UTC+1) = 19:00 UTC.
        let friday_20h = 1_793_991_600;
        assert_eq!(slot_of(friday_20h, 60), "wd-20");
        assert_eq!(slot_of(friday_20h + 86_400, 60), "we-20");
    }

    #[test]
    fn channel_family_merges_qualities() {
        assert_eq!(channel_family("France 2 FHD"), channel_family("france 2 sd"));
        assert_eq!(channel_family("TF1 4K"), "tf1");
    }

    #[test]
    fn the_summary_holds_no_title() {
        let mut taste = Taste::default();
        taste.add(&["genre:thriller".into(), "decade:2010".into(), "lang:fr".into()], 1.0);
        let text = taste.finish(&HashMap::new()).summary();
        assert!(text.contains("genres: thriller") && text.contains("decades: 2010"));
    }
}
