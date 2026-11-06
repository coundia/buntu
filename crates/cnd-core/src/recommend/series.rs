//! Series shelves (PRD 34 § 5.2). The unit is the SERIES: a card is a series, with at most the
//! next episode of that same series. No episode of another series is ever proposed.

use crate::db::catalog_repo::SeriesRecord;
use crate::db::reco_repo::WatchedEntry;
use crate::db::IptvItemRecord;
use crate::recommend::shelves::{diversify, finish_taste, Cand, Ctx, RecoCard, RecoKind, RecoShelf, RecoShelfKind};
use crate::recommend::taste::{reason_for, series_features, series_weight, similarity, Taste};
use crate::CndError;
use std::collections::{HashMap, HashSet};

const POOL_TOP_RATED: u32 = 300;
const POOL_NEWEST: u32 = 150;
/// A season added to the catalog after the last watch, within this many days, is "new".
const NEW_SEASON_DAYS: i64 = 45;
/// Series of the history whose next episode is looked up (the most recently watched ones).
const MAX_SERIES_EXAMINED: usize = 60;

/// What the profile has seen of one series.
#[derive(Debug, Clone)]
pub(crate) struct Progress {
    pub series_id: i64,
    pub last: WatchedEntry,
    pub watched: u32,
    pub completed: u32,
}

/// The next episode to watch in a series: resume the one in progress, else the first one after it.
#[derive(Debug, Clone)]
pub(crate) enum Next {
    Resume(IptvItemRecord),
    Episode(IptvItemRecord),
    /// The first episode of a later season (the caller decides if that season is new).
    Season(IptvItemRecord),
    Finished,
}

pub(crate) fn progress(ctx: &Ctx<'_>) -> Result<Vec<Progress>, CndError> {
    let entries = ctx.db.watched_entries("episode", 1_000)?;
    let mut by_series: HashMap<i64, Progress> = HashMap::new();
    let mut order = Vec::new();
    for e in entries {
        let Some(series_id) = e.item.series_id else { continue };
        match by_series.get_mut(&series_id) {
            Some(p) => {
                p.watched += 1;
                p.completed += u32::from(e.completed);
            }
            None => {
                order.push(series_id);
                by_series.insert(series_id, Progress { series_id, completed: u32::from(e.completed), watched: 1, last: e });
            }
        }
    }
    // Entries come most recent first: `order` is the order of the last watch.
    Ok(order.into_iter().filter_map(|id| by_series.remove(&id)).collect())
}

/// Pure choice of the next episode, from the list of the series' episodes in order.
pub(crate) fn next_episode(episodes: &[IptvItemRecord], last: &IptvItemRecord, last_completed: bool, last_position_ms: i64, last_duration_ms: i64) -> Next {
    let key = |e: &IptvItemRecord| (e.season_num.unwrap_or(1), e.episode_num.unwrap_or(1));
    let in_progress = !last_completed && last_position_ms > 0 && last_duration_ms > 0 && last_position_ms * 100 < last_duration_ms * 92;
    if in_progress {
        return Next::Resume(last.clone());
    }
    let last_key = key(last);
    match episodes.iter().filter(|e| key(e) > last_key && !e.is_completed).min_by_key(|e| key(e)) {
        Some(e) if key(e).0 > last_key.0 => Next::Season(e.clone()),
        Some(e) => Next::Episode(e.clone()),
        None => Next::Finished,
    }
}

fn label(e: &IptvItemRecord) -> String {
    format!("S{}:E{}", e.season_num.unwrap_or(1), e.episode_num.unwrap_or(1))
}

pub(crate) struct SeriesState {
    pub taste: Taste,
    pub progress: Vec<Progress>,
    pub visible: HashMap<i64, SeriesRecord>,
}

pub(crate) fn state(ctx: &Ctx<'_>) -> Result<SeriesState, CndError> {
    let progress = progress(ctx)?;
    let ids: Vec<i64> = progress.iter().map(|p| p.series_id).collect();
    let visible: HashMap<i64, SeriesRecord> = ctx.db.visible_series_by_ids(&ids)?.into_iter().map(|s| (s.id, s)).collect();
    let mut taste = Taste::default();
    for p in &progress {
        if let Some(s) = visible.get(&p.series_id) {
            let w = series_weight(p.watched, p.completed, s.episode_count, p.last.last_watched_at, ctx.now);
            taste.add(&series_features(s, ctx.meta.for_series(s)), w);
        }
    }
    for fav in ctx.db.list_favorite_series()? {
        taste.add(&series_features(&fav, ctx.meta.for_series(&fav)), 1.0);
    }
    Ok(SeriesState { taste: finish_taste(ctx, RecoKind::Series, taste), progress, visible })
}

/// Series never started by the profile, with their features and score.
pub(crate) fn candidates(ctx: &Ctx<'_>, st: &SeriesState, n: usize) -> Result<Vec<Cand>, CndError> {
    let pool = ctx.db.reco_series_pool(POOL_TOP_RATED, POOL_NEWEST)?;
    Ok(rank(ctx, st, pool, n))
}

fn rank(ctx: &Ctx<'_>, st: &SeriesState, pool: Vec<SeriesRecord>, n: usize) -> Vec<Cand> {
    let started: HashSet<i64> = st.progress.iter().map(|p| p.series_id).collect();
    let mut out = Vec::new();
    for s in pool {
        if started.contains(&s.id) || ctx.dismissed.contains(&s.stable_hash) {
            continue;
        }
        let features = series_features(&s, ctx.meta.for_series(&s));
        let reason = match st.taste.best_feature(&features) {
            Some((f, _)) if !st.taste.is_empty() => reason_for(f),
            _ => "Populaire dans vos sources".to_string(),
        };
        let score = st.taste.score(&features) + s.imdb_rating.unwrap_or(0.0) / 10.0 * 0.4;
        out.push(Cand { title: s.title.clone(), year: None, features, score, card: RecoCard::of_series(s, None, reason) });
    }
    diversify(out, 2, n)
}

/// The first episode of a series, for a card of a series not started yet.
fn with_first_episode(ctx: &Ctx<'_>, mut card: RecoCard) -> RecoCard {
    if let Some(s) = &card.series {
        card.next_episode = ctx.db.first_episode_of(s.id).ok().flatten();
    }
    card
}

pub(crate) fn shelves(ctx: &Ctx<'_>) -> Result<Vec<RecoShelf>, CndError> {
    let st = state(ctx)?;
    let mut seen: HashSet<String> = HashSet::new();
    let mut shelves = Vec::new();

    // 1. Continue (and: a season that arrived after the last watch).
    let mut keep_going = Vec::new();
    let mut new_season = Vec::new();
    for p in st.progress.iter().take(MAX_SERIES_EXAMINED) {
        if keep_going.len() >= ctx.limit && new_season.len() >= ctx.limit {
            break;
        }
        let Some(series) = st.visible.get(&p.series_id) else { continue };
        if ctx.dismissed.contains(&series.stable_hash) {
            continue;
        }
        let episodes = ctx.db.get_series_episodes(p.series_id, None)?;
        match next_episode(&episodes, &p.last.item, p.last.completed, p.last.position_ms, p.last.duration_ms) {
            Next::Resume(e) => {
                let why = format!("Reprendre {}", label(&e));
                keep_going.push(RecoCard::of_series(series.clone(), Some(e), why));
            }
            Next::Episode(e) => {
                let why = format!("Épisode suivant · {}", label(&e));
                keep_going.push(RecoCard::of_series(series.clone(), Some(e), why));
            }
            Next::Season(e) => {
                let season = e.season_num.unwrap_or(1);
                let added = ctx.db.season_first_added(p.series_id, season)?.unwrap_or(0);
                let is_new = added > p.last.last_watched_at && ctx.now - added <= NEW_SEASON_DAYS * 86_400;
                if is_new {
                    new_season.push(RecoCard::of_series(series.clone(), Some(e), format!("Nouvelle saison · S{season}")));
                } else {
                    let why = format!("Saison suivante · {}", label(&e));
                    keep_going.push(RecoCard::of_series(series.clone(), Some(e), why));
                }
            }
            Next::Finished => {}
        }
    }
    keep_going.truncate(ctx.limit);
    new_season.truncate(ctx.limit);
    seen.extend(keep_going.iter().chain(new_season.iter()).map(|c| c.hash()));
    shelves.push(RecoShelf::new(RecoKind::Series, RecoShelfKind::Continue, "series.continue", "Continuer", keep_going));
    shelves.push(RecoShelf::new(RecoKind::Series, RecoShelfKind::NewSeason, "series.newseason", "Nouvelle saison disponible", new_season));

    // 2. For you / popular.
    let pool = ctx.db.reco_series_pool(POOL_TOP_RATED, POOL_NEWEST)?;
    let base = rank(ctx, &st, pool.clone(), 400);
    let ranked = &base[..base.len().min(ctx.limit * 2 + 10)];
    let (shelf, title, id, note) = if st.taste.is_empty() {
        (
            RecoShelfKind::Popular,
            "Populaires dans vos sources",
            "series.popular",
            Some("Regardez quelques séries : cette rangée s'adaptera à vos goûts."),
        )
    } else {
        (RecoShelfKind::ForYou, "Pour vous", "series.foryou", None)
    };
    let for_you: Vec<RecoCard> = ranked
        .iter()
        .filter(|c| !seen.contains(&c.card.hash()))
        .take(ctx.limit)
        .map(|c| with_first_episode(ctx, c.card.clone()))
        .collect();
    seen.extend(for_you.iter().map(|c| c.hash()));
    let mut for_you_shelf = RecoShelf::new(RecoKind::Series, shelf, id, title, for_you);
    for_you_shelf.note = note.map(str::to_string);
    shelves.push(for_you_shelf);

    // 3. Because you watched Y (the last two series, by last watch).
    for p in st.progress.iter().take(2) {
        let Some(series) = st.visible.get(&p.series_id) else { continue };
        let target = series_features(series, ctx.meta.for_series(series));
        let mut similar: Vec<Cand> = base
            .iter()
            .filter(|c| !seen.contains(&c.card.hash()))
            .filter_map(|c| {
                let (score, best) = similarity(&target, &c.features);
                (score > 0.0).then(|| {
                    let mut cand = c.clone();
                    cand.score = score + c.score * 0.2;
                    cand.card.reason_text = best.as_deref().map(reason_for).unwrap_or_else(|| "Série proche".to_string());
                    cand
                })
            })
            .collect();
        similar = diversify(similar, 2, ctx.limit);
        let cards: Vec<RecoCard> = similar.into_iter().map(|c| with_first_episode(ctx, c.card)).collect();
        seen.extend(cards.iter().map(|c| c.hash()));
        shelves.push(RecoShelf::new(
            RecoKind::Series,
            RecoShelfKind::BecauseYouWatched,
            &format!("series.because.{}", series.stable_hash),
            format!("Parce que vous avez regardé {}", series.title),
            cards,
        ));
    }
    Ok(shelves)
}
