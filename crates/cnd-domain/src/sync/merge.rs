//! Deterministic Last-Write-Wins (LWW) conflict resolution using HLC timestamps (PRD 41 § 4).

use super::clock::HlcTimestamp;
use super::records::*;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct HouseholdState {
    pub sources: HashMap<String, SyncSourceRecord>,
    pub profiles: HashMap<String, SyncProfileRecord>,
    pub favorites: HashMap<String, SyncFavoriteRecord>,
    pub progress: HashMap<String, SyncProgressRecord>,
    pub recents: HashMap<String, SyncRecentRecord>,
    pub last_channel: HashMap<String, SyncLastChannelRecord>,
    pub tombstones: HashMap<String, SyncTombstone>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct MergeReport {
    pub applied_sources: usize,
    pub applied_profiles: usize,
    pub applied_favorites: usize,
    pub applied_progress: usize,
    pub applied_recents: usize,
    pub applied_last_channel: usize,
    pub applied_tombstones: usize,
}

impl HouseholdState {
    pub fn new() -> Self {
        Self::default()
    }

    fn tombstone_key(kind: TombstoneKind, key: &str) -> String {
        format!("{:?}:{}", kind, key)
    }

    /// Merges an incoming SyncDelta into this household state.
    pub fn apply_delta(&mut self, delta: &SyncDelta) -> MergeReport {
        let mut report = MergeReport::default();

        // 1. Process incoming tombstones first
        for tb in &delta.tombstones {
            let tb_key = Self::tombstone_key(tb.kind, &tb.key);
            let should_apply = match self.tombstones.get(&tb_key) {
                Some(existing) => tb.hlc > existing.hlc,
                None => true,
            };

            if should_apply {
                // Delete corresponding live record if tombstone is newer or equal
                match tb.kind {
                    TombstoneKind::Source => {
                        if let Some(r) = self.sources.get(&tb.key) {
                            if tb.hlc >= r.hlc {
                                self.sources.remove(&tb.key);
                            }
                        }
                    }
                    TombstoneKind::Profile => {
                        if let Some(r) = self.profiles.get(&tb.key) {
                            if tb.hlc >= r.hlc {
                                self.profiles.remove(&tb.key);
                            }
                        }
                    }
                    TombstoneKind::Favorite => {
                        if let Some(r) = self.favorites.get(&tb.key) {
                            if tb.hlc >= r.hlc {
                                self.favorites.remove(&tb.key);
                            }
                        }
                    }
                    TombstoneKind::Progress => {
                        if let Some(r) = self.progress.get(&tb.key) {
                            if tb.hlc >= r.hlc {
                                self.progress.remove(&tb.key);
                            }
                        }
                    }
                    TombstoneKind::Recent => {
                        if let Some(r) = self.recents.get(&tb.key) {
                            if tb.hlc >= r.hlc {
                                self.recents.remove(&tb.key);
                            }
                        }
                    }
                    TombstoneKind::LastChannel => {
                        if let Some(r) = self.last_channel.get(&tb.key) {
                            if tb.hlc >= r.hlc {
                                self.last_channel.remove(&tb.key);
                            }
                        }
                    }
                }
                self.tombstones.insert(tb_key, tb.clone());
                report.applied_tombstones += 1;
            }
        }

        // 2. Process sources
        for s in &delta.sources {
            let tb_key = Self::tombstone_key(TombstoneKind::Source, &s.source_key);
            if let Some(tb) = self.tombstones.get(&tb_key) {
                if tb.hlc >= s.hlc {
                    continue;
                }
            }
            let is_newer = self
                .sources
                .get(&s.source_key)
                .map(|cur| s.hlc > cur.hlc)
                .unwrap_or(true);
            if is_newer {
                self.sources.insert(s.source_key.clone(), s.clone());
                report.applied_sources += 1;
            }
        }

        // 3. Process profiles
        for p in &delta.profiles {
            let tb_key = Self::tombstone_key(TombstoneKind::Profile, &p.uuid);
            if let Some(tb) = self.tombstones.get(&tb_key) {
                if tb.hlc >= p.hlc {
                    continue;
                }
            }
            let is_newer = self
                .profiles
                .get(&p.uuid)
                .map(|cur| p.hlc > cur.hlc)
                .unwrap_or(true);
            if is_newer {
                self.profiles.insert(p.uuid.clone(), p.clone());
                report.applied_profiles += 1;
            }
        }

        // 4. Process favorites
        for f in &delta.favorites {
            let key = format!("{}:{}", f.profile_uuid, f.content_key);
            let tb_key = Self::tombstone_key(TombstoneKind::Favorite, &key);
            if let Some(tb) = self.tombstones.get(&tb_key) {
                if tb.hlc >= f.hlc {
                    continue;
                }
            }
            let is_newer = self
                .favorites
                .get(&key)
                .map(|cur| f.hlc > cur.hlc)
                .unwrap_or(true);
            if is_newer {
                self.favorites.insert(key, f.clone());
                report.applied_favorites += 1;
            }
        }

        // 5. Process progress
        for prg in &delta.progress {
            let key = format!("{}:{}", prg.profile_uuid, prg.content_key);
            let tb_key = Self::tombstone_key(TombstoneKind::Progress, &key);
            if let Some(tb) = self.tombstones.get(&tb_key) {
                if tb.hlc >= prg.hlc {
                    continue;
                }
            }
            let is_newer = self
                .progress
                .get(&key)
                .map(|cur| prg.hlc > cur.hlc)
                .unwrap_or(true);
            if is_newer {
                self.progress.insert(key, prg.clone());
                report.applied_progress += 1;
            }
        }

        // 6. Process recents
        for rc in &delta.recents {
            let key = format!("{}:{}", rc.profile_uuid, rc.content_key);
            let tb_key = Self::tombstone_key(TombstoneKind::Recent, &key);
            if let Some(tb) = self.tombstones.get(&tb_key) {
                if tb.hlc >= rc.hlc {
                    continue;
                }
            }
            let is_newer = self
                .recents
                .get(&key)
                .map(|cur| rc.hlc > cur.hlc)
                .unwrap_or(true);
            if is_newer {
                self.recents.insert(key, rc.clone());
                report.applied_recents += 1;
            }
        }

        // 7. Process last channel
        if let Some(lc) = &delta.last_channel {
            let key = lc.profile_uuid.clone();
            let tb_key = Self::tombstone_key(TombstoneKind::LastChannel, &key);
            if let Some(tb) = self.tombstones.get(&tb_key) {
                if tb.hlc >= lc.hlc {
                    return report;
                }
            }
            let is_newer = self
                .last_channel
                .get(&key)
                .map(|cur| lc.hlc > cur.hlc)
                .unwrap_or(true);
            if is_newer {
                self.last_channel.insert(key, lc.clone());
                report.applied_last_channel += 1;
            }
        }

        report
    }

    /// Exports changes that occurred strictly after `from_hlc`.
    pub fn export_delta(&self, from_hlc: Option<&HlcTimestamp>, to_hlc: HlcTimestamp) -> SyncDelta {
        let is_after = |hlc: &HlcTimestamp| match from_hlc {
            Some(from) => hlc > from,
            None => true,
        };

        SyncDelta {
            from_hlc: from_hlc.cloned(),
            to_hlc,
            sources: self
                .sources
                .values()
                .filter(|s| is_after(&s.hlc))
                .cloned()
                .collect(),
            profiles: self
                .profiles
                .values()
                .filter(|p| is_after(&p.hlc))
                .cloned()
                .collect(),
            favorites: self
                .favorites
                .values()
                .filter(|f| is_after(&f.hlc))
                .cloned()
                .collect(),
            progress: self
                .progress
                .values()
                .filter(|p| is_after(&p.hlc))
                .cloned()
                .collect(),
            recents: self
                .recents
                .values()
                .filter(|r| is_after(&r.hlc))
                .cloned()
                .collect(),
            last_channel: self
                .last_channel
                .values()
                .filter(|l| is_after(&l.hlc))
                .max_by(|a, b| a.hlc.cmp(&b.hlc))
                .cloned(),
            tombstones: self
                .tombstones
                .values()
                .filter(|t| is_after(&t.hlc))
                .cloned()
                .collect(),
        }
    }
}
