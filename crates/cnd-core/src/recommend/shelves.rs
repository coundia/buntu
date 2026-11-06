//! Shelves of recommendations per kind (PRD 34): « Pour vous », « Continuer », « En ce moment »…
//!
//! Films, series and TV are three separate systems. A shelf has ONE kind and every card of it is
//! checked against that kind before it leaves the engine (`finalize`), whatever produced it.

use crate::db::catalog_repo::SeriesRecord;
use crate::db::epg_repo::EpgProgramRecord;
use crate::db::reco_repo::{MetadataIndex, WatchedEntry};
use crate::db::{chrono_now_ts, DatabaseManager, IptvItemRecord};
use crate::recommend::taste::Taste;
use crate::{CndEngine, CndError};
use std::collections::HashSet;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum RecoKind {
    Movies,
    Series,
    Live,
}

impl RecoKind {
    /// The `iptv_items.kind` / taste key.
    pub fn key(self) -> &'static str {
        match self {
            RecoKind::Movies => "movie",
            RecoKind::Series => "series",
            RecoKind::Live => "live",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum RecoShelfKind {
    /// Movies started and not finished.
    Resume,
    /// Next episode of each series in progress.
    Continue,
    ForYou,
    /// New profile: the best of the sources.
    Popular,
    /// Next film of the sagas the user watches.
    Sagas,
    BecauseYouWatched,
    NewForYou,
    NewSeason,
    OnNow,
    Soon,
    UsualChannels,
    /// The guide has nothing on the air: no programme shelf, a message instead.
    GuideStale,
}

/// One card. Exactly one of `item`, `series` is the subject (a film or a channel, or a series);
/// `program` goes with a channel, `next_episode` with a series.
#[derive(Debug, Clone, uniffi::Record)]
pub struct RecoCard {
    pub item: Option<IptvItemRecord>,
    pub series: Option<SeriesRecord>,
    pub program: Option<EpgProgramRecord>,
    pub next_episode: Option<IptvItemRecord>,
    pub reason_text: String,
    /// The reason or the place of the card comes from the AI.
    pub ai_reason: bool,
}

impl RecoCard {
    pub fn of_item(item: IptvItemRecord, reason: impl Into<String>) -> Self {
        Self { item: Some(item), series: None, program: None, next_episode: None, reason_text: reason.into(), ai_reason: false }
    }

    pub fn of_series(series: SeriesRecord, next_episode: Option<IptvItemRecord>, reason: impl Into<String>) -> Self {
        Self { item: None, series: Some(series), program: None, next_episode, reason_text: reason.into(), ai_reason: false }
    }

    pub fn of_channel(channel: IptvItemRecord, program: Option<EpgProgramRecord>, reason: impl Into<String>) -> Self {
        Self { item: Some(channel), series: None, program, next_episode: None, reason_text: reason.into(), ai_reason: false }
    }

    /// The stable hash that "Pas intéressé" and the seen-sets use.
    pub fn hash(&self) -> String {
        match (&self.series, &self.item) {
            (Some(s), _) => s.stable_hash.clone(),
            (None, Some(i)) => i.stable_hash.clone(),
            _ => String::new(),
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct RecoShelf {
    pub id: String,
    pub kind: RecoKind,
    pub shelf: RecoShelfKind,
    pub title: String,
    pub items: Vec<RecoCard>,
    /// « Gemini », « Ollama (local) »… when the AI re-ranked this shelf.
    pub refined_by: Option<String>,
    /// A sentence under the title (why the shelf is what it is, or that the guide is out of date).
    pub note: Option<String>,
}

impl RecoShelf {
    pub fn new(kind: RecoKind, shelf: RecoShelfKind, id: &str, title: impl Into<String>, items: Vec<RecoCard>) -> Self {
        Self { id: id.to_string(), kind, shelf, title: title.into(), items, refined_by: None, note: None }
    }
}

/// A candidate with what the scoring and the AI prompt need.
#[derive(Debug, Clone)]
pub(crate) struct Cand {
    pub card: RecoCard,
    pub features: Vec<String>,
    pub score: f64,
    pub title: String,
    pub year: Option<u32>,
}

/// Everything one build of shelves shares.
pub(crate) struct Ctx<'a> {
    pub engine: &'a CndEngine,
    pub db: &'a DatabaseManager,
    pub now: i64,
    pub utc_offset_minutes: i32,
    pub limit: usize,
    pub dismissed: HashSet<String>,
    pub meta: MetadataIndex,
}

impl<'a> Ctx<'a> {
    pub fn new(engine: &'a CndEngine, limit_per_shelf: u32, utc_offset_minutes: i32) -> Result<Self, CndError> {
        Self::new_at(engine, limit_per_shelf, utc_offset_minutes, chrono_now_ts())
    }

    /// The same at a given time (tests and the AI flow share one clock).
    pub fn new_at(engine: &'a CndEngine, limit_per_shelf: u32, utc_offset_minutes: i32, now: i64) -> Result<Self, CndError> {
        let profile_id = engine.active_profile_id.load(std::sync::atomic::Ordering::Relaxed);
        Ok(Self {
            engine,
            db: &engine.db,
            now,
            utc_offset_minutes,
            limit: limit_per_shelf.clamp(1, 40) as usize,
            dismissed: engine.db.get_dismissed_hashes(profile_id).unwrap_or_default(),
            meta: engine.db.metadata_index().unwrap_or_default(),
        })
    }

    /// The watched entries the profile may still see (hidden or broken ones dropped), in order.
    pub fn visible_entries(&self, entries: Vec<WatchedEntry>) -> Vec<WatchedEntry> {
        let ids: Vec<i64> = entries.iter().map(|e| e.item.id).collect();
        let visible: HashSet<i64> = self
            .db
            .visible_items_by_ids(&ids)
            .unwrap_or_default()
            .into_iter()
            .map(|i| i.id)
            .collect();
        entries.into_iter().filter(|e| visible.contains(&e.item.id)).collect()
    }
}

/// Taste of one kind, finished with the profile's feedback.
pub(crate) fn finish_taste(ctx: &Ctx<'_>, kind: RecoKind, taste: Taste) -> Taste {
    let feedback = ctx.db.load_reco_feedback(kind.key()).unwrap_or_default();
    taste.finish(&feedback)
}

/// Orders by score, then keeps at most `max_run` neighbours with the same primary feature,
/// and stops at `limit` cards (the rest is never looked at).
pub(crate) fn diversify(mut cands: Vec<Cand>, max_run: usize, limit: usize) -> Vec<Cand> {
    cands.sort_by(|a, b| b.score.partial_cmp(&a.score).unwrap_or(std::cmp::Ordering::Equal));
    let primary: Vec<Option<String>> = cands
        .iter()
        .map(|c| crate::recommend::taste::primary_feature(&c.features).cloned())
        .collect();
    let mut used = vec![false; cands.len()];
    let mut order: Vec<usize> = Vec::with_capacity(limit.min(cands.len()));
    let mut first_free = 0;
    while order.len() < limit && first_free < cands.len() {
        while first_free < cands.len() && used[first_free] {
            first_free += 1;
        }
        if first_free >= cands.len() {
            break;
        }
        let n = order.len();
        let blocked: Option<&String> = if n >= max_run {
            let last = primary[order[n - 1]].as_ref();
            if last.is_some() && order[n - max_run..].iter().all(|&i| primary[i].as_ref() == last) {
                last
            } else {
                None
            }
        } else {
            None
        };
        let pick = match blocked {
            Some(f) => (first_free..cands.len()).find(|&i| !used[i] && primary[i].as_ref() != Some(f)).unwrap_or(first_free),
            None => first_free,
        };
        used[pick] = true;
        order.push(pick);
    }
    let mut slots: Vec<Option<Cand>> = cands.into_iter().map(Some).collect();
    order.into_iter().filter_map(|i| slots[i].take()).collect()
}

/// Whether a card belongs to a shelf of this kind (the second lock of PRD 34 § 2).
pub(crate) fn belongs(kind: RecoKind, card: &RecoCard) -> bool {
    match kind {
        RecoKind::Movies => {
            card.item.as_ref().is_some_and(|i| i.kind == "movie")
                && card.series.is_none()
                && card.program.is_none()
                && card.next_episode.is_none()
        }
        RecoKind::Series => card.series.as_ref().is_some_and(|s| {
            card.item.is_none()
                && card.program.is_none()
                && card.next_episode.as_ref().is_none_or(|e| e.kind == "episode" && e.series_id == Some(s.id))
        }),
        RecoKind::Live => {
            card.item.as_ref().is_some_and(|i| i.kind == "live")
                && card.series.is_none()
                && card.next_episode.is_none()
                && card.program.as_ref().is_none_or(|p| card.item.as_ref().and_then(|i| i.tvg_id.as_deref()) == Some(p.channel_tvg_id.as_str()))
        }
    }
}

/// Drops every card of another kind, empty shelves, and a card shown twice in one shelf.
/// Returns the shelves and how many foreign cards were removed (logged as `RECO`).
pub(crate) fn finalize(kind: RecoKind, shelves: Vec<RecoShelf>) -> (Vec<RecoShelf>, usize) {
    let mut removed = 0;
    let mut out = Vec::new();
    for mut shelf in shelves {
        shelf.kind = kind;
        let before = shelf.items.len();
        let mut seen = HashSet::new();
        shelf.items.retain(|c| belongs(kind, c) && seen.insert(c.hash()));
        removed += before - shelf.items.len();
        if !shelf.items.is_empty() || shelf.shelf == RecoShelfKind::GuideStale {
            out.push(shelf);
        }
    }
    (out, removed)
}

impl CndEngine {
    /// Local shelves of one kind: synchronous, no network.
    pub fn recommendation_shelves_impl(
        &self,
        kind: RecoKind,
        limit_per_shelf: u32,
        utc_offset_minutes: i32,
    ) -> Result<Vec<RecoShelf>, CndError> {
        self.recommendation_shelves_at(kind, limit_per_shelf, utc_offset_minutes, chrono_now_ts())
    }

    pub(crate) fn recommendation_shelves_at(
        &self,
        kind: RecoKind,
        limit_per_shelf: u32,
        utc_offset_minutes: i32,
        now: i64,
    ) -> Result<Vec<RecoShelf>, CndError> {
        let ctx = Ctx::new_at(self, limit_per_shelf, utc_offset_minutes, now)?;
        let shelves = match kind {
            RecoKind::Movies => crate::recommend::movies::shelves(&ctx)?,
            RecoKind::Series => crate::recommend::series::shelves(&ctx)?,
            RecoKind::Live => crate::recommend::live::shelves(&ctx)?,
        };
        let (shelves, removed) = finalize(kind, shelves);
        if removed > 0 {
            self.telemetry.warn("RECO", format!("{removed} carte(s) d'un autre type retirée(s) d'une rangée {}", kind.key()));
        }
        Ok(shelves)
    }

    /// "Moins de ce genre": lowers the main feature of this content, for this kind only, and hides it.
    pub fn less_like_this_impl(&self, kind: RecoKind, stable_hash: String) -> Result<(), CndError> {
        let ctx = Ctx::new(self, 10, 0)?;
        let feature = match kind {
            RecoKind::Movies => self.db.item_by_stable_hash(&stable_hash)?.filter(|i| i.kind == "movie").and_then(|i| {
                let f = crate::recommend::taste::movie_features(&i, ctx.meta.for_item(&i));
                crate::recommend::taste::primary_feature(&f).cloned()
            }),
            RecoKind::Series => self.db.series_by_stable_hash(&stable_hash)?.and_then(|s| {
                let f = crate::recommend::taste::series_features(&s, ctx.meta.for_series(&s));
                crate::recommend::taste::primary_feature(&f).cloned()
            }),
            RecoKind::Live => self.db.item_by_stable_hash(&stable_hash)?.filter(|i| i.kind == "live").and_then(|i| {
                let f = crate::recommend::taste::live_features(&i, None);
                f.into_iter().find(|f| f.starts_with("group:"))
            }),
        };
        if let Some(feature) = feature {
            self.db.add_reco_feedback(kind.key(), &feature, -1.5)?;
        }
        self.dismiss_recommendation_impl(stable_hash)?;
        self.db.invalidate_reco_ai_cache(kind.key())?;
        Ok(())
    }

    /// Forgets the taste feedback and the AI cache of one kind.
    pub fn reset_taste_impl(&self, kind: RecoKind) -> Result<(), CndError> {
        self.db.reset_reco_taste(kind.key())?;
        Ok(())
    }
}
