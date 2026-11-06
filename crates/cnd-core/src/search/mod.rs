//! Prompt search (PRD 33): one search over live channels, programmes, films and series.
//!
//! Step 1 reads the sentence (`query_parser`), step 2 searches the user's catalog (`engine`), steps 3
//! and 4 optionally let the user's AI provider understand the request and propose titles (`ai_search`).
//! Whatever the provider says, only items that exist in the catalog (and that the active profile may
//! see) are ever offered.

pub mod ai_search;
#[cfg(test)]
mod ai_tests;
pub mod engine;
#[cfg(test)]
pub(crate) mod eval;
pub mod fuzzy;
pub mod query_parser;

use crate::ai::AiAction;
use crate::db::epg_repo::EpgProgramRecord;
use crate::db::catalog_repo::SeriesRecord;
use crate::db::IptvItemRecord;

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SearchKind {
    Live,
    Program,
    Movie,
    Series,
}

impl From<query_parser::Kind> for SearchKind {
    fn from(kind: query_parser::Kind) -> Self {
        match kind {
            query_parser::Kind::Live => SearchKind::Live,
            query_parser::Kind::Program => SearchKind::Program,
            query_parser::Kind::Movie => SearchKind::Movie,
            query_parser::Kind::Series => SearchKind::Series,
        }
    }
}

/// One result. `item` is the channel (live, programme) or the film; `series` the series; `program` the
/// programme of a programme hit, carried by the channel in `item`.
#[derive(Debug, Clone, uniffi::Record)]
pub struct SearchHit {
    pub kind: SearchKind,
    pub item: Option<IptvItemRecord>,
    pub series: Option<SeriesRecord>,
    pub program: Option<EpgProgramRecord>,
    /// Why it is there: « Avec Tom Cruise », « Ce soir 21:00 sur Canal+ Sport ».
    pub reason: String,
    pub score: f64,
    /// Found thanks to a title proposed by the assistant.
    pub from_assistant: bool,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct SearchContext {
    pub playing_stable_hash: Option<String>,
    pub group_title: Option<String>,
    /// UI language such as `fr-FR`; reasons and replies are written in it.
    pub locale: String,
    /// Offset of the user's time zone from UTC, for "ce soir" and "demain".
    pub utc_offset_minutes: i32,
    /// What the user is looking for: TV (`Live`, `Program`), films, or series. Empty means everything.
    /// The screen the search was opened from sets it, so films never show up among channels and the
    /// other way round; nothing, not even the assistant, can widen it.
    pub kinds: Vec<SearchKind>,
}

impl From<SearchKind> for query_parser::Kind {
    fn from(kind: SearchKind) -> Self {
        match kind {
            SearchKind::Live => query_parser::Kind::Live,
            SearchKind::Program => query_parser::Kind::Program,
            SearchKind::Movie => query_parser::Kind::Movie,
            SearchKind::Series => query_parser::Kind::Series,
        }
    }
}

impl SearchContext {
    /// The scope as parser kinds (empty: no restriction).
    pub fn scope(&self) -> Vec<query_parser::Kind> {
        let mut kinds: Vec<query_parser::Kind> = Vec::new();
        for kind in &self.kinds {
            let k = query_parser::Kind::from(*kind);
            if !kinds.contains(&k) {
                kinds.push(k);
            }
        }
        kinds
    }

    /// Whether channel commands ("mets TF1", "chaîne 3") make sense here: only when TV is in scope.
    pub fn allows_channels(&self) -> bool {
        self.kinds.is_empty() || self.kinds.iter().any(|k| matches!(k, SearchKind::Live | SearchKind::Program))
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct SearchResponse {
    /// A direct command ("mets TF1", "chaîne suivante") resolved locally: the app performs it.
    pub command: Option<AiAction>,
    pub hits: Vec<SearchHit>,
    /// Titles the assistant knows that are not in the user's sources (text only, never playable).
    pub missing_titles: Vec<String>,
    pub reply: String,
    /// `"local"`, or the provider that understood the request.
    pub resolved_by: String,
    pub latency_ms: u64,
    pub fallback_reason: Option<String>,
}
