//! Film shelves (PRD 34 § 5.1). Only films: every query here takes `kind = 'movie'`.

use crate::db::reco_repo::WatchedEntry;
use crate::db::IptvItemRecord;
use crate::recommend::saga::{normalize_root_key, parse_saga_title};
use crate::recommend::scoring::{deduplicate_versions, RecommendationReasonKind};
use crate::recommend::shelves::{diversify, finish_taste, Cand, Ctx, RecoCard, RecoKind, RecoShelf, RecoShelfKind};
use crate::recommend::taste::{movie_features, reason_for, similarity, watch_weight, Taste};
use crate::recommend::SagaOrderPreference;
use crate::CndError;
use std::collections::HashSet;

const POOL_TOP_RATED: u32 = 400;
const POOL_NEWEST: u32 = 200;

/// What the film shelves and the AI prompt both start from.
pub(crate) struct MovieState {
    pub taste: Taste,
    pub entries: Vec<WatchedEntry>,
    pub watched: HashSet<String>,
    /// Title + year of what was watched: another copy (4K, VOSTFR) of a seen film is not "new".
    pub watched_works: HashSet<String>,
}

fn work_key(item: &IptvItemRecord) -> String {
    format!("{}:{}", normalize_root_key(&item.name_clean), item.year.unwrap_or(0))
}

pub(crate) fn state(ctx: &Ctx<'_>) -> Result<MovieState, CndError> {
    let entries = ctx.visible_entries(ctx.db.watched_entries("movie", 300)?);
    let mut taste = Taste::default();
    for e in &entries {
        let w = watch_weight(e.position_ms, e.duration_ms, e.completed, e.last_watched_at, ctx.now);
        taste.add(&movie_features(&e.item, ctx.meta.for_item(&e.item)), w);
    }
    for fav in ctx.db.list_favorite_items("movie")? {
        taste.add(&movie_features(&fav, ctx.meta.for_item(&fav)), 1.0);
    }
    let taste = finish_taste(ctx, RecoKind::Movies, taste);
    let all = ctx.db.watched_entries("movie", 5_000)?;
    let watched_works = all.iter().map(|e| work_key(&e.item)).collect();
    let watched = all.into_iter().map(|e| e.item.stable_hash).collect();
    Ok(MovieState { taste, entries, watched, watched_works })
}

/// Unwatched films of the profile, one version each, with their features.
fn pool(ctx: &Ctx<'_>, st: &MovieState) -> Result<Vec<IptvItemRecord>, CndError> {
    let mut items = ctx.db.reco_item_pool("movie", POOL_TOP_RATED, POOL_NEWEST)?;
    let groups: Vec<String> = st
        .taste
        .top("group", 3)
        .into_iter()
        .filter_map(|(g, _)| {
            // The feature is lower-cased and trimmed: find the real category names of the history.
            st.entries.iter().filter_map(|e| e.item.group_title.clone()).find(|t| t.split_whitespace().collect::<Vec<_>>().join(" ").to_lowercase() == g)
        })
        .collect();
    let mut seen: HashSet<i64> = items.iter().map(|i| i.id).collect();
    for extra in ctx.db.reco_items_in_groups("movie", &groups, 200)? {
        if seen.insert(extra.id) {
            items.push(extra);
        }
    }
    let items = deduplicate_versions(items, None);
    Ok(items
        .into_iter()
        .filter(|i| {
            i.kind == "movie"
                && !st.watched.contains(&i.stable_hash)
                && !st.watched_works.contains(&work_key(i))
                && !ctx.dismissed.contains(&i.stable_hash)
        })
        .collect())
}

fn rating_bonus(item: &IptvItemRecord) -> f64 {
    item.imdb_rating.unwrap_or(0.0) / 10.0 * 0.4
}

/// Candidates scored against the taste, best first, with no more than 2 of the same genre in a row.
pub(crate) fn candidates(ctx: &Ctx<'_>, st: &MovieState, n: usize) -> Result<Vec<Cand>, CndError> {
    Ok(rank(ctx, st, &pool(ctx, st)?, n))
}

fn rank(ctx: &Ctx<'_>, st: &MovieState, base: &[IptvItemRecord], n: usize) -> Vec<Cand> {
    let mut out = Vec::new();
    for item in base.iter().cloned() {
        let features = movie_features(&item, ctx.meta.for_item(&item));
        let affinity = st.taste.score(&features);
        let reason = match st.taste.best_feature(&features) {
            Some((f, _)) if !st.taste.is_empty() => reason_for(f),
            _ => "Populaire dans vos sources".to_string(),
        };
        let score = affinity + rating_bonus(&item);
        out.push(Cand {
            title: item.name_clean.clone(),
            year: item.year,
            features,
            score,
            card: RecoCard::of_item(item, reason),
        });
    }
    diversify(out, 2, n)
}

fn title_of(item: &IptvItemRecord) -> String {
    item.name_clean.trim().to_string()
}

pub(crate) fn shelves(ctx: &Ctx<'_>) -> Result<Vec<RecoShelf>, CndError> {
    let st = state(ctx)?;
    let mut shelves: Vec<RecoShelf> = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();

    // 1. Resume: started, not finished.
    let resume: Vec<RecoCard> = st
        .entries
        .iter()
        .filter(|e| {
            !e.completed && e.position_ms > 0 && e.duration_ms > 0 && e.position_ms * 10 < e.duration_ms * 9 && !ctx.dismissed.contains(&e.item.stable_hash)
        })
        .take(ctx.limit)
        .map(|e| RecoCard::of_item(e.item.clone(), "Reprendre la lecture"))
        .collect();
    seen.extend(resume.iter().map(|c| c.hash()));
    shelves.push(RecoShelf::new(RecoKind::Movies, RecoShelfKind::Resume, "movies.resume", "Reprendre", resume));

    // 2. Next film of the sagas the user watches (the saga engine of PRD 27).
    let finished: Vec<&WatchedEntry> = {
        let mut roots = HashSet::new();
        st.entries
            .iter()
            .filter(|e| e.completed)
            .filter(|e| roots.insert(normalize_root_key(&parse_saga_title(&e.item.name_clean, e.item.year).root)))
            .collect()
    };
    let mut saga_cards = Vec::new();
    for e in finished.iter().take(4) {
        let Ok(recs) = ctx.engine.recommend_movie(&e.item, &ctx.dismissed, SagaOrderPreference::StoryChronology) else { continue };
        if let Some(next) = recs.into_iter().find(|c| {
            c.reason_kind == RecommendationReasonKind::SagaNext && !st.watched.contains(&c.item.stable_hash) && c.item.kind == "movie"
        }) {
            if seen.insert(next.item.stable_hash.clone()) {
                saga_cards.push(RecoCard::of_item(next.item, next.reason_text));
            }
        }
    }
    saga_cards.truncate(ctx.limit);
    shelves.push(RecoShelf::new(RecoKind::Movies, RecoShelfKind::Sagas, "movies.sagas", "Suite de vos sagas", saga_cards));

    // 3. For you (or the best of the sources for a profile with no history).
    let base = pool(ctx, &st)?;
    let ranked = rank(ctx, &st, &base, ctx.limit * 2 + 10);
    let (shelf, title, id, note) = if st.taste.is_empty() {
        (
            RecoShelfKind::Popular,
            "Populaires dans vos sources",
            "movies.popular",
            Some("Regardez quelques films : cette rangée s'adaptera à vos goûts."),
        )
    } else {
        (RecoShelfKind::ForYou, "Pour vous", "movies.foryou", None)
    };
    let for_you: Vec<RecoCard> = ranked
        .iter()
        .filter(|c| !seen.contains(&c.card.hash()))
        .take(ctx.limit)
        .map(|c| c.card.clone())
        .collect();
    seen.extend(for_you.iter().map(|c| c.hash()));
    let mut for_you_shelf = RecoShelf::new(RecoKind::Movies, shelf, id, title, for_you);
    for_you_shelf.note = note.map(str::to_string);
    shelves.push(for_you_shelf);

    // 4. Because you watched X (the last two different films finished).
    for e in st.entries.iter().filter(|e| e.completed).take(2) {
        let target = movie_features(&e.item, ctx.meta.for_item(&e.item));
        let mut similar: Vec<Cand> = base
            .iter()
            .filter(|i| !seen.contains(&i.stable_hash) && normalize_root_key(&i.name_clean) != normalize_root_key(&e.item.name_clean))
            .filter_map(|i| {
                let feats = movie_features(i, ctx.meta.for_item(i));
                let (score, best) = similarity(&target, &feats);
                (score > 0.0).then(|| Cand {
                    title: title_of(i),
                    year: i.year,
                    score: score + rating_bonus(i),
                    card: RecoCard::of_item(i.clone(), best.as_deref().map(reason_for).unwrap_or_else(|| "Contenu similaire".to_string())),
                    features: feats,
                })
            })
            .collect();
        similar = diversify(similar, 2, ctx.limit);
        seen.extend(similar.iter().map(|c| c.card.hash()));
        shelves.push(RecoShelf::new(
            RecoKind::Movies,
            RecoShelfKind::BecauseYouWatched,
            &format!("movies.because.{}", e.item.stable_hash),
            format!("Parce que vous avez regardé {}", title_of(&e.item)),
            similar.into_iter().map(|c| c.card).collect(),
        ));
    }

    // 5. New in the catalog, and close to the taste.
    let mut newest: Vec<&IptvItemRecord> = base.iter().filter(|i| !seen.contains(&i.stable_hash)).collect();
    newest.sort_by_key(|i| std::cmp::Reverse(i.id));
    let fresh: Vec<RecoCard> = newest
        .into_iter()
        .take(60)
        .filter_map(|i| {
            let feats = movie_features(i, ctx.meta.for_item(i));
            if st.taste.is_empty() || st.taste.score(&feats) <= 0.0 {
                return None;
            }
            let why = st.taste.best_feature(&feats).map(|(f, _)| reason_for(f)).unwrap_or_default();
            Some(RecoCard::of_item(i.clone(), format!("Nouveau · {why}")))
        })
        .take(ctx.limit)
        .collect();
    shelves.push(RecoShelf::new(RecoKind::Movies, RecoShelfKind::NewForYou, "movies.new", "Nouveautés pour vous", fresh));

    Ok(shelves)
}
