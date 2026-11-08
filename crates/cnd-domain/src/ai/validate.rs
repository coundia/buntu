use super::prompt::{
    clean_text, MAX_GUESS_CHARS, MAX_GUESSES, MAX_RECO_DISCOVER, MAX_RECO_PICKS, MAX_RECO_REASON_CHARS,
};
use super::providers::parse_decision;
use super::types::{
    AiAction, AiCandidate, ModelDecision, RecoValidationPick, RecoValidationResult, SearchUnderstanding,
    TitleGuess,
};
use serde_json::Value;
use std::collections::HashSet;

pub const MAX_QUERY_CHARS: usize = 100;
pub const MAX_REPLY_CHARS: usize = 140;
pub const MIN_RECO_CONFIDENCE: f64 = 0.5;

pub fn clean_reply(text: &str) -> String {
    let cleaned: String = text.chars().filter(|c| !c.is_control()).collect();
    cleaned.trim().chars().take(MAX_REPLY_CHARS).collect()
}

pub fn validate_command(
    decision: &ModelDecision,
    candidates: &[AiCandidate],
) -> Result<(AiAction, Option<String>), String> {
    let reply = decision.reply.as_deref().map(clean_reply).filter(|r| !r.is_empty());
    let known = |id: i64| candidates.iter().any(|c| c.id == id);
    match decision.action.trim().to_ascii_lowercase().as_str() {
        "play" => match decision.item_id {
            Some(id) if known(id) => Ok((AiAction::PlayChannel { item_id: id }, reply)),
            _ => Err("réponse invalide : chaîne inconnue".to_string()),
        },
        "guide" => match decision.item_id {
            Some(id) if known(id) => Ok((AiAction::ShowGuide { item_id: id }, reply)),
            _ => Err("réponse invalide : chaîne inconnue".to_string()),
        },
        "search" => {
            let query: String = decision
                .query
                .as_deref()
                .unwrap_or("")
                .chars()
                .filter(|c| !c.is_control())
                .take(MAX_QUERY_CHARS)
                .collect();
            if query.trim().is_empty() {
                Err("réponse invalide : recherche vide".to_string())
            } else {
                Ok((AiAction::Search { query: query.trim().to_string() }, reply))
            }
        }
        "next" => Ok((AiAction::NextChannel, reply)),
        "previous" => Ok((AiAction::PreviousChannel, reply)),
        "multiview" => {
            let ids = decision.item_ids.as_deref().unwrap_or(&[]);
            let valid_ids: Vec<i64> = ids.iter().copied().filter(|id| known(*id)).collect();
            if valid_ids.len() >= 2 && valid_ids.len() <= 4 {
                Ok((AiAction::MultiView { item_ids: valid_ids }, reply))
            } else {
                Err("réponse invalide : mosaïque avec moins de 2 chaînes valides".to_string())
            }
        }
        "none" => Ok((AiAction::None, reply)),
        _ => Err("réponse invalide : action inconnue".to_string()),
    }
}

pub fn validate_command_text(
    text: &str,
    candidates: &[AiCandidate],
) -> Result<(AiAction, Option<String>), String> {
    let decision = parse_decision(text)?;
    validate_command(&decision, candidates)
}

pub fn validate_understand(text: &str) -> Result<SearchUnderstanding, String> {
    let trimmed = text.trim();
    let start = trimmed.find('{').ok_or_else(|| "réponse non JSON".to_string())?;
    let end = trimmed.rfind('}').ok_or_else(|| "réponse non JSON".to_string())?;
    if end < start {
        return Err("réponse non JSON".to_string());
    }
    let v: Value = serde_json::from_str(&trimmed[start..=end]).map_err(|_| "réponse non JSON".to_string())?;

    let intent = v["intent"].as_str().unwrap_or("none").to_string();
    let kinds: Vec<String> = v["kinds"]
        .as_array()
        .map(|arr| {
            arr.iter()
                .filter_map(Value::as_str)
                .filter(|k| matches!(*k, "live" | "program" | "movie" | "series"))
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default();

    let time_hint = v["time_hint"].as_str().map(str::to_string);
    let genres: Vec<String> = v["genres"]
        .as_array()
        .map(|arr| arr.iter().filter_map(Value::as_str).map(str::to_string).collect())
        .unwrap_or_default();
    let people: Vec<String> = v["people"]
        .as_array()
        .map(|arr| arr.iter().filter_map(Value::as_str).map(str::to_string).collect())
        .unwrap_or_default();

    let year_from = v["year_from"].as_i64().map(|y| y as i32);
    let year_to = v["year_to"].as_i64().map(|y| y as i32);
    let languages: Vec<String> = v["languages"]
        .as_array()
        .map(|arr| arr.iter().filter_map(Value::as_str).map(str::to_string).collect())
        .unwrap_or_default();

    let similar_to = v["similar_to"].as_str().map(str::to_string);
    let query_rewrite = v["query_rewrite"].as_str().map(str::to_string);

    let title_guesses: Vec<TitleGuess> = v["title_guesses"]
        .as_array()
        .map(|arr| {
            arr.iter()
                .filter_map(|g| {
                    let title = clean_text(g["title"].as_str()?, MAX_GUESS_CHARS);
                    if title.is_empty() {
                        return None;
                    }
                    let year = g["year"].as_u64().map(|y| y as u32);
                    Some(TitleGuess { title, year })
                })
                .take(MAX_GUESSES)
                .collect()
        })
        .unwrap_or_default();

    let reply = v["reply"].as_str().map(clean_reply).unwrap_or_default();

    Ok(SearchUnderstanding {
        intent,
        kinds,
        time_hint,
        genres,
        people,
        year_from,
        year_to,
        languages,
        similar_to,
        query_rewrite,
        title_guesses,
        reply,
    })
}

fn sanitize_reason(raw: &str) -> Option<String> {
    let text = clean_text(raw, 200);
    let lower = text.to_lowercase();
    if text.is_empty() || lower.contains("http") || lower.contains("www.") || lower.contains("://") {
        return None;
    }
    Some(text.chars().take(MAX_RECO_REASON_CHARS).collect::<String>().trim().to_string())
}

pub fn validate_recommend(
    text: &str,
    expected_kind: &str,
    candidate_ids: &[String],
) -> Result<RecoValidationResult, String> {
    let trimmed = text.trim();
    let start = trimmed.find('{').ok_or_else(|| "réponse non JSON".to_string())?;
    let end = trimmed.rfind('}').ok_or_else(|| "réponse non JSON".to_string())?;
    if end < start {
        return Err("réponse non JSON".to_string());
    }
    let v: Value = serde_json::from_str(&trimmed[start..=end]).map_err(|_| "réponse non JSON".to_string())?;

    if v["kind"].as_str() != Some(expected_kind) {
        return Err("type de la réponse différent de celui demandé".to_string());
    }
    let confidence = v["confidence"].as_f64().unwrap_or(0.0);
    if confidence < MIN_RECO_CONFIDENCE {
        return Err(format!("confiance trop faible ({confidence:.2})"));
    }

    let id_set: HashSet<&str> = candidate_ids.iter().map(String::as_str).collect();
    let mut seen = HashSet::new();
    let mut picks = Vec::new();

    for p in v["picks"].as_array().cloned().unwrap_or_default() {
        let Some(id) = p["id"].as_str() else { continue };
        let trimmed_id = id.trim();
        if !id_set.contains(trimmed_id) {
            continue;
        }
        if !seen.insert(trimmed_id.to_string()) {
            continue;
        }
        let reason = p["reason"].as_str().and_then(sanitize_reason);
        picks.push(RecoValidationPick {
            id: trimmed_id.to_string(),
            reason,
        });
        if picks.len() >= MAX_RECO_PICKS {
            break;
        }
    }

    if picks.is_empty() {
        return Err("aucun identifiant valide dans la réponse".to_string());
    }

    let discover: Vec<TitleGuess> = v["discover"]
        .as_array()
        .cloned()
        .unwrap_or_default()
        .iter()
        .filter_map(|g| {
            let title = clean_text(g["title"].as_str()?, MAX_GUESS_CHARS);
            if title.is_empty() {
                return None;
            }
            let year = g["year"].as_u64().map(|y| y as u32);
            Some(TitleGuess { title, year })
        })
        .take(MAX_RECO_DISCOVER)
        .collect();

    Ok(RecoValidationResult {
        kind: expected_kind.to_string(),
        picks,
        discover,
        confidence,
    })
}

