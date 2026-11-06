//! TV shelves (PRD 34 § 5.3): programmes on the air or about to start on channels the profile likes.
//! Only channels and their programmes. Without a current guide, no programme shelf is built.

use crate::db::epg_repo::{compute_progress_ratio, EpgProgramRecord};
use crate::db::reco_repo::WatchedEntry;
use crate::db::IptvItemRecord;
use crate::recommend::shelves::{finish_taste, Cand, Ctx, RecoCard, RecoKind, RecoShelf, RecoShelfKind};
use crate::recommend::taste::{channel_family, live_features, reason_for, slot_of, watch_weight, Taste};
use crate::CndError;
use std::collections::HashSet;

/// Programmes read from the guide for one build (a guide has thousands of channels).
const AIRING_LIMIT: u32 = 2_000;
/// Candidates kept after scoring (the AI gets 60, a shelf shows a dozen).
const KEEP: usize = 150;
/// "Bientôt": what starts within two hours.
const SOON_SECS: i64 = 2 * 3_600;
/// A guide older than this has nothing for "now".
pub(crate) const STALE_NOTE: &str = "Le guide TV n'est pas à jour : aucun programme n'est en cours. Actualisez les sources pour le recharger.";

pub(crate) struct LiveState {
    pub taste: Taste,
    pub entries: Vec<WatchedEntry>,
    pub favorites: HashSet<String>,
}

pub(crate) fn state(ctx: &Ctx<'_>) -> Result<LiveState, CndError> {
    let entries = ctx.visible_entries(ctx.db.watched_entries("live", 200)?);
    let mut taste = Taste::default();
    for e in &entries {
        // The programme that was on when the channel was watched, when the guide still holds it.
        let category = e
            .item
            .tvg_id
            .as_deref()
            .and_then(|t| ctx.db.program_at(t, e.last_watched_at).ok().flatten())
            .and_then(|p| p.category);
        let mut features = live_features(&e.item, category.as_deref());
        features.push(format!("slot:{}", slot_of(e.last_watched_at, ctx.utc_offset_minutes)));
        taste.add(&features, watch_weight(e.position_ms, e.duration_ms, e.completed, e.last_watched_at, ctx.now));
    }
    let mut favorites = HashSet::new();
    for fav in ctx.db.list_favorite_items("live")? {
        taste.add(&live_features(&fav, None), 1.0);
        favorites.insert(channel_family(&fav.name_clean));
    }
    Ok(LiveState { taste: finish_taste(ctx, RecoKind::Live, taste), entries, favorites })
}

fn with_progress(mut p: EpgProgramRecord, now: i64) -> EpgProgramRecord {
    p.progress_ratio = compute_progress_ratio(p.start_ts, p.end_ts, now);
    p
}

/// Programmes on the air at `at`, scored. One per channel family, best version of a channel first
/// (a favorite, then HD).
pub(crate) fn airing_candidates(ctx: &Ctx<'_>, st: &LiveState, at: i64, until: i64, now: i64) -> Result<Vec<Cand>, CndError> {
    let slot = format!("slot:{}", slot_of(at.max(now), ctx.utc_offset_minutes));
    let rows = ctx.db.reco_airing_with_channels(at, until, AIRING_LIMIT)?;
    // Score every row without cloning anything; keep the best row of each channel family.
    struct Scored {
        family: String,
        idx: usize,
        score: f64,
        features: Vec<String>,
        reason: String,
    }
    let mut best: std::collections::HashMap<String, Scored> = std::collections::HashMap::new();
    for (idx, (channel, program)) in rows.iter().enumerate() {
        if channel.kind != "live" || ctx.dismissed.contains(&channel.stable_hash) {
            continue;
        }
        let family = channel_family(&channel.name_clean);
        let mut features = live_features(channel, program.category.as_deref());
        features.push(slot.clone());
        let mut score = st.taste.score(&features);
        if st.favorites.contains(&family) || channel.is_favorite {
            score += 0.6;
        }
        let reason = match st.taste.best_feature(&features) {
            Some((f, _)) if !st.taste.is_empty() => reason_for(f),
            _ if channel.is_favorite => "Une de vos chaînes favorites".to_string(),
            _ => "En ce moment".to_string(),
        };
        // A little for the better version of a channel (HD over SD) so it wins its family.
        let name = channel.name_clean.to_lowercase();
        if name.contains("fhd") || name.contains("4k") || name.contains(" hd") {
            score += 0.01;
        }
        if best.get(&family).is_none_or(|old| score > old.score) {
            best.insert(family.clone(), Scored { family, idx, score, features, reason });
        }
    }
    let mut kept: Vec<Scored> = best.into_values().collect();
    kept.sort_by(|a, b| {
        b.score
            .partial_cmp(&a.score)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then(rows[a.idx].1.title.cmp(&rows[b.idx].1.title))
            .then(a.family.cmp(&b.family))
    });
    kept.truncate(KEEP);
    let mut slots: Vec<Option<(IptvItemRecord, EpgProgramRecord)>> = rows.into_iter().map(Some).collect();
    Ok(kept
        .into_iter()
        .filter_map(|s| {
            let (channel, program) = slots[s.idx].take()?;
            Some(Cand {
                title: program.title.clone(),
                year: None,
                features: s.features,
                score: s.score,
                card: RecoCard::of_channel(channel, Some(with_progress(program, now)), s.reason),
            })
        })
        .collect())
}

/// At most two channels of the same group in a row.
fn spread(cands: Vec<Cand>, n: usize) -> Vec<Cand> {
    let group = |c: &Cand| c.card.item.as_ref().and_then(|i| i.group_title.clone());
    let mut rest = cands;
    let mut out: Vec<Cand> = Vec::new();
    while !rest.is_empty() && out.len() < n {
        let len = out.len();
        let blocked = if len >= 2 && group(&out[len - 1]).is_some() && group(&out[len - 1]) == group(&out[len - 2]) {
            group(&out[len - 1])
        } else {
            None
        };
        let pick = rest.iter().position(|c| blocked.is_none() || group(c) != blocked).unwrap_or(0);
        out.push(rest.remove(pick));
    }
    out
}

/// Channels the profile watches at this time of the week; else the ones watched last.
fn usual_channels(ctx: &Ctx<'_>, st: &LiveState) -> (Vec<RecoCard>, bool) {
    let slot_now = slot_of(ctx.now, ctx.utc_offset_minutes);
    let pick = |matching: bool| -> Vec<RecoCard> {
        let mut seen = HashSet::new();
        st.entries
            .iter()
            .filter(|e| !ctx.dismissed.contains(&e.item.stable_hash))
            .filter(|e| !matching || slot_of(e.last_watched_at, ctx.utc_offset_minutes) == slot_now)
            .filter(|e| seen.insert(channel_family(&e.item.name_clean)))
            .take(ctx.limit)
            .map(|e| {
                let why = if matching { "Vous la regardez à cette heure-ci" } else { "Chaîne récente" };
                RecoCard::of_channel(e.item.clone(), None, why)
            })
            .collect()
    };
    let in_slot = pick(true);
    if in_slot.is_empty() {
        (pick(false), false)
    } else {
        (in_slot, true)
    }
}

pub(crate) fn shelves(ctx: &Ctx<'_>) -> Result<Vec<RecoShelf>, CndError> {
    let st = state(ctx)?;
    let fresh = ctx.db.epg_freshness(ctx.now)?;
    let (usual, by_slot) = usual_channels(ctx, &st);
    let usual_title = if by_slot { "Vos chaînes à cette heure-ci" } else { "Vos chaînes récentes" };
    let usual_shelf = RecoShelf::new(RecoKind::Live, RecoShelfKind::UsualChannels, "live.usual", usual_title, usual);

    if fresh.on_air_now == 0 {
        let mut stale = RecoShelf::new(RecoKind::Live, RecoShelfKind::GuideStale, "live.stale", "Guide TV non à jour", Vec::new());
        stale.note = Some(STALE_NOTE.to_string());
        return Ok(vec![stale, usual_shelf]);
    }

    let mut shelves = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();

    // On the air now.
    let now_cands = airing_candidates(ctx, &st, ctx.now, ctx.now + 1, ctx.now)?;
    let on_now: Vec<RecoCard> = spread(now_cands, ctx.limit).into_iter().map(|c| c.card).collect();
    seen.extend(on_now.iter().map(|c| c.hash()));
    let mut shelf = RecoShelf::new(RecoKind::Live, RecoShelfKind::OnNow, "live.now", "En ce moment pour vous", on_now);
    if st.taste.is_empty() {
        shelf.note = Some("Regardez quelques chaînes : cette rangée s'adaptera à vos goûts.".to_string());
    }
    shelves.push(shelf);

    // Starting within two hours, on channels the profile likes (a positive affinity).
    let soon_cands: Vec<Cand> = airing_candidates(ctx, &st, ctx.now + 1, ctx.now + SOON_SECS, ctx.now)?
        .into_iter()
        .filter(|c| c.card.program.as_ref().is_some_and(|p| p.start_ts > ctx.now))
        .filter(|c| (st.taste.is_empty() && c.score > 0.0) || c.score > 0.5)
        .filter(|c| !seen.contains(&c.card.hash()))
        .collect();
    let mut soon: Vec<Cand> = spread(soon_cands, ctx.limit * 2);
    soon.sort_by_key(|c| c.card.program.as_ref().map(|p| p.start_ts).unwrap_or(i64::MAX));
    soon.truncate(ctx.limit);
    let soon: Vec<RecoCard> = soon
        .into_iter()
        .map(|mut c| {
            if let Some(p) = &c.card.program {
                let minutes = ((p.start_ts - ctx.now) / 60).max(1);
                c.card.reason_text = format!("Dans {minutes} min · {}", c.card.reason_text);
            }
            c.card
        })
        .collect();
    shelves.push(RecoShelf::new(RecoKind::Live, RecoShelfKind::Soon, "live.soon", "Bientôt", soon));

    shelves.push(usual_shelf);
    Ok(shelves)
}

/// A channel with the programme on the air on it right now, for a card of the usual-channels shelf.
#[allow(dead_code)]
pub(crate) fn channel_with_program(ctx: &Ctx<'_>, channel: IptvItemRecord) -> RecoCard {
    let program = channel.tvg_id.as_deref().and_then(|t| ctx.db.program_at(t, ctx.now).ok().flatten()).map(|p| with_progress(p, ctx.now));
    RecoCard::of_channel(channel, program, "")
}
