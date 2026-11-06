use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// Half-life of a watch: a film seen a month ago counts half as much as one seen today.
pub const HALF_LIFE_DAYS: f64 = 30.0;
/// Under two minutes of playback nothing is counted (zapping).
pub const ZAPPING_MS: i64 = 120_000;

pub fn family_factor(feature: &str) -> f64 {
    match feature.split(':').next().unwrap_or("") {
        "genre" => 1.0,
        "director" => 0.8,
        "category" => 0.9,
        "channel" => 0.9,
        "group" => 0.6,
        "actor" => 0.5,
        "slot" => 0.5,
        "lang" => 0.3,
        "decade" => 0.3,
        _ => 0.2,
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Taste {
    pub weights: HashMap<String, f64>,
    pub samples: u32,
}

impl Taste {
    pub fn add(&mut self, features: &[String], weight: f64) {
        if weight == 0.0 || features.is_empty() {
            return;
        }
        self.samples += 1;
        for f in features {
            *self.weights.entry(f.clone()).or_insert(0.0) += weight;
        }
    }

    pub fn finish(mut self, feedback: &HashMap<String, f64>) -> Self {
        let max = self.weights.values().cloned().fold(0.0_f64, f64::max);
        if max > 0.0 {
            for v in self.weights.values_mut() {
                *v /= max;
            }
        }
        for (feature, delta) in feedback {
            *self.weights.entry(feature.clone()).or_insert(0.0) += delta;
        }
        self
    }

    pub fn is_empty(&self) -> bool {
        self.samples == 0
    }

    pub fn weight(&self, feature: &str) -> f64 {
        self.weights.get(feature).copied().unwrap_or(0.0)
    }

    pub fn score(&self, features: &[String]) -> f64 {
        features.iter().map(|f| self.weight(f) * family_factor(f)).sum()
    }

    pub fn best_feature<'a>(&self, features: &'a [String]) -> Option<(&'a String, f64)> {
        features
            .iter()
            .map(|f| (f, self.weight(f) * family_factor(f)))
            .filter(|(_, w)| *w > 0.0)
            .max_by(|a, b| a.1.partial_cmp(&b.1).unwrap_or(std::cmp::Ordering::Equal))
    }

    pub fn top(&self, family: &str, n: usize) -> Vec<(String, f64)> {
        let prefix = format!("{family}:");
        let mut v: Vec<(String, f64)> = self
            .weights
            .iter()
            .filter(|(k, w)| k.starts_with(&prefix) && **w > 0.0)
            .map(|(k, w)| (k[prefix.len()..].to_string(), *w))
            .collect();
        v.sort_by(|a, b| {
            b.1.partial_cmp(&a.1)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then(a.0.cmp(&b.0))
        });
        v.truncate(n);
        v
    }
}
