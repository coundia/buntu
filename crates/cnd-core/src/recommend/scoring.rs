use crate::db::recommend_repo::CachedItemMetadata;
use crate::db::IptvItemRecord;
use crate::recommend::saga::normalize_root_key;
use std::collections::{HashMap, HashSet};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum RecommendationReasonKind {
    SagaNext,
    SagaMember,
    NextEpisode,
    SameDirector,
    SameActor,
    SimilarGenre,
    Resume,
    LiveNow,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SagaPosition {
    pub index: u32,
    pub total: u32,
}

#[derive(Debug, Clone)]
pub struct ScoredCandidate {
    pub item: IptvItemRecord,
    pub reason_kind: RecommendationReasonKind,
    pub reason_text: String,
    pub score: f64,
    pub saga_position: Option<SagaPosition>,
    pub already_watched: bool,
}

/// Deduplicates multiple releases of the same movie or episode (e.g. 4K, 1080p, VF, VOSTFR).
/// Groups by imdb_id when available, otherwise by normalized clean title and year.
pub fn deduplicate_versions(
    items: Vec<IptvItemRecord>,
    preferred_ext: Option<&str>,
) -> Vec<IptvItemRecord> {
    let mut groups: HashMap<String, Vec<IptvItemRecord>> = HashMap::new();
    let mut order = Vec::new();

    for item in items {
        let key = if let Some(imdb) = &item.imdb_id {
            if !imdb.trim().is_empty() {
                format!("imdb:{}", imdb.trim().to_lowercase())
            } else {
                format!("title:{}:{}", normalize_root_key(&item.name_clean), item.year.unwrap_or(0))
            }
        } else {
            format!("title:{}:{}", normalize_root_key(&item.name_clean), item.year.unwrap_or(0))
        };

        if !groups.contains_key(&key) {
            order.push(key.clone());
        }
        groups.entry(key).or_default().push(item);
    }

    let mut result = Vec::with_capacity(order.len());
    for key in order {
        if let Some(list) = groups.remove(&key) {
            let best = select_best_version(list, preferred_ext);
            result.push(best);
        }
    }
    result
}

fn select_best_version(mut versions: Vec<IptvItemRecord>, preferred_ext: Option<&str>) -> IptvItemRecord {
    if versions.len() == 1 {
        return versions.remove(0);
    }

    // Sort versions by preference:
    // 1. Not broken
    // 2. Favorite
    // 3. Preferred container extension matching current stream
    // 4. Highest ID (newest entry in DB)
    versions.sort_by(|a, b| {
        let a_broken = a.is_broken;
        let b_broken = b.is_broken;
        if a_broken != b_broken {
            return a_broken.cmp(&b_broken); // false (not broken) comes first
        }

        if a.is_favorite != b.is_favorite {
            return b.is_favorite.cmp(&a.is_favorite); // true comes first
        }

        if let Some(pref) = preferred_ext {
            let a_match = a.container_ext.as_deref().map(|e| e.eq_ignore_ascii_case(pref)).unwrap_or(false);
            let b_match = b.container_ext.as_deref().map(|e| e.eq_ignore_ascii_case(pref)).unwrap_or(false);
            if a_match != b_match {
                return b_match.cmp(&a_match);
            }
        }

        b.id.cmp(&a.id)
    });

    versions.remove(0)
}

/// Evaluates content similarity between a target item and candidate item using cached OMDb metadata.
pub fn score_metadata_similarity(
    target_meta: &CachedItemMetadata,
    candidate_meta: &CachedItemMetadata,
) -> (f64, Option<RecommendationReasonKind>, Option<String>) {
    let mut score = 0.0;
    let mut best_reason = None;
    let mut best_text = None;

    // Director match (+150)
    if let (Some(d1), Some(d2)) = (&target_meta.director, &candidate_meta.director) {
        let dir1 = d1.trim().to_lowercase();
        let dir2 = d2.trim().to_lowercase();
        if !dir1.is_empty() && dir1 != "n/a" && (dir1 == dir2 || dir2.contains(&dir1) || dir1.contains(&dir2)) {
            score += 150.0;
            best_reason = Some(RecommendationReasonKind::SameDirector);
            best_text = Some(format!("Même réalisateur · {}", d1.trim()));
        }
    }

    // Actors overlap (up to +150, 50 per shared actor)
    if let (Some(a1), Some(a2)) = (&target_meta.actors, &candidate_meta.actors) {
        let set1: HashSet<String> = a1.split(',').map(|s| s.trim().to_lowercase()).filter(|s| !s.is_empty() && s != "n/a").collect();
        let mut shared_actor = None;
        let mut actor_overlap = 0;
        for act in a2.split(',').map(|s| s.trim().to_lowercase()).filter(|s| !s.is_empty() && s != "n/a") {
            if set1.contains(&act) {
                actor_overlap += 1;
                if shared_actor.is_none() {
                    shared_actor = Some(act);
                }
            }
        }
        if actor_overlap > 0 {
            let points = (actor_overlap as f64 * 50.0).min(150.0);
            score += points;
            if best_reason.is_none() {
                best_reason = Some(RecommendationReasonKind::SameActor);
                if let Some(act) = shared_actor {
                    let cap = capitalize_words(&act);
                    best_text = Some(format!("Avec {cap}"));
                }
            }
        }
    }

    // Genres overlap (up to +120, 30 per shared genre)
    if let (Some(g1), Some(g2)) = (&target_meta.genres, &candidate_meta.genres) {
        let set1: HashSet<String> = g1.split(',').map(|s| s.trim().to_lowercase()).filter(|s| !s.is_empty() && s != "n/a").collect();
        let mut genre_overlap = 0;
        let mut first_genre = None;
        for g in g2.split(',').map(|s| s.trim().to_lowercase()).filter(|s| !s.is_empty() && s != "n/a") {
            if set1.contains(&g) {
                genre_overlap += 1;
                if first_genre.is_none() {
                    first_genre = Some(g);
                }
            }
        }
        if genre_overlap > 0 {
            let points = (genre_overlap as f64 * 30.0).min(120.0);
            score += points;
            if best_reason.is_none() {
                best_reason = Some(RecommendationReasonKind::SimilarGenre);
                best_text = Some("Contenu similaire".to_string());
            }
        }
    }

    (score, best_reason, best_text)
}

fn capitalize_words(s: &str) -> String {
    s.split_whitespace()
        .map(|w| {
            let mut chars = w.chars();
            match chars.next() {
                None => String::new(),
                Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

/// Enforces diversity: no more than 3 consecutive cards with the same reason kind
/// (outside of saga continuation).
pub fn enforce_diversity(mut candidates: Vec<ScoredCandidate>) -> Vec<ScoredCandidate> {
    if candidates.len() <= 3 {
        return candidates;
    }

    let mut result: Vec<ScoredCandidate> = Vec::with_capacity(candidates.len());

    while !candidates.is_empty() {
        let n = result.len();
        let needs_diversity = n >= 3
            && result[n - 1].reason_kind == result[n - 2].reason_kind
            && result[n - 2].reason_kind == result[n - 3].reason_kind
            && result[n - 1].reason_kind != RecommendationReasonKind::SagaNext
            && result[n - 1].reason_kind != RecommendationReasonKind::SagaMember
            && result[n - 1].reason_kind != RecommendationReasonKind::NextEpisode;

        if needs_diversity {
            let last_kind = result[n - 1].reason_kind;
            // Find first candidate with a different reason_kind
            if let Some(pos) = candidates.iter().position(|c| c.reason_kind != last_kind) {
                result.push(candidates.remove(pos));
            } else {
                // No alternative available, just append next
                result.push(candidates.remove(0));
            }
        } else {
            result.push(candidates.remove(0));
        }
    }

    result
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dummy_item(id: i64, name: &str, imdb: Option<&str>, year: Option<u32>) -> IptvItemRecord {
        IptvItemRecord {
            id,
            source_id: 1,
            series_id: None,
            stable_hash: format!("hash_{id}"),
            kind: "movie".to_string(),
            season_num: None,
            episode_num: None,
            name: name.to_string(),
            name_clean: name.to_string(),
            year,
            group_title: Some("Cinema".to_string()),
            tvg_id: None,
            logo_url: None,
            chno: None,
            host: "test.cdn".to_string(),
            container_ext: Some("mp4".to_string()),
            stream_url: format!("http://test.cdn/{id}.mp4"),
            user_agent: None,
            referer: None,
            headers_json: None,
            catchup_type: None,
            catchup_source: None,
            catchup_days: None,
            plot: None,
            imdb_id: imdb.map(|s| s.to_string()),
            imdb_rating: Some(8.0),
            is_favorite: false,
            is_broken: false,
            resume_position_ms: 0,
            duration_ms: 0,
            is_completed: false,
        }
    }

    #[test]
    fn test_deduplicate_versions_by_imdb_id() {
        let v1 = dummy_item(1, "Avengers 4K VF", Some("tt4154796"), Some(2019));
        let mut v2 = dummy_item(2, "Avengers 1080p VOSTFR", Some("tt4154796"), Some(2019));
        v2.is_favorite = true; // Preferred

        let deduped = deduplicate_versions(vec![v1, v2], Some("mp4"));
        assert_eq!(deduped.len(), 1);
        assert_eq!(deduped[0].id, 2);
    }

    #[test]
    fn test_enforce_diversity() {
        let items = (0..6)
            .map(|i| ScoredCandidate {
                item: dummy_item(i, &format!("Movie {i}"), None, None),
                reason_kind: if i == 4 { RecommendationReasonKind::SameDirector } else { RecommendationReasonKind::SimilarGenre },
                reason_text: "Reason".to_string(),
                score: 100.0 - (i as f64),
                saga_position: None,
                already_watched: false,
            })
            .collect();

        let diversified = enforce_diversity(items);
        assert_eq!(diversified.len(), 6);
        // The 4th item (index 3) must NOT have SimilarGenre because the first 3 were SimilarGenre
        assert_eq!(diversified[3].reason_kind, RecommendationReasonKind::SameDirector);
    }
}
