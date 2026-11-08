use super::types::{AiAction, AiCandidate, AiCommandContext};
use crate::normalizer::fold_diacritics_ascii;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};

/// Words that only phrase the request ("mets", "sur", "la chaîne"...), in French and English.
pub const FILLER: &[&str] = &[
    "mets", "met", "mettre", "mettez", "lance", "lancer", "passe", "passer", "va", "vas", "aller",
    "sur", "la", "le", "les", "l", "un", "une", "des", "du", "de", "d", "en", "et", "au", "aux", "a",
    "chaine", "chaines", "tv", "channel", "play", "watch", "switch", "to", "the", "on", "please",
    "stp", "svp", "s", "il", "vous", "plait", "moi", "me", "je", "veux", "voir", "regarder",
    "regarde", "jouer", "ouvre", "ouvrir", "affiche", "afficher", "donne", "show", "open", "put",
    "go", "numero", "n", "no",
];

/// Words that describe a programme in general rather than name it.
pub const GENERIC: &[&str] = &[
    "match", "film", "serie", "series", "emission", "programme", "direct", "live", "ce", "soir",
    "maintenant", "actuellement", "cours", "aujourd", "hui",
];

pub const NEXT: &[&str] = &["suivante", "suivant", "next", "apres", "prochaine", "prochain"];
pub const PREVIOUS: &[&str] = &["precedente", "precedent", "previous", "prev"];
pub const BACK: &[&str] = &["retour", "reviens", "revenir", "avant", "back", "derniere", "dernier"];

/// Tokens that describe a stream rather than name a channel.
pub const QUALITY_NOISE: &[&str] = &["hd", "fhd", "uhd", "4k", "sd", "hevc", "h265", "h264", "raw", "backup"];
pub const COUNTRY_NOISE: &[&str] = &[
    "fr", "uk", "us", "en", "de", "es", "it", "pt", "be", "ch", "ca", "nl", "ar", "tr",
];

pub const CONFIDENT: f32 = 0.85;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct LocalOutcome {
    pub action: Option<AiAction>,
    pub candidates: Vec<AiCandidate>,
    pub note: Option<String>,
}

impl LocalOutcome {
    pub fn action(action: AiAction) -> Self {
        Self { action: Some(action), candidates: Vec::new(), note: None }
    }

    pub fn candidates(candidates: Vec<AiCandidate>) -> Self {
        Self { action: None, candidates, note: None }
    }
}

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

pub fn split_letters_digits(word: &str) -> Vec<String> {
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

pub fn tokens(text: &str) -> Vec<String> {
    words(text).iter().flat_map(|w| split_letters_digits(w)).collect()
}

pub fn without_noise(tokens: Vec<String>) -> Vec<String> {
    let kept: Vec<String> = tokens
        .iter()
        .filter(|t| !QUALITY_NOISE.contains(&t.as_str()) && !COUNTRY_NOISE.contains(&t.as_str()))
        .cloned()
        .collect();
    if kept.is_empty() { tokens } else { kept }
}

pub fn significant_words(command: &str) -> Vec<String> {
    without_noise(
        words(command)
            .into_iter()
            .filter(|w| !FILLER.contains(&w.as_str()))
            .collect(),
    )
}

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

pub fn distinctive_tokens(command: &str) -> Vec<String> {
    significant_tokens(command)
        .into_iter()
        .filter(|t| !GENERIC.contains(&t.as_str()))
        .collect()
}

pub fn significant_tokens(command: &str) -> Vec<String> {
    without_noise(
        tokens(command)
            .into_iter()
            .filter(|t| !FILLER.contains(&t.as_str()))
            .collect(),
    )
}

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

pub fn strip_country_prefix(name: &str) -> &str {
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

fn prefer(a: &AiCandidate, b: &AiCandidate) -> bool {
    (a.is_favorite, a.chno.is_some(), std::cmp::Reverse(a.id))
        > (b.is_favorite, b.chno.is_some(), std::cmp::Reverse(b.id))
}

pub fn dedupe_by_name(items: Vec<AiCandidate>) -> Vec<AiCandidate> {
    let mut order: Vec<String> = Vec::new();
    let mut best: HashMap<String, AiCandidate> = HashMap::new();
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

pub fn name_score(query: &[String], name: &str) -> f32 {
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
    command: &str,
    candidates: &[AiCandidate],
    context: &AiCommandContext,
) -> LocalOutcome {
    let significant = significant_tokens(command);
    if significant.is_empty() {
        return LocalOutcome::candidates(Vec::new());
    }

    // 1. Navigation
    if significant.iter().any(|t| PREVIOUS.contains(&t.as_str()))
        && all_in(&significant, &[PREVIOUS, BACK].concat())
    {
        return LocalOutcome::action(AiAction::PreviousChannel);
    }
    if all_in(&significant, NEXT) {
        return LocalOutcome::action(AiAction::NextChannel);
    }
    if all_in(&significant, BACK) {
        if context.playing_stable_hash.is_none() && candidates.is_empty() {
            return LocalOutcome {
                action: Some(AiAction::None),
                candidates: Vec::new(),
                note: Some("back_without_history".to_string()),
            };
        }
        if let Some(target) = candidates.first() {
            return LocalOutcome::action(AiAction::PlayChannel { item_id: target.id });
        }
        return LocalOutcome {
            action: Some(AiAction::None),
            candidates: Vec::new(),
            note: Some("back_without_history".to_string()),
        };
    }

    // 2. Channel number
    if significant.len() == 1 {
        if let Ok(number) = significant[0].parse::<u32>() {
            let matches: Vec<AiCandidate> = candidates
                .iter()
                .filter(|c| c.chno == Some(number))
                .cloned()
                .collect();
            let unique = dedupe_by_name(matches);
            return match unique.len() {
                0 => LocalOutcome::candidates(Vec::new()),
                1 => LocalOutcome::action(AiAction::PlayChannel { item_id: unique[0].id }),
                _ => LocalOutcome::candidates(unique),
            };
        }
    }

    // 3. Multi-View
    if let Some(multi) = try_resolve_multiview(command, candidates) {
        return LocalOutcome::action(multi);
    }

    // 4. Channel name score
    let mut scored: Vec<(f32, AiCandidate)> = candidates
        .iter()
        .map(|item| (name_score(&significant, &item.name), item.clone()))
        .collect();
    scored.sort_by(|a, b| {
        b.0.partial_cmp(&a.0)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| b.1.is_favorite.cmp(&a.1.is_favorite))
    });

    let confident: Vec<AiCandidate> = dedupe_by_name(
        scored.iter().filter(|(score, _)| *score >= CONFIDENT).map(|(_, item)| item.clone()).collect(),
    );
    if confident.len() == 1 {
        return LocalOutcome::action(AiAction::PlayChannel { item_id: confident[0].id });
    }
    let mut deduped_candidates = dedupe_by_name(scored.into_iter().map(|(_, item)| item).collect());
    if deduped_candidates.len() > 1 && !confident.is_empty() {
        deduped_candidates.truncate(5);
        return LocalOutcome::candidates(deduped_candidates);
    }

    // 5. Programme on air right now
    let distinctive = distinctive_tokens(command);
    if !distinctive.is_empty() {
        let on_air: Vec<AiCandidate> = candidates
            .iter()
            .filter(|c| {
                if let Some(now) = &c.current_programme {
                    let prog_tokens = tokens(now);
                    let prog_set: HashSet<&String> = prog_tokens.iter().collect();
                    distinctive.iter().any(|d| prog_set.contains(d))
                } else {
                    false
                }
            })
            .cloned()
            .collect();
        let unique = dedupe_by_name(on_air);
        match unique.len() {
            0 => {}
            1 => return LocalOutcome::action(AiAction::PlayChannel { item_id: unique[0].id }),
            _ => {
                let mut merged = unique;
                for item in deduped_candidates {
                    if !merged.iter().any(|m| m.id == item.id) {
                        merged.push(item);
                    }
                }
                return LocalOutcome::candidates(merged);
            }
        }
    }

    LocalOutcome::candidates(deduped_candidates)
}

fn try_resolve_multiview(command: &str, candidates: &[AiCandidate]) -> Option<AiAction> {
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
        return None;
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
        .filter(|p| !p.is_empty())
        .collect();

    if parts.len() < 2 || parts.len() > 4 {
        return None;
    }

    let mut matched_ids = Vec::new();
    for part in parts {
        let part_sig = significant_tokens(part);
        if part_sig.is_empty() {
            return None;
        }
        let best = candidates
            .iter()
            .map(|c| (name_score(&part_sig, &c.name), c))
            .filter(|(s, _)| *s >= CONFIDENT)
            .max_by(|a, b| a.0.partial_cmp(&b.0).unwrap_or(std::cmp::Ordering::Equal));
        if let Some((_, item)) = best {
            if !matched_ids.contains(&item.id) {
                matched_ids.push(item.id);
            }
        } else {
            return None;
        }
    }

    if matched_ids.len() >= 2 && matched_ids.len() <= 4 {
        Some(AiAction::MultiView { item_ids: matched_ids })
    } else {
        None
    }
}

