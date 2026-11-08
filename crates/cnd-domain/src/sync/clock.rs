//! Hybrid Logical Clock (HLC) for serverless multi-device synchronization (PRD 41 § 4).
//!
//! Solves clock skew between home devices (e.g. ± 10 min) while ensuring strict causality:
//! if event B was created after receiving event A, B.hlc is guaranteed to be strictly greater than A.hlc.

use serde::{Deserialize, Deserializer, Serialize, Serializer};
use std::cmp::Ordering;

#[derive(Debug, Clone, Default, PartialEq, Eq, Hash)]
pub struct HlcTimestamp {
    pub physical_ms: u64,
    pub counter: u32,
    pub node_id: String,
}

impl HlcTimestamp {
    pub fn new(physical_ms: u64, counter: u32, node_id: impl Into<String>) -> Self {
        Self {
            physical_ms,
            counter,
            node_id: node_id.into(),
        }
    }

    pub fn to_compact_string(&self) -> String {
        format!("{}.{}.{}", self.physical_ms, self.counter, self.node_id)
    }

    pub fn parse_compact(s: &str) -> Option<Self> {
        let mut parts = s.split('.');
        let p_str = parts.next()?;
        let c_str = parts.next()?;
        let node_id = parts.next()?.to_string();
        if parts.next().is_some() {
            return None;
        }
        let physical_ms = p_str.parse().ok()?;
        let counter = c_str.parse().ok()?;
        Some(Self {
            physical_ms,
            counter,
            node_id,
        })
    }
}

impl PartialOrd for HlcTimestamp {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for HlcTimestamp {
    fn cmp(&self, other: &Self) -> Ordering {
        self.physical_ms
            .cmp(&other.physical_ms)
            .then_with(|| self.counter.cmp(&other.counter))
            .then_with(|| self.node_id.cmp(&other.node_id))
    }
}

impl Serialize for HlcTimestamp {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_str(&self.to_compact_string())
    }
}

impl<'de> Deserialize<'de> for HlcTimestamp {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let s = String::deserialize(deserializer)?;
        Self::parse_compact(&s).ok_or_else(|| serde::de::Error::custom("invalid HLC timestamp format"))
    }
}

/// Node clock tracking state.
#[derive(Debug, Clone)]
pub struct HlcClock {
    pub node_id: String,
    pub latest: HlcTimestamp,
}

impl HlcClock {
    pub fn new(node_id: impl Into<String>) -> Self {
        let node_id = node_id.into();
        Self {
            latest: HlcTimestamp::new(0, 0, &node_id),
            node_id,
        }
    }

    /// Ticks the clock for a new local event.
    pub fn now(&mut self, physical_now_ms: u64) -> HlcTimestamp {
        if physical_now_ms > self.latest.physical_ms {
            self.latest.physical_ms = physical_now_ms;
            self.latest.counter = 0;
        } else {
            self.latest.counter = self.latest.counter.saturating_add(1);
        }
        self.latest.clone()
    }

    /// Updates the clock upon receiving a remote HLC timestamp.
    pub fn update(&mut self, remote: &HlcTimestamp, physical_now_ms: u64) -> HlcTimestamp {
        let max_ms = physical_now_ms
            .max(self.latest.physical_ms)
            .max(remote.physical_ms);

        if max_ms == self.latest.physical_ms && max_ms == remote.physical_ms {
            self.latest.counter = self.latest.counter.max(remote.counter).saturating_add(1);
        } else if max_ms == self.latest.physical_ms {
            self.latest.counter = self.latest.counter.saturating_add(1);
        } else if max_ms == remote.physical_ms {
            self.latest.counter = remote.counter.saturating_add(1);
        } else {
            self.latest.counter = 0;
        }

        self.latest.physical_ms = max_ms;
        self.latest.clone()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_hlc_monotonicity_same_millisecond() {
        let mut clock = HlcClock::new("nodeA");
        let t1 = clock.now(1_000_000);
        let t2 = clock.now(1_000_000);
        let t3 = clock.now(1_000_000);

        assert_eq!(t1.counter, 0);
        assert_eq!(t2.counter, 1);
        assert_eq!(t3.counter, 2);
        assert!(t1 < t2);
        assert!(t2 < t3);
    }

    #[test]
    fn test_hlc_advances_on_physical_time() {
        let mut clock = HlcClock::new("nodeA");
        let _ = clock.now(1_000_000);
        let _ = clock.now(1_000_000);
        let t_next = clock.now(1_000_005);

        assert_eq!(t_next.physical_ms, 1_000_005);
        assert_eq!(t_next.counter, 0);
    }

    #[test]
    fn test_hlc_causality_across_nodes_with_skew() {
        // Node A has clock 1000, Node B has clock 500 (500ms behind)
        let mut clock_a = HlcClock::new("nodeA");
        let mut clock_b = HlcClock::new("nodeB");

        let event_a = clock_a.now(1_000);
        // Node B receives event_a while its physical clock is still at 505
        let event_b = clock_b.update(&event_a, 505);

        assert!(event_b > event_a);
        assert_eq!(event_b.physical_ms, 1_000);
        assert_eq!(event_b.counter, 1);
    }

    #[test]
    fn test_hlc_serialization_roundtrip() {
        let ts = HlcTimestamp::new(1_700_000_123, 42, "nodeX");
        let compact = ts.to_compact_string();
        assert_eq!(compact, "1700000123.42.nodeX");

        let parsed = HlcTimestamp::parse_compact(&compact).unwrap();
        assert_eq!(parsed, ts);

        let json = serde_json::to_string(&ts).unwrap();
        assert_eq!(json, "\"1700000123.42.nodeX\"");
        let deserialized: HlcTimestamp = serde_json::from_str(&json).unwrap();
        assert_eq!(deserialized, ts);
    }
}
