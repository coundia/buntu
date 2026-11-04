pub mod llm_saga;
pub mod saga;
pub mod scoring;

use crate::ai::intent::{AiProviderConfig, AiProviderKind};
use crate::db::IptvItemRecord;
use crate::recommend::saga::{known_saga_order, parse_saga_title, universe_keywords_for};
pub use crate::recommend::scoring::{RecommendationReasonKind, SagaPosition, ScoredCandidate};
use crate::recommend::scoring::{deduplicate_versions, enforce_diversity, score_metadata_similarity};
use crate::{CndEngine, CndError};
use std::collections::HashSet;

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum RecommendationContext {
    Playing,
    Ending,
    Live,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SagaOrderPreference {
    StoryChronology,
    ReleaseOrder,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct Recommendation {
    pub item: IptvItemRecord,
    pub reason_kind: RecommendationReasonKind,
    pub reason_text: String,
    pub saga_position: Option<SagaPosition>,
    pub already_watched: bool,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct SagaInfo {
    pub saga_key: String,
    pub name: String,
    pub level: String,
    pub order_kind: String,
    pub members: Vec<IptvItemRecord>,
    pub missing_titles: Vec<String>,
}

impl CndEngine {
    /// Returns recommendations for the given media item, adapted to playback context.
    pub fn recommendations_for_impl(
        &self,
        item_id: i64,
        context: RecommendationContext,
        limit: u32,
    ) -> Result<Vec<Recommendation>, CndError> {
        let Some(item) = self.db.get_item_by_id(item_id)? else {
            return Ok(Vec::new());
        };

        let profile_id = self.active_profile_id.load(std::sync::atomic::Ordering::Relaxed);
        let dismissed = self.db.get_dismissed_hashes(profile_id).unwrap_or_default();

        let mut scored_list = match item.kind.as_str() {
            "live" => self.recommend_live(&item, &dismissed)?,
            "episode" => self.recommend_episode(&item, &dismissed)?,
            _ => self.recommend_movie(&item, &dismissed, SagaOrderPreference::StoryChronology)?,
        };

        // Filter out current item and dismissed
        scored_list.retain(|c| {
            c.item.id != item.id
                && c.item.stable_hash != item.stable_hash
                && !dismissed.contains(&c.item.stable_hash)
        });

        // In Ending context, prioritize saga continuation or next episode at position 0
        if context == RecommendationContext::Ending {
            scored_list.sort_by(|a, b| {
                let a_pri = a.reason_kind == RecommendationReasonKind::SagaNext || a.reason_kind == RecommendationReasonKind::NextEpisode;
                let b_pri = b.reason_kind == RecommendationReasonKind::SagaNext || b.reason_kind == RecommendationReasonKind::NextEpisode;
                if a_pri != b_pri {
                    return b_pri.cmp(&a_pri);
                }
                b.score.partial_cmp(&a.score).unwrap_or(std::cmp::Ordering::Equal)
            });
        }

        // Enforce diversity
        let diverse = enforce_diversity(scored_list);

        let final_list: Vec<Recommendation> = diverse
            .into_iter()
            .take(limit as usize)
            .map(|sc| Recommendation {
                item: sc.item,
                reason_kind: sc.reason_kind,
                reason_text: sc.reason_text,
                saga_position: sc.saga_position,
                already_watched: sc.already_watched,
            })
            .collect();

        Ok(final_list)
    }

    /// Single next-up recommendation for the end-of-playback card.
    pub fn next_up_impl(&self, item_id: i64) -> Result<Option<Recommendation>, CndError> {
        let recs = self.recommendations_for_impl(item_id, RecommendationContext::Ending, 1)?;
        Ok(recs.into_iter().next())
    }

    /// Marks an item as "Pas intéressé" for the active profile.
    pub fn dismiss_recommendation_impl(&self, stable_hash: String) -> Result<(), CndError> {
        let profile_id = self.active_profile_id.load(std::sync::atomic::Ordering::Relaxed);
        self.db.add_recommendation_dismissal(profile_id, &stable_hash)?;
        Ok(())
    }

    /// Resets all dismissed recommendations for the active profile.
    pub fn reset_dismissed_recommendations_impl(&self) -> Result<(), CndError> {
        let profile_id = self.active_profile_id.load(std::sync::atomic::Ordering::Relaxed);
        self.db.reset_recommendation_dismissals(profile_id)?;
        Ok(())
    }

    /// Returns saga details and members for the given item.
    pub fn saga_for_impl(&self, item_id: i64) -> Result<Option<SagaInfo>, CndError> {
        let Some(item) = self.db.get_item_by_id(item_id)? else {
            return Ok(None);
        };
        if item.kind != "movie" {
            return Ok(None);
        }

        let parsed = parse_saga_title(&item.name_clean, item.year);
        let work_key = item.imdb_id.clone().filter(|s| !s.trim().is_empty()).unwrap_or_else(|| {
            format!("{}:{}", parsed.root, item.year.unwrap_or(0))
        });

        // Check DB saga cache
        if let Some((saga_rec, members)) = self.db.find_saga_for_work(&work_key)? {
            let mut member_items = Vec::new();
            for m in &members {
                if let Ok(Some(cand)) = self.db.find_item_by_work_key(&m.work_key) {
                    if !member_items.iter().any(|i: &IptvItemRecord| i.id == cand.id) {
                        member_items.push(cand);
                    }
                }
            }
            let missing: Vec<String> = saga_rec
                .missing_titles
                .as_deref()
                .and_then(|json| serde_json::from_str(json).ok())
                .unwrap_or_default();

            let order_kind = if saga_rec.level == "universe" { "chronologie de l'histoire".to_string() } else { "ordre de sortie".to_string() };
            return Ok(Some(SagaInfo {
                saga_key: saga_rec.saga_key,
                name: saga_rec.name,
                level: saga_rec.level,
                order_kind,
                members: member_items,
                missing_titles: missing,
            }));
        }

        // Local saga root discovery
        let candidates = self.db.load_recommendation_candidates("movie", None, 300)?;
        let mut matching_members = Vec::new();

        for cand in candidates {
            let cand_parsed = parse_saga_title(&cand.name_clean, cand.year);
            if cand_parsed.root == parsed.root {
                matching_members.push(cand);
            }
        }

        if matching_members.len() >= 2 {
            // Sort by sequence number or year
            matching_members.sort_by_key(|m| {
                let p = parse_saga_title(&m.name_clean, m.year);
                let num = p.number.or_else(|| known_saga_order(&p.root, p.subtitle.as_deref().unwrap_or(""))).unwrap_or(1);
                (num, p.year.unwrap_or(0))
            });

            return Ok(Some(SagaInfo {
                saga_key: format!("local:{}", parsed.root),
                name: capitalize_words(&parsed.root),
                level: "saga".to_string(),
                order_kind: "ordre de sortie".to_string(),
                members: deduplicate_versions(matching_members, item.container_ext.as_deref()),
                missing_titles: Vec::new(),
            }));
        }

        Ok(None)
    }

    /// Asynchronously queries the user's AI provider to discover and organize saga chronology.
    pub async fn resolve_saga_with_ai_impl(
        &self,
        item_id: i64,
        config: AiProviderConfig,
    ) -> Result<Option<SagaInfo>, CndError> {
        let Some(item) = self.db.get_item_by_id(item_id)? else {
            return Ok(None);
        };
        if item.kind != "movie" {
            return Ok(None);
        }

        if config.kind == AiProviderKind::LocalOnly {
            return Ok(None);
        }

        let parsed = parse_saga_title(&item.name_clean, item.year);
        let universe_kw = universe_keywords_for(&parsed.root, &item.name_clean);
        let candidates = self.db.load_movie_candidates_for_item(&item, &parsed.root, universe_kw, 150)?;
        match llm_saga::resolve_saga_with_llm(self, &config, &item, &candidates).await {
            Ok(Some((saga_rec, members))) => {
                let _ = self.db.save_saga(&saga_rec, &members);
                self.saga_for_impl(item_id)
            }
            Ok(None) => Ok(None),
            Err(e) => {
                self.telemetry.warn(
                    "RECO",
                    format!("Échec reconnaissance IA de saga : {e}"),
                );
                Ok(None)
            }
        }
    }

    // MARK: - Private Recommendation Helpers

    fn recommend_movie(
        &self,
        current: &IptvItemRecord,
        dismissed: &HashSet<String>,
        order_pref: SagaOrderPreference,
    ) -> Result<Vec<ScoredCandidate>, CndError> {
        let mut scored = Vec::new();
        let parsed = parse_saga_title(&current.name_clean, current.year);
        let universe_kw = universe_keywords_for(&parsed.root, &current.name_clean);

        // Preselect candidates related to this movie (franchise root, universe, category, top-rated)
        let candidates = self.db.load_movie_candidates_for_item(current, &parsed.root, universe_kw, 100)?;
        let deduped_candidates = deduplicate_versions(candidates, current.container_ext.as_deref());

        let work_key = current.imdb_id.clone().filter(|s| !s.trim().is_empty()).unwrap_or_else(|| {
            format!("{}:{}", parsed.root, current.year.unwrap_or(0))
        });

        // 1. Check if saga is in DB (either from LLM resolution or cached)
        let mut db_saga_used = false;
        if let Ok(Some((saga_rec, mut members))) = self.db.find_saga_for_work(&work_key) {
            if order_pref == SagaOrderPreference::StoryChronology {
                members.sort_by_key(|m| m.story_index.unwrap_or(m.release_index));
            } else {
                members.sort_by_key(|m| m.release_index);
            }

            let current_pos = members.iter().position(|m| m.work_key == work_key);
            let total_members = members.len() as u32;

            for (idx, m) in members.iter().enumerate() {
                if m.work_key == work_key {
                    continue;
                }
                if let Ok(Some(item)) = self.db.find_item_by_work_key(&m.work_key) {
                    if item.id == current.id || item.stable_hash == current.stable_hash || dismissed.contains(&item.stable_hash) {
                        continue;
                    }
                    if scored.iter().any(|s: &ScoredCandidate| s.item.id == item.id) {
                        continue;
                    }

                    let is_next = current_pos.is_some_and(|cp| idx == cp + 1);
                    let display_num = (idx + 1) as u32;
                    let pos = SagaPosition {
                        index: display_num,
                        total: total_members,
                    };

                    if is_next {
                        scored.push(ScoredCandidate {
                            item: item.clone(),
                            reason_kind: RecommendationReasonKind::SagaNext,
                            reason_text: format!("Suite de la saga {} · {}/{}", saga_rec.name, display_num, total_members),
                            score: 1000.0,
                            saga_position: Some(pos),
                            already_watched: item.is_completed,
                        });
                    } else {
                        scored.push(ScoredCandidate {
                            item: item.clone(),
                            reason_kind: RecommendationReasonKind::SagaMember,
                            reason_text: format!("Dans la même saga {} · {}/{}", saga_rec.name, display_num, total_members),
                            score: 850.0 - (idx as f64 * 2.0),
                            saga_position: Some(pos),
                            already_watched: item.is_completed,
                        });
                    }
                    db_saga_used = true;
                }
            }
        }

        // 2. Local saga detection if DB saga was not used
        if !db_saga_used {
            let mut saga_candidates = Vec::new();
            for cand in &deduped_candidates {
                if cand.id == current.id {
                    continue;
                }
                let cand_parsed = parse_saga_title(&cand.name_clean, cand.year);
                if cand_parsed.root == parsed.root {
                    saga_candidates.push((cand.clone(), cand_parsed));
                }
            }

            if !saga_candidates.is_empty() {
                let current_num = parsed
                    .number
                    .or_else(|| known_saga_order(&parsed.root, parsed.subtitle.as_deref().unwrap_or("")))
                    .unwrap_or(1);

                saga_candidates.sort_by_key(|(_, p)| {
                    let num = p.number.or_else(|| known_saga_order(&p.root, p.subtitle.as_deref().unwrap_or(""))).unwrap_or(1);
                    if order_pref == SagaOrderPreference::ReleaseOrder {
                        (p.year.unwrap_or(0), num)
                    } else {
                        (num, p.year.unwrap_or(0))
                    }
                });

                let total_saga = (saga_candidates.len() + 1) as u32;
                let mut next_found = false;
                for (cand, p) in &saga_candidates {
                    let num = p.number.or_else(|| known_saga_order(&p.root, p.subtitle.as_deref().unwrap_or(""))).unwrap_or(1);
                    let is_next = !next_found && (num > current_num || (num == current_num && p.year.unwrap_or(0) > current.year.unwrap_or(0)));

                    let pos = SagaPosition {
                        index: num,
                        total: total_saga,
                    };

                    if is_next {
                        next_found = true;
                        scored.push(ScoredCandidate {
                            item: cand.clone(),
                            reason_kind: RecommendationReasonKind::SagaNext,
                            reason_text: format!("Suite de la saga · {}/{}", num, total_saga),
                            score: 950.0,
                            saga_position: Some(pos),
                            already_watched: cand.is_completed,
                        });
                    } else {
                        scored.push(ScoredCandidate {
                            item: cand.clone(),
                            reason_kind: RecommendationReasonKind::SagaMember,
                            reason_text: format!("Dans la même saga · {}/{}", num, total_saga),
                            score: 800.0 - (num as f64 * 2.0),
                            saga_position: Some(pos),
                            already_watched: cand.is_completed,
                        });
                    }
                }
            }
        }

        // 2. In-progress resume candidates
        let in_progress = self.db.load_in_progress_candidates("movie", 5)?;
        for cand in in_progress {
            if cand.id != current.id && !dismissed.contains(&cand.stable_hash) {
                scored.push(ScoredCandidate {
                    item: cand,
                    reason_kind: RecommendationReasonKind::Resume,
                    reason_text: "Reprendre la lecture".to_string(),
                    score: 550.0,
                    saga_position: None,
                    already_watched: false,
                });
            }
        }

        // 3. Similar content via metadata cache
        let target_meta = self.db.get_metadata_for_item(current)?;
        for cand in deduped_candidates.iter().take(30) {
            if cand.id == current.id || scored.iter().any(|s| s.item.id == cand.id) {
                continue;
            }

            let mut base_score = 100.0;
            let mut reason_kind = RecommendationReasonKind::SimilarGenre;
            let mut reason_text = "Recommandé pour vous".to_string();

            if let Some(target) = &target_meta {
                if let Ok(Some(cand_meta)) = self.db.get_metadata_for_item(cand) {
                    let (sim_score, sim_reason, sim_text) = score_metadata_similarity(target, &cand_meta);
                    if sim_score > 0.0 {
                        base_score += sim_score;
                        if let Some(rk) = sim_reason {
                            reason_kind = rk;
                        }
                        if let Some(rt) = sim_text {
                            reason_text = rt;
                        }
                    }
                }
            } else if let (Some(g1), Some(g2)) = (&current.group_title, &cand.group_title) {
                if g1.eq_ignore_ascii_case(g2) {
                    base_score += 80.0;
                    reason_text = format!("Même catégorie · {}", g1);
                }
            }

            // IMDb rating booster
            if let Some(rating) = cand.imdb_rating {
                base_score += (rating / 10.0) * 20.0;
            }

            scored.push(ScoredCandidate {
                item: cand.clone(),
                reason_kind,
                reason_text,
                score: base_score,
                saga_position: None,
                already_watched: cand.is_completed,
            });
        }

        // Sort by score descending
        scored.sort_by(|a, b| b.score.partial_cmp(&a.score).unwrap_or(std::cmp::Ordering::Equal));
        Ok(scored)
    }

    fn recommend_episode(
        &self,
        current: &IptvItemRecord,
        dismissed: &HashSet<String>,
    ) -> Result<Vec<ScoredCandidate>, CndError> {
        let mut scored = Vec::new();

        // 1. Next episode of series
        if let Some(series_id) = current.series_id {
            let episodes = self.db.get_series_episodes(series_id, None)?;
            let current_season = current.season_num.unwrap_or(1);
            let current_ep = current.episode_num.unwrap_or(1);

            let mut next_ep = None;
            for ep in &episodes {
                let s = ep.season_num.unwrap_or(1);
                let e = ep.episode_num.unwrap_or(1);
                if s == current_season && e == current_ep + 1 {
                    next_ep = Some(ep.clone());
                    break;
                } else if s == current_season + 1 && e == 1 && next_ep.is_none() {
                    next_ep = Some(ep.clone());
                }
            }

            if let Some(next) = next_ep {
                let s = next.season_num.unwrap_or(1);
                let e = next.episode_num.unwrap_or(1);
                scored.push(ScoredCandidate {
                    item: next,
                    reason_kind: RecommendationReasonKind::NextEpisode,
                    reason_text: format!("Épisode suivant · S{s}:E{e}"),
                    score: 1000.0,
                    saga_position: None,
                    already_watched: false,
                });
            }
        }

        // 2. Resume other in-progress episodes
        let in_progress = self.db.load_in_progress_candidates("episode", 4)?;
        for cand in in_progress {
            if cand.id != current.id && !dismissed.contains(&cand.stable_hash) {
                scored.push(ScoredCandidate {
                    item: cand,
                    reason_kind: RecommendationReasonKind::Resume,
                    reason_text: "Reprendre la série".to_string(),
                    score: 600.0,
                    saga_position: None,
                    already_watched: false,
                });
            }
        }

        // 3. Similar episodes / series
        let candidates = self.db.load_recommendation_candidates("episode", current.group_title.as_deref(), 30)?;
        for cand in candidates {
            if cand.id != current.id && !scored.iter().any(|s| s.item.id == cand.id) {
                scored.push(ScoredCandidate {
                    item: cand,
                    reason_kind: RecommendationReasonKind::SimilarGenre,
                    reason_text: "Dans la même catégorie".to_string(),
                    score: 150.0,
                    saga_position: None,
                    already_watched: false,
                });
            }
        }

        scored.sort_by(|a, b| b.score.partial_cmp(&a.score).unwrap_or(std::cmp::Ordering::Equal));
        Ok(scored)
    }

    fn recommend_live(
        &self,
        current: &IptvItemRecord,
        _dismissed: &HashSet<String>,
    ) -> Result<Vec<ScoredCandidate>, CndError> {
        let mut scored = Vec::new();

        // Channels in same group
        let same_group = self.db.load_recommendation_candidates("live", current.group_title.as_deref(), 15)?;
        for cand in same_group {
            if cand.id != current.id {
                scored.push(ScoredCandidate {
                    item: cand,
                    reason_kind: RecommendationReasonKind::LiveNow,
                    reason_text: "Ailleurs en ce moment".to_string(),
                    score: 300.0,
                    saga_position: None,
                    already_watched: false,
                });
            }
        }

        // Recent channels
        let recents = self.db.list_recent_items("live", 10)?;
        for cand in recents {
            if cand.id != current.id && !scored.iter().any(|s| s.item.id == cand.id) {
                scored.push(ScoredCandidate {
                    item: cand,
                    reason_kind: RecommendationReasonKind::LiveNow,
                    reason_text: "Chaîne récente".to_string(),
                    score: 200.0,
                    saga_position: None,
                    already_watched: false,
                });
            }
        }

        Ok(scored)
    }
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::DatabaseManager;
    use std::sync::Arc;

    fn setup_test_engine() -> Arc<CndEngine> {
        let db = DatabaseManager::open_in_memory().expect("db");
        // Insert sample movies for an Avengers saga
        db.with_conn(|conn| {
            conn.execute(
                "INSERT INTO iptv_sources (id, uuid, name, source_type, created_at, updated_at)
                 VALUES (1, 's1', 'Source 1', 'xtream', 1, 1)",
                [],
            )?;
            conn.execute(
                "INSERT INTO iptv_items (id, source_id, stable_hash, kind, name, name_clean, year, group_title, host, stream_url, created_at, updated_at)
                 VALUES (10, 1, 'h10', 'movie', 'The Avengers (2012)', 'Avengers', 2012, 'Marvel', 'cdn', 'http://cdn/10.mp4', 1, 1),
                        (11, 1, 'h11', 'movie', 'Avengers: Age of Ultron (2015)', 'Avengers: Age of Ultron', 2015, 'Marvel', 'cdn', 'http://cdn/11.mp4', 1, 1),
                        (12, 1, 'h12', 'movie', 'Avengers: Infinity War (2018)', 'Avengers: Infinity War', 2018, 'Marvel', 'cdn', 'http://cdn/12.mp4', 1, 1),
                        (13, 1, 'h13', 'movie', 'Avengers: Endgame (2019)', 'Avengers: Endgame', 2019, 'Marvel', 'cdn', 'http://cdn/13.mp4', 1, 1),
                        (20, 1, 'h20', 'movie', 'Inception (2010)', 'Inception', 2010, 'Sci-Fi', 'cdn', 'http://cdn/20.mp4', 1, 1)",
                [],
            )?;

            // Insert a series with 2 episodes
            conn.execute(
                "INSERT INTO series_catalog (id, source_id, canonical_key, stable_hash, title, group_title, updated_at)
                 VALUES (1, 1, 'loki', 'sh_loki', 'Loki', 'Marvel', 1)",
                [],
            )?;
            conn.execute(
                "INSERT INTO iptv_items (id, source_id, series_id, stable_hash, kind, season_num, episode_num, name, name_clean, host, stream_url, created_at, updated_at)
                 VALUES (31, 1, 1, 'h31', 'episode', 1, 1, 'Loki S01E01', 'Glorious Purpose', 'cdn', 'http://cdn/31.mp4', 1, 1),
                        (32, 1, 1, 'h32', 'episode', 1, 2, 'Loki S01E02', 'The Variant', 'cdn', 'http://cdn/32.mp4', 1, 1)",
                [],
            )?;

            Ok(())
        })
        .expect("setup items");

        CndEngine::from_db(db).expect("engine")
    }

    #[test]
    fn test_movie_saga_recommendations() {
        let engine = setup_test_engine();

        // Watching Avengers 1 (id 10)
        let recs = engine
            .recommendations_for_impl(10, RecommendationContext::Playing, 5)
            .expect("recs");

        assert!(!recs.is_empty());
        // First recommendation must be Suite de la saga (Avengers 2: Age of Ultron, id 11)
        assert_eq!(recs[0].item.id, 11);
        assert_eq!(recs[0].reason_kind, RecommendationReasonKind::SagaNext);
        assert!(recs[0].reason_text.starts_with("Suite de la saga"));

        // Next-up card choice must be Avengers 2
        let next = engine.next_up_impl(10).expect("next_up").expect("some");
        assert_eq!(next.item.id, 11);
        assert_eq!(next.reason_kind, RecommendationReasonKind::SagaNext);
    }

    #[test]
    fn test_episode_next_up_recommendation() {
        let engine = setup_test_engine();

        // Watching S01E01 (id 31)
        let recs = engine
            .recommendations_for_impl(31, RecommendationContext::Ending, 5)
            .expect("recs");

        assert!(!recs.is_empty());
        assert_eq!(recs[0].item.id, 32);
        assert_eq!(recs[0].reason_kind, RecommendationReasonKind::NextEpisode);
        assert!(recs[0].reason_text.contains("S1:E2"));
    }

    #[test]
    fn test_dismissal_filters_out_recommendation() {
        let engine = setup_test_engine();

        // Dismiss Avengers 2 (h11)
        engine.dismiss_recommendation_impl("h11".to_string()).expect("dismiss");

        let recs = engine
            .recommendations_for_impl(10, RecommendationContext::Playing, 5)
            .expect("recs");

        // Avengers 2 is dismissed, next up must be Avengers 3 (Infinity War, id 12)
        assert_eq!(recs[0].item.id, 12);

        // Reset dismissals
        engine.reset_dismissed_recommendations_impl().expect("reset");
        let recs_reset = engine
            .recommendations_for_impl(10, RecommendationContext::Playing, 5)
            .expect("recs");
        assert_eq!(recs_reset[0].item.id, 11);
    }

    #[test]
    fn test_saga_info_discovery() {
        let engine = setup_test_engine();
        let saga = engine.saga_for_impl(10).expect("saga").expect("found");

        assert_eq!(saga.name, "Avengers");
        assert_eq!(saga.members.len(), 4);
        assert_eq!(saga.members[0].id, 10);
        assert_eq!(saga.members[3].id, 13);
    }

    #[test]
    fn test_recommendations_sla_50k_items() {
        let db = DatabaseManager::open_in_memory().expect("db");
        db.with_conn_mut(|conn| {
            conn.execute(
                "INSERT INTO iptv_sources (id, uuid, name, source_type, created_at, updated_at)
                 VALUES (1, 's1', 'Source 1', 'xtream', 1, 1)",
                [],
            )?;
            let tx = conn.transaction()?;
            {
                let mut stmt = tx.prepare(
                    "INSERT INTO iptv_items (id, source_id, stable_hash, kind, name, name_clean, year, group_title, host, stream_url, created_at, updated_at)
                     VALUES (?1, 1, ?2, 'movie', ?3, ?4, ?5, 'Action', 'cdn', 'http://cdn/stream.mp4', 1, 1)"
                )?;
                for i in 1..=50_000 {
                    let hash = format!("hash_{i}");
                    let name = format!("Action Movie {i}");
                    let clean = format!("action movie {i}");
                    let year = 1980 + (i % 40) as u32;
                    stmt.execute(rusqlite::params![i, hash, name, clean, year])?;
                }
            }
            tx.commit()?;
            Ok(())
        })
        .expect("insert 50k items");

        let engine = CndEngine::from_db(db).expect("engine");

        let start = std::time::Instant::now();
        let recs = engine.recommendations_for_impl(1, RecommendationContext::Playing, 10).expect("recs");
        let elapsed = start.elapsed();

        println!("SLA recommendations_for on 50,000 items took {:?}", elapsed);
        assert!(!recs.is_empty());
        // In release mode, must be well under 50ms
        #[cfg(not(debug_assertions))]
        assert!(elapsed < std::time::Duration::from_millis(50), "SLA violated: took {:?}", elapsed);
    }
}
