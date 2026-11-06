use crate::search::fuzzy::match_edits;
use crate::search::query_parser::ParsedQuery;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SearchCandidate {
    pub id: i64,
    pub name: String,
    pub name_clean: String,
    pub kind: String,
    pub group_title: Option<String>,
    pub year: Option<u32>,
    pub is_favorite: bool,
    pub logo_url: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RankedSearchResult {
    pub candidate: SearchCandidate,
    pub score: f64,
}

pub fn rank_candidates(query: &ParsedQuery, candidates: &[SearchCandidate]) -> Vec<RankedSearchResult> {
    let mut results: Vec<RankedSearchResult> = candidates
        .iter()
        .filter_map(|c| {
            let score = score_candidate(query, c)?;
            Some(RankedSearchResult {
                candidate: c.clone(),
                score,
            })
        })
        .collect();

    results.sort_by(|a, b| b.score.partial_cmp(&a.score).unwrap_or(std::cmp::Ordering::Equal));
    results
}

fn score_candidate(query: &ParsedQuery, c: &SearchCandidate) -> Option<f64> {
    if !query.kinds.is_empty() {
        let matches_kind = query.kinds.iter().any(|k| match k {
            crate::search::query_parser::Kind::Live => c.kind == "live",
            crate::search::query_parser::Kind::Movie => c.kind == "movie",
            crate::search::query_parser::Kind::Series => c.kind == "series" || c.kind == "episode",
            crate::search::query_parser::Kind::Program => c.kind == "live",
        });
        if !matches_kind {
            return None;
        }
    }

    let mut score = 0.0;

    let title_words: Vec<String> = c
        .name_clean
        .split_whitespace()
        .map(|w| w.to_lowercase())
        .collect();

    if !query.terms.is_empty() {
        if let Some(edits) = match_edits(&query.terms, &title_words) {
            score += (10.0 - (edits as f64) * 2.5).max(1.0);
        } else {
            // Check group title
            let group_words: Vec<String> = c
                .group_title
                .as_deref()
                .unwrap_or("")
                .split_whitespace()
                .map(|w| w.to_lowercase())
                .collect();
            let edits = match_edits(&query.terms, &group_words)?;
            score += (6.0 - (edits as f64) * 2.0).max(0.5);
        }
    } else {
        score += 5.0;
    }

    if let (Some(y), Some(qy_from)) = (c.year, query.year_from) {
        if let Some(qy_to) = query.year_to {
            if y >= qy_from && y <= qy_to {
                score += 3.0;
            }
        } else if y == qy_from {
            score += 3.0;
        }
    }

    if c.is_favorite {
        score += 2.0;
    }

    Some(score)
}
