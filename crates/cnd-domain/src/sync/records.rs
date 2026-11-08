//! Data models for serverless household synchronization (PRD 41 § 4).

use super::clock::HlcTimestamp;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SyncSourceRecord {
    pub source_key: String,
    pub name: String,
    pub source_type: String, // "xtream" | "m3u"
    pub server_or_url: String,
    #[serde(default)]
    pub username: Option<String>,
    #[serde(default)]
    pub password: Option<String>, // End-to-end encrypted across household
    #[serde(default)]
    pub epg_url: Option<String>,
    pub hlc: HlcTimestamp,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SyncProfileRecord {
    pub uuid: String,
    pub name: String,
    pub avatar: String,
    pub is_kids: bool,
    #[serde(default)]
    pub restrictions: Vec<String>,
    pub hlc: HlcTimestamp,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SyncFavoriteRecord {
    pub profile_uuid: String,
    pub content_key: String,
    pub item_kind: String, // "live" | "movie" | "series"
    pub hlc: HlcTimestamp,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SyncProgressRecord {
    pub profile_uuid: String,
    pub content_key: String,
    pub item_kind: String, // "movie" | "episode"
    pub position_ms: u64,
    pub duration_ms: u64,
    pub completed: bool,
    pub hlc: HlcTimestamp,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SyncRecentRecord {
    pub profile_uuid: String,
    pub content_key: String,
    pub item_kind: String, // "live" | "movie" | "series"
    pub title: Option<String>,
    pub hlc: HlcTimestamp,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SyncLastChannelRecord {
    pub profile_uuid: String,
    pub content_key: String,
    pub channel_name: Option<String>,
    pub hlc: HlcTimestamp,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TombstoneKind {
    Source,
    Profile,
    Favorite,
    Progress,
    Recent,
    LastChannel,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SyncTombstone {
    pub kind: TombstoneKind,
    pub key: String, // e.g. source_key, uuid, or "profile_uuid:content_key"
    pub hlc: HlcTimestamp,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SyncDelta {
    #[serde(default)]
    pub from_hlc: Option<HlcTimestamp>,
    pub to_hlc: HlcTimestamp,
    #[serde(default)]
    pub sources: Vec<SyncSourceRecord>,
    #[serde(default)]
    pub profiles: Vec<SyncProfileRecord>,
    #[serde(default)]
    pub favorites: Vec<SyncFavoriteRecord>,
    #[serde(default)]
    pub progress: Vec<SyncProgressRecord>,
    #[serde(default)]
    pub recents: Vec<SyncRecentRecord>,
    #[serde(default)]
    pub last_channel: Option<SyncLastChannelRecord>,
    #[serde(default)]
    pub tombstones: Vec<SyncTombstone>,
}

impl SyncDelta {
    pub fn is_empty(&self) -> bool {
        self.sources.is_empty()
            && self.profiles.is_empty()
            && self.favorites.is_empty()
            && self.progress.is_empty()
            && self.recents.is_empty()
            && self.last_channel.is_none()
            && self.tombstones.is_empty()
    }
}

