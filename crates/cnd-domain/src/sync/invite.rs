//! The QR code that adds a device to the household (PRD-41, PRD-44).
//!
//! The code carries the household key itself: whoever sees it can join the household, so apps show it
//! only on request and never store or log it. The payload is a link `buntu://household?key=<64 hex>`;
//! a bare 64-character hexadecimal key is accepted too, for codes made by hand.
//!
//! Same format as Apple `HouseholdInvite.swift`, written here once for the other platforms.

pub const HOUSEHOLD_INVITE_SCHEME: &str = "buntu";
pub const HOUSEHOLD_INVITE_HOST: &str = "household";
pub const HOUSEHOLD_KEY_HEX_LEN: usize = 64;

/// Lower-cased key when `candidate` (trimmed) is exactly 64 hexadecimal characters.
pub fn normalize_household_key(candidate: &str) -> Option<String> {
    let key = candidate.trim().to_ascii_lowercase();
    if key.len() == HOUSEHOLD_KEY_HEX_LEN && key.bytes().all(|b| b.is_ascii_hexdigit()) {
        Some(key)
    } else {
        None
    }
}

/// The text to put in the QR code for `key_hex`, or `None` when it is not a valid key.
pub fn household_invite_link(key_hex: &str) -> Option<String> {
    let key = normalize_household_key(key_hex)?;
    Some(format!("{HOUSEHOLD_INVITE_SCHEME}://{HOUSEHOLD_INVITE_HOST}?key={key}"))
}

/// The household key found in what a scanner read, or `None` when it is not a household code
/// (for example a `buntu://pair?…` link, which adds sources to a TV and is handled elsewhere).
pub fn household_key_from_scanned(text: &str) -> Option<String> {
    let trimmed = text.trim();
    if let Some(key) = normalize_household_key(trimmed) {
        return Some(key);
    }
    let (scheme, rest) = trimmed.split_once("://")?;
    if !scheme.eq_ignore_ascii_case(HOUSEHOLD_INVITE_SCHEME) {
        return None;
    }
    let (host, query) = match rest.split_once('?') {
        Some((h, q)) => (h, q),
        None => (rest, ""),
    };
    // `buntu://household/?key=…` is the same link.
    if !host.trim_end_matches('/').eq_ignore_ascii_case(HOUSEHOLD_INVITE_HOST) {
        return None;
    }
    let query = query.split('#').next().unwrap_or("");
    query
        .split('&')
        .filter_map(|pair| pair.split_once('='))
        .find(|(name, _)| *name == "key")
        .and_then(|(_, value)| normalize_household_key(value))
}

#[cfg(test)]
mod tests {
    use super::*;

    const KEY: &str = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff";

    #[test]
    fn link_round_trips() {
        let link = household_invite_link(KEY).unwrap();
        assert_eq!(link, format!("buntu://household?key={KEY}"));
        assert_eq!(household_key_from_scanned(&link).as_deref(), Some(KEY));
    }

    #[test]
    fn upper_case_key_and_scheme_are_accepted() {
        let upper = KEY.to_ascii_uppercase();
        assert_eq!(household_invite_link(&upper).unwrap(), format!("buntu://household?key={KEY}"));
        let scanned = format!("  BUNTU://Household?key={upper}\n");
        assert_eq!(household_key_from_scanned(&scanned).as_deref(), Some(KEY));
    }

    #[test]
    fn bare_key_is_accepted() {
        assert_eq!(household_key_from_scanned(KEY).as_deref(), Some(KEY));
    }

    #[test]
    fn other_parameters_and_trailing_slash_are_ignored() {
        let scanned = format!("buntu://household/?v=1&key={KEY}#x");
        assert_eq!(household_key_from_scanned(&scanned).as_deref(), Some(KEY));
    }

    #[test]
    fn other_codes_are_refused() {
        assert_eq!(household_key_from_scanned(&format!("buntu://pair?key={KEY}")), None);
        assert_eq!(household_key_from_scanned(&format!("https://household?key={KEY}")), None);
        assert_eq!(household_key_from_scanned("buntu://household?key=1234"), None);
        assert_eq!(household_key_from_scanned("buntu://household"), None);
        assert_eq!(household_key_from_scanned(&format!("{KEY}0")), None);
        assert_eq!(household_key_from_scanned(&KEY.replace('0', "g")), None);
        assert_eq!(household_invite_link("not a key"), None);
    }
}
