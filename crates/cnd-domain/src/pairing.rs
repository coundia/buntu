//! Pairing of a phone with a TV by QR code (PRD 39).
//!
//! The TV shows a QR code holding a link with its **one-time X25519 public key**. The phone scans it,
//! seals the sources document (`cnd-source-share`, PRD 26) with a key agreed from its own one-time
//! key, and sends the message over whatever transport the TV listens on. Nobody who watches the
//! network can read it or pose as the TV: the TV's key only travels through the screen.
//!
//! Pure functions, no I/O and no clock or randomness of their own: the caller passes the time and
//! fresh random bytes (`entropy`), so Swift, Kotlin and the TV's WebAssembly share ONE implementation
//! and the same test vectors.

use aes_gcm::aead::{Aead, KeyInit, Payload};
use aes_gcm::{Aes256Gcm, Nonce};
use hkdf::Hkdf;
use serde::{Deserialize, Serialize};
use sha2::Sha256;
use x25519_dalek::{PublicKey, StaticSecret};

pub const VERSION: u32 = 1;
/// A session lasts five minutes.
pub const SESSION_SECONDS: i64 = 300;
/// Largest message accepted (ciphertext, base64url characters).
pub const MAX_MESSAGE_CHARS: usize = 96 * 1024;
/// Invalid messages tolerated before the session closes.
pub const MAX_FAILURES: u32 = 3;
/// Random bytes `create_offer` needs: 32 for the key, 8 for the session id.
pub const OFFER_ENTROPY: usize = 40;
/// Random bytes `seal` needs: 32 for the key, 12 for the nonce.
pub const SEAL_ENTROPY: usize = 44;
/// Random bytes `seal_reply` needs: the nonce.
pub const REPLY_ENTROPY: usize = 12;

const HKDF_INFO: &[u8] = b"buntu-pair-v1";

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum PairingError {
    #[error("lien d'appariement invalide")]
    BadLink,
    #[error("session expirée")]
    Expired,
    #[error("session fermée")]
    Closed,
    #[error("message invalide")]
    BadMessage,
    #[error("message trop volumineux")]
    TooLarge,
    #[error("pas assez d'aléa fourni")]
    NotEnoughEntropy,
}

// ----------------------------------------------------------------------------- base64url

const B64: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

pub fn b64_encode(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let n = (u32::from(chunk[0]) << 16)
            | (u32::from(*chunk.get(1).unwrap_or(&0)) << 8)
            | u32::from(*chunk.get(2).unwrap_or(&0));
        out.push(B64[(n >> 18) as usize & 63] as char);
        out.push(B64[(n >> 12) as usize & 63] as char);
        if chunk.len() > 1 {
            out.push(B64[(n >> 6) as usize & 63] as char);
        }
        if chunk.len() > 2 {
            out.push(B64[n as usize & 63] as char);
        }
    }
    out
}

pub fn b64_decode(text: &str) -> Option<Vec<u8>> {
    let mut out = Vec::with_capacity(text.len() * 3 / 4);
    let mut acc = 0u32;
    let mut bits = 0;
    for c in text.bytes() {
        let v = B64.iter().position(|&b| b == c)? as u32;
        acc = (acc << 6) | v;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
            acc &= (1 << bits) - 1;
        }
    }
    // A dangling character cannot be valid.
    if bits >= 6 {
        return None;
    }
    Some(out)
}

fn b32(bytes: &[u8]) -> String {
    const A: &[u8; 32] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
    let mut out = String::new();
    let (mut acc, mut bits) = (0u32, 0);
    for &b in bytes {
        acc = (acc << 8) | u32::from(b);
        bits += 8;
        while bits >= 5 {
            bits -= 5;
            out.push(A[(acc >> bits) as usize & 31] as char);
        }
    }
    if bits > 0 {
        out.push(A[(acc << (5 - bits)) as usize & 31] as char);
    }
    out
}

// ----------------------------------------------------------------------------- the offer (TV)

/// What the TV keeps while it waits. Serialised as JSON between calls: nothing else holds state.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SessionState {
    pub session: String,
    pub secret_key: String,
    pub expires_at: i64,
    pub failures: u32,
    pub used: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Offer {
    pub session: String,
    /// What the QR code encodes.
    pub link: String,
    /// JSON of the `SessionState` the TV keeps (it holds the one-time private key).
    pub state: String,
    pub expires_at: i64,
}

/// `transport`: `msf` (Samsung channel), `http` (Android TV) or `tls` (Apple TV).
pub fn create_offer(
    entropy: &[u8],
    tv_name: &str,
    transport: &str,
    host: &str,
    port: u16,
    now: i64,
) -> Result<Offer, PairingError> {
    if entropy.len() < OFFER_ENTROPY {
        return Err(PairingError::NotEnoughEntropy);
    }
    let mut seed = [0u8; 32];
    seed.copy_from_slice(&entropy[..32]);
    let secret = StaticSecret::from(seed);
    let public = PublicKey::from(&secret);
    let session = b32(&entropy[32..40]);
    let expires_at = now + SESSION_SECONDS;
    let name: String = tv_name.chars().filter(|c| !c.is_control()).take(40).collect();

    let mut url = url::Url::parse("buntu://pair").map_err(|_| PairingError::BadLink)?;
    url.query_pairs_mut()
        .append_pair("v", &VERSION.to_string())
        .append_pair("s", &session)
        .append_pair("n", &name)
        .append_pair("t", transport)
        .append_pair("h", host)
        .append_pair("p", &port.to_string())
        .append_pair("k", &b64_encode(public.as_bytes()))
        .append_pair("e", &expires_at.to_string());
    let state = SessionState { session: session.clone(), secret_key: b64_encode(&seed), expires_at, failures: 0, used: false };
    Ok(Offer {
        session,
        link: url.to_string(),
        state: serde_json::to_string(&state).map_err(|_| PairingError::BadLink)?,
        expires_at,
    })
}

/// A scanned link, validated.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ParsedLink {
    pub session: String,
    pub tv_name: String,
    pub transport: String,
    pub host: String,
    pub port: u16,
    pub tv_public_key: String,
    pub expires_at: i64,
}

/// Reads the link of a QR code. Accepts the `buntu://pair?…` form and the `http://ip:port/pair#…`
/// form of Android TV (parameters in the query or in the fragment).
pub fn parse_link(link: &str, now: i64) -> Result<ParsedLink, PairingError> {
    let url = url::Url::parse(link.trim()).map_err(|_| PairingError::BadLink)?;
    let query = match (url.query(), url.fragment()) {
        (Some(q), _) if !q.is_empty() => q.to_string(),
        (_, Some(f)) if !f.is_empty() => f.to_string(),
        _ => return Err(PairingError::BadLink),
    };
    let params: std::collections::HashMap<String, String> =
        url::form_urlencoded::parse(query.as_bytes()).into_owned().collect();
    let get = |k: &str| params.get(k).cloned().ok_or(PairingError::BadLink);
    if get("v")?.parse::<u32>().ok() != Some(VERSION) {
        return Err(PairingError::BadLink);
    }
    let key = get("k")?;
    if b64_decode(&key).map(|b| b.len()) != Some(32) {
        return Err(PairingError::BadLink);
    }
    let transport = get("t")?;
    if !matches!(transport.as_str(), "msf" | "http" | "tls" | "tcp") {
        return Err(PairingError::BadLink);
    }
    let parsed = ParsedLink {
        session: get("s")?,
        tv_name: get("n").unwrap_or_default(),
        transport,
        host: get("h")?,
        port: get("p")?.parse().map_err(|_| PairingError::BadLink)?,
        tv_public_key: key,
        expires_at: get("e")?.parse().map_err(|_| PairingError::BadLink)?,
    };
    if parsed.session.is_empty() || parsed.host.is_empty() || parsed.session.len() > 32 {
        return Err(PairingError::BadLink);
    }
    if parsed.expires_at <= now {
        return Err(PairingError::Expired);
    }
    Ok(parsed)
}

// ----------------------------------------------------------------------------- the message

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Message {
    pub v: u32,
    pub s: String,
    pub from: String,
    pub epk: String,
    pub nonce: String,
    pub ct: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Sealed {
    /// JSON of the `Message` to send to the TV.
    pub message: String,
    /// Key to read the TV's answer; the phone keeps it until then.
    pub reply_key: String,
}

fn derive_key(shared: &[u8; 32], session: &str) -> [u8; 32] {
    let hk = Hkdf::<Sha256>::new(None, shared);
    let mut info = HKDF_INFO.to_vec();
    info.extend_from_slice(session.as_bytes());
    let mut key = [0u8; 32];
    // 32 bytes is far below HKDF-SHA256's limit.
    hk.expand(&info, &mut key).expect("hkdf length");
    key
}

/// Computes a 6-digit confirmation code (Short Authentication String) from the agreed secret and session.
/// Displayed on both screens to let users confirm they are talking to each other without a MITM.
pub fn compute_sas(shared_secret: &[u8; 32], session: &str) -> String {
    let key = derive_key(shared_secret, session);
    let num = (u32::from_be_bytes([key[0], key[1], key[2], key[3]]) & 0x7FFF_FFFF) % 1_000_000;
    format!("{:06}", num)
}

fn aad(session: &str, from: &str) -> Vec<u8> {
    let mut a = vec![VERSION as u8];
    a.extend_from_slice(session.as_bytes());
    a.push(0);
    a.extend_from_slice(from.as_bytes());
    a
}

fn encrypt(key: &[u8; 32], nonce: &[u8], aad: &[u8], plain: &[u8]) -> Result<Vec<u8>, PairingError> {
    let cipher = Aes256Gcm::new(key.into());
    cipher
        .encrypt(Nonce::from_slice(nonce), Payload { msg: plain, aad })
        .map_err(|_| PairingError::BadMessage)
}

fn decrypt(key: &[u8; 32], nonce: &[u8], aad: &[u8], cipher_text: &[u8]) -> Result<Vec<u8>, PairingError> {
    let cipher = Aes256Gcm::new(key.into());
    cipher
        .decrypt(Nonce::from_slice(nonce), Payload { msg: cipher_text, aad })
        .map_err(|_| PairingError::BadMessage)
}

/// Phone side: encrypts the sources document for the TV of a scanned link.
pub fn seal(
    link: &str,
    entropy: &[u8],
    share_json: &str,
    phone_name: &str,
    now: i64,
) -> Result<Sealed, PairingError> {
    if entropy.len() < SEAL_ENTROPY {
        return Err(PairingError::NotEnoughEntropy);
    }
    let parsed = parse_link(link, now)?;
    let tv_public: [u8; 32] = b64_decode(&parsed.tv_public_key)
        .and_then(|b| b.try_into().ok())
        .ok_or(PairingError::BadLink)?;
    let mut seed = [0u8; 32];
    seed.copy_from_slice(&entropy[..32]);
    let secret = StaticSecret::from(seed);
    let epk = PublicKey::from(&secret);
    let shared = secret.diffie_hellman(&PublicKey::from(tv_public));
    let key = derive_key(shared.as_bytes(), &parsed.session);
    let from: String = phone_name.chars().filter(|c| !c.is_control()).take(40).collect();
    let nonce = &entropy[32..44];
    let ct = encrypt(&key, nonce, &aad(&parsed.session, &from), share_json.as_bytes())?;
    if ct.len() * 4 / 3 > MAX_MESSAGE_CHARS {
        return Err(PairingError::TooLarge);
    }
    let message = Message {
        v: VERSION,
        s: parsed.session,
        from,
        epk: b64_encode(epk.as_bytes()),
        nonce: b64_encode(nonce),
        ct: b64_encode(&ct),
    };
    Ok(Sealed {
        message: serde_json::to_string(&message).map_err(|_| PairingError::BadMessage)?,
        reply_key: b64_encode(&key),
    })
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Opened {
    /// The document or message, in clear (sources document, ai-config, or text).
    pub share_json: String,
    pub from: String,
    /// Key to answer the phone with `seal_reply`.
    pub reply_key: String,
    /// The new session state (one use, failures counted): the TV stores it in place of the old one.
    pub state: String,
}

/// Payload sent from phone to TV to configure an AI provider (PRD 40 § 4.2).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AiConfigPayload {
    pub provider: String,
    #[serde(default)]
    pub model: Option<String>,
    #[serde(default)]
    pub base_url: Option<String>,
    pub api_key: String,
}

/// Text input sent from phone to TV for search or assistant (PRD 40 § 4.2).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TextPayload {
    pub text: String,
}

/// Envelope recognizing the type of message sent to the TV.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "type", rename_all = "kebab-case")]
pub enum SealedPayload {
    #[serde(rename = "cnd-source-share")]
    SourceShare,
    AiConfig {
        provider: String,
        #[serde(default)]
        model: Option<String>,
        #[serde(default)]
        base_url: Option<String>,
        api_key: String,
    },
    Text {
        text: String,
    },
    HouseholdJoin {
        household_id: String,
        household_key: String,
        household_name: String,
        #[serde(default)]
        sender_device_name: Option<String>,
        #[serde(default)]
        sender_device_id: Option<String>,
    },
    HouseholdJoinRequest {
        device_name: String,
        device_id: String,
        device_type: String,
    },
}

/// What `open` did to the session when it did not produce a document.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Rejected {
    pub error: String,
    pub state: String,
    /// Three bad messages, an expiry or a first success: the TV must show a new QR code.
    pub closed: bool,
}

/// TV side: decrypts a message. The session serves ONE message, closes after `MAX_FAILURES` invalid
/// ones, and never after its expiry. Returns the opened document or the reason it was refused.
pub fn open(state_json: &str, message_json: &str, now: i64) -> Result<Opened, Rejected> {
    let mut state: SessionState = serde_json::from_str(state_json).map_err(|_| Rejected {
        error: PairingError::Closed.to_string(),
        state: state_json.to_string(),
        closed: true,
    })?;
    let reject = |state: &mut SessionState, err: PairingError, count: bool| -> Rejected {
        if count {
            state.failures += 1;
        }
        let closed = state.used || state.failures >= MAX_FAILURES || now >= state.expires_at;
        Rejected {
            error: err.to_string(),
            state: serde_json::to_string(state).unwrap_or_default(),
            closed,
        }
    };
    if state.used || state.failures >= MAX_FAILURES {
        return Err(reject(&mut state, PairingError::Closed, false));
    }
    if now >= state.expires_at {
        return Err(reject(&mut state, PairingError::Expired, false));
    }
    if message_json.len() > MAX_MESSAGE_CHARS + 1024 {
        return Err(reject(&mut state, PairingError::TooLarge, true));
    }
    let Ok(msg) = serde_json::from_str::<Message>(message_json) else {
        return Err(reject(&mut state, PairingError::BadMessage, true));
    };
    if msg.v != VERSION || msg.s != state.session {
        return Err(reject(&mut state, PairingError::BadMessage, true));
    }
    let parts = (
        b64_decode(&state.secret_key).and_then(|b| <[u8; 32]>::try_from(b).ok()),
        b64_decode(&msg.epk).and_then(|b| <[u8; 32]>::try_from(b).ok()),
        b64_decode(&msg.nonce).filter(|n| n.len() == 12),
        b64_decode(&msg.ct),
    );
    let (Some(seed), Some(epk), Some(nonce), Some(ct)) = parts else {
        return Err(reject(&mut state, PairingError::BadMessage, true));
    };
    let secret = StaticSecret::from(seed);
    let shared = secret.diffie_hellman(&PublicKey::from(epk));
    let key = derive_key(shared.as_bytes(), &state.session);
    let plain = match decrypt(&key, &nonce, &aad(&state.session, &msg.from), &ct) {
        Ok(p) => p,
        Err(e) => return Err(reject(&mut state, e, true)),
    };
    let Ok(share_json) = String::from_utf8(plain) else {
        return Err(reject(&mut state, PairingError::BadMessage, true));
    };
    // One message per session: the private key is wiped, a replay finds the session closed.
    state.used = true;
    state.secret_key = String::new();
    Ok(Opened {
        share_json,
        from: msg.from,
        reply_key: b64_encode(&key),
        state: serde_json::to_string(&state).unwrap_or_default(),
    })
}

// ----------------------------------------------------------------------------- the answer (TV → phone)

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Reply {
    pub s: String,
    pub nonce: String,
    pub ct: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ReplyBody {
    /// `added`, `refused` or `error`.
    pub result: String,
    pub count: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub payload: Option<String>,
}

/// TV or inviter side: sends back a reply with an optional encrypted payload (e.g. household credentials).
pub fn seal_reply_with_payload(
    reply_key: &str,
    session: &str,
    entropy: &[u8],
    result: &str,
    count: u32,
    payload: Option<&str>,
) -> Result<String, PairingError> {
    if entropy.len() < REPLY_ENTROPY {
        return Err(PairingError::NotEnoughEntropy);
    }
    let key: [u8; 32] = b64_decode(reply_key).and_then(|b| b.try_into().ok()).ok_or(PairingError::BadMessage)?;
    let body = serde_json::to_vec(&ReplyBody {
        result: result.to_string(),
        count,
        payload: payload.map(|s| s.to_string()),
    }).map_err(|_| PairingError::BadMessage)?;
    let nonce = &entropy[..12];
    let ct = encrypt(&key, nonce, &aad(session, "reply"), &body)?;
    serde_json::to_string(&Reply { s: session.to_string(), nonce: b64_encode(nonce), ct: b64_encode(&ct) })
        .map_err(|_| PairingError::BadMessage)
}

/// TV side: tells the phone what happened (encrypted with the key of the session).
pub fn seal_reply(
    reply_key: &str,
    session: &str,
    entropy: &[u8],
    result: &str,
    count: u32,
) -> Result<String, PairingError> {
    seal_reply_with_payload(reply_key, session, entropy, result, count, None)
}

/// Phone side: reads the TV's answer.
pub fn open_reply(reply_key: &str, session: &str, reply_json: &str) -> Result<ReplyBody, PairingError> {
    let key: [u8; 32] = b64_decode(reply_key).and_then(|b| b.try_into().ok()).ok_or(PairingError::BadMessage)?;
    let reply: Reply = serde_json::from_str(reply_json).map_err(|_| PairingError::BadMessage)?;
    if reply.s != session {
        return Err(PairingError::BadMessage);
    }
    let nonce = b64_decode(&reply.nonce).filter(|n| n.len() == 12).ok_or(PairingError::BadMessage)?;
    let ct = b64_decode(&reply.ct).ok_or(PairingError::BadMessage)?;
    let plain = decrypt(&key, &nonce, &aad(session, "reply"), &ct)?;
    serde_json::from_slice(&plain).map_err(|_| PairingError::BadMessage)
}

#[cfg(test)]
mod tests;
