//! Two-phase handoff state machine and rate limiter (PRD-42 § 3.2, § 3.4, § 5.2).
//!
//! Pure state machine: no I/O, no system clocks, deterministic inputs.

use std::collections::HashMap;

use super::messages::{PlayRefuseReason, TargetAccessPolicy};
use crate::sync::envelope::SyncMessage;

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum HandoffError {
    #[error("requête expirée ({0} ms)")]
    TimedOut(u64),
    #[error("identifiant de requête inattendu: attendu {expected}, reçu {actual}")]
    MismatchedRequestId { expected: String, actual: String },
    #[error("état de transfert invalide")]
    InvalidState(String),
    #[error("transfert refusé par la cible : {0:?}")]
    Refused(PlayRefuseReason),
}

/// Enforces the maximum rate of 1 play_request every 2 seconds per sender device ID (PRD-42 § 5.2).
#[derive(Debug, Default, Clone)]
pub struct RateLimiter {
    last_requests: HashMap<String, u64>,
}

impl RateLimiter {
    pub fn new() -> Self {
        Self {
            last_requests: HashMap::new(),
        }
    }

    /// Returns `true` if allowed, `false` if rate-limited.
    pub fn check_and_record(&mut self, sender_device_id: &str, now_ms: u64, min_interval_ms: u64) -> bool {
        if let Some(&last) = self.last_requests.get(sender_device_id) {
            if now_ms.saturating_sub(last) < min_interval_ms {
                return false;
            }
        }
        self.last_requests.insert(sender_device_id.to_string(), now_ms);
        true
    }
}

/// Evaluates if a playing stream must be stopped when a `release_stream` notification is received (PRD-42 § 3.4).
pub fn should_stop_stream_on_release(current_source_key: Option<&str>, release_source_key: &str) -> bool {
    match current_source_key {
        Some(curr) => curr.trim().eq_ignore_ascii_case(release_source_key.trim()),
        None => false,
    }
}

// ----------------------------------------------------------------------------
// Origin Handoff State Machine (Sender)
// ----------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OriginState {
    Idle,
    WaitingReady {
        request_id: String,
        target_device_id: String,
        content_key: String,
        source_key: Option<String>,
        initial_position_ms: u64,
        started_at_ms: u64,
    },
    StoppingLocalPlayback {
        request_id: String,
        target_device_id: String,
        content_key: String,
        source_key: Option<String>,
        final_position_ms: u64,
    },
    HandedOff {
        request_id: String,
        target_device_id: String,
        content_key: String,
        source_key: Option<String>,
        last_known_position_ms: u64,
        handed_off_at_ms: u64,
    },
    Failed {
        reason: String,
        can_resume_at_ms: Option<u64>,
    },
}

#[derive(Debug, Clone)]
pub struct OriginHandoffSession {
    pub state: OriginState,
}

impl Default for OriginHandoffSession {
    fn default() -> Self {
        Self::new()
    }
}

impl OriginHandoffSession {
    pub fn new() -> Self {
        Self {
            state: OriginState::Idle,
        }
    }

    /// Step 1: Start transfer by generating a `PlayRequest`.
    #[allow(clippy::too_many_arguments)]
    pub fn start(
        &mut self,
        target_device_id: &str,
        request_id: &str,
        content_key: &str,
        source_key: Option<&str>,
        item_kind: &str,
        provider_ref: Option<&str>,
        title: Option<&str>,
        position_ms: u64,
        profile_uuid: Option<&str>,
        replace: bool,
        now_ms: u64,
    ) -> SyncMessage {
        self.state = OriginState::WaitingReady {
            request_id: request_id.to_string(),
            target_device_id: target_device_id.to_string(),
            content_key: content_key.to_string(),
            source_key: source_key.map(|s| s.to_string()),
            initial_position_ms: position_ms,
            started_at_ms: now_ms,
        };

        SyncMessage::PlayRequest {
            target_device_id: target_device_id.to_string(),
            request_id: request_id.to_string(),
            content_key: content_key.to_string(),
            source_key: source_key.map(|s| s.to_string()),
            item_kind: item_kind.to_string(),
            provider_ref: provider_ref.map(|s| s.to_string()),
            title: title.map(|s| s.to_string()),
            position_ms,
            profile_uuid: profile_uuid.map(|s| s.to_string()),
            replace,
        }
    }

    /// Step 2: Target replied `PlayReady`. Origin stops local playback and creates `PlayGo`.
    pub fn on_play_ready(
        &mut self,
        received_request_id: &str,
        measured_final_position_ms: u64,
        now_ms: u64,
    ) -> Result<SyncMessage, HandoffError> {
        match &self.state {
            OriginState::WaitingReady {
                request_id,
                target_device_id,
                content_key,
                source_key,
                ..
            } => {
                if request_id != received_request_id {
                    return Err(HandoffError::MismatchedRequestId {
                        expected: request_id.clone(),
                        actual: received_request_id.to_string(),
                    });
                }

                let req_id = request_id.clone();
                let tgt_id = target_device_id.clone();
                let c_key = content_key.clone();
                let s_key = source_key.clone();

                self.state = OriginState::HandedOff {
                    request_id: req_id.clone(),
                    target_device_id: tgt_id,
                    content_key: c_key,
                    source_key: s_key,
                    last_known_position_ms: measured_final_position_ms,
                    handed_off_at_ms: now_ms,
                };

                Ok(SyncMessage::PlayGo {
                    request_id: req_id,
                    position_ms: measured_final_position_ms,
                })
            }
            other => Err(HandoffError::InvalidState(format!("{other:?}"))),
        }
    }

    /// Target replied `PlayRefused`. Origin does not interrupt local playback.
    pub fn on_play_refused(&mut self, received_request_id: &str, reason: PlayRefuseReason) {
        if let OriginState::WaitingReady { request_id, initial_position_ms, .. } = &self.state {
            if request_id == received_request_id {
                self.state = OriginState::Failed {
                    reason: format!("{reason:?}"),
                    can_resume_at_ms: Some(*initial_position_ms),
                };
            }
        }
    }

    /// Checks if waiting for target `PlayReady` exceeded the 5000 ms SLA timeout (PRD-42 § 3.2).
    pub fn check_timeout(&mut self, now_ms: u64) -> bool {
        if let OriginState::WaitingReady { started_at_ms, initial_position_ms, .. } = &self.state {
            if now_ms.saturating_sub(*started_at_ms) > 5000 {
                self.state = OriginState::Failed {
                    reason: "Délai d'attente dépassé (5 s sans réponse de la cible)".to_string(),
                    can_resume_at_ms: Some(*initial_position_ms),
                };
                return true;
            }
        }
        false
    }

    /// Target error report: if target failed within 15 seconds after handoff, returns the position to resume.
    pub fn on_target_playback_error(&mut self, now_ms: u64) -> Option<u64> {
        if let OriginState::HandedOff { handed_off_at_ms, last_known_position_ms, .. } = &self.state {
            if now_ms.saturating_sub(*handed_off_at_ms) <= 15_000 {
                let resume_pos = *last_known_position_ms;
                self.state = OriginState::Failed {
                    reason: "Erreur de lecture sur la cible".to_string(),
                    can_resume_at_ms: Some(resume_pos),
                };
                return Some(resume_pos);
            }
        }
        None
    }
}

// ----------------------------------------------------------------------------
// Target Handoff State Machine (Receiver)
// ----------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TargetState {
    Idle,
    Reserved {
        request_id: String,
        content_key: String,
        source_key: Option<String>,
        reserved_at_ms: u64,
    },
    Playing {
        content_key: String,
        source_key: Option<String>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TargetEvaluation {
    Ready {
        reply: SyncMessage, // PlayReady
    },
    Refused {
        reply: SyncMessage, // PlayRefused
        reason: PlayRefuseReason,
    },
    NeedsUserPrompt {
        request_id: String,
        title: Option<String>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TargetPlaybackInstruction {
    pub content_key: String,
    pub source_key: Option<String>,
    pub position_ms: u64,
    pub broadcast_release: Option<SyncMessage>, // ReleaseStream
}

#[derive(Debug, Clone)]
pub struct TargetHandoffSession {
    pub state: TargetState,
}

impl Default for TargetHandoffSession {
    fn default() -> Self {
        Self::new()
    }
}

impl TargetHandoffSession {
    pub fn new() -> Self {
        Self {
            state: TargetState::Idle,
        }
    }

    /// Evaluates incoming `PlayRequest` according to access policy, kids mode, current state, and content presence.
    #[allow(clippy::too_many_arguments)]
    pub fn evaluate_request(
        &mut self,
        sender_device_id: &str,
        request_id: &str,
        content_key: &str,
        source_key: Option<&str>,
        title: Option<&str>,
        policy: TargetAccessPolicy,
        has_content: bool,
        is_playing: bool,
        replace_requested: bool,
        kids_active: bool,
        content_is_adult: bool,
        rate_limiter: &mut RateLimiter,
        now_ms: u64,
    ) -> TargetEvaluation {
        // Rate limiting check (PRD-42 § 5.2)
        if !rate_limiter.check_and_record(sender_device_id, now_ms, 2000) {
            return TargetEvaluation::Refused {
                reply: SyncMessage::PlayRefused {
                    request_id: request_id.to_string(),
                    reason: PlayRefuseReason::RateLimited,
                },
                reason: PlayRefuseReason::RateLimited,
            };
        }

        // Access policy check (PRD-42 § 5.3)
        if policy == TargetAccessPolicy::Disabled {
            return TargetEvaluation::Refused {
                reply: SyncMessage::PlayRefused {
                    request_id: request_id.to_string(),
                    reason: PlayRefuseReason::NotAllowed,
                },
                reason: PlayRefuseReason::NotAllowed,
            };
        }

        // Kids profile restriction (PRD-42 § 5.4)
        if kids_active && content_is_adult {
            return TargetEvaluation::Refused {
                reply: SyncMessage::PlayRefused {
                    request_id: request_id.to_string(),
                    reason: PlayRefuseReason::KidsRestricted,
                },
                reason: PlayRefuseReason::KidsRestricted,
            };
        }

        // Unknown content check (PRD-42 § 6)
        if !has_content {
            return TargetEvaluation::Refused {
                reply: SyncMessage::PlayRefused {
                    request_id: request_id.to_string(),
                    reason: PlayRefuseReason::UnknownContent,
                },
                reason: PlayRefuseReason::UnknownContent,
            };
        }

        // Busy check or prompt needed
        if is_playing && !replace_requested {
            if policy == TargetAccessPolicy::AlwaysAsk {
                return TargetEvaluation::NeedsUserPrompt {
                    request_id: request_id.to_string(),
                    title: title.map(|t| t.to_string()),
                };
            }
            return TargetEvaluation::Refused {
                reply: SyncMessage::PlayRefused {
                    request_id: request_id.to_string(),
                    reason: PlayRefuseReason::Busy,
                },
                reason: PlayRefuseReason::Busy,
            };
        }

        if policy == TargetAccessPolicy::AlwaysAsk {
            return TargetEvaluation::NeedsUserPrompt {
                request_id: request_id.to_string(),
                title: title.map(|t| t.to_string()),
            };
        }

        // Ready: reserve slot for incoming PlayGo (max 10s)
        self.state = TargetState::Reserved {
            request_id: request_id.to_string(),
            content_key: content_key.to_string(),
            source_key: source_key.map(|s| s.to_string()),
            reserved_at_ms: now_ms,
        };

        TargetEvaluation::Ready {
            reply: SyncMessage::PlayReady {
                request_id: request_id.to_string(),
            },
        }
    }

    /// User confirmed prompt on screen.
    pub fn confirm_prompt(&mut self, request_id: &str, content_key: &str, source_key: Option<&str>, now_ms: u64) -> SyncMessage {
        self.state = TargetState::Reserved {
            request_id: request_id.to_string(),
            content_key: content_key.to_string(),
            source_key: source_key.map(|s| s.to_string()),
            reserved_at_ms: now_ms,
        };
        SyncMessage::PlayReady {
            request_id: request_id.to_string(),
        }
    }

    /// User declined prompt or prompt timed out (10s default decline).
    pub fn decline_prompt(&mut self, request_id: &str) -> SyncMessage {
        self.state = TargetState::Idle;
        SyncMessage::PlayRefused {
            request_id: request_id.to_string(),
            reason: PlayRefuseReason::DeclinedByUser,
        }
    }

    /// Step 3: Target receives `PlayGo`. Produces playback instruction and broadcast `ReleaseStream`.
    pub fn on_play_go(&mut self, received_request_id: &str, position_ms: u64) -> Result<TargetPlaybackInstruction, HandoffError> {
        match &self.state {
            TargetState::Reserved {
                request_id,
                content_key,
                source_key,
                ..
            } => {
                if request_id != received_request_id {
                    return Err(HandoffError::MismatchedRequestId {
                        expected: request_id.clone(),
                        actual: received_request_id.to_string(),
                    });
                }

                let c_key = content_key.clone();
                let s_key = source_key.clone();

                self.state = TargetState::Playing {
                    content_key: c_key.clone(),
                    source_key: s_key.clone(),
                };

                let release_msg = s_key.as_ref().map(|k| SyncMessage::ReleaseStream {
                    source_key: k.clone(),
                });

                Ok(TargetPlaybackInstruction {
                    content_key: c_key,
                    source_key: s_key,
                    position_ms,
                    broadcast_release: release_msg,
                })
            }
            other => Err(HandoffError::InvalidState(format!("{other:?}"))),
        }
    }

    /// Checks if reservation expired without `PlayGo` (10s SLA timeout).
    pub fn check_reservation_timeout(&mut self, now_ms: u64) -> bool {
        if let TargetState::Reserved { reserved_at_ms, .. } = &self.state {
            if now_ms.saturating_sub(*reserved_at_ms) > 10_000 {
                self.state = TargetState::Idle;
                return true;
            }
        }
        false
    }
}
