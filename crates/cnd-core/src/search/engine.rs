//! Step 2 of the prompt search (PRD 33 § 3.2): the local search over the user's catalog.
//!
//! Candidates come from the full-text index (titles, categories), from the EPG, from the cached OMDb
//! metadata (genres, people) and, when little is found, from a typo-tolerant pass over the titles.
//! Everything goes through queries that apply the profile's rules, so nothing hidden, adult (unless
//! shown), outside the kids allow-list, or flagged as broken can appear.

use crate::ai::intent::{AiAction, AiCommandContext};
use crate::ai::local_matcher::{self, fts_variants, tokens, words};
use crate::db::catalog_repo::{CatalogFilter, SeriesRecord, SortField};
use crate::db::{DatabaseManager, IptvItemRecord};
use crate::iptv::normalizer::fold_diacritics_ascii;
use crate::search::fuzzy;
use crate::search::query_parser::{self, Clock, Kind, ParsedQuery, Quality, Window};
use crate::search::{SearchContext, SearchHit, SearchKind};
use std::collections::{HashMap, HashSet};

pub const DEFAULT_LIMIT: usize = 40;
const PER_KIND: usize = 15;
const FTS_LIMIT: u32 = 40;
const FUZZY_BELOW: usize = 3;

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Lang {
    Fr,
    En,
}

impl Lang {
    pub fn from_locale(locale: &str) -> Self {
        if locale.to_ascii_lowercase().starts_with("fr") { Lang::Fr } else { Lang::En }
    }

    pub fn pick(self, fr: &str, en: &str) -> String {
        match self {
            Lang::Fr => fr.to_string(),
            Lang::En => en.to_string(),
        }
    }
}

/// Channels the assistant's own local resolution finds for a command ("chaîne 3", "France 2"): the
/// channel itself, or the few that fit. They come first, so typing "chaine 03" still shows channel 3.
pub fn command_hits(db: &DatabaseManager, text: &str, context: &SearchContext, clock: Clock, lang: Lang) -> Vec<SearchHit> {
    let ai_context = AiCommandContext {
        playing_stable_hash: context.playing_stable_hash.clone(),
        group_title: context.group_title.clone(),
        locale: context.locale.clone(),
    };
    let Ok(outcome) = local_matcher::resolve_local(db, text, &ai_context, clock.now) else {
        return Vec::new();
    };
    let ids: Vec<i64> = match outcome.action {
        Some(AiAction::PlayChannel { item_id }) | Some(AiAction::ShowGuide { item_id }) => vec![item_id],
        Some(_) => Vec::new(),
        None => outcome.candidates.iter().map(|c| c.id).take(5).collect(),
    };
    db.visible_items_by_ids(&ids)
        .unwrap_or_default()
        .into_iter()
        .enumerate()
        .map(|(rank, item)| SearchHit {
            kind: SearchKind::Live,
            item: Some(item),
            series: None,
            program: None,
            reason: lang.pick("Chaîne correspondant à votre demande", "Channel matching your request"),
            score: 3.0 - rank as f64 * 0.05,
            from_assistant: false,
        })
        .collect()
}

/// The local search with the command resolution in front: what the palette shows on each keystroke.
pub fn search_for_palette(db: &DatabaseManager, text: &str, context: &SearchContext, clock: Clock, lang: Lang, limit: usize) -> Vec<SearchHit> {
    let parsed = query_parser::parse(text, clock);
    let mut hits = command_hits(db, text, context, clock, lang);
    hits.extend(search_parsed(db, &parsed, clock, lang, limit));
    rank(hits, &parsed, limit)
}

/// Parses `text` and searches.
pub fn search_local(db: &DatabaseManager, text: &str, clock: Clock, lang: Lang, limit: usize) -> Vec<SearchHit> {
    let parsed = query_parser::parse(text, clock);
    search_parsed(db, &parsed, clock, lang, limit)
}

pub fn search_parsed(db: &DatabaseManager, query: &ParsedQuery, clock: Clock, lang: Lang, limit: usize) -> Vec<SearchHit> {
    if query.terms.is_empty()
        && query.genre_words.is_empty()
        && query.genres.is_empty()
        && query.people.is_empty()
        && query.similar_to.is_none()
        && query.window.is_none()
        && query.languages.is_empty()
        && query.year_from.is_none()
        && query.quality.is_none()
    {
        return Vec::new();
    }
    let mut hits: Vec<SearchHit> = Vec::new();
    if wants_live(query) {
        hits.extend(live_hits(db, query, clock, lang));
    }
    if wants_programs(query) {
        hits.extend(program_hits(db, query, clock, lang));
    }
    if query.wants(Kind::Movie) {
        hits.extend(movie_hits(db, query, lang));
    }
    if query.wants(Kind::Series) {
        hits.extend(series_hits(db, query, lang));
    }
    rank(hits, query, limit)
}

fn wants_live(query: &ParsedQuery) -> bool {
    if query.kinds.is_empty() {
        // "action 2022" or "comme Inception" are not about channels.
        return query.similar_to.is_none() && query.year_from.is_none() && !query.people_explicit;
    }
    query.kinds.contains(&Kind::Live)
}

fn wants_programs(query: &ParsedQuery) -> bool {
    if query.kinds.is_empty() {
        return query.similar_to.is_none() && query.year_from.is_none() && !query.people_explicit && !query.terms.is_empty();
    }
    query.kinds.contains(&Kind::Program)
}

fn fold(text: &str) -> String {
    words(text).join(" ")
}

fn title_words(name: &str) -> Vec<String> {
    words(name)
}

// ---------------------------------------------------------------- live channels

fn live_hits(db: &DatabaseManager, query: &ParsedQuery, clock: Clock, lang: Lang) -> Vec<SearchHit> {
    let mut found: Vec<(IptvItemRecord, f64, String)> = Vec::new();
    let mut seen: HashSet<i64> = HashSet::new();

    if !query.terms.is_empty() {
        let phrase = query.terms.join(" ");
        for variant in fts_variants(&phrase) {
            let filter = catalog_filter("live", &variant, FTS_LIMIT);
            for (rank, item) in db.query_catalog(&filter).unwrap_or_default().into_iter().enumerate() {
                if seen.insert(item.id) {
                    let score = 1.0 - rank as f64 * 0.02 + name_match_bonus(&item.name_clean, &query.terms);
                    found.push((item, score, lang.pick("Nom de chaîne", "Channel name")));
                }
            }
        }
        if found.len() < FUZZY_BELOW {
            for (item, edits) in fuzzy_items(db, "live", &query.terms) {
                if seen.insert(item.id) {
                    found.push((item, 0.7 - 0.2 * edits as f64, lang.pick("Nom proche", "Similar name")));
                }
            }
        }
    } else {
        // No name: a topic ("les infos en anglais"): channels of the matching categories.
        let mut topic: Vec<String> = query.genre_words.clone();
        for genre in &query.genres {
            topic.extend(genre.categories.iter().map(|c| (*c).to_string()));
        }
        topic.sort();
        topic.dedup();
        for word in topic {
            let filter = catalog_filter("live", &word, FTS_LIMIT);
            for (rank, item) in db.query_catalog(&filter).unwrap_or_default().into_iter().enumerate() {
                if seen.insert(item.id) {
                    let reason = item
                        .group_title
                        .clone()
                        .map(|g| lang.pick(&format!("Catégorie : {g}"), &format!("Category: {g}")))
                        .unwrap_or_default();
                    found.push((item, 0.6 - rank as f64 * 0.01, reason));
                }
            }
        }
    }

    if !query.languages.is_empty() {
        found.retain(|(item, _, _)| matches_language(item, &query.languages));
    }
    if let Some(quality) = query.quality {
        found.retain(|(item, _, _)| matches_quality(&item.name, quality));
    }

    // What is on the air, for the reason line.
    let tvg_ids: Vec<String> = found
        .iter()
        .filter_map(|(item, _, _)| item.tvg_id.clone().filter(|t| !t.is_empty()))
        .collect();
    let now_next: HashMap<String, String> = db
        .get_epg_now_next_at(&tvg_ids, clock.now)
        .unwrap_or_default()
        .into_iter()
        .filter_map(|entry| entry.now.map(|p| (entry.channel_tvg_id.clone(), p.title)))
        .collect();

    found
        .into_iter()
        .map(|(item, score, reason)| {
            let on_air = item.tvg_id.as_ref().and_then(|t| now_next.get(t)).cloned();
            let reason = match on_air {
                Some(title) => lang.pick(&format!("En ce moment : {title}"), &format!("On now: {title}")),
                None => reason,
            };
            SearchHit {
                kind: SearchKind::Live,
                item: Some(item),
                series: None,
                program: None,
                reason,
                score,
                from_assistant: false,
            }
        })
        .collect()
}

fn matches_language(item: &IptvItemRecord, codes: &[String]) -> bool {
    let mut haystack = tokens(item.group_title.as_deref().unwrap_or(""));
    haystack.extend(tokens(&item.name));
    codes.iter().any(|code| haystack.iter().any(|t| t == code))
}

fn matches_quality(name: &str, quality: Quality) -> bool {
    let t = words(name);
    let has = |w: &[&str]| t.iter().any(|x| w.contains(&x.as_str()));
    match quality {
        Quality::Uhd => has(&["uhd", "4k", "2160p", "2160"]),
        Quality::FullHd => has(&["fhd", "1080p", "1080"]),
        Quality::Hd => has(&["hd", "720p", "720", "fhd", "uhd"]),
    }
}

// ---------------------------------------------------------------- programmes

fn program_hits(db: &DatabaseManager, query: &ParsedQuery, clock: Clock, lang: Lang) -> Vec<SearchHit> {
    let mut search_words: Vec<String> = query.terms.iter().filter(|w| w.chars().count() >= 2).cloned().collect();
    if search_words.is_empty() {
        search_words.extend(query.genre_words.iter().cloned());
    }
    if search_words.is_empty() {
        return Vec::new();
    }
    let window = query.window.unwrap_or(Window { from: clock.now, to: clock.now + 36 * 3600, past: false });
    let mut airing = db.search_epg(&search_words, window.from, window.to.max(window.from + 1), 400).unwrap_or_default();
    // The same programme on the copies of one channel counts once.
    let mut seen: HashSet<(String, i64)> = HashSet::new();
    airing.retain(|a| seen.insert((a.program.title.to_lowercase(), a.program.start_ts)));
    let ids: Vec<i64> = airing.iter().map(|a| a.channel_id).collect();
    let channels: HashMap<i64, IptvItemRecord> = db
        .visible_items_by_ids(&ids)
        .unwrap_or_default()
        .into_iter()
        .map(|item| (item.id, item))
        .collect();

    airing
        .into_iter()
        .filter_map(|a| {
            let channel = channels.get(&a.channel_id)?.clone();
            let past = a.program.end_ts <= clock.now;
            if past && !has_archive(&channel) {
                return None; // gone, and the provider keeps no replay
            }
            let on_air = a.program.start_ts <= clock.now && a.program.end_ts > clock.now;
            let when = if on_air {
                lang.pick("En ce moment", "On now")
            } else {
                format_when(a.program.start_ts, clock, lang)
            };
            let verb = if past { lang.pick("Replay", "Replay") } else { when };
            let reason = format!("{verb} · {}", channel.name);
            let mut program = a.program;
            program.progress_ratio = if on_air {
                crate::db::epg_repo::compute_progress_ratio(program.start_ts, program.end_ts, clock.now)
            } else {
                0.0
            };
            // Favour what is on now or soon.
            let distance_hours = (program.start_ts - clock.now).abs() as f64 / 3600.0;
            let score = 1.2 - (distance_hours / 48.0).min(0.6) + title_bonus(&program.title, &query.terms);
            Some(SearchHit {
                kind: SearchKind::Program,
                item: Some(channel),
                series: None,
                program: Some(program),
                reason,
                score,
                from_assistant: false,
            })
        })
        .collect()
}

fn has_archive(item: &IptvItemRecord) -> bool {
    item.catchup_days.unwrap_or(0) > 0 || item.catchup_source.as_deref().is_some_and(|s| !s.is_empty())
}

const WEEKDAYS_FR: [&str; 7] = ["lun.", "mar.", "mer.", "jeu.", "ven.", "sam.", "dim."];
const WEEKDAYS_EN: [&str; 7] = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];

/// « Aujourd'hui 21:00 », « Demain 20:30 », « sam. 21:00 ».
pub fn format_when(ts: i64, clock: Clock, lang: Lang) -> String {
    let offset = i64::from(clock.utc_offset_minutes) * 60;
    let local = ts + offset;
    let days_since_epoch = local.div_euclid(86_400);
    let today = (clock.now + offset).div_euclid(86_400);
    let secs = local.rem_euclid(86_400);
    let time = format!("{:02}:{:02}", secs / 3600, (secs % 3600) / 60);
    let weekday = ((days_since_epoch + 3).rem_euclid(7)) as usize;
    let day = match days_since_epoch - today {
        0 => lang.pick("Aujourd'hui", "Today"),
        1 => lang.pick("Demain", "Tomorrow"),
        -1 => lang.pick("Hier", "Yesterday"),
        _ => match lang {
            Lang::Fr => WEEKDAYS_FR[weekday].to_string(),
            Lang::En => WEEKDAYS_EN[weekday].to_string(),
        },
    };
    format!("{day} {time}")
}

// ---------------------------------------------------------------- films

fn movie_hits(db: &DatabaseManager, query: &ParsedQuery, lang: Lang) -> Vec<SearchHit> {
    let mut found: Vec<(IptvItemRecord, f64, String)> = Vec::new();
    let mut seen: HashSet<i64> = HashSet::new();
    let mut push = |found: &mut Vec<(IptvItemRecord, f64, String)>, item: IptvItemRecord, score: f64, reason: String| {
        if seen.insert(item.id) {
            found.push((item, score, reason));
        }
    };

    // Words that name the film.
    if !query.terms.is_empty() {
        let phrase = query.terms.join(" ");
        for variant in fts_variants(&phrase) {
            let filter = catalog_filter("movie", &variant, FTS_LIMIT);
            for (rank, item) in db.query_catalog(&filter).unwrap_or_default().into_iter().enumerate() {
                let score = 1.0 - rank as f64 * 0.02 + name_match_bonus(&item.name_clean, &query.terms);
                push(&mut found, item, score, lang.pick("Titre correspondant", "Matching title"));
            }
        }
        if found.len() < FUZZY_BELOW {
            for (item, edits) in fuzzy_items(db, "movie", &query.terms) {
                push(&mut found, item, 0.7 - 0.2 * edits as f64, lang.pick("Titre proche", "Similar title"));
            }
        }
    }

    // Genres, people: cached OMDb metadata first, then the playlist's own categories.
    let genre_omdb: Vec<String> = query.genres.iter().map(|g| fold(g.omdb)).collect();
    if !genre_omdb.is_empty() || !query.people.is_empty() {
        let people: Vec<String> = query.people.iter().map(|p| fold(p)).collect();
        let ids = db.search_by_metadata("movie", &genre_omdb, &people, &[], 80).unwrap_or_default();
        let items = db.visible_items_by_ids(&ids).unwrap_or_default();
        for (rank, item) in items.into_iter().enumerate() {
            let mut reasons: Vec<String> = Vec::new();
            let mut score = 0.9 - rank as f64 * 0.005;
            if !people.is_empty() {
                score += 1.0;
                reasons.push(lang.pick(&format!("Avec {}", title_case(&query.people[0])), &format!("With {}", title_case(&query.people[0]))));
            }
            if !genre_omdb.is_empty() {
                score += 0.6;
                reasons.push(lang.pick(&format!("Genre : {}", query.genres[0].omdb), &format!("Genre: {}", query.genres[0].omdb)));
            }
            push(&mut found, item, score, reasons.join(" · "));
        }
    }
    if !query.genres.is_empty() || !query.genre_words.is_empty() {
        let mut topic: Vec<String> = query.genre_words.clone();
        for genre in &query.genres {
            topic.extend(genre.categories.iter().map(|c| (*c).to_string()));
        }
        topic.sort();
        topic.dedup();
        for word in topic {
            let filter = catalog_filter("movie", &word, FTS_LIMIT);
            for (rank, item) in db.query_catalog(&filter).unwrap_or_default().into_iter().enumerate() {
                let reason = item
                    .group_title
                    .clone()
                    .map(|g| lang.pick(&format!("Catégorie : {g}"), &format!("Category: {g}")))
                    .unwrap_or_default();
                push(&mut found, item, 0.5 - rank as f64 * 0.005, reason);
            }
        }
    }

    // Only filters (a year, a language): the best rated films that fit.
    if query.has_no_title() && query.people.is_empty() && query.genres.is_empty() && query.genre_words.is_empty() {
        let languages = query.languages.clone();
        if query.year_from.is_some() || !languages.is_empty() {
            let items = db.browse_items("movie", query.year_from, query.year_to, &languages, 60).unwrap_or_default();
            for (rank, item) in items.into_iter().enumerate() {
                let reason = match (query.year_from, item.year) {
                    (Some(_), Some(y)) => lang.pick(&format!("Film de {y}"), &format!("Film from {y}")),
                    _ => item.group_title.clone().map(|g| lang.pick(&format!("Catégorie : {g}"), &format!("Category: {g}"))).unwrap_or_default(),
                };
                push(&mut found, item, 0.6 - rank as f64 * 0.005, reason);
            }
        }
    }

    // « comme X »: X itself first, then films with the same genres, director or cast.
    if let Some(similar) = &query.similar_to {
        let seed_terms: Vec<String> = similar.split_whitespace().map(str::to_string).collect();
        let seeds = db
            .query_catalog(&catalog_filter("movie", &fts_variants(similar).into_iter().next().unwrap_or_default(), 5))
            .unwrap_or_default();
        let seed = seeds.iter().find(|i| name_match_bonus(&i.name_clean, &seed_terms) >= 1.0).or(seeds.first()).cloned();
        if let Some(seed) = seed {
            let label = seed.name_clean.clone();
            push(&mut found, seed.clone(), 2.5, lang.pick("Le film cité", "The film you named"));
            if let Ok(Some(meta)) = db.get_metadata_for_item(&seed) {
                let genres: Vec<String> = meta
                    .genres
                    .as_deref()
                    .unwrap_or("")
                    .split(',')
                    .map(|g| fold(g.trim()))
                    .filter(|g| !g.is_empty())
                    .take(2)
                    .collect();
                let director: Vec<String> = meta.director.as_deref().map(|d| vec![fold(d.split(',').next().unwrap_or(d).trim())]).unwrap_or_default();
                let mut related = Vec::new();
                if !director.is_empty() {
                    related.extend(db.search_by_metadata("movie", &[], &director, &[], 20).unwrap_or_default().into_iter().map(|id| (id, 1.4, true)));
                }
                if !genres.is_empty() {
                    related.extend(db.search_by_metadata("movie", &genres, &[], &[], 40).unwrap_or_default().into_iter().map(|id| (id, 0.9, false)));
                }
                let ids: Vec<i64> = related.iter().map(|(id, _, _)| *id).collect();
                let by_id: HashMap<i64, IptvItemRecord> = db.visible_items_by_ids(&ids).unwrap_or_default().into_iter().map(|i| (i.id, i)).collect();
                for (id, score, same_director) in related {
                    if let Some(item) = by_id.get(&id) {
                        if item.id == seed.id {
                            continue;
                        }
                        let reason = if same_director {
                            lang.pick(&format!("Même réalisateur que « {label} »"), &format!("Same director as “{label}”"))
                        } else {
                            lang.pick(&format!("Proche de « {label} »"), &format!("Close to “{label}”"))
                        };
                        push(&mut found, item.clone(), score, reason);
                    }
                }
            } else if let Some(group) = &seed.group_title {
                // No metadata: films of the same category.
                let filter = catalog_filter("movie", &fold(group), FTS_LIMIT);
                for (rank, item) in db.query_catalog(&filter).unwrap_or_default().into_iter().enumerate() {
                    if item.id != seed.id {
                        push(&mut found, item, 0.6 - rank as f64 * 0.005, lang.pick(&format!("Proche de « {label} »"), &format!("Close to “{label}”")));
                    }
                }
            }
        }
    }

    // Filters on what is known of each film.
    found.retain(|(item, _, _)| in_years(item.year, query));
    if let Some(quality) = query.quality {
        found.retain(|(item, _, _)| matches_quality(&item.name, quality));
    }
    if !query.languages.is_empty() {
        // Films carry the language in their category (« FR | ACTION ») when the playlist says so; films
        // with no marker at all are kept, they may be in any language.
        found.retain(|(item, _, _)| {
            let marked = item
                .group_title
                .as_deref()
                .map(|g| tokens(g).iter().any(|t| t.len() == 2 && ["fr", "uk", "us", "en", "es", "de", "it", "ar", "pt", "tr", "kr", "jp", "ko", "ja", "in", "hi", "be", "ch"].contains(&t.as_str())))
                .unwrap_or(false);
            !marked || matches_language(item, &query.languages)
        });
    }

    found
        .into_iter()
        .map(|(item, score, reason)| SearchHit {
            kind: SearchKind::Movie,
            item: Some(item),
            series: None,
            program: None,
            reason,
            score,
            from_assistant: false,
        })
        .collect()
}

fn in_years(year: Option<u32>, query: &ParsedQuery) -> bool {
    match (query.year_from, query.year_to, year) {
        (None, None, _) => true,
        (_, _, None) => true, // unknown year: keep it, it ranks lower
        (from, to, Some(y)) => from.is_none_or(|f| y >= f) && to.is_none_or(|t| y <= t),
    }
}

// ---------------------------------------------------------------- séries

fn series_hits(db: &DatabaseManager, query: &ParsedQuery, lang: Lang) -> Vec<SearchHit> {
    let mut found: Vec<(SeriesRecord, f64, String)> = Vec::new();
    let mut seen: HashSet<i64> = HashSet::new();
    let mut push = |found: &mut Vec<(SeriesRecord, f64, String)>, series: SeriesRecord, score: f64, reason: String| {
        if seen.insert(series.id) {
            found.push((series, score, reason));
        }
    };
    if !query.terms.is_empty() {
        let words: Vec<String> = query.terms.iter().filter(|t| t.chars().count() >= 2).cloned().collect();
        for (rank, series) in db.search_series_words(&words, FTS_LIMIT).unwrap_or_default().into_iter().enumerate() {
            let score = 1.0 - rank as f64 * 0.02 + name_match_bonus(&series.title, &query.terms);
            push(&mut found, series, score, lang.pick("Titre correspondant", "Matching title"));
        }
    }
    let mut topic: Vec<String> = query.genre_words.clone();
    for genre in &query.genres {
        topic.extend(genre.categories.iter().map(|c| (*c).to_string()));
    }
    if topic.is_empty() && query.terms.is_empty() {
        topic.extend(query.languages.iter().cloned()); // "une série coréenne"
    }
    topic.sort();
    topic.dedup();
    if !topic.is_empty() {
        for (rank, series) in db.browse_series(&topic, FTS_LIMIT).unwrap_or_default().into_iter().enumerate() {
            let reason = series
                .group_title
                .clone()
                .map(|g| lang.pick(&format!("Catégorie : {g}"), &format!("Category: {g}")))
                .unwrap_or_default();
            push(&mut found, series, 0.5 - rank as f64 * 0.01, reason);
        }
    }
    if !query.languages.is_empty() {
        found.retain(|(s, _, _)| {
            let g = tokens(s.group_title.as_deref().unwrap_or(""));
            let marked = g.iter().any(|t| t.len() == 2);
            !marked || query.languages.iter().any(|c| g.contains(c))
        });
    }
    found
        .into_iter()
        .map(|(series, score, reason)| SearchHit {
            kind: SearchKind::Series,
            item: None,
            series: Some(series),
            program: None,
            reason,
            score,
            from_assistant: false,
        })
        .collect()
}

// ---------------------------------------------------------------- helpers

pub(crate) fn catalog_filter(kind: &str, query: &str, limit: u32) -> CatalogFilter {
    CatalogFilter {
        kind: kind.to_string(),
        source_id: None,
        query: query.to_string(),
        group_title: None,
        host: None,
        favorites_only: false,
        include_broken: false,
        include_hidden: false,
        sort_by: SortField::Name,
        sort_asc: true,
        limit,
        offset: 0,
    }
}

/// Items whose title is within a few edits of every query word.
fn fuzzy_items(db: &DatabaseManager, kind: &str, terms: &[String]) -> Vec<(IptvItemRecord, usize)> {
    let query_words: Vec<String> = terms.iter().filter(|t| t.chars().count() >= 3).cloned().collect();
    if query_words.is_empty() {
        return Vec::new();
    }
    let pool = db.visible_name_pool(kind).unwrap_or_default();
    let mut scored: Vec<(i64, usize)> = pool
        .into_iter()
        .filter_map(|(id, name)| fuzzy::match_edits(&query_words, &title_words(&name)).map(|e| (id, e)))
        .collect();
    scored.sort_by_key(|(_, e)| *e);
    scored.truncate(15);
    let ids: Vec<i64> = scored.iter().map(|(id, _)| *id).collect();
    let edits: HashMap<i64, usize> = scored.into_iter().collect();
    db.visible_items_by_ids(&ids)
        .unwrap_or_default()
        .into_iter()
        .map(|item| {
            let e = edits.get(&item.id).copied().unwrap_or(2);
            (item, e)
        })
        .collect()
}

/// 2.0 for the exact title, 1.0 when every word is in it, 0.5 for the start of a word.
pub(crate) fn name_match_bonus(name: &str, terms: &[String]) -> f64 {
    if terms.is_empty() {
        return 0.0;
    }
    let title = title_words(&strip_prefix(name));
    let joined = title.join(" ");
    let wanted = terms.join(" ");
    if joined == wanted {
        return 2.0;
    }
    if terms.iter().all(|t| title.iter().any(|w| w == t)) {
        return 1.0;
    }
    if terms.iter().all(|t| title.iter().any(|w| w.starts_with(t.as_str()))) {
        return 0.5;
    }
    0.0
}

fn title_bonus(title: &str, terms: &[String]) -> f64 {
    name_match_bonus(title, terms).min(1.0) * 0.5
}

/// `FR: TF1 HD` -> `TF1 HD`: a channel is not named by its country tag.
fn strip_prefix(name: &str) -> String {
    match name.split_once(':') {
        Some((head, tail)) if head.trim().chars().count() <= 3 => tail.trim().to_string(),
        _ => name.to_string(),
    }
}

fn title_case(text: &str) -> String {
    text.split_whitespace()
        .map(|w| {
            let mut c = w.chars();
            c.next().map(|f| f.to_uppercase().collect::<String>() + c.as_str()).unwrap_or_default()
        })
        .collect::<Vec<_>>()
        .join(" ")
}

/// Orders the hits, groups the versions of one title, and keeps a bounded, balanced list.
pub(crate) fn rank(mut hits: Vec<SearchHit>, query: &ParsedQuery, limit: usize) -> Vec<SearchHit> {
    for hit in &mut hits {
        let mut bonus = 0.0;
        if let Some(item) = &hit.item {
            if item.is_favorite { bonus += 0.3; }
            if item.resume_position_ms > 0 && !item.is_completed { bonus += 0.2; }
            if let Some(rating) = item.imdb_rating { bonus += rating * 0.02; }
            if query.latest { bonus += item.year.map(|y| (y.saturating_sub(2000)) as f64 * 0.01).unwrap_or(0.0); }
        }
        if let Some(series) = &hit.series {
            if series.is_favorite { bonus += 0.3; }
            if let Some(rating) = series.imdb_rating { bonus += rating * 0.02; }
        }
        // A request that names a kind puts that kind first.
        if query.kinds.len() == 1 && SearchKind::from(query.kinds[0]) == hit.kind { bonus += 0.4; }
        hit.score += bonus;
    }
    hits.sort_by(|a, b| b.score.partial_cmp(&a.score).unwrap_or(std::cmp::Ordering::Equal));

    // One entry per title (VF, VOSTFR, 4K copies...), the best one first.
    let mut seen: HashSet<String> = HashSet::new();
    hits.retain(|hit| {
        let key = match (&hit.item, &hit.series, &hit.program) {
            (Some(item), _, Some(p)) => format!("p:{}:{}:{}", item.id, fold_diacritics_ascii(&p.title).to_lowercase(), p.start_ts / 60),
            (Some(item), _, None) => format!("{:?}:{}:{}", hit.kind, fold(&strip_prefix(&item.name_clean)), item.year.unwrap_or(0)),
            (None, Some(series), _) => format!("s:{}", fold(&series.title)),
            _ => String::new(),
        };
        key.is_empty() || seen.insert(key)
    });

    let mut per_kind: HashMap<String, usize> = HashMap::new();
    hits.retain(|hit| {
        let count = per_kind.entry(format!("{:?}", hit.kind)).or_insert(0);
        *count += 1;
        *count <= PER_KIND
    });
    hits.truncate(limit);
    hits
}
