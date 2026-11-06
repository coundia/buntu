//! Steps 3 and 4 of the prompt search (PRD 33 § 3.3): the user's AI provider understands the request.
//!
//! The model never sees the catalog. It returns filters and a list of real titles that fit; each title is
//! then looked up **locally**, and only what exists in the user's sources (and the profile may see) is
//! offered. A title the model knows but the catalog lacks is reported as text, never as something playable.

use crate::ai::intent::{AiAction, AiCommandContext, AiProviderConfig, AiProviderKind};
use crate::ai::local_matcher::{self, fts_variants, words};
use crate::ai::prompt::{understand_system_prompt, understand_user_prompt, MAX_GUESSES, MAX_GUESS_CHARS};
use crate::ai::providers::Task;
use crate::db::{chrono_now_ts, DatabaseManager, IptvItemRecord};
use crate::search::engine::{self, catalog_filter, name_match_bonus, Lang};
use crate::search::query_parser::{self, Clock, Kind, ParsedQuery};
use crate::search::{SearchContext, SearchHit, SearchKind, SearchResponse};
use crate::{CndEngine, CndError};
use serde::Deserialize;
use std::time::Instant;

const MAX_REPLY_CHARS: usize = 140;
const MAX_LIST: usize = 12;

#[derive(Debug, Clone, Default, Deserialize, PartialEq)]
#[serde(default)]
pub struct Guess {
    pub title: String,
    #[serde(deserialize_with = "lenient_year")]
    pub year: Option<u32>,
}

/// What the model answered, before any of it is trusted.
#[derive(Debug, Clone, Default, Deserialize, PartialEq)]
#[serde(default)]
pub struct Understanding {
    pub intent: String,
    pub kinds: Vec<String>,
    pub time_hint: Option<String>,
    pub genres: Vec<String>,
    pub people: Vec<String>,
    #[serde(deserialize_with = "lenient_year")]
    pub year_from: Option<u32>,
    #[serde(deserialize_with = "lenient_year")]
    pub year_to: Option<u32>,
    pub languages: Vec<String>,
    pub similar_to: Option<String>,
    pub query_rewrite: Option<String>,
    pub title_guesses: Vec<Guess>,
    pub reply: Option<String>,
}

fn lenient_year<'de, D: serde::Deserializer<'de>>(d: D) -> Result<Option<u32>, D::Error> {
    let v = Option::<serde_json::Value>::deserialize(d)?;
    Ok(v.and_then(|v| match v {
        serde_json::Value::Number(n) => n.as_i64().or_else(|| n.as_f64().map(|f| f as i64)),
        serde_json::Value::String(s) => s.trim().parse::<i64>().ok(),
        _ => None,
    })
    .filter(|y| (1880..=2100).contains(y))
    .map(|y| y as u32))
}

/// Parses the model's JSON, tolerating Markdown fences and text around the object.
pub fn parse_understanding(text: &str) -> Result<Understanding, String> {
    let trimmed = text.trim();
    let start = trimmed.find('{').ok_or("réponse non JSON")?;
    let end = trimmed.rfind('}').ok_or("réponse non JSON")?;
    if end < start {
        return Err("réponse non JSON".to_string());
    }
    let parsed: Understanding = serde_json::from_str(&trimmed[start..=end]).map_err(|_| "réponse non JSON".to_string())?;
    if parsed.intent.trim().is_empty() {
        return Err("réponse sans intention".to_string());
    }
    Ok(parsed)
}

impl Understanding {
    /// Keeps only what is safe to use: bounded lists, plain text, known kinds.
    pub fn sanitized(mut self) -> Self {
        let clean = |s: &str, max: usize| -> String { s.chars().filter(|c| !c.is_control()).take(max).collect::<String>().trim().to_string() };
        self.title_guesses = self
            .title_guesses
            .into_iter()
            .map(|g| Guess { title: clean(&g.title, MAX_GUESS_CHARS), year: g.year })
            .filter(|g| !g.title.is_empty())
            .take(MAX_GUESSES)
            .collect();
        self.people = self.people.iter().map(|p| clean(p, 80)).filter(|p| !p.is_empty()).take(5).collect();
        self.genres = self.genres.iter().map(|p| clean(p, 40)).filter(|p| !p.is_empty()).take(5).collect();
        self.languages = self.languages.iter().map(|p| clean(p, 40)).filter(|p| !p.is_empty()).take(5).collect();
        self.similar_to = self.similar_to.map(|s| clean(&s, 100)).filter(|s| !s.is_empty());
        self.query_rewrite = self.query_rewrite.map(|s| clean(&s, 100)).filter(|s| !s.is_empty());
        self.reply = self.reply.map(|s| clean(&s, MAX_REPLY_CHARS)).filter(|s| !s.is_empty());
        self.kinds.retain(|k| matches!(k.as_str(), "live" | "program" | "movie" | "series"));
        self
    }
}

/// The request the user typed, completed with what the model understood. Nothing the model says can
/// remove a restriction the user wrote.
pub fn merge(parsed: &ParsedQuery, understood: &Understanding, clock: Clock) -> ParsedQuery {
    let mut merged = parsed.clone();
    if merged.kinds.is_empty() {
        for kind in &understood.kinds {
            merged.kinds.push(match kind.as_str() {
                "live" => Kind::Live,
                "program" => Kind::Program,
                "movie" => Kind::Movie,
                _ => Kind::Series,
            });
        }
    }
    for genre in &understood.genres {
        if let Some(g) = query_parser::genre_for(genre) {
            if !merged.genres.contains(&g) {
                merged.genres.push(g);
            }
        }
    }
    for person in &understood.people {
        let folded = words(person).join(" ");
        if !folded.is_empty() && !merged.people.contains(&folded) {
            merged.people.push(folded);
        }
    }
    for language in &understood.languages {
        if let Some(codes) = query_parser::language_codes(language) {
            for code in codes {
                if !merged.languages.iter().any(|c| c == code) {
                    merged.languages.push((*code).to_string());
                }
            }
        }
    }
    if merged.year_from.is_none() {
        merged.year_from = understood.year_from;
        merged.year_to = understood.year_to.or(understood.year_from);
    }
    if merged.similar_to.is_none() {
        merged.similar_to = understood.similar_to.as_deref().map(|s| words(s).join(" ")).filter(|s| !s.is_empty());
    }
    if merged.window.is_none() {
        let phrase = match understood.time_hint.as_deref() {
            Some("now") => Some("maintenant"),
            Some("tonight") => Some("ce soir"),
            Some("tomorrow") => Some("demain"),
            Some("yesterday") => Some("hier"),
            Some("weekend") => Some("ce week end"),
            _ => None,
        };
        merged.window = phrase.and_then(|p| query_parser::parse(p, clock).window);
    }
    if merged.terms.is_empty() && merged.similar_to.is_none() {
        if let Some(rewrite) = &understood.query_rewrite {
            // A rewrite is a title or a topic: its words are search words, minus anything already a filter.
            let reparsed = query_parser::parse(rewrite, clock);
            merged.terms = reparsed.terms;
            for g in reparsed.genre_words {
                if !merged.genre_words.contains(&g) {
                    merged.genre_words.push(g);
                }
            }
        }
    }
    merged
}

fn kinds_in_catalog(db: &DatabaseManager) -> Vec<&'static str> {
    let mut out = Vec::new();
    for (kind, label) in [("live", "live"), ("movie", "movie")] {
        if !db.visible_name_pool(kind).map(|p| p.is_empty()).unwrap_or(true) {
            out.push(label);
        }
    }
    if db.browse_series(&["".to_string()], 1).is_ok() || db.search_series_words(&[" ".to_string()], 1).is_ok() {
        out.push("series");
    }
    out
}

fn local_time_label(clock: Clock) -> String {
    let local = clock.now + i64::from(clock.utc_offset_minutes) * 60;
    let secs = local.rem_euclid(86_400);
    let day = local.div_euclid(86_400);
    let (y, m, d) = civil_from_days(day);
    let weekdays = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"];
    format!("{y:04}-{m:02}-{d:02} {:02}:{:02} ({})", secs / 3600, (secs % 3600) / 60, weekdays[((day + 3).rem_euclid(7)) as usize])
}

/// Days since 1970-01-01 to a calendar date (Howard Hinnant's algorithm).
fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

/// Looks the model's titles up in the catalog. Returns the hits found and the titles that are not there.
pub fn resolve_guesses(
    db: &DatabaseManager,
    guesses: &[Guess],
    merged: &ParsedQuery,
    lang: Lang,
) -> (Vec<SearchHit>, Vec<String>) {
    let want_movies = merged.wants(Kind::Movie);
    let want_series = merged.wants(Kind::Series);
    let mut hits: Vec<SearchHit> = Vec::new();
    let mut missing: Vec<String> = Vec::new();
    let why = if merged.people.is_empty() {
        lang.pick("Proposé par l'assistant", "Suggested by the assistant")
    } else {
        let name = merged.people[0].split_whitespace().map(|w| {
            let mut c = w.chars();
            c.next().map(|f| f.to_uppercase().collect::<String>() + c.as_str()).unwrap_or_default()
        }).collect::<Vec<_>>().join(" ");
        lang.pick(&format!("Avec {name} (assistant)"), &format!("With {name} (assistant)"))
    };
    for (index, guess) in guesses.iter().enumerate() {
        let terms: Vec<String> = words(&guess.title).into_iter().filter(|w| !w.is_empty()).collect();
        if terms.is_empty() {
            continue;
        }
        let mut found = false;
        if want_movies {
            let mut best: Option<(IptvItemRecord, f64)> = None;
            for variant in fts_variants(&guess.title) {
                for item in db.query_catalog(&catalog_filter("movie", &variant, 8)).unwrap_or_default() {
                    let bonus = name_match_bonus(&item.name_clean, &terms);
                    // The title must be the film's own (every word), and the year, when both are known, must agree.
                    let year_ok = match (guess.year, item.year) {
                        (Some(a), Some(b)) => a.abs_diff(b) <= 1,
                        _ => true,
                    };
                    if bonus >= 1.0 && year_ok && best.as_ref().is_none_or(|(_, s)| bonus > *s) {
                        best = Some((item, bonus));
                    }
                }
            }
            if let Some((item, bonus)) = best {
                found = true;
                hits.push(SearchHit {
                    kind: SearchKind::Movie,
                    item: Some(item),
                    series: None,
                    program: None,
                    reason: why.clone(),
                    score: 2.0 + bonus - index as f64 * 0.03,
                    from_assistant: true,
                });
            }
        }
        if want_series && !found {
            if let Some(series) = db
                .search_series_words(&terms, 8)
                .unwrap_or_default()
                .into_iter()
                .find(|s| name_match_bonus(&s.title, &terms) >= 1.0)
            {
                found = true;
                hits.push(SearchHit {
                    kind: SearchKind::Series,
                    item: None,
                    series: Some(series),
                    program: None,
                    reason: why.clone(),
                    score: 2.0 - index as f64 * 0.03,
                    from_assistant: true,
                });
            }
        }
        if !found && (want_movies || want_series) {
            let label = match guess.year {
                Some(y) => format!("{} ({y})", guess.title),
                None => guess.title.clone(),
            };
            missing.push(label);
        }
    }
    (hits, missing)
}

fn merge_hits(local: Vec<SearchHit>, assistant: Vec<SearchHit>) -> Vec<SearchHit> {
    fn key(hit: &SearchHit) -> String {
        match (&hit.item, &hit.series, &hit.program) {
            (Some(item), _, Some(p)) => format!("p:{}:{}:{}", item.id, p.start_ts, p.title),
            (Some(item), _, None) => format!("i:{}", item.id),
            (None, Some(series), _) => format!("s:{}", series.id),
            _ => String::new(),
        }
    }
    let mut out: Vec<SearchHit> = Vec::new();
    for hit in assistant.into_iter().chain(local) {
        let k = key(&hit);
        match out.iter_mut().find(|h| !k.is_empty() && key(h) == k) {
            // Already there: the better score and the explanation of the assistant win.
            Some(existing) => {
                if hit.score > existing.score {
                    existing.score = hit.score;
                }
                if hit.from_assistant {
                    existing.from_assistant = true;
                }
            }
            None => out.push(hit),
        }
    }
    out
}

fn unusable(config: &AiProviderConfig) -> Option<Option<String>> {
    match config.kind {
        AiProviderKind::LocalOnly => Some(None),
        _ if config.requires_key() && config.key().is_none() => Some(Some("clé API absente".to_string())),
        _ => None,
    }
}

/// Local search, then the model when one is configured and allowed (never for the kids profile).
pub(crate) async fn search_with_ai(
    engine: &CndEngine,
    text: String,
    context: SearchContext,
    config: AiProviderConfig,
) -> Result<SearchResponse, CndError> {
    let started = Instant::now();
    let lang = Lang::from_locale(&context.locale);
    let clock = Clock { now: chrono_now_ts(), utc_offset_minutes: context.utc_offset_minutes };
    let command: String = text.chars().filter(|c| !c.is_control()).take(crate::ai::prompt::MAX_COMMAND_CHARS).collect();
    let command = command.trim().to_string();
    let respond = |command: Option<AiAction>, hits: Vec<SearchHit>, missing: Vec<String>, reply: String, by: &str, fallback: Option<String>| SearchResponse {
        command,
        hits,
        missing_titles: missing,
        reply,
        resolved_by: by.to_string(),
        latency_ms: started.elapsed().as_millis() as u64,
        fallback_reason: fallback,
    };
    if command.is_empty() {
        return Ok(respond(None, Vec::new(), Vec::new(), String::new(), "local", None));
    }

    // A direct command ("mets TF1", "chaîne suivante") is performed, not searched.
    let ai_context = AiCommandContext {
        playing_stable_hash: context.playing_stable_hash.clone(),
        group_title: context.group_title.clone(),
        locale: context.locale.clone(),
    };
    let local = local_matcher::resolve_local(&engine.db, &command, &ai_context, clock.now)?;
    if let Some(action) = local.action {
        if !matches!(action, AiAction::None | AiAction::Search { .. }) {
            let reply = match &action {
                AiAction::PlayChannel { item_id } | AiAction::ShowGuide { item_id } => {
                    engine.db.get_item_by_id(*item_id)?.map(|i| i.name).unwrap_or_default()
                }
                _ => String::new(),
            };
            return Ok(respond(Some(action), Vec::new(), Vec::new(), reply, "local", None));
        }
    }

    let parsed = query_parser::parse(&command, clock);
    let mut local_hits = engine::command_hits(&engine.db, &command, &context, clock, lang);
    local_hits.extend(engine::search_parsed(&engine.db, &parsed, clock, lang, engine::DEFAULT_LIMIT));
    let local_hits = engine::rank(local_hits, &parsed, engine::DEFAULT_LIMIT);

    if engine.db.is_kids_only() {
        return Ok(respond(None, local_hits, Vec::new(), String::new(), "local", None));
    }
    if let Some(reason) = unusable(&config) {
        return Ok(respond(None, local_hits, Vec::new(), String::new(), "local", reason));
    }

    // Step 3: the model understands the request.
    let system = understand_system_prompt(&context.locale);
    let user = understand_user_prompt(&command, &local_time_label(clock), &kinds_in_catalog(&engine.db));
    let understood = match crate::ai::call_provider_text(engine, &config, &system, &user, Task::UnderstandSearch).await {
        Ok(text) => parse_understanding(&text).map(Understanding::sanitized),
        Err(reason) => Err(reason),
    };
    let provider = config.kind.label();
    let understood = match understood {
        Ok(u) if u.intent.trim().eq_ignore_ascii_case("search") => u,
        Ok(_) => return Ok(respond(None, local_hits, Vec::new(), String::new(), provider, None)),
        Err(reason) => return Ok(respond(None, local_hits, Vec::new(), String::new(), "local", Some(reason))),
    };

    // Filters of the model complete the request; the titles it knows are looked up locally.
    let merged = merge(&parsed, &understood, clock);
    let refined = engine::search_parsed(&engine.db, &merged, clock, lang, engine::DEFAULT_LIMIT);
    let (assistant_hits, missing) = resolve_guesses(&engine.db, &understood.title_guesses, &merged, lang);
    let combined = merge_hits(refined.into_iter().chain(local_hits).collect(), assistant_hits);
    let hits = engine::rank(combined, &merged, engine::DEFAULT_LIMIT);
    let mut missing = missing;
    missing.truncate(MAX_LIST);
    let reply = understood.reply.unwrap_or_default();
    Ok(respond(None, hits, missing, reply, provider, None))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn clock() -> Clock {
        Clock { now: crate::search::eval::NOW, utc_offset_minutes: 60 }
    }

    #[test]
    fn the_answer_is_parsed_through_fences_and_text() {
        let text = "Voici :\n```json\n{\"intent\":\"search\",\"kinds\":[\"movie\"],\"title_guesses\":[{\"title\":\"Top Gun\",\"year\":\"1986\"}]}\n```";
        let u = parse_understanding(text).expect("parsed");
        assert_eq!(u.kinds, vec!["movie"]);
        assert_eq!(u.title_guesses[0].year, Some(1986), "a year written as text is read");
        assert!(parse_understanding("pas du json").is_err());
        assert!(parse_understanding("{\"kinds\":[]}").is_err(), "no intent");
    }

    #[test]
    fn everything_from_the_model_is_bounded_and_clean() {
        let guesses: Vec<Guess> = (0..60).map(|i| Guess { title: format!("Titre {i}\u{0}"), year: Some(2000) }).collect();
        let u = Understanding {
            intent: "search".into(),
            kinds: vec!["movie".into(), "hack".into()],
            title_guesses: guesses,
            people: vec!["x".repeat(500)],
            reply: Some("a".repeat(900)),
            ..Understanding::default()
        }
        .sanitized();
        assert_eq!(u.title_guesses.len(), MAX_GUESSES);
        assert!(u.title_guesses.iter().all(|g| !g.title.contains('\u{0}') && g.title.chars().count() <= MAX_GUESS_CHARS));
        assert_eq!(u.kinds, vec!["movie"], "unknown kinds are dropped");
        assert!(u.people[0].chars().count() <= 80);
        assert!(u.reply.unwrap().chars().count() <= MAX_REPLY_CHARS);
    }

    #[test]
    fn a_year_outside_reason_is_ignored() {
        let u = parse_understanding("{\"intent\":\"search\",\"year_from\":3000,\"year_to\":1990}").unwrap();
        assert_eq!(u.year_from, None);
        assert_eq!(u.year_to, Some(1990));
    }

    #[test]
    fn the_model_completes_but_never_removes_what_the_user_wrote() {
        let parsed = query_parser::parse("film en 4K", clock());
        let understood = Understanding {
            intent: "search".into(),
            kinds: vec!["series".into()],
            genres: vec!["Action".into()],
            people: vec!["Tom Cruise".into()],
            languages: vec!["korean".into()],
            year_from: Some(2018),
            time_hint: Some("tonight".into()),
            query_rewrite: Some("top gun".into()),
            ..Understanding::default()
        };
        let merged = merge(&parsed, &understood, clock());
        assert_eq!(merged.kinds, vec![Kind::Movie], "the user said film: the model cannot turn it into a series");
        assert_eq!(merged.quality, parsed.quality);
        assert_eq!(merged.genres.first().map(|g| g.omdb), Some("Action"));
        assert!(merged.people.contains(&"tom cruise".to_string()));
        assert!(merged.languages.contains(&"kr".to_string()));
        assert_eq!(merged.year_from, Some(2018));
        assert!(merged.window.is_some());
        assert_eq!(merged.terms, vec!["top".to_string(), "gun".to_string()]);
    }

    #[test]
    fn local_time_is_written_for_the_model() {
        assert_eq!(local_time_label(clock()), "2026-11-06 20:00 (Friday)");
        assert_eq!(civil_from_days(0), (1970, 1, 1));
    }
}
