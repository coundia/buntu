//! Protocol messages and data types for cross-device playback ("Lire sur...", PRD-42).

pub use crate::sync::envelope::{PlayRefuseReason, SyncMessage};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum TargetAccessPolicy {
    /// Devices can play directly; if busy, requests user confirmation.
    #[default]
    Open,
    /// Every incoming request prompts the user: "Accept / Decline" (10s timeout, default decline).
    AlwaysAsk,
    /// Device is never available as a playback target.
    Disabled,
}

impl TargetAccessPolicy {
    pub fn default_for_device_type(device_type: &str) -> Self {
        match device_type.to_ascii_lowercase().as_str() {
            "tv" | "desktop" => Self::Open,
            _ => Self::AlwaysAsk,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TargetDeviceInfo {
    pub device_id: String,
    pub device_name: String,
    pub device_type: String,
    pub can_play: bool,
    pub capabilities: Vec<String>,
    pub state: String, // "idle" | "playing" | "busy"
    pub profile_uuid: Option<String>,
    pub kids: bool,
    pub last_seen_ms: u64,
}

impl TargetDeviceInfo {
    pub fn is_available(&self, now_ms: u64) -> bool {
        // Considered offline if not seen for > 120 seconds (PRD-42 § 2.1)
        if now_ms.saturating_sub(self.last_seen_ms) > 120_000 {
            return false;
        }
        self.can_play
    }
}
