use crate::ai::intent::{AiProviderConfig, AiProviderKind};
use crate::ai::providers::{self, RequestMode};
use crate::db::recommend_repo::{SagaMemberRecord, SagaRecord};
use crate::db::{chrono_now_ts, IptvItemRecord};
use crate::CndEngine;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::time::Duration;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LlmSagaResponse {
    pub universe: Option<String>,
    pub saga: Option<String>,
    pub story_order: Vec<String>,
    pub release_order: Vec<String>,
    #[serde(default)]
    pub missing_titles: Vec<String>,
    pub confidence: f64,
}

const MAX_CANDIDATES: usize = 150;
const MAX_MISSING_TITLES: usize = 20;
const MAX_TITLE_LEN: usize = 80;
const LLM_SAGA_TIMEOUT: Duration = Duration::from_secs(8);

/// Calls the user-configured LLM provider to recognize universe, saga, and story chronology.
pub async fn resolve_saga_with_llm(
    engine: &CndEngine,
    config: &AiProviderConfig,
    current_movie: &IptvItemRecord,
    candidates: &[IptvItemRecord],
) -> Result<Option<(SagaRecord, Vec<SagaMemberRecord>)>, String> {
    if config.kind == AiProviderKind::LocalOnly {
        return Ok(None);
    }

    // Build bounded candidate map with opaque IDs (c1, c2, ...)
    let mut opaque_to_item = HashMap::new();
    let mut candidate_lines = Vec::new();

    // Ensure current movie is in candidate list as c1
    opaque_to_item.insert("c1".to_string(), current_movie.clone());
    candidate_lines.push(format!("- id: c1 | title: {} | year: {:?}", current_movie.name_clean, current_movie.year));

    let mut counter = 2;
    for cand in candidates {
        if cand.id == current_movie.id || cand.stable_hash == current_movie.stable_hash {
            continue;
        }
        if counter > MAX_CANDIDATES {
            break;
        }
        let cid = format!("c{counter}");
        candidate_lines.push(format!("- id: {cid} | title: {} | year: {:?}", cand.name_clean, cand.year));
        opaque_to_item.insert(cid, cand.clone());
        counter += 1;
    }

    let system_prompt = "You are an expert film franchise chronologist. Return ONLY strict JSON matching the schema, with no markdown fences.";
    let user_prompt = format!(
        "Identify if the target film belongs to a franchise, saga, or shared cinematic universe (e.g. Marvel Cinematic Universe, Star Wars, Harry Potter, James Bond, Fast & Furious, DC, Mission Impossible, etc.). \
         Select and order ONLY the candidate IDs that belong to this franchise into story_order (chronological timeline within the story) and release_order (theatrical release date). Exclude unrelated candidate IDs. Both orders MUST include c1 (the target film). \
         List up to 20 notable missing franchise titles that are absent from the candidates. \
         Target film: id=c1, title='{}', year={:?}. \
         Candidates:\n{}\n\
         Respond with strict JSON: {{\"universe\": string|null, \"saga\": string|null, \"story_order\": [ids], \"release_order\": [ids], \"missing_titles\": [string], \"confidence\": 0.0-1.0}}",
        current_movie.name_clean,
        current_movie.year,
        candidate_lines.join("\n")
    );

    let request = providers::build_request(config, system_prompt, &user_prompt, RequestMode::Light)?;
    let client = engine.http_pool.client().map_err(|e| e.to_string())?;

    let mut builder = client
        .post(&request.url)
        .timeout(LLM_SAGA_TIMEOUT)
        .json(&request.body);

    for (k, v) in &request.headers {
        builder = builder.header(*k, v.as_str());
    }

    let res = builder.send().await.map_err(|e| format!("LLM request failed: {e}"))?;
    if !res.status().is_success() {
        return Err(format!("LLM returned status {}", res.status()));
    }

    let body = res.text().await.map_err(|e| e.to_string())?;
    let json_val: serde_json::Value = serde_json::from_str(&body).map_err(|_| "LLM response is not valid JSON".to_string())?;
    let text = providers::extract_text(config.kind, &json_val)?;

    let parsed = parse_and_validate_llm_response(&text, &opaque_to_item, "c1")?;
    let now = chrono_now_ts();

    let saga_name = parsed.universe.clone().or_else(|| parsed.saga.clone()).unwrap_or_else(|| current_movie.name_clean.clone());
    let saga_key = format!("llm:{}", crate::recommend::saga::normalize_root_key(&saga_name));
    let level = if parsed.universe.is_some() { "universe" } else { "saga" };

    let missing_json = if !parsed.missing_titles.is_empty() {
        serde_json::to_string(&parsed.missing_titles).ok()
    } else {
        None
    };

    let saga_record = SagaRecord {
        saga_key: saga_key.clone(),
        name: saga_name,
        level: level.to_string(),
        source: "llm".to_string(),
        confidence: parsed.confidence,
        fetched_at: now,
        missing_titles: missing_json,
    };

    let mut members = Vec::new();
    let mut seen_items = HashSet::new();

    // Map story and release order indices
    for (rel_idx, id) in parsed.release_order.iter().enumerate() {
        if let Some(item) = opaque_to_item.get(id) {
            let work_key = item.imdb_id.clone().filter(|s| !s.trim().is_empty()).unwrap_or_else(|| {
                format!("{}:{}", crate::recommend::saga::normalize_root_key(&item.name_clean), item.year.unwrap_or(0))
            });
            if seen_items.insert(work_key.clone()) {
                let story_idx = parsed.story_order.iter().position(|sid| sid == id).map(|p| p as i32);
                members.push(SagaMemberRecord {
                    saga_key: saga_key.clone(),
                    work_key,
                    release_index: rel_idx as i32,
                    story_index: story_idx,
                });
            }
        }
    }

    Ok(Some((saga_record, members)))
}

/// Validates raw text from LLM against schema and candidate IDs.
pub fn parse_and_validate_llm_response(
    raw_text: &str,
    valid_candidates: &HashMap<String, IptvItemRecord>,
    target_id: &str,
) -> Result<LlmSagaResponse, String> {
    // Extract JSON block if wrapped in markdown code fence
    let json_str = if let Some(start) = raw_text.find("```json") {
        let after = &raw_text[start + 7..];
        if let Some(end) = after.find("```") {
            after[..end].trim()
        } else {
            after.trim()
        }
    } else if let Some(start) = raw_text.find('{') {
        if let Some(end) = raw_text.rfind('}') {
            &raw_text[start..=end]
        } else {
            raw_text.trim()
        }
    } else {
        raw_text.trim()
    };

    let resp: LlmSagaResponse = serde_json::from_str(json_str)
        .map_err(|e| format!("Impossible de décoder le JSON de la saga : {e}"))?;

    if resp.confidence < 0.6 {
        return Err(format!("Confiance insuffisante ({})", resp.confidence));
    }

    // Filter story_order and release_order to only include valid candidate IDs
    let mut valid_story = Vec::new();
    for id in resp.story_order {
        if valid_candidates.contains_key(&id) && !valid_story.contains(&id) {
            valid_story.push(id);
        }
    }

    let mut valid_release = Vec::new();
    for id in resp.release_order {
        if valid_candidates.contains_key(&id) && !valid_release.contains(&id) {
            valid_release.push(id);
        }
    }

    // Must contain target movie
    if !valid_story.contains(&target_id.to_string()) && !valid_release.contains(&target_id.to_string()) {
        return Err("Le film en cours est absent de l'ordre retourné".to_string());
    }

    // Ensure both orders are non-empty
    if valid_story.is_empty() {
        valid_story = valid_release.clone();
    }
    if valid_release.is_empty() {
        valid_release = valid_story.clone();
    }

    let missing = resp
        .missing_titles
        .into_iter()
        .take(MAX_MISSING_TITLES)
        .map(|s| s.chars().take(MAX_TITLE_LEN).collect::<String>())
        .collect();

    Ok(LlmSagaResponse {
        universe: resp.universe,
        saga: resp.saga,
        story_order: valid_story,
        release_order: valid_release,
        missing_titles: missing,
        confidence: resp.confidence,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_validate_llm_response() {
        let mut candidates = HashMap::new();
        let dummy = IptvItemRecord {
            id: 1,
            source_id: 1,
            series_id: None,
            stable_hash: "h1".to_string(),
            kind: "movie".to_string(),
            season_num: None,
            episode_num: None,
            name: "Avengers".to_string(),
            name_clean: "Avengers".to_string(),
            year: Some(2012),
            group_title: None,
            tvg_id: None,
            logo_url: None,
            chno: None,
            host: "h".to_string(),
            container_ext: None,
            stream_url: "url".to_string(),
            user_agent: None,
            referer: None,
            headers_json: None,
            catchup_type: None,
            catchup_source: None,
            catchup_days: None,
            plot: None,
            imdb_id: None,
            imdb_rating: None,
            is_favorite: false,
            is_broken: false,
            resume_position_ms: 0,
            duration_ms: 0,
            is_completed: false,
        };
        candidates.insert("c1".to_string(), dummy.clone());
        candidates.insert("c2".to_string(), dummy.clone());

        let raw = r#"{
            "universe": "Marvel Cinematic Universe",
            "saga": "Avengers",
            "story_order": ["c1", "c2", "c999_invented"],
            "release_order": ["c1", "c2"],
            "missing_titles": ["Iron Man 3"],
            "confidence": 0.95
        }"#;

        let res = parse_and_validate_llm_response(raw, &candidates, "c1").unwrap();
        assert_eq!(res.universe.as_deref(), Some("Marvel Cinematic Universe"));
        assert_eq!(res.story_order, vec!["c1", "c2"]); // c999_invented dropped
        assert_eq!(res.missing_titles, vec!["Iron Man 3"]);
    }
}
