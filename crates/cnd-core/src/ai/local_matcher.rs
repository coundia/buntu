//! Resolution of a spoken or typed command against the local catalog, without any network call.
//!
//! Handles explicit requests (a channel name, a number, "next", "previous", "go back") and programmes
//! on air right now. Anything it is not sure about is left to the model, together with a short list
//! of candidates.

use crate::ai::intent::{AiAction, AiCommandContext};
use crate::db::catalog_repo::{CatalogFilter, SortField, ITEM_SELECT_COLUMNS};
use crate::db::{DatabaseManager, DbError, IptvItemRecord};
use crate::iptv::normalizer::fold_diacritics_ascii;
use rusqlite::params;
use std::collections::{HashMap, HashSet};

/// Words that only phrase the request ("mets", "sur", "la chaîne"...), in French and English.
const FILLER: &[&str] = &[
    "mets", "met", "mettre", "mettez", "lance", "lancer", "passe", "passer", "va", "vas", "aller",
    "sur", "la", "le", "les", "l", "un", "une", "des", "du", "de", "d", "en", "et", "au", "aux", "a",
    "chaine", "chaines", "tv", "channel", "play", "watch", "switch", "to", "the", "on", "please",
    "stp", "svp", "s", "il", "vous", "plait", "moi", "me", "je", "veux", "voir", "regarder",
    "regarde", "jouer", "ouvre", "ouvrir", "affiche", "afficher", "donne", "show", "open", "put",
    "go", "numero", "n", "no",
];

/// Words that describe a programme in general rather than name it.
const GENERIC: &[&str] = &[
    "match", "film", "serie", "series", "emission", "programme", "direct", "live", "ce", "soir",
    "maintenant", "actuellement", "cours", "aujourd", "hui",
];

const NEXT: &[&str] = &["suivante", "suivant", "next", "apres", "prochaine", "prochain"];
const PREVIOUS: &[&str] = &["precedente", "precedent", "previous", "prev"];
const BACK: &[&str] = &["retour", "reviens", "revenir", "avant", "back", "derniere", "dernier"];

/// Tokens that describe a stream rather than name a channel.
const QUALITY_NOISE: &[&str] = &["hd", "fhd", "uhd", "4k", "sd", "hevc", "h265", "h264", "raw", "backup"];
const COUNTRY_NOISE: &[&str] = &[
    "fr", "uk", "us", "en", "de", "es", "it", "pt", "be", "ch", "ca", "nl", "ar", "tr",
];

pub const CONFIDENT: f32 = 0.85;

#[derive(Debug, Clone)]
pub struct LocalOutcome {
    /// Set when the command is resolved with confidence.
    pub action: Option<AiAction>,
    /// Best first, one entry per distinct channel name.
    pub candidates: Vec<IptvItemRecord>,
    /// Why nothing was decided, for the reply (`"back_without_history"`...).
    pub note: Option<&'static str>,
}

impl LocalOutcome {
    fn action(action: AiAction) -> Self {
        Self { action: Some(action), candidates: Vec::new(), note: None }
    }

    fn candidates(candidates: Vec<IptvItemRecord>) -> Self {
        Self { action: None, candidates, note: None }
    }
}

/// Lower-case ASCII words of a phrase, `4k` and `h265` normalised so they survive splitting.
pub fn words(text: &str) -> Vec<String> {
    fold_diacritics_ascii(text)
        .to_lowercase()
        .split(|c: char| !c.is_alphanumeric())
        .filter(|t| !t.is_empty())
        .map(|w| match w {
            "4k" => "uhd".to_string(),
            "h265" | "h264" => "hevc".to_string(),
            other => other.to_string(),
        })
        .collect()
}

/// `"france2"` -> `["france", "2"]`, `"tf1"` -> `["tf", "1"]`: letters and digits are separated so
/// that "France 2", "france2" and "FRANCE-2" all give the same tokens.
fn split_letters_digits(word: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let mut current = String::new();
    let mut last_is_digit: Option<bool> = None;
    for ch in word.chars() {
        let is_digit = ch.is_ascii_digit();
        if let Some(previous) = last_is_digit {
            if previous != is_digit {
                out.push(std::mem::take(&mut current));
            }
        }
        current.push(ch);
        last_is_digit = Some(is_digit);
    }
    if !current.is_empty() {
        out.push(current);
    }
    out
}

/// Tokens used for comparing a command with channel names: `"Mets France2 !"` -> `["mets", "france", "2"]`.
pub fn tokens(text: &str) -> Vec<String> {
    words(text).iter().flat_map(|w| split_letters_digits(w)).collect()
}

/// Drops stream tags ("hd", "fr"...) unless nothing else would be left: a channel is not named by them.
fn without_noise(tokens: Vec<String>) -> Vec<String> {
    let kept: Vec<String> = tokens
        .iter()
        .filter(|t| !QUALITY_NOISE.contains(&t.as_str()) && !COUNTRY_NOISE.contains(&t.as_str()))
        .cloned()
        .collect();
    if kept.is_empty() { tokens } else { kept }
}

/// The meaningful words of a command, not split (what a playlist's own tokens look like): `["tf1"]`.
pub fn significant_words(command: &str) -> Vec<String> {
    without_noise(
        words(command)
            .into_iter()
            .filter(|w| !FILLER.contains(&w.as_str()))
            .collect(),
    )
}

/// Search strings for the full-text index: the words as typed, and split at letter/digit borders,
/// because a playlist may name a channel "TF1" or "France 2" and the index does not know they match.
pub fn fts_variants(command: &str) -> Vec<String> {
    let joined = significant_words(command).join(" ");
    let split = significant_tokens(command).join(" ");
    let mut out = vec![joined];
    if !out.contains(&split) {
        out.push(split);
    }
    out.retain(|q| !q.trim().is_empty());
    out
}

/// Meaningful words that name something, not just describe a programme in general.
pub fn distinctive_tokens(command: &str) -> Vec<String> {
    significant_tokens(command)
        .into_iter()
        .filter(|t| !GENERIC.contains(&t.as_str()))
        .collect()
}

/// The words of the command that carry meaning (filler removed).
pub fn significant_tokens(command: &str) -> Vec<String> {
    without_noise(
        tokens(command)
            .into_iter()
            .filter(|t| !FILLER.contains(&t.as_str()))
            .collect(),
    )
}

/// Name of a channel reduced to what identifies it: country prefix (`FR: `), quality and country
/// tags removed. Falls back to the plain tokens if that would leave nothing.
pub fn channel_name_tokens(name: &str) -> Vec<String> {
    let trimmed = strip_country_prefix(name);
    let all = tokens(trimmed);
    let kept: Vec<String> = all
        .iter()
        .filter(|t| !QUALITY_NOISE.contains(&t.as_str()) && !COUNTRY_NOISE.contains(&t.as_str()))
        .cloned()
        .collect();
    if kept.is_empty() { all } else { kept }
}

/// `"FR: TF1"`, `"FR | TF1"`, `"UK - BBC One"` -> the part after the separator.
fn strip_country_prefix(name: &str) -> &str {
    let trimmed = name.trim_start();
    let mut letters = 0;
    for (idx, ch) in trimmed.char_indices() {
        if ch.is_ascii_alphabetic() && letters < 3 {
            letters += 1;
            continue;
        }
        if (2..=3).contains(&letters) {
            let rest = trimmed[idx..].trim_start();
            if let Some(after) = rest.strip_prefix(['|', ':', '-']) {
                return after.trim_start();
            }
        }
        break;
    }
    trimmed
}

fn all_in(tokens: &[String], vocabulary: &[&str]) -> bool {
    !tokens.is_empty() && tokens.iter().all(|t| vocabulary.contains(&t.as_str()))
}

fn prefer(a: &IptvItemRecord, b: &IptvItemRecord) -> bool {
    // true when `a` is the better representative of a channel than `b`
    (a.is_favorite, a.chno.is_some(), std::cmp::Reverse(a.id))
        > (b.is_favorite, b.chno.is_some(), std::cmp::Reverse(b.id))
}

/// One entry per distinct channel name, keeping the preferred copy (favorite, numbered, oldest).
fn dedupe_by_name(items: Vec<IptvItemRecord>) -> Vec<IptvItemRecord> {
    let mut order: Vec<String> = Vec::new();
    let mut best: HashMap<String, IptvItemRecord> = HashMap::new();
    for item in items {
        let key = channel_name_tokens(&item.name).join(" ");
        match best.get(&key) {
            None => {
                order.push(key.clone());
                best.insert(key, item);
            }
            Some(current) if prefer(&item, current) => {
                best.insert(key, item);
            }
            Some(_) => {}
        }
    }
    order.into_iter().filter_map(|key| best.remove(&key)).collect()
}

fn name_score(query: &[String], name: &str) -> f32 {
    let name_tokens = channel_name_tokens(name);
    if name_tokens == query {
        return 1.0;
    }
    let set: HashSet<&String> = name_tokens.iter().collect();
    if query.iter().all(|t| set.contains(t)) {
        return if name_tokens.len() <= query.len() + 1 { 0.9 } else { 0.6 };
    }
    0.3
}

pub fn resolve_local(
    db: &DatabaseManager,
    command: &str,
    context: &AiCommandContext,
    now: i64,
) -> Result<LocalOutcome, DbError> {
    let significant = significant_tokens(command);
    if significant.is_empty() {
        return Ok(LocalOutcome::candidates(Vec::new()));
    }

    // Navigation.
    if significant.iter().any(|t| PREVIOUS.contains(&t.as_str()))
        && all_in(&significant, &[PREVIOUS, BACK].concat())
    {
        return Ok(LocalOutcome::action(AiAction::PreviousChannel));
    }
    if all_in(&significant, NEXT) {
        return Ok(LocalOutcome::action(AiAction::NextChannel));
    }
    if all_in(&significant, BACK) {
        let recents = db.list_recent_items("live", 5)?;
        let target = recents
            .into_iter()
            .find(|item| Some(&item.stable_hash) != context.playing_stable_hash.as_ref());
        return Ok(match target {
            Some(item) => LocalOutcome::action(AiAction::PlayChannel { item_id: item.id }),
            None => LocalOutcome { action: Some(AiAction::None), candidates: Vec::new(), note: Some("back_without_history") },
        });
    }

    // Channel number.
    if significant.len() == 1 {
        if let Ok(number) = significant[0].parse::<u32>() {
            let matches = items_with_number(db, number)?;
            let unique = dedupe_by_name(matches);
            return Ok(match unique.len() {
                0 => LocalOutcome::candidates(Vec::new()),
                1 => LocalOutcome::action(AiAction::PlayChannel { item_id: unique[0].id }),
                _ => LocalOutcome::candidates(unique),
            });
        }
    }

    // Multi-View (2 to 4 channels: "TF1 et M6 côte à côte", "mosaïque France 2, France 3").
    if let Some(multi) = try_resolve_multiview(db, command)? {
        return Ok(LocalOutcome::action(multi));
    }

    // Channel name.
    let mut found: Vec<IptvItemRecord> = Vec::new();
    for query in fts_variants(command) {
        for item in db.query_catalog(&CatalogFilter {
            kind: "live".to_string(),
            source_id: None,
            query,
            group_title: None,
            host: None,
            favorites_only: false,
            include_broken: false,
            include_hidden: false,
            sort_by: SortField::ChannelNumber,
            sort_asc: true,
            limit: 80,
            offset: 0,
        })? {
            if !found.iter().any(|f| f.id == item.id) {
                found.push(item);
            }
        }
    }
    let mut scored: Vec<(f32, IptvItemRecord)> = found
        .into_iter()
        .map(|item| (name_score(&significant, &item.name), item))
        .collect();
    scored.sort_by(|a, b| {
        b.0.partial_cmp(&a.0)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| b.1.is_favorite.cmp(&a.1.is_favorite))
    });
    let confident: Vec<IptvItemRecord> = dedupe_by_name(
        scored.iter().filter(|(score, _)| *score >= CONFIDENT).map(|(_, item)| item.clone()).collect(),
    );
    if confident.len() == 1 {
        return Ok(LocalOutcome::action(AiAction::PlayChannel { item_id: confident[0].id }));
    }
    let mut candidates = dedupe_by_name(scored.into_iter().map(|(_, item)| item).collect());
    if candidates.len() > 1 && !confident.is_empty() {
        candidates.truncate(5);
        return Ok(LocalOutcome::candidates(candidates));
    }

    // Programme on air right now.
    let distinctive = distinctive_tokens(command);
    if !distinctive.is_empty() {
        let on_air = channels_airing(db, &distinctive, now)?;
        let unique = dedupe_by_name(on_air);
        match unique.len() {
            0 => {}
            1 => return Ok(LocalOutcome::action(AiAction::PlayChannel { item_id: unique[0].id })),
            _ => {
                let mut merged = unique;
                for item in candidates {
                    if !merged.iter().any(|m| m.id == item.id) {
                        merged.push(item);
                    }
                }
                return Ok(LocalOutcome::candidates(merged));
            }
        }
    }

    Ok(LocalOutcome::candidates(candidates))
}

fn try_resolve_multiview(db: &DatabaseManager, command: &str) -> Result<Option<AiAction>, DbError> {
    let lower = command.to_lowercase();
    let is_multiview_keyword = lower.contains("mosaïque")
        || lower.contains("mosaique")
        || lower.contains("multiview")
        || lower.contains("multi-view")
        || lower.contains("côte à côte")
        || lower.contains("cote a cote");

    let has_separator = lower.contains(" et ")
        || lower.contains(" and ")
        || lower.contains('&')
        || lower.contains('+')
        || lower.contains(',');

    if !is_multiview_keyword && !has_separator {
        return Ok(None);
    }

    let cleaned = lower
        .replace("mosaïque", "")
        .replace("mosaique", "")
        .replace("multiview", "")
        .replace("multi-view", "")
        .replace("côte à côte", "")
        .replace("cote a cote", "")
        .replace("mets", "")
        .replace("lance", "")
        .replace("affiche", "")
        .replace("regarde", "")
        .replace("regarder", "")
        .replace("en direct", "");

    let parts: Vec<&str> = cleaned
        .split([',', '&', '+'])
        .flat_map(|p| p.split(" et "))
        .flat_map(|p| p.split(" and "))
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .collect();

    if parts.len() < 2 || parts.len() > 4 {
        return Ok(None);
    }

    let mut item_ids = Vec::new();
    for part in &parts {
        let sig = significant_tokens(part);
        if sig.is_empty() {
            return Ok(None);
        }
        if let Some(id) = find_confident_channel(db, &sig, part)? {
            if !item_ids.contains(&id) {
                item_ids.push(id);
            }
        } else {
            return Ok(None);
        }
    }

    if item_ids.len() == parts.len() && item_ids.len() >= 2 {
        Ok(Some(AiAction::MultiView { item_ids }))
    } else {
        Ok(None)
    }
}

fn find_confident_channel(db: &DatabaseManager, significant: &[String], raw_str: &str) -> Result<Option<i64>, DbError> {
    if significant.len() == 1 {
        if let Ok(number) = significant[0].parse::<u32>() {
            let matches = items_with_number(db, number)?;
            let unique = dedupe_by_name(matches);
            if unique.len() == 1 {
                return Ok(Some(unique[0].id));
            }
        }
    }
    let mut found: Vec<IptvItemRecord> = Vec::new();
    for query in fts_variants(raw_str) {
        for item in db.query_catalog(&CatalogFilter {
            kind: "live".to_string(),
            source_id: None,
            query,
            group_title: None,
            host: None,
            favorites_only: false,
            include_broken: false,
            include_hidden: false,
            sort_by: SortField::ChannelNumber,
            sort_asc: true,
            limit: 80,
            offset: 0,
        })? {
            if !found.iter().any(|f| f.id == item.id) {
                found.push(item);
            }
        }
    }
    let mut scored: Vec<(f32, IptvItemRecord)> = found
        .into_iter()
        .map(|item| (name_score(significant, &item.name), item))
        .collect();
    scored.sort_by(|a, b| {
        b.0.partial_cmp(&a.0)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| b.1.is_favorite.cmp(&a.1.is_favorite))
    });
    let confident: Vec<IptvItemRecord> = dedupe_by_name(
        scored.iter().filter(|(score, _)| *score >= CONFIDENT).map(|(_, item)| item.clone()).collect(),
    );
    if confident.len() == 1 {
        Ok(Some(confident[0].id))
    } else {
        Ok(None)
    }
}

fn items_with_number(db: &DatabaseManager, number: u32) -> Result<Vec<IptvItemRecord>, DbError> {
    db.with_conn(|conn| {
        let sql = format!(
            "SELECT {ITEM_SELECT_COLUMNS}
             FROM iptv_items i
             LEFT JOIN favorites f ON f.stable_hash = i.stable_hash
             LEFT JOIN broken_flags bf ON bf.stable_hash = i.stable_hash
             LEFT JOIN watch_history wh ON wh.stable_hash = i.stable_hash
             WHERE i.kind = 'live' AND i.chno = ?1 AND bf.stable_hash IS NULL
             ORDER BY i.id ASC LIMIT 20"
        );
        let mut stmt = conn.prepare_cached(&sql)?;
        let rows = stmt.query_map(params![number], crate::db::catalog_repo::map_item_row)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(DbError::from)
    })
}

/// Live channels whose programme on air at `now` contains every distinctive word. The comparison
/// is done here, on folded text, because SQLite's `LIKE` does not ignore accents.
pub fn channels_airing(db: &DatabaseManager, words: &[String], now: i64) -> Result<Vec<IptvItemRecord>, DbError> {
    let ids: Vec<i64> = db.with_conn(|conn| {
        let mut stmt = conn.prepare_cached(
            "SELECT i.id, e.title
             FROM epg_programs e
             INNER JOIN iptv_items i ON i.tvg_id = e.channel_tvg_id AND i.kind = 'live'
             WHERE e.start_ts <= ?1 AND e.end_ts > ?1",
        )?;
        let rows = stmt.query_map(params![now], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?)))?;
        let mut ids = Vec::new();
        for row in rows {
            let (id, title) = row?;
            let title_tokens = tokens(&title);
            let all = words.iter().all(|w| {
                title_tokens.iter().any(|t| t == w || (w.len() >= 3 && t.starts_with(w.as_str())))
            });
            if all {
                ids.push(id);
                if ids.len() >= 60 {
                    break;
                }
            }
        }
        Ok(ids)
    })?;
    items_by_ids(db, &ids)
}

pub fn items_by_ids(db: &DatabaseManager, ids: &[i64]) -> Result<Vec<IptvItemRecord>, DbError> {
    let mut out = Vec::with_capacity(ids.len());
    for id in ids {
        if let Some(item) = db.get_item_by_id(*id)? {
            out.push(item);
        }
    }
    Ok(out)
}

#[cfg(test)]
pub(crate) mod test_catalog {
    use super::*;

    pub struct Seeded {
        pub db: DatabaseManager,
        pub now: i64,
    }

    /// Channels: (name, group, chno, tvg id). One source, plus current programmes.
    pub fn seed() -> Seeded {
        let db = DatabaseManager::open_in_memory().expect("db");
        let now = seed_into(&db);
        Seeded { db, now }
    }

    /// Fills `db` with the test channels and returns the "now" used for the programmes.
    pub fn seed_into(db: &DatabaseManager) -> i64 {
        let source = db
            .add_source("Test", "m3u", Some("http://x/l.m3u"), None, None, None)
            .expect("source");
        let channels: &[(&str, &str, u32, &str)] = &[
            ("FR: TF1 HD", "FR | GENERALISTES", 1, "tf1.fr"),
            ("FR: France 2 FHD", "FR | GENERALISTES", 2, "france2.fr"),
            ("France 2", "FR | GENERALISTES", 202, "france2.fr"), // same channel, other source copy
            ("FR: France 3", "FR | GENERALISTES", 3, "france3.fr"),
            ("FR: France 24", "FR | INFO", 24, "france24.fr"),
            ("FR: France Info", "FR | INFO", 25, "franceinfo.fr"),
            ("FR: M6 HD", "FR | GENERALISTES", 6, "m6.fr"),
            ("FR: Canal+ Sport", "FR | SPORT", 31, "canalsport.fr"),
            ("FR: beIN Sports 1", "FR | SPORT", 32, "bein1.fr"),
            ("FR: beIN Sports 2", "FR | SPORT", 33, "bein2.fr"),
            ("UK: BBC News", "UK | NEWS", 101, "bbcnews.uk"),
            ("US: CNN International", "US | NEWS", 102, "cnn.us"),
            ("FR: Chaîne Météo", "FR | INFO", 50, "meteo.fr"),
        ];
        db.with_conn(|conn| {
            for (index, (name, group, chno, tvg)) in channels.iter().enumerate() {
                conn.execute(
                    "INSERT INTO iptv_items (source_id, stable_hash, kind, name, name_clean, group_title, tvg_id, chno, host, stream_url, created_at, updated_at)
                     VALUES (?1, ?2, 'live', ?3, ?3, ?4, ?5, ?6, 'h', ?7, 1, 1)",
                    params![source, format!("hash_{index}"), name, group, tvg, chno, format!("http://h/{index}.ts")],
                )?;
            }
            Ok(())
        })
        .expect("items");
        // Relative to the real clock so engine-level tests (which use the current time) see them on air.
        let now = crate::db::chrono_now_ts();
        db.with_conn(|conn| {
            let programmes: &[(&str, &str)] = &[
                ("tf1.fr", "Journal de 20h"),
                ("france2.fr", "Envoyé spécial"),
                ("m6.fr", "Capital"),
                ("bein1.fr", "Ligue 1 : PSG - Marseille"),
                ("canalsport.fr", "Top 14 : Toulouse - Racing"),
                ("meteo.fr", "La météo de la semaine"),
            ];
            for (tvg, title) in programmes {
                conn.execute(
                    "INSERT INTO epg_programs (channel_tvg_id, start_ts, end_ts, title) VALUES (?1, ?2, ?3, ?4)",
                    params![tvg, now - 600, now + 3000, title],
                )?;
            }
            Ok(())
        })
        .expect("epg");
        now
    }

    pub fn ctx(playing: Option<&str>) -> AiCommandContext {
        AiCommandContext {
            playing_stable_hash: playing.map(str::to_string),
            group_title: None,
            locale: "fr-FR".to_string(),
        }
    }

    pub fn id_of(db: &DatabaseManager, name: &str) -> i64 {
        db.with_conn(|conn| {
            conn.query_row("SELECT id FROM iptv_items WHERE name = ?1", params![name], |r| r.get(0))
                .map_err(DbError::from)
        })
        .expect("id")
    }
}

#[cfg(test)]
mod tests {
    use super::test_catalog::*;
    use super::*;

    fn play_id(outcome: &LocalOutcome) -> Option<i64> {
        match outcome.action {
            Some(AiAction::PlayChannel { item_id }) => Some(item_id),
            _ => None,
        }
    }

    #[test]
    fn tokenizes_without_accents_or_punctuation() {
        assert_eq!(tokens("Mets France 2 !"), vec!["mets", "france", "2"]);
        assert_eq!(tokens("L'émission à 20h"), vec!["l", "emission", "a", "20", "h"]);
        assert_eq!(tokens("france2"), tokens("France 2"));
        assert_eq!(tokens("TF1"), vec!["tf", "1"]);
        assert_eq!(fts_variants("mets tf1"), vec!["tf1", "tf 1"]);
        assert_eq!(fts_variants("france 2"), vec!["france 2"]);
        assert_eq!(significant_tokens("mets la chaîne France 2 stp"), vec!["france", "2"]);
    }

    #[test]
    fn channel_names_lose_country_prefix_and_quality_tags() {
        assert_eq!(channel_name_tokens("FR: France 2 FHD"), vec!["france", "2"]);
        assert_eq!(channel_name_tokens("FR | TF1 HD"), vec!["tf", "1"]);
        assert_eq!(channel_name_tokens("UK - BBC One"), vec!["bbc", "one"]);
        assert_eq!(channel_name_tokens("France 2"), vec!["france", "2"]);
        assert_eq!(channel_name_tokens("Canal+ Sport 4K"), vec!["canal", "sport"]);
        assert_eq!(channel_name_tokens("HD"), vec!["hd"], "never reduced to nothing");
        assert_eq!(channel_name_tokens("Arte"), vec!["arte"]);
    }

    #[test]
    fn explicit_names_resolve_locally_whatever_the_phrasing() {
        let s = seed();
        let france2 = id_of(&s.db, "FR: France 2 FHD");
        for phrase in ["France 2", "france2 hd", "france2", "FRANCE-2", "FR: France 2", "mets France 2", "mets la chaîne France 2 stp", "lance france 2"] {
            let outcome = resolve_local(&s.db, phrase, &ctx(None), s.now).unwrap();
            let id = play_id(&outcome).unwrap_or_else(|| panic!("{phrase:?} not resolved: {outcome:?}"));
            assert!(id == france2 || id == id_of(&s.db, "France 2"), "{phrase:?} -> {id}");
        }
        let tf1 = resolve_local(&s.db, "TF1", &ctx(None), s.now).unwrap();
        assert_eq!(play_id(&tf1), Some(id_of(&s.db, "FR: TF1 HD")));
        let m6 = resolve_local(&s.db, "mets M6", &ctx(None), s.now).unwrap();
        assert_eq!(play_id(&m6), Some(id_of(&s.db, "FR: M6 HD")));
    }

    #[test]
    fn france_2_is_not_confused_with_france_24() {
        let s = seed();
        let outcome = resolve_local(&s.db, "france 2", &ctx(None), s.now).unwrap();
        let id = play_id(&outcome).expect("resolved");
        assert_ne!(id, id_of(&s.db, "FR: France 24"));
        let f24 = resolve_local(&s.db, "france 24", &ctx(None), s.now).unwrap();
        assert_eq!(play_id(&f24), Some(id_of(&s.db, "FR: France 24")));
    }

    #[test]
    fn duplicate_copies_of_a_channel_pick_the_numbered_older_one() {
        let s = seed();
        let outcome = resolve_local(&s.db, "france 2", &ctx(None), s.now).unwrap();
        assert_eq!(play_id(&outcome), Some(id_of(&s.db, "FR: France 2 FHD")), "lowest id wins when equal");
        // A favorite copy is preferred.
        let other = id_of(&s.db, "France 2");
        let hash: String = s.db.with_conn(|c| c.query_row("SELECT stable_hash FROM iptv_items WHERE id = ?1", params![other], |r| r.get(0)).map_err(DbError::from)).unwrap();
        s.db.toggle_favorite(&hash, "live").unwrap();
        let again = resolve_local(&s.db, "france 2", &ctx(None), s.now).unwrap();
        assert_eq!(play_id(&again), Some(other));
    }

    #[test]
    fn ambiguous_names_return_candidates_instead_of_guessing() {
        let s = seed();
        let outcome = resolve_local(&s.db, "france", &ctx(None), s.now).unwrap();
        assert!(outcome.action.is_none());
        let names: Vec<&str> = outcome.candidates.iter().map(|c| c.name.as_str()).collect();
        assert!(names.contains(&"FR: France 3") && names.contains(&"FR: France 24") && names.contains(&"FR: France Info"), "{names:?}");
        let bein = resolve_local(&s.db, "bein sports", &ctx(None), s.now).unwrap();
        assert!(bein.action.is_none());
        assert_eq!(bein.candidates.len(), 2);
    }

    #[test]
    fn channel_numbers() {
        let s = seed();
        for phrase in ["6", "chaîne 6", "la 6", "mets la chaîne numéro 6"] {
            let outcome = resolve_local(&s.db, phrase, &ctx(None), s.now).unwrap();
            assert_eq!(play_id(&outcome), Some(id_of(&s.db, "FR: M6 HD")), "{phrase}");
        }
        let none = resolve_local(&s.db, "chaîne 999", &ctx(None), s.now).unwrap();
        assert!(none.action.is_none() && none.candidates.is_empty());
    }

    #[test]
    fn navigation_words() {
        let s = seed();
        let next = resolve_local(&s.db, "suivante", &ctx(None), s.now).unwrap();
        assert_eq!(next.action, Some(AiAction::NextChannel));
        let next2 = resolve_local(&s.db, "mets la chaîne suivante", &ctx(None), s.now).unwrap();
        assert_eq!(next2.action, Some(AiAction::NextChannel));
        let prev = resolve_local(&s.db, "chaîne précédente", &ctx(None), s.now).unwrap();
        assert_eq!(prev.action, Some(AiAction::PreviousChannel));
        let prev2 = resolve_local(&s.db, "reviens sur la chaîne précédente", &ctx(None), s.now).unwrap();
        assert_eq!(prev2.action, Some(AiAction::PreviousChannel));
    }

    #[test]
    fn go_back_returns_to_the_last_other_channel_watched() {
        let s = seed();
        let tf1 = id_of(&s.db, "FR: TF1 HD");
        let m6 = id_of(&s.db, "FR: M6 HD");
        let hash = |id: i64| -> String {
            s.db.with_conn(|c| c.query_row("SELECT stable_hash FROM iptv_items WHERE id = ?1", params![id], |r| r.get(0)).map_err(DbError::from)).unwrap()
        };
        let none = resolve_local(&s.db, "reviens sur la chaîne d'avant", &ctx(None), s.now).unwrap();
        assert_eq!(none.action, Some(AiAction::None));
        assert_eq!(none.note, Some("back_without_history"));

        // Make the order explicit: watching timestamps are in seconds.
        let tf1_hash = hash(tf1);
        s.db.record_watch_progress(&tf1_hash, 0, 0).unwrap();
        s.db.with_conn(|c| c.execute("UPDATE watch_history SET last_watched_at = last_watched_at - 100 WHERE stable_hash = ?1", params![tf1_hash]).map_err(DbError::from)).unwrap();
        s.db.record_watch_progress(&hash(m6), 0, 0).unwrap();

        let back = resolve_local(&s.db, "retour", &ctx(Some(&hash(m6))), s.now).unwrap();
        assert_eq!(play_id(&back), Some(tf1), "M6 is playing, so go back to TF1");
        let back2 = resolve_local(&s.db, "reviens sur la chaîne d'avant", &ctx(Some(&hash(tf1))), s.now).unwrap();
        assert_eq!(play_id(&back2), Some(m6));
    }

    #[test]
    fn programme_on_air_resolves_when_unique() {
        let s = seed();
        let outcome = resolve_local(&s.db, "mets le match du PSG", &ctx(None), s.now).unwrap();
        assert_eq!(play_id(&outcome), Some(id_of(&s.db, "FR: beIN Sports 1")), "{outcome:?}");

        // Accents in the guide do not matter.
        let meteo = resolve_local(&s.db, "la meteo", &ctx(None), s.now).unwrap();
        assert!(play_id(&meteo).is_some(), "{meteo:?}");

        // Programme times are respected: nothing airs a day later.
        let later = resolve_local(&s.db, "le match du PSG", &ctx(None), s.now + 86_400).unwrap();
        assert!(later.action.is_none());
    }

    #[test]
    fn unrelated_or_empty_commands_stay_undecided() {
        let s = seed();
        let empty = resolve_local(&s.db, "  ", &ctx(None), s.now).unwrap();
        assert!(empty.action.is_none() && empty.candidates.is_empty());
        let filler = resolve_local(&s.db, "mets la chaîne s'il te plaît", &ctx(None), s.now).unwrap();
        assert!(filler.action.is_none());
        let vague = resolve_local(&s.db, "une chaîne d'info en anglais", &ctx(None), s.now).unwrap();
        assert!(vague.action.is_none(), "left to the model: {vague:?}");
    }

    #[test]
    fn special_characters_never_break_the_search() {
        let s = seed();
        for phrase in ["\"; DROP TABLE iptv_items; --", "france* AND (", "'", "***", "%_"] {
            resolve_local(&s.db, phrase, &ctx(None), s.now).expect(phrase);
        }
        assert!(s.db.get_stats().unwrap().total_live_channels >= 13);
    }

    #[test]
    fn multiview_resolves_locally_for_two_to_four_channels() {
        let s = seed();
        let tf1 = id_of(&s.db, "FR: TF1 HD");
        let m6 = id_of(&s.db, "FR: M6 HD");
        let france2 = id_of(&s.db, "FR: France 2 FHD");

        let mv2 = resolve_local(&s.db, "TF1 et M6 côte à côte", &ctx(None), s.now).unwrap();
        assert_eq!(mv2.action, Some(AiAction::MultiView { item_ids: vec![tf1, m6] }));

        let mv3 = resolve_local(&s.db, "mosaïque TF1, France 2 et M6", &ctx(None), s.now).unwrap();
        assert_eq!(mv3.action, Some(AiAction::MultiView { item_ids: vec![tf1, france2, m6] }));
    }
}
