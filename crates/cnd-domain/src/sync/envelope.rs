//! Secure end-to-end encrypted household envelope (PRD 41 § 5 & § 6).
//!
//! Encrypted with AES-256-GCM using the 256-bit household key.
//! Enforces monotonic sequence numbers per device to prevent replay attacks on local network broadcasts.

use aes_gcm::aead::{Aead, KeyInit, Payload};
use aes_gcm::{Aes256Gcm, Nonce};
use serde::{Deserialize, Serialize};

use super::records::SyncDelta;

fn default_true() -> bool {
    true
}

fn default_idle() -> String {
    "idle".to_string()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PlayRefuseReason {
    UnknownContent,
    SourceMissing,
    Busy,
    KidsRestricted,
    DeclinedByUser,
    NotAllowed,
    AppNotReady,
    RateLimited,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
#[allow(clippy::large_enum_variant)]
pub enum SyncMessage {
    SyncDelta(SyncDelta),
    /// Deprecated PRD-41 broadcast alias, preserved for backwards compatibility.
    PlayRemote {
        content_key: String,
        position_ms: u64,
        #[serde(default)]
        title: Option<String>,
        #[serde(default)]
        source_key: Option<String>,
    },
    RemoteKey {
        key: String, // "up" | "down" | "left" | "right" | "select" | "back" | "channel_up" | "channel_down"
    },
    RemoteText {
        text: String,
    },
    DeviceAnnounce {
        device_id: String,
        device_name: String,
        device_type: String, // "tv" | "mobile" | "desktop"
        app_version: String,
        #[serde(default = "default_true")]
        can_play: bool,
        #[serde(default)]
        capabilities: Vec<String>,
        #[serde(default = "default_idle")]
        state: String, // "idle" | "playing" | "busy"
        #[serde(default)]
        profile_uuid: Option<String>,
        #[serde(default)]
        kids: bool,
    },
    Ping,
    Pong,
    // PRD-42 Handoff & Remote Playback messages
    PlayRequest {
        target_device_id: String,
        request_id: String,
        content_key: String,
        #[serde(default)]
        source_key: Option<String>,
        item_kind: String, // "live" | "movie" | "episode"
        #[serde(default)]
        provider_ref: Option<String>,
        #[serde(default)]
        title: Option<String>,
        position_ms: u64,
        #[serde(default)]
        profile_uuid: Option<String>,
        #[serde(default)]
        replace: bool,
    },
    PlayReady {
        request_id: String,
    },
    PlayRefused {
        request_id: String,
        reason: PlayRefuseReason,
    },
    PlayGo {
        request_id: String,
        position_ms: u64,
    },
    PlaybackState {
        device_id: String,
        #[serde(default)]
        content_key: Option<String>,
        #[serde(default)]
        title: Option<String>,
        state: String, // "loading" | "playing" | "paused" | "ended" | "error"
        position_ms: u64,
        duration_ms: u64,
        #[serde(default)]
        controls: Vec<String>,
    },
    PlaybackControl {
        target_device_id: String,
        action: String, // "pause" | "resume" | "seek_to" | "seek_by" | "stop" | "next" | "previous" | "channel_up" | "channel_down" | "volume"
        #[serde(default)]
        value: Option<i64>,
    },
    ReleaseRequest {
        target_device_id: String,
        request_id: String,
    },
    ReleaseDone {
        request_id: String,
        #[serde(default)]
        content_key: Option<String>,
        position_ms: u64,
    },
    ReleaseStream {
        source_key: String,
    },
    /// Accounts, profiles, favorites and progress as the Apple apps store them (keyed by uuid and
    /// `stable_hash`, the format of `cnd-core`'s delta export). Carried as an opaque object: its rules
    /// (last write wins by `updated_at`) are applied by `cnd-core` on import. It may hold the Xtream
    /// passwords of the accounts, which only ever travel inside this encrypted envelope.
    HouseholdDataDelta {
        delta: serde_json::Value,
    },
    /// "Send me everything you have": answered with a `HouseholdDataDelta` of the whole state.
    SyncRequest,
    /// New household key after a device was removed (PRD-41 § 5), sealed with the previous key.
    HouseholdRekey {
        new_key_hex: String,
        #[serde(default)]
        removed_device_id: Option<String>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HouseholdEnvelope {
    pub household_id: String,
    pub sender_device_id: String,
    pub sequence: u64,
    /// 12 bytes base64url or hex
    pub nonce_hex: String,
    /// Ciphertext + 16-byte Poly1305/GCM auth tag (hex encoded)
    pub ciphertext_hex: String,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum EnvelopeError {
    #[error("clé de foyer invalide (32 octets requis)")]
    InvalidKeyLength,
    #[error("identifiant de foyer invalide")]
    MismatchedHouseholdId,
    #[error("rejeu détecté : séquence {sequence} <= {last_seen}")]
    ReplayDetected { sequence: u64, last_seen: u64 },
    #[error("échec de déchiffrement ou corruption du message")]
    DecryptionFailed,
    #[error("données aléatoires (nonce) insuffisantes")]
    InsufficientEntropy,
    #[error("format de payload invalide : {0}")]
    InvalidPayload(String),
}

/// Derives a stable public household ID from the 32-byte secret key.
pub fn derive_household_id(household_key: &[u8; 32]) -> String {
    let mut hasher = blake3::Hasher::new();
    hasher.update(b"buntu_household_id_v1:");
    hasher.update(household_key);
    let hash = hasher.finalize();
    format!("buntu_hh_{}", &hash.to_hex()[..16])
}

/// Generates a new random 256-bit household key from 32 bytes of entropy.
pub fn create_household_key(entropy: &[u8; 32]) -> String {
    blake3::hash(entropy).to_hex().to_string()
}

/// Seals a SyncMessage into an encrypted HouseholdEnvelope.
pub fn seal_envelope(
    household_key: &[u8; 32],
    sender_device_id: &str,
    sequence: u64,
    nonce_bytes: &[u8; 12],
    message: &SyncMessage,
) -> Result<HouseholdEnvelope, EnvelopeError> {
    let household_id = derive_household_id(household_key);
    let cipher = Aes256Gcm::new_from_slice(household_key)
        .map_err(|_| EnvelopeError::InvalidKeyLength)?;

    let aad = format!("{household_id}:{sender_device_id}:{sequence}");
    let plaintext = serde_json::to_vec(message)
        .map_err(|e| EnvelopeError::InvalidPayload(e.to_string()))?;

    let nonce = Nonce::from_slice(nonce_bytes);
    let payload = Payload {
        msg: &plaintext,
        aad: aad.as_bytes(),
    };

    let ciphertext = cipher
        .encrypt(nonce, payload)
        .map_err(|_| EnvelopeError::DecryptionFailed)?;

    Ok(HouseholdEnvelope {
        household_id,
        sender_device_id: sender_device_id.to_string(),
        sequence,
        nonce_hex: hex_encode(nonce_bytes),
        ciphertext_hex: hex_encode(&ciphertext),
    })
}

/// Opens and authenticates a HouseholdEnvelope, enforcing the replay sequence barrier.
pub fn open_envelope(
    household_key: &[u8; 32],
    envelope: &HouseholdEnvelope,
    last_seen_sequence: u64,
) -> Result<SyncMessage, EnvelopeError> {
    // 1. Verify household ID
    let expected_id = derive_household_id(household_key);
    if envelope.household_id != expected_id {
        return Err(EnvelopeError::MismatchedHouseholdId);
    }

    // 2. Anti-replay barrier
    if envelope.sequence <= last_seen_sequence {
        return Err(EnvelopeError::ReplayDetected {
            sequence: envelope.sequence,
            last_seen: last_seen_sequence,
        });
    }

    // 3. Decrypt
    let cipher = Aes256Gcm::new_from_slice(household_key)
        .map_err(|_| EnvelopeError::InvalidKeyLength)?;

    let nonce_bytes = hex_decode(&envelope.nonce_hex)
        .ok_or(EnvelopeError::DecryptionFailed)?;
    if nonce_bytes.len() != 12 {
        return Err(EnvelopeError::DecryptionFailed);
    }

    let ciphertext = hex_decode(&envelope.ciphertext_hex)
        .ok_or(EnvelopeError::DecryptionFailed)?;

    let aad = format!("{}:{}:{}", envelope.household_id, envelope.sender_device_id, envelope.sequence);
    let nonce = Nonce::from_slice(&nonce_bytes);
    let payload = Payload {
        msg: &ciphertext,
        aad: aad.as_bytes(),
    };

    let plaintext = cipher
        .decrypt(nonce, payload)
        .map_err(|_| EnvelopeError::DecryptionFailed)?;

    serde_json::from_slice(&plaintext)
        .map_err(|e| EnvelopeError::InvalidPayload(e.to_string()))
}

fn hex_encode(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        s.push_str(&format!("{:02x}", b));
    }
    s
}

fn hex_decode(s: &str) -> Option<Vec<u8>> {
    if !s.len().is_multiple_of(2) {
        return None;
    }
    let mut bytes = Vec::with_capacity(s.len() / 2);
    for i in (0..s.len()).step_by(2) {
        let b = u8::from_str_radix(&s[i..i + 2], 16).ok()?;
        bytes.push(b);
    }
    Some(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_seal_and_open_roundtrip() {
        let key = [42u8; 32];
        let nonce = [7u8; 12];
        let msg = SyncMessage::PlayRemote {
            content_key: "abc1234".to_string(),
            position_ms: 55_000,
            title: Some("Inception".to_string()),
            source_key: None,
        };

        let env = seal_envelope(&key, "phone_1", 1, &nonce, &msg).unwrap();
        assert_eq!(env.sequence, 1);
        assert!(!env.ciphertext_hex.is_empty());

        let opened = open_envelope(&key, &env, 0).unwrap();
        assert_eq!(opened, msg);
    }

    #[test]
    fn test_replay_rejected() {
        let key = [42u8; 32];
        let nonce = [7u8; 12];
        let msg = SyncMessage::Ping;

        let env = seal_envelope(&key, "phone_1", 5, &nonce, &msg).unwrap();

        // Already seen sequence 5 -> replay rejected
        let res = open_envelope(&key, &env, 5);
        assert!(matches!(res, Err(EnvelopeError::ReplayDetected { .. })));

        // Seen sequence 6 -> replay rejected
        let res = open_envelope(&key, &env, 6);
        assert!(matches!(res, Err(EnvelopeError::ReplayDetected { .. })));
    }

    #[test]
    fn test_wrong_key_rejected() {
        let key1 = [42u8; 32];
        let key2 = [99u8; 32];
        let nonce = [7u8; 12];
        let msg = SyncMessage::Ping;

        let env = seal_envelope(&key1, "phone_1", 1, &nonce, &msg).unwrap();
        let res = open_envelope(&key2, &env, 0);
        assert!(matches!(res, Err(EnvelopeError::MismatchedHouseholdId)));
    }

    #[test]
    fn test_household_messages_round_trip() {
        let key = [7u8; 32];
        let nonce = [1u8; 12];
        let messages = [
            r#"{"type":"household_data_delta","delta":{"sources":[{"uuid":"u1","password":"pw"}],"favorites":[]}}"#,
            r#"{"type":"sync_request"}"#,
            r#"{"type":"household_rekey","new_key_hex":"ab","removed_device_id":"apple_x"}"#,
            r#"{"type":"household_rekey","new_key_hex":"ab"}"#,
        ];
        for (i, raw) in messages.iter().enumerate() {
            let msg: SyncMessage = serde_json::from_str(raw).expect("message accepted by the protocol");
            let env = seal_envelope(&key, "dev", 10 + i as u64, &nonce, &msg).expect("sealed");
            let opened = open_envelope(&key, &env, 0).expect("opened");
            assert_eq!(opened, msg);
        }
        // The opaque delta keeps every field, the password included.
        let msg: SyncMessage = serde_json::from_str(messages[0]).unwrap();
        let json = serde_json::to_value(&msg).unwrap();
        assert_eq!(json["delta"]["sources"][0]["password"], "pw");
    }
}
