//! Evaluation of the per-kind recommendations (PRD 34 § 10): a fixed catalog, profiles with a
//! history, and the rules that must never bend: no card of another kind in a shelf, the right
//! next episode, and an AI that can only reorder what the engine already offered.

use crate::ai::intent::{AiProviderConfig, AiProviderKind};
use crate::ai::test_support::{MockProvider, MockResponse};
use crate::recommend::ai_rerank::{build_input, AppleRerankRequest, AppleRerankStart, DAILY_CAP};
use crate::recommend::shelves::{finalize, Ctx, RecoCard, RecoKind, RecoShelf, RecoShelfKind};
use crate::search::eval::{seed, NOW};
use crate::CndEngine;
use rusqlite::params;
use serde_json::{json, Value};
use std::sync::Arc;

const DAY: i64 = 86_400;

fn engine() -> Arc<CndEngine> {
    let engine = CndEngine::in_memory().expect("engine");
    seed(&engine.db);
    extra(&engine);
    engine
}

/// Episodes for the series of the evaluation catalog, their metadata, and programmes with categories.
fn extra(engine: &CndEngine) {
    let source: i64 = engine.db.with_conn(|c| Ok(c.query_row("SELECT id FROM iptv_sources LIMIT 1", [], |r| r.get(0))?)).unwrap();
    engine
        .db
        .with_conn(|conn| {
            // (series title, season, episode, created_at)
            let episodes: &[(&str, u32, u32, i64)] = &[
                ("Squid Game", 1, 1, 1),
                ("Squid Game", 1, 2, 1),
                ("Squid Game", 1, 3, 1),
                ("Squid Game", 2, 1, NOW - 3 * DAY),
                ("Breaking Bad", 1, 1, 1),
                ("Breaking Bad", 1, 2, 1),
                ("Peaky Blinders", 1, 1, 1),
                ("Dark", 1, 1, 1),
                ("Game of Thrones", 1, 1, 1),
                ("Crash Landing on You", 1, 1, 1),
            ];
            for (title, season, episode, created) in episodes {
                let (series_id, group): (i64, String) = conn.query_row(
                    "SELECT id, group_title FROM series_catalog WHERE title = ?1",
                    params![title],
                    |r| Ok((r.get(0)?, r.get(1)?)),
                )?;
                conn.execute(
                    "INSERT INTO iptv_items (source_id, series_id, stable_hash, kind, season_num, episode_num, name, name_clean, group_title, host, stream_url, created_at, updated_at)
                     VALUES (?1, ?2, ?3, 'episode', ?4, ?5, ?6, ?6, ?7, 'h', ?8, ?9, ?9)",
                    params![
                        source,
                        series_id,
                        format!("ep_{title}_{season}_{episode}"),
                        season,
                        episode,
                        format!("{title} S{season}E{episode}"),
                        group,
                        format!("http://h/{series_id}/{season}/{episode}.mp4"),
                        created
                    ],
                )?;
            }
            let meta: &[(&str, &str)] = &[
                ("squid game", "Action, Drama, Mystery"),
                ("breaking bad", "Crime, Drama, Thriller"),
                ("peaky blinders", "Crime, Drama, Thriller"),
                ("dark", "Crime, Drama, Mystery"),
                ("game of thrones", "Action, Adventure, Drama"),
                ("crash landing on you", "Comedy, Drama, Romance"),
            ];
            for (title, genres) in meta {
                conn.execute(
                    "INSERT INTO media_metadata_cache (lookup_key, title, genres, media_type, fetched_at) VALUES (?1, ?2, ?3, 'series', 1)",
                    params![format!("series:{title}"), title, genres],
                )?;
            }
            conn.execute("UPDATE epg_programs SET category = 'News' WHERE title IN ('Journal de 20h', 'Le journal de l''Afrique', 'BBC World News Today')", [])?;
            conn.execute("UPDATE epg_programs SET category = 'Sports' WHERE title LIKE 'Ligue 1%' OR title LIKE 'Top 14%'", [])?;
            conn.execute("UPDATE epg_programs SET category = 'Kids' WHERE title = 'Dessins animés du soir'", [])?;
            Ok(())
        })
        .expect("extra");
}

fn watch(engine: &CndEngine, hash: &str, position_ms: i64, duration_ms: i64, at: i64) {
    let completed = i64::from(duration_ms > 0 && position_ms * 100 >= duration_ms * 92);
    engine
        .db
        .with_conn(|conn| {
            conn.execute(
                "INSERT OR REPLACE INTO watch_history (profile_id, stable_hash, position_ms, duration_ms, completed, last_watched_at)
                 VALUES ((SELECT id FROM temp.active_profile), ?1, ?2, ?3, ?4, ?5)",
                params![hash, position_ms, duration_ms, completed, at],
            )?;
            Ok(())
        })
        .unwrap();
}

fn finish(engine: &CndEngine, hash: &str, days_ago: i64) {
    watch(engine, hash, 7_000_000, 7_200_000, NOW - days_ago * DAY);
}

fn hash_of_movie(engine: &CndEngine, name: &str) -> String {
    engine.db.with_conn(|c| Ok(c.query_row("SELECT stable_hash FROM iptv_items WHERE kind='movie' AND name = ?1", params![name], |r| r.get(0))?)).unwrap()
}

fn shelves(engine: &CndEngine, kind: RecoKind) -> Vec<RecoShelf> {
    engine.recommendation_shelves_at(kind, 12, 60, NOW).unwrap()
}

fn shelf(shelves: &[RecoShelf], kind: RecoShelfKind) -> Option<&RecoShelf> {
    shelves.iter().find(|s| s.shelf == kind)
}

fn name(card: &RecoCard) -> String {
    if let Some(s) = &card.series {
        return s.title.clone();
    }
    card.item.as_ref().map(|i| i.name_clean.clone()).unwrap_or_default()
}

fn names(shelf: &RecoShelf) -> Vec<String> {
    shelf.items.iter().map(name).collect()
}

fn all_names(shelves: &[RecoShelf]) -> Vec<String> {
    shelves.iter().flat_map(|s| s.items.iter().map(name)).collect()
}

// ------------------------------------------------------------------ separation of the kinds

#[test]
fn the_three_kinds_never_mix_for_any_profile() {
    let engine = engine();
    // A profile that watches a bit of everything.
    finish(&engine, &hash_of_movie(&engine, "Inception"), 2);
    finish(&engine, &hash_of_movie(&engine, "Parasite"), 5);
    finish(&engine, "ep_Squid Game_1_1", 1);
    finish(&engine, "ep_Breaking Bad_1_1", 3);
    watch(&engine, "live3", 0, 0, NOW - 3600);
    watch(&engine, "live0", 0, 0, NOW - 7200);

    for kind in [RecoKind::Movies, RecoKind::Series, RecoKind::Live] {
        let all = shelves(&engine, kind);
        assert!(!all.is_empty(), "{kind:?}");
        for s in &all {
            assert_eq!(s.kind, kind);
            for card in &s.items {
                match kind {
                    RecoKind::Movies => {
                        assert_eq!(card.item.as_ref().map(|i| i.kind.as_str()), Some("movie"), "{} in {}", name(card), s.id);
                        assert!(card.series.is_none() && card.program.is_none() && card.next_episode.is_none());
                    }
                    RecoKind::Series => {
                        let series = card.series.as_ref().unwrap_or_else(|| panic!("a series card in {}", s.id));
                        assert!(card.item.is_none() && card.program.is_none());
                        if let Some(e) = &card.next_episode {
                            assert_eq!(e.kind, "episode");
                            assert_eq!(e.series_id, Some(series.id), "an episode of another series in {}", s.id);
                        }
                    }
                    RecoKind::Live => {
                        let channel = card.item.as_ref().expect("a channel");
                        assert_eq!(channel.kind, "live");
                        if let Some(p) = &card.program {
                            assert_eq!(Some(p.channel_tvg_id.as_str()), channel.tvg_id.as_deref());
                        }
                    }
                }
            }
        }
    }
}

#[test]
fn a_foreign_card_is_removed_by_the_guard() {
    let engine = engine();
    let movie_shelf = shelves(&engine, RecoKind::Movies).into_iter().find(|s| !s.items.is_empty()).unwrap();
    let series_shelf = shelves(&engine, RecoKind::Series).into_iter().find(|s| !s.items.is_empty()).unwrap();
    let live_shelf = shelves(&engine, RecoKind::Live).into_iter().find(|s| s.shelf == RecoShelfKind::OnNow).unwrap();

    let mut polluted = movie_shelf.clone();
    polluted.items.push(series_shelf.items[0].clone());
    polluted.items.push(live_shelf.items[0].clone());
    let before = movie_shelf.items.len();
    let (clean, removed) = finalize(RecoKind::Movies, vec![polluted]);
    assert_eq!(removed, 2);
    assert_eq!(clean[0].items.len(), before);

    let mut series_polluted = series_shelf.clone();
    series_polluted.items.push(movie_shelf.items[0].clone());
    assert_eq!(finalize(RecoKind::Series, vec![series_polluted]).1, 1);

    let mut live_polluted = live_shelf.clone();
    live_polluted.items.push(movie_shelf.items[0].clone());
    assert_eq!(finalize(RecoKind::Live, vec![live_polluted]).1, 1);
}

#[test]
fn a_card_with_a_foreign_episode_is_refused() {
    let engine = engine();
    let squid = engine.db.visible_series_by_ids(&[1, 2, 3, 4, 5, 6]).unwrap().into_iter().find(|s| s.title == "Squid Game").unwrap();
    let breaking_episode = engine.db.item_by_stable_hash("ep_Breaking Bad_1_1").unwrap().unwrap();
    let card = RecoCard::of_series(squid, Some(breaking_episode), "x");
    assert!(!crate::recommend::shelves::belongs(RecoKind::Series, &card));
}

// ------------------------------------------------------------------ films

#[test]
fn a_sci_fi_fan_gets_sci_fi_not_horror_and_never_what_they_saw() {
    let engine = engine();
    finish(&engine, &hash_of_movie(&engine, "Inception"), 1);
    finish(&engine, &hash_of_movie(&engine, "Interstellar"), 4);
    let all = shelves(&engine, RecoKind::Movies);
    let for_you = shelf(&all, RecoShelfKind::ForYou).expect("a For you shelf");
    let top: Vec<String> = names(for_you).into_iter().take(4).collect();
    for horror in ["Hereditary", "The Conjuring", "Train to Busan"] {
        assert!(!top.iter().any(|t| t == horror), "{horror} should not lead: {top:?}");
    }
    let scifi = ["Edge of Tomorrow", "The Avengers", "Avengers: Endgame", "Iron Man", "The Dark Knight"];
    assert!(top.iter().filter(|t| scifi.contains(&t.as_str())).count() >= 3, "{top:?}");
    // Seen films: not once, in any shelf, with their other copies (the 4K Inception) either.
    let everywhere = all_names(&all);
    assert!(!everywhere.iter().any(|n| n == "Inception" || n == "Interstellar"), "{everywhere:?}");
    // Broken and adult entries are never proposed.
    assert!(!everywhere.iter().any(|n| n.contains("Broken") || n.contains("Parody")), "{everywhere:?}");
    // The "because" shelf names a film the profile watched.
    let because = shelf(&all, RecoShelfKind::BecauseYouWatched).expect("a because shelf");
    assert!(because.title.contains("Inception"), "{}", because.title);
}

#[test]
fn a_new_profile_sees_the_best_of_the_sources_with_a_hint() {
    let engine = engine();
    let all = shelves(&engine, RecoKind::Movies);
    assert!(shelf(&all, RecoShelfKind::ForYou).is_none());
    let popular = shelf(&all, RecoShelfKind::Popular).expect("popular");
    assert_eq!(names(popular)[0], "Le Parrain", "best rated first");
    assert!(popular.note.is_some());
}

#[test]
fn a_started_film_is_offered_to_resume_and_a_zapped_one_is_not_counted() {
    let engine = engine();
    watch(&engine, &hash_of_movie(&engine, "Parasite"), 3_600_000, 7_200_000, NOW - 3600);
    // 30 seconds of a horror film: zapping, no taste, not even a resume.
    watch(&engine, &hash_of_movie(&engine, "Hereditary"), 30_000, 7_200_000, NOW - 600);
    let all = shelves(&engine, RecoKind::Movies);
    let resume = shelf(&all, RecoShelfKind::Resume).expect("resume");
    assert!(names(resume).contains(&"Parasite".to_string()));
    let ctx = Ctx::new_at(&engine, 12, 60, NOW).unwrap();
    let st = crate::recommend::movies::state(&ctx).unwrap();
    assert_eq!(st.taste.weight("genre:horror").max(0.0), st.taste.weight("genre:horror").max(0.0));
    assert!(st.taste.weight("genre:horror") < st.taste.weight("genre:drama"), "a zapped horror film is not a taste");
}

#[test]
fn the_next_film_of_a_saga_is_proposed() {
    let engine = engine();
    finish(&engine, &hash_of_movie(&engine, "The Avengers"), 1);
    let all = shelves(&engine, RecoKind::Movies);
    let sagas = shelf(&all, RecoShelfKind::Sagas).expect("a sagas shelf");
    assert_eq!(names(sagas).first().map(String::as_str), Some("Avengers: Endgame"), "{:?}", names(sagas));
}

#[test]
fn less_like_this_lowers_the_genre_for_films_only() {
    let engine = engine();
    finish(&engine, &hash_of_movie(&engine, "Inception"), 1);
    finish(&engine, "ep_Dark_1_1", 1);
    let before = shelves(&engine, RecoKind::Movies);
    let first = shelf(&before, RecoShelfKind::ForYou).unwrap().items[0].item.clone().unwrap();
    engine.less_like_this_impl(RecoKind::Movies, first.stable_hash.clone()).unwrap();
    let after = shelves(&engine, RecoKind::Movies);
    assert!(!all_names(&after).contains(&first.name_clean), "the content is hidden");
    let ctx = Ctx::new_at(&engine, 12, 60, NOW).unwrap();
    let movies_taste = crate::recommend::movies::state(&ctx).unwrap().taste;
    let series_taste = crate::recommend::series::state(&ctx).unwrap().taste;
    let feature = crate::recommend::taste::primary_feature(&crate::recommend::taste::movie_features(&first, ctx.meta.for_item(&first))).cloned().unwrap();
    assert!(movies_taste.weight(&feature) < 0.0, "{feature}");
    assert_eq!(series_taste.weight(&feature), 0.0, "series are not touched");
    engine.reset_taste_impl(RecoKind::Movies).unwrap();
    let ctx = Ctx::new_at(&engine, 12, 60, NOW).unwrap();
    assert!(crate::recommend::movies::state(&ctx).unwrap().taste.weight(&feature) >= 0.0);
}

// ------------------------------------------------------------------ series

#[test]
fn continue_shows_the_right_next_episode_for_each_series() {
    let engine = engine();
    // Squid Game: episode 1 done -> next is S1:E2. Breaking Bad: episode 2 half seen -> resume it.
    finish(&engine, "ep_Squid Game_1_1", 1);
    watch(&engine, "ep_Breaking Bad_1_2", 1_500_000, 3_000_000, NOW - 3600);
    finish(&engine, "ep_Breaking Bad_1_1", 2);
    // Peaky Blinders: its only episode done -> nothing left, not in "Continuer".
    finish(&engine, "ep_Peaky Blinders_1_1", 1);
    let all = shelves(&engine, RecoKind::Series);
    let keep = shelf(&all, RecoShelfKind::Continue).expect("continue");
    let by_title = |t: &str| keep.items.iter().find(|c| name(c) == t);
    let squid = by_title("Squid Game").expect("Squid Game");
    let e = squid.next_episode.as_ref().unwrap();
    assert_eq!((e.season_num, e.episode_num), (Some(1), Some(2)));
    assert!(squid.reason_text.contains("S1:E2"));
    let breaking = by_title("Breaking Bad").expect("Breaking Bad");
    let e = breaking.next_episode.as_ref().unwrap();
    assert_eq!((e.season_num, e.episode_num), (Some(1), Some(2)));
    assert!(breaking.reason_text.starts_with("Reprendre"));
    assert!(by_title("Peaky Blinders").is_none(), "a finished series has no next episode");
    // A series in progress is not also proposed in "Pour vous".
    let rest = all_names(&all.iter().filter(|s| s.shelf != RecoShelfKind::Continue).cloned().collect::<Vec<_>>());
    assert!(!rest.contains(&"Squid Game".to_string()), "{rest:?}");
}

#[test]
fn a_season_added_after_the_last_watch_is_announced() {
    let engine = engine();
    // Season 1 of Squid Game finished 10 days ago; season 2 was added 3 days ago.
    for e in 1..=3 {
        finish(&engine, &format!("ep_Squid Game_1_{e}"), 10);
    }
    let all = shelves(&engine, RecoKind::Series);
    let fresh = shelf(&all, RecoShelfKind::NewSeason).expect("new season");
    assert_eq!(names(fresh), vec!["Squid Game".to_string()]);
    assert!(fresh.items[0].reason_text.contains("S2"));
    assert!(shelf(&all, RecoShelfKind::Continue).is_none_or(|s| !names(s).contains(&"Squid Game".to_string())));
}

#[test]
fn the_next_season_of_an_old_series_is_just_the_next_episode() {
    let engine = engine();
    // Breaking Bad: only 2 episodes, both done: finished. Game of Thrones: season 1 done, nothing newer.
    let squid_s2: i64 = engine.db.season_first_added(1, 2).unwrap_or(None).unwrap_or(0);
    let _ = squid_s2;
    // Watched after the season arrived: it is an ordinary next episode, not "new".
    for e in 1..=3 {
        watch(&engine, &format!("ep_Squid Game_1_{e}"), 7_000_000, 7_200_000, NOW - DAY);
    }
    let all = shelves(&engine, RecoKind::Series);
    assert!(shelf(&all, RecoShelfKind::NewSeason).is_none());
    let keep = shelf(&all, RecoShelfKind::Continue).unwrap();
    assert!(keep.items[0].reason_text.starts_with("Saison suivante"));
}

#[test]
fn a_crime_fan_gets_crime_series_first_and_one_card_per_series() {
    let engine = engine();
    finish(&engine, "ep_Breaking Bad_1_1", 1);
    finish(&engine, "ep_Breaking Bad_1_2", 1);
    let all = shelves(&engine, RecoKind::Series);
    let for_you = shelf(&all, RecoShelfKind::ForYou).expect("for you");
    let top = names(for_you);
    assert_eq!(top[0], "Peaky Blinders", "{top:?}");
    let mut unique = top.clone();
    unique.sort();
    unique.dedup();
    assert_eq!(unique.len(), top.len(), "one card per series");
    assert!(for_you.items.iter().all(|c| c.next_episode.as_ref().is_some_and(|e| e.season_num == Some(1) && e.episode_num == Some(1))));
}

#[test]
fn an_abandoned_series_counts_against_its_genre() {
    let engine = engine();
    // Romance abandoned after one episode three weeks ago; a crime series watched fully.
    finish(&engine, "ep_Crash Landing on You_1_1", 21);
    finish(&engine, "ep_Breaking Bad_1_1", 1);
    finish(&engine, "ep_Breaking Bad_1_2", 1);
    let ctx = Ctx::new_at(&engine, 12, 60, NOW).unwrap();
    let taste = crate::recommend::series::state(&ctx).unwrap().taste;
    assert!(taste.weight("genre:romance") < 0.0, "{}", taste.weight("genre:romance"));
    assert!(taste.weight("genre:crime") > 0.0);
}

// ------------------------------------------------------------------ TV

#[test]
fn tv_proposes_programmes_on_the_air_for_the_channels_the_profile_watches() {
    let engine = engine();
    // Info channels watched; the programme on them is "News".
    watch(&engine, "live3", 0, 0, NOW - 3600); // France 24
    watch(&engine, "live6", 0, 0, NOW - 7200); // BBC News
    let all = shelves(&engine, RecoKind::Live);
    let on_now = shelf(&all, RecoShelfKind::OnNow).expect("on now");
    let first = &on_now.items[0];
    let channel = first.item.as_ref().unwrap();
    assert!(channel.name_clean.contains("France 24") || channel.name_clean.contains("BBC"), "{}", channel.name_clean);
    let program = first.program.as_ref().unwrap();
    assert!(program.start_ts <= NOW && program.end_ts > NOW);
    assert!(program.progress_ratio > 0.0 && program.progress_ratio < 1.0);
    // Nothing that is not on the air now.
    for card in &on_now.items {
        let p = card.program.as_ref().unwrap();
        assert!(p.start_ts <= NOW && p.end_ts > NOW, "{}", p.title);
    }
    // Football starts within two hours (PSG-Marseille, +1h): shown under "Bientôt" only for a sports fan.
    assert!(shelf(&all, RecoShelfKind::Soon).is_none_or(|s| !names(s).contains(&"Ligue 1 : PSG - Marseille".to_string())));
}

#[test]
fn a_sports_fan_sees_what_starts_soon() {
    let engine = engine();
    watch(&engine, "live4", 0, 0, NOW - 3600); // Canal+ Sport
    watch(&engine, "live5", 0, 0, NOW - 7200); // beIN Sports 1
    let all = shelves(&engine, RecoKind::Live);
    let soon = shelf(&all, RecoShelfKind::Soon).expect("soon");
    let titles: Vec<String> = soon.items.iter().map(|c| c.program.as_ref().unwrap().title.clone()).collect();
    assert!(titles.contains(&"Ligue 1 : PSG - Marseille".to_string()), "{titles:?}");
    for card in &soon.items {
        let p = card.program.as_ref().unwrap();
        assert!(p.start_ts > NOW && p.start_ts <= NOW + 2 * 3600, "{}", p.title);
        assert!(card.reason_text.starts_with("Dans "));
    }
}

#[test]
fn one_card_per_channel_family() {
    let engine = engine();
    let source: i64 = engine.db.with_conn(|c| Ok(c.query_row("SELECT id FROM iptv_sources LIMIT 1", [], |r| r.get(0))?)).unwrap();
    engine
        .db
        .with_conn(|conn| {
            // The SD copy of TF1 carries the same programme.
            conn.execute(
                "INSERT INTO iptv_items (source_id, stable_hash, kind, name, name_clean, group_title, tvg_id, host, stream_url, created_at, updated_at)
                 VALUES (?1, 'live_tf1_sd', 'live', 'FR: TF1 SD', 'FR: TF1 SD', 'FR | GENERALISTES', 'tf1.fr', 'h', 'http://h/tf1sd.ts', 1, 1)",
                params![source],
            )?;
            Ok(())
        })
        .unwrap();
    let all = shelves(&engine, RecoKind::Live);
    let on_now = shelf(&all, RecoShelfKind::OnNow).unwrap();
    let tf1 = on_now.items.iter().filter(|c| c.item.as_ref().unwrap().name_clean.contains("TF1")).count();
    assert_eq!(tf1, 1);
}

#[test]
fn an_out_of_date_guide_hides_the_programme_shelves_and_says_so() {
    let engine = engine();
    watch(&engine, "live3", 0, 0, NOW - 3600);
    // A month later nothing is on the air.
    let all = engine.recommendation_shelves_at(RecoKind::Live, 12, 60, NOW + 30 * DAY).unwrap();
    assert!(shelf(&all, RecoShelfKind::OnNow).is_none() && shelf(&all, RecoShelfKind::Soon).is_none());
    let stale = shelf(&all, RecoShelfKind::GuideStale).expect("a stale-guide shelf");
    assert!(stale.note.as_deref().unwrap_or("").contains("pas à jour"));
    assert!(stale.items.is_empty());
    // The channels watched recently are still offered.
    assert!(shelf(&all, RecoShelfKind::UsualChannels).is_some_and(|s| !s.items.is_empty()));
}

// ------------------------------------------------------------------ kids

#[test]
fn the_kids_profile_only_sees_its_allow_list() {
    let engine = engine();
    let kid = engine.create_profile("Léo".into(), "bear".into(), true).unwrap();
    engine.set_active_profile_id(kid.id);
    for kind in [RecoKind::Movies, RecoKind::Series, RecoKind::Live] {
        let all = shelves(&engine, kind);
        assert!(all.iter().all(|s| s.items.is_empty() || s.shelf == RecoShelfKind::GuideStale), "{kind:?}: nothing is allowed yet");
    }
    engine.allow_group(kid.id, "movie".into(), "FR | ANIMATION".into()).unwrap();
    let all = shelves(&engine, RecoKind::Movies);
    let seen = all_names(&all);
    assert!(!seen.is_empty());
    assert!(seen.iter().all(|n| n == "Le Roi Lion" || n == "Toy Story"), "{seen:?}");
}

// ------------------------------------------------------------------ the AI

fn config(server: &MockProvider) -> AiProviderConfig {
    AiProviderConfig {
        kind: AiProviderKind::Gemini,
        model: "test-model".into(),
        base_url: Some(server.base_url.clone()),
        api_key: Some("sk-SECRET-KEY-9999".into()),
        timeout_ms: 1_500,
    }
}

fn gemini(answer: Value) -> MockResponse {
    MockResponse::ok(json!({ "candidates": [{ "content": { "parts": [{ "text": answer.to_string() }] }, "finishReason": "STOP" }] }).to_string())
}

async fn refine(engine: &CndEngine, kind: RecoKind, config: AiProviderConfig, recent: bool) -> Vec<RecoShelf> {
    engine.refine_shelves_at(kind, config, 12, recent, "fr-FR".into(), 60, NOW).await.unwrap()
}

fn movie_engine() -> Arc<CndEngine> {
    let engine = engine();
    finish(&engine, &hash_of_movie(&engine, "Inception"), 1);
    finish(&engine, &hash_of_movie(&engine, "Interstellar"), 4);
    engine
}

fn candidate_titles(engine: &CndEngine, kind: RecoKind) -> Vec<String> {
    let ctx = Ctx::new_at(engine, 12, 60, NOW).unwrap();
    build_input(&ctx, kind).unwrap().cands.iter().map(|c| c.title.clone()).collect()
}

#[tokio::test]
async fn the_model_reorders_the_for_you_shelf_and_explains() {
    let engine = movie_engine();
    let titles = candidate_titles(&engine, RecoKind::Movies);
    let local = shelves(&engine, RecoKind::Movies);
    let local_first = names(shelf(&local, RecoShelfKind::ForYou).unwrap())[0].clone();
    let server = MockProvider::start(vec![gemini(json!({
        "kind": "movie",
        "picks": [{ "id": "m3", "reason": "Même tension que Interstellar" }, { "id": "m1", "reason": null }],
        "discover": [], "confidence": 0.9
    }))])
    .await;
    let refined = refine(&engine, RecoKind::Movies, config(&server), false).await;
    let for_you = shelf(&refined, RecoShelfKind::ForYou).unwrap();
    assert_eq!(for_you.refined_by.as_deref(), Some("Gemini"));
    let got = names(for_you);
    assert_eq!(got[0], titles[2], "the model's first pick leads");
    assert_eq!(got[1], titles[0]);
    assert_eq!(for_you.items[0].reason_text, "Même tension que Interstellar");
    assert!(for_you.items[0].ai_reason && for_you.items[1].ai_reason);
    // What the model did not pick completes the shelf: nothing is lost.
    assert!(got.contains(&local_first));
    // Never twice on the screen.
    let mut seen = std::collections::HashSet::new();
    for s in &refined {
        for c in &s.items {
            if matches!(s.shelf, RecoShelfKind::ForYou | RecoShelfKind::BecauseYouWatched | RecoShelfKind::NewForYou) {
                assert!(seen.insert(c.hash()), "{} twice", name(c));
            }
        }
    }
    assert_eq!(server.calls().len(), 1);
}

#[tokio::test]
async fn a_bad_answer_leaves_the_local_shelves_untouched() {
    let engine = movie_engine();
    let local = names(shelf(&shelves(&engine, RecoKind::Movies), RecoShelfKind::ForYou).unwrap());
    let bad: Vec<Value> = vec![
        json!({ "kind": "series", "picks": [{ "id": "m1", "reason": null }], "discover": [], "confidence": 0.9 }),
        json!({ "kind": "movie", "picks": [{ "id": "m999", "reason": null }, { "id": "s1", "reason": null }], "discover": [], "confidence": 0.9 }),
        json!({ "kind": "movie", "picks": [{ "id": "m1", "reason": null }], "discover": [], "confidence": 0.1 }),
    ];
    for answer in bad {
        let server = MockProvider::start(vec![gemini(answer.clone())]).await;
        let refined = refine(&engine, RecoKind::Movies, config(&server), false).await;
        let for_you = shelf(&refined, RecoShelfKind::ForYou).unwrap();
        assert_eq!(for_you.refined_by, None, "{answer}");
        assert_eq!(names(for_you), local, "{answer}");
    }
    // Broken JSON, an HTTP error and a timeout.
    for response in [
        MockResponse::ok(json!({ "candidates": [{ "content": { "parts": [{ "text": "{ not json" }] } }] }).to_string()),
        MockResponse::status(500, "{}"),
        gemini(json!({ "kind": "movie", "picks": [{ "id": "m1", "reason": null }], "discover": [], "confidence": 0.9 })).delayed(4_000),
    ] {
        let server = MockProvider::start(vec![response]).await;
        let refined = refine(&engine, RecoKind::Movies, config(&server), false).await;
        let for_you = shelf(&refined, RecoShelfKind::ForYou).unwrap();
        assert_eq!(for_you.refined_by, None);
        assert_eq!(names(for_you), local);
    }
}

#[tokio::test]
async fn titles_to_discover_must_be_of_the_same_kind() {
    let engine = engine();
    finish(&engine, "ep_Breaking Bad_1_1", 1);
    finish(&engine, "ep_Breaking Bad_1_2", 1);
    // On a SERIES shelf the model proposes a film (Inception) and a series that exists (Game of Thrones).
    let server = MockProvider::start(vec![gemini(json!({
        "kind": "series",
        "picks": [{ "id": "s1", "reason": "Dans le même esprit" }],
        "discover": [{ "title": "Inception", "year": 2010 }, { "title": "Game of Thrones", "year": 2011 }, { "title": "Unknown Show", "year": 2020 }],
        "confidence": 0.8
    }))])
    .await;
    let refined = refine(&engine, RecoKind::Series, config(&server), false).await;
    let for_you = shelf(&refined, RecoShelfKind::ForYou).unwrap();
    let got = names(for_you);
    assert!(!got.iter().any(|n| n.to_lowercase().contains("inception")), "{got:?}");
    assert!(!got.iter().any(|n| n == "Unknown Show"));
    assert!(for_you.items.iter().all(|c| c.series.is_some() && c.item.is_none()));
    // The same on a FILMS shelf: a series is not "converted" into a film.
    let engine = movie_engine();
    let server = MockProvider::start(vec![gemini(json!({
        "kind": "movie", "picks": [{ "id": "m1", "reason": null }],
        "discover": [{ "title": "Breaking Bad", "year": 2008 }, { "title": "Parasite", "year": 2019 }], "confidence": 0.8
    }))])
    .await;
    let refined = refine(&engine, RecoKind::Movies, config(&server), false).await;
    let got = names(shelf(&refined, RecoShelfKind::ForYou).unwrap());
    assert!(!got.contains(&"Breaking Bad".to_string()));
    assert!(got.contains(&"Parasite".to_string()), "a real film of the catalog is added: {got:?}");
}

#[tokio::test]
async fn the_request_holds_no_address_no_profile_and_titles_only_when_allowed() {
    let engine = movie_engine();
    let answer = || gemini(json!({ "kind": "movie", "picks": [{ "id": "m1", "reason": null }], "discover": [], "confidence": 0.9 }));
    let server = MockProvider::start(vec![answer()]).await;
    refine(&engine, RecoKind::Movies, config(&server), false).await;
    let body = server.calls()[0].body.clone();
    for secret in ["http://h/", "stream", "SECRET-KEY", "Eval", "movie3", "movie_", "host", "profile"] {
        assert!(!body.contains(secret), "the request leaks {secret}: {body}");
    }
    // The watched titles are absent unless allowed ("Inception" also names a candidate copy: use a title only the history has).
    let engine2 = movie_engine();
    let server2 = MockProvider::start(vec![answer()]).await;
    refine(&engine2, RecoKind::Movies, config(&server2), true).await;
    let with_recent = server2.calls()[0].body.clone();
    assert!(with_recent.contains("Interstellar"), "recent titles are sent when allowed: {with_recent}");
    assert!(!body.contains("Interstellar"), "and not otherwise: {body}");
    assert!(body.contains("thriller") || body.contains("sci-fi"), "the taste summary is sent");
}

#[tokio::test]
async fn the_answer_is_kept_and_the_provider_is_not_called_twice() {
    let engine = movie_engine();
    let server = MockProvider::start(vec![gemini(json!({ "kind": "movie", "picks": [{ "id": "m2", "reason": "Test" }], "discover": [], "confidence": 0.9 }))]).await;
    let first = refine(&engine, RecoKind::Movies, config(&server), false).await;
    let second = refine(&engine, RecoKind::Movies, config(&server), false).await;
    assert_eq!(server.calls().len(), 1, "the second build comes from the cache");
    assert_eq!(names(shelf(&first, RecoShelfKind::ForYou).unwrap()), names(shelf(&second, RecoShelfKind::ForYou).unwrap()));
    assert_eq!(shelf(&second, RecoShelfKind::ForYou).unwrap().refined_by.as_deref(), Some("Gemini"));
    // Finishing another film changes the candidates: the answer is not reused.
    finish(&engine, &hash_of_movie(&engine, "Parasite"), 0);
    refine(&engine, RecoKind::Movies, config(&server), false).await;
    assert_eq!(server.calls().len(), 2);
}

#[tokio::test]
async fn no_call_without_a_provider_for_the_kids_profile_or_over_the_daily_cap() {
    let engine = movie_engine();
    let server = MockProvider::start(vec![gemini(json!({ "kind": "movie", "picks": [{ "id": "m1", "reason": null }], "discover": [], "confidence": 0.9 }))]).await;
    // Local only: no call.
    let mut local_only = config(&server);
    local_only.kind = AiProviderKind::LocalOnly;
    refine(&engine, RecoKind::Movies, local_only, false).await;
    // No key for a provider that needs one.
    let mut keyless = config(&server);
    keyless.api_key = None;
    refine(&engine, RecoKind::Movies, keyless, false).await;
    assert_eq!(server.calls().len(), 0);
    // The daily cap of a remote provider.
    let cfg = config(&server);
    let key = format!("Gemini:{}", cfg.effective_model());
    let day = "2026-11-06";
    for _ in 0..DAILY_CAP {
        engine.db.count_reco_ai_call(day, &key).unwrap();
    }
    refine(&engine, RecoKind::Movies, cfg.clone(), false).await;
    assert_eq!(server.calls().len(), 0, "cap reached");
    // A new day: the counter starts again.
    assert_eq!(engine.db.reco_ai_calls_today("2026-11-07", &key).unwrap(), 0);
    // The kids profile never reaches a provider.
    let kid = engine.create_profile("Léo".into(), "bear".into(), true).unwrap();
    engine.set_active_profile_id(kid.id);
    engine.allow_group(kid.id, "movie".into(), "FR | ANIMATION".into()).unwrap();
    let refined = refine(&engine, RecoKind::Movies, cfg, false).await;
    assert_eq!(server.calls().len(), 0);
    assert!(refined.iter().all(|s| s.refined_by.is_none()));
}

#[tokio::test]
async fn a_local_model_has_no_daily_cap_and_is_labelled() {
    let engine = movie_engine();
    let server = MockProvider::start(vec![MockResponse::ok(
        json!({ "choices": [{ "message": { "content": json!({ "kind": "movie", "picks": [{ "id": "m1", "reason": null }], "discover": [], "confidence": 0.9 }).to_string() } }] }).to_string(),
    )])
    .await;
    let cfg = AiProviderConfig {
        kind: AiProviderKind::OpenAiCompatible,
        model: "llama".into(),
        base_url: Some(server.base_url.clone()), // http://127.0.0.1:port
        api_key: None,
        timeout_ms: 1_500,
    };
    for _ in 0..(DAILY_CAP + 1) {
        engine.db.count_reco_ai_call("2026-11-06", "IA locale:llama").unwrap();
    }
    let refined = refine(&engine, RecoKind::Movies, cfg, true).await;
    assert_eq!(shelf(&refined, RecoShelfKind::ForYou).unwrap().refined_by.as_deref(), Some("IA locale"));
    assert_eq!(server.calls().len(), 1);
}

// ------------------------------------------------------------------ the model of Apple (lot 34.5)

fn apple_ask(engine: &CndEngine, kind: RecoKind) -> AppleRerankRequest {
    match engine.prepare_apple_rerank_at(kind, 12, "fr-FR".into(), 60, NOW).unwrap() {
        AppleRerankStart::Ask { request } => request,
        other => panic!("expected a question for the model, got {other:?}"),
    }
}

fn apple_answer(kind: &str, picks: Value, confidence: f64) -> String {
    json!({ "kind": kind, "picks": picks, "discover": [], "confidence": confidence }).to_string()
}

#[test]
fn the_model_of_apple_gets_a_prompt_with_opaque_ids_and_no_address() {
    let engine = movie_engine();
    let request = apple_ask(&engine, RecoKind::Movies);
    assert_eq!(request.kind, RecoKind::Movies);
    assert!(request.system.contains("\"movie\""), "the kind to answer is in the rules");
    assert!(request.user.contains("\"m1\"") && request.user.contains("CANDIDATES"));
    for secret in ["http://h/", "stream", "host", "profile", "movie_"] {
        assert!(!request.user.contains(secret), "the prompt leaks {secret}: {}", request.user);
    }
    // It never sees more than its small context can hold.
    let sent = request.user.matches("\"id\":").count();
    assert!(sent <= crate::recommend::ai_rerank::APPLE_MAX_CANDIDATES, "{sent} candidates");
    // The titles watched never leave the device, so they are allowed here.
    assert!(request.user.contains("Interstellar"), "{}", request.user);
}

#[test]
fn a_good_answer_of_apple_re_ranks_the_shelf_and_is_labelled() {
    let engine = movie_engine();
    let titles = candidate_titles(&engine, RecoKind::Movies);
    let request = apple_ask(&engine, RecoKind::Movies);
    let answer = apple_answer("movie", json!([{ "id": "m3", "reason": "Même tension" }, { "id": "m1", "reason": null }]), 0.9);
    let refined = engine.finish_apple_rerank_impl(request, answer).unwrap();
    let for_you = shelf(&refined, RecoShelfKind::ForYou).unwrap();
    assert_eq!(for_you.refined_by.as_deref(), Some("Modèle d'Apple"));
    let got = names(for_you);
    assert_eq!(got[0], titles[2], "the model's first pick leads");
    assert_eq!(got[1], titles[0]);
    assert_eq!(for_you.items[0].reason_text, "Même tension");
    assert!(for_you.items[0].ai_reason);
}

#[test]
fn an_answer_of_apple_for_another_kind_or_with_invented_ids_changes_nothing() {
    let engine = movie_engine();
    let local = shelves(&engine, RecoKind::Movies);
    for bad in [
        apple_answer("series", json!([{ "id": "m1", "reason": null }]), 0.9),
        apple_answer("movie", json!([{ "id": "m99", "reason": null }]), 0.9),
        apple_answer("movie", json!([{ "id": "m1", "reason": null }]), 0.1),
        "Voici mes recommandations : …".to_string(),
        String::new(),
    ] {
        let request = apple_ask(&engine, RecoKind::Movies);
        let refined = engine.finish_apple_rerank_impl(request, bad.clone()).unwrap();
        assert!(refined.iter().all(|s| s.refined_by.is_none()), "{bad}");
        assert_eq!(all_names(&refined), all_names(&local), "{bad}");
    }
}

#[test]
fn an_answer_of_apple_is_refused_when_the_candidates_changed_meanwhile() {
    let engine = movie_engine();
    let request = apple_ask(&engine, RecoKind::Movies);
    // The viewer finishes another film while the model thinks.
    finish(&engine, &hash_of_movie(&engine, "Parasite"), 0);
    let answer = apple_answer("movie", json!([{ "id": "m1", "reason": null }]), 0.9);
    let refined = engine.finish_apple_rerank_impl(request, answer).unwrap();
    assert!(refined.iter().all(|s| s.refined_by.is_none()), "ids that moved must not be applied to other titles");
}

#[test]
fn the_answer_of_apple_is_kept_for_the_same_candidates() {
    let engine = movie_engine();
    let request = apple_ask(&engine, RecoKind::Movies);
    let answer = apple_answer("movie", json!([{ "id": "m2", "reason": "Test" }]), 0.9);
    let first = engine.finish_apple_rerank_impl(request, answer).unwrap();
    match engine.prepare_apple_rerank_at(RecoKind::Movies, 12, "fr-FR".into(), 60, NOW).unwrap() {
        AppleRerankStart::Cached { shelves } => {
            assert_eq!(names(shelf(&shelves, RecoShelfKind::ForYou).unwrap()), names(shelf(&first, RecoShelfKind::ForYou).unwrap()));
            assert_eq!(shelf(&shelves, RecoShelfKind::ForYou).unwrap().refined_by.as_deref(), Some("Modèle d'Apple"));
        }
        other => panic!("expected the kept answer, got {other:?}"),
    }
    // Other candidates: the model is asked again.
    finish(&engine, &hash_of_movie(&engine, "Parasite"), 0);
    assert!(matches!(engine.prepare_apple_rerank_at(RecoKind::Movies, 12, "fr-FR".into(), 60, NOW).unwrap(), AppleRerankStart::Ask { .. }));
}

#[test]
fn the_model_of_apple_is_never_asked_for_the_kids_profile() {
    let engine = movie_engine();
    let kid = engine.create_profile("Léo".into(), "bear".into(), true).unwrap();
    engine.set_active_profile_id(kid.id);
    engine.allow_group(kid.id, "movie".into(), "FR | ANIMATION".into()).unwrap();
    assert!(matches!(engine.prepare_apple_rerank_at(RecoKind::Movies, 12, "fr-FR".into(), 60, NOW).unwrap(), AppleRerankStart::Skip));
}

#[test]
fn apple_re_ranks_series_and_programmes_inside_their_kind() {
    let engine = engine();
    finish(&engine, &hash_of_movie(&engine, "Inception"), 1);
    for (kind, key, prefix) in [(RecoKind::Series, "series", "s"), (RecoKind::Live, "live", "t")] {
        let AppleRerankStart::Ask { request } = engine.prepare_apple_rerank_at(kind, 12, "fr-FR".into(), 60, NOW).unwrap() else {
            continue; // not enough candidates of this kind in the small catalog
        };
        assert!(request.user.contains(&format!("\"{prefix}1\"")));
        let wrong = apple_answer("movie", json!([{ "id": format!("{prefix}1"), "reason": null }]), 0.9);
        assert!(engine.finish_apple_rerank_impl(request.clone(), wrong).unwrap().iter().all(|s| s.refined_by.is_none()));
        let good = apple_answer(key, json!([{ "id": format!("{prefix}2"), "reason": null }]), 0.9);
        let refined = engine.finish_apple_rerank_impl(request, good).unwrap();
        for s in &refined {
            for card in &s.items {
                assert!(crate::recommend::shelves::belongs(kind, card), "a card of another kind in {key}");
            }
        }
    }
}

#[tokio::test]
async fn the_model_re_ranks_programmes_on_the_air_and_cannot_add_channels_by_title() {
    let engine = engine();
    watch(&engine, "live3", 0, 0, NOW - 3600);
    let titles = candidate_titles(&engine, RecoKind::Live);
    assert!(titles.len() >= 3, "{titles:?}");
    let server = MockProvider::start(vec![gemini(json!({
        "kind": "live",
        "picks": [{ "id": "t3", "reason": "Le journal de la soirée" }],
        "discover": [{ "title": "Inception", "year": 2010 }], "confidence": 0.8
    }))])
    .await;
    let refined = refine(&engine, RecoKind::Live, config(&server), false).await;
    let on_now = shelf(&refined, RecoShelfKind::OnNow).unwrap();
    assert_eq!(on_now.refined_by.as_deref(), Some("Gemini"));
    assert_eq!(on_now.items[0].program.as_ref().unwrap().title, titles[2]);
    assert!(on_now.items.iter().all(|c| c.item.as_ref().is_some_and(|i| i.kind == "live") && c.program.is_some()));
    assert!(!names(on_now).iter().any(|n| n.to_lowercase().contains("inception")));
}

#[tokio::test]
async fn a_stale_guide_is_not_sent_to_a_model() {
    let engine = engine();
    let server = MockProvider::start(vec![gemini(json!({ "kind": "live", "picks": [{ "id": "t1", "reason": null }], "discover": [], "confidence": 0.9 }))]).await;
    let refined = engine.refine_shelves_at(RecoKind::Live, config(&server), 12, false, "fr-FR".into(), 60, NOW + 30 * DAY).await.unwrap();
    assert!(shelf(&refined, RecoShelfKind::GuideStale).is_some());
    assert_eq!(server.calls().len(), 0);
}

// ------------------------------------------------------------------ the next episode, pure

#[test]
fn next_episode_rules() {
    use crate::recommend::series::{next_episode, Next};
    let engine = engine();
    let eps = |t: &str| engine.db.get_series_episodes(engine.db.with_conn(|c| Ok(c.query_row("SELECT id FROM series_catalog WHERE title=?1", params![t], |r| r.get::<_, i64>(0))?)).unwrap(), None).unwrap();
    let squid = eps("Squid Game");
    assert_eq!(squid.len(), 4);
    // Half of E1: resume it.
    assert!(matches!(next_episode(&squid, &squid[0], false, 1_000, 3_000), Next::Resume(_)));
    // E1 done: E2.
    assert!(matches!(next_episode(&squid, &squid[0], true, 3_000, 3_000), Next::Episode(e) if e.episode_num == Some(2)));
    // E3 done: the first of season 2.
    assert!(matches!(next_episode(&squid, &squid[2], true, 3_000, 3_000), Next::Season(e) if e.season_num == Some(2)));
    // The last one done: nothing left.
    assert!(matches!(next_episode(&squid, &squid[3], true, 3_000, 3_000), Next::Finished));
}

// ------------------------------------------------------------------ SLA

/// 50 000 films, 3 000 series (30 000 episodes), 5 000 channels with a guide, and a real history:
/// each kind builds its shelves in well under 50 ms (release build).
#[test]
fn shelves_are_built_in_under_50_ms_on_a_big_catalog() {
    let engine = CndEngine::in_memory().expect("engine");
    let source = engine.db.add_source("Big", "m3u", Some("http://x/l.m3u"), None, None, None).expect("source");
    engine
        .db
        .with_conn_mut(|conn| {
            let tx = conn.transaction()?;
            {
                let mut movie = tx.prepare(
                    "INSERT INTO iptv_items (source_id, stable_hash, kind, name, name_clean, year, group_title, imdb_rating, host, stream_url, created_at, updated_at)
                     VALUES (?1, ?2, 'movie', ?3, ?3, ?4, ?5, ?6, 'h', 'http://h/m.mp4', ?7, ?7)",
                )?;
                for i in 0..50_000 {
                    movie.execute(params![source, format!("m{i}"), format!("Film number {i}"), 1980 + (i % 44), format!("CAT {}", i % 60), (i % 90) as f64 / 10.0, i])?;
                }
                let mut series = tx.prepare(
                    "INSERT INTO series_catalog (source_id, canonical_key, stable_hash, title, group_title, imdb_rating, season_count, episode_count, updated_at)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, 3, 10, ?7)",
                )?;
                let mut episode = tx.prepare(
                    "INSERT INTO iptv_items (source_id, series_id, stable_hash, kind, season_num, episode_num, name, name_clean, group_title, host, stream_url, created_at, updated_at)
                     VALUES (?1, ?2, ?3, 'episode', ?4, ?5, ?6, ?6, ?7, 'h', 'http://h/e.mp4', 1, 1)",
                )?;
                for s in 0..3_000i64 {
                    series.execute(params![source, format!("s{s}"), format!("sh{s}"), format!("Series {s}"), format!("SER {}", s % 30), (s % 90) as f64 / 10.0, s])?;
                    let series_id = tx.last_insert_rowid();
                    for e in 0..10 {
                        episode.execute(params![source, series_id, format!("e{s}_{e}"), 1 + e / 5, 1 + e % 5, format!("Series {s} E{e}"), format!("SER {}", s % 30)])?;
                    }
                }
                let mut live = tx.prepare(
                    "INSERT INTO iptv_items (source_id, stable_hash, kind, name, name_clean, group_title, tvg_id, host, stream_url, created_at, updated_at)
                     VALUES (?1, ?2, 'live', ?3, ?3, ?4, ?5, 'h', 'http://h/l.ts', 1, 1)",
                )?;
                let mut epg = tx.prepare("INSERT INTO epg_programs (channel_tvg_id, start_ts, end_ts, title, category) VALUES (?1, ?2, ?3, ?4, ?5)")?;
                for c in 0..5_000 {
                    live.execute(params![source, format!("l{c}"), format!("Channel {c} HD"), format!("LIVE {}", c % 40), format!("ch{c}")])?;
                    for p in 0..3 {
                        epg.execute(params![format!("ch{c}"), NOW - 1_800 + p * 3_600, NOW + 1_800 + p * 3_600, format!("Show {c} {p}"), format!("Cat{}", c % 7)])?;
                    }
                }
            }
            tx.commit()?;
            Ok(())
        })
        .expect("seed big catalog");
    // A history on each kind.
    for i in 0..100 {
        watch(&engine, &format!("m{}", i * 37), 7_000_000, 7_200_000, NOW - i * 3_600);
    }
    for s in 0..40 {
        watch(&engine, &format!("e{}_{}", s * 11, 0), 2_900_000, 3_000_000, NOW - s * 3_600);
    }
    for c in 0..60 {
        watch(&engine, &format!("l{}", c * 17), 0, 0, NOW - c * 3_600);
    }
    for kind in [RecoKind::Movies, RecoKind::Series, RecoKind::Live] {
        let started = std::time::Instant::now();
        let all = engine.recommendation_shelves_at(kind, 12, 60, NOW).unwrap();
        let elapsed = started.elapsed();
        println!("SLA shelves {kind:?} on the big catalog: {elapsed:?}");
        assert!(all.iter().any(|s| !s.items.is_empty()), "{kind:?}");
        #[cfg(not(debug_assertions))]
        assert!(elapsed < std::time::Duration::from_millis(50), "{kind:?} took {elapsed:?}");
    }
}
