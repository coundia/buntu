use crate::recommend::taste::Taste;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CandidateItem {
    pub id: i64,
    pub name: String,
    pub name_clean: String,
    pub kind: String,
    pub group_title: Option<String>,
    pub year: Option<u32>,
    pub imdb_rating: Option<f64>,
    pub features: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScoredItem {
    pub item: CandidateItem,
    pub score: f64,
    pub reason: String,
}

pub fn score_candidates(taste: &Taste, items: &[CandidateItem]) -> Vec<ScoredItem> {
    let mut scored: Vec<ScoredItem> = items
        .iter()
        .map(|item| {
            let affinity = taste.score(&item.features);
            let rating_boost = item.imdb_rating.map(|r| r / 10.0 * 2.0).unwrap_or(0.0);
            let score = affinity + rating_boost;
            let reason = taste
                .best_feature(&item.features)
                .map(|(f, _)| format!("Parce que vous aimez {}", f))
                .unwrap_or_else(|| "Recommandé pour vous".to_string());
            ScoredItem {
                item: item.clone(),
                score,
                reason,
            }
        })
        .collect();

    scored.sort_by(|a, b| b.score.partial_cmp(&a.score).unwrap_or(std::cmp::Ordering::Equal));
    scored
}
