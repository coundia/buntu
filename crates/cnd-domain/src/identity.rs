//! Common identity of IPTV sources and contents across all platforms (PRD 41 § 3).
//!
//! A watch position, a favorite or a recommendation dismissal attaches to a `content_key`.
//! Previously, identifiers differed between Tizen and the Rust core, and sources used random UUIDs
//! so the same account added to two devices produced completely different keys.
//!
//! Rules:
//! - Deterministic source key:
//!   - Xtream: `blake3("xtream:<norm_server>:<norm_username>")`
//!   - M3U: `blake3("m3u:<norm_playlist_url_without_credentials>")`
//! - Deterministic content key:
//!   - `blake3("<source_key>:<kind>:<provider_item_id>")`

use url::Url;

const SENSITIVE_QUERY_KEYS: &[&str] = &[
    "username", "user", "login", "password", "pass", "passwd", "pwd", "token", "apikey", "api_key",
    "key", "auth", "access_token", "secret",
];

/// Normalizes an Xtream server URL (lowercase scheme/host, trimmed, no trailing slash).
pub fn normalize_xtream_server(raw: &str) -> String {
    let trimmed = raw.trim();
    if let Ok(mut parsed) = Url::parse(trimmed) {
        let _ = parsed.set_username("");
        let _ = parsed.set_password(None);
        parsed.set_query(None);
        parsed.set_fragment(None);
        let mut s = parsed.to_string();
        if s.ends_with('/') {
            s.pop();
        }
        s.to_ascii_lowercase()
    } else {
        trimmed.trim_end_matches('/').to_ascii_lowercase()
    }
}

/// Normalizes an M3U playlist URL by blanking credentials and stripping fragments.
pub fn normalize_m3u_endpoint(raw: &str) -> String {
    let trimmed = raw.trim();
    if let Ok(mut parsed) = Url::parse(trimmed) {
        let _ = parsed.set_username("");
        let _ = parsed.set_password(None);
        parsed.set_fragment(None);

        let pairs: Vec<(String, String)> = parsed
            .query_pairs()
            .map(|(k, v)| (k.into_owned(), v.into_owned()))
            .collect();

        if !pairs.is_empty() {
            let mut serializer = url::form_urlencoded::Serializer::new(String::new());
            for (key, value) in &pairs {
                let k_lower = key.trim().to_ascii_lowercase();
                if SENSITIVE_QUERY_KEYS.contains(&k_lower.as_str()) {
                    serializer.append_pair(key, "");
                } else {
                    serializer.append_pair(key, value);
                }
            }
            parsed.set_query(Some(&serializer.finish()));
        }

        let mut s = parsed.to_string();
        if s.ends_with('/') {
            s.pop();
        }
        s.to_ascii_lowercase()
    } else {
        trimmed.trim_end_matches('/').to_ascii_lowercase()
    }
}

/// Computes the deterministic 256-bit source key for an Xtream source.
pub fn source_key_xtream(server: &str, username: &str) -> String {
    let norm_server = normalize_xtream_server(server);
    let norm_user = username.trim().to_ascii_lowercase();
    let input = format!("xtream:{norm_server}:{norm_user}");
    blake3::hash(input.as_bytes()).to_hex().to_string()
}

/// Computes the deterministic 256-bit source key for an M3U source.
pub fn source_key_m3u(playlist_url: &str) -> String {
    let norm_url = normalize_m3u_endpoint(playlist_url);
    let input = format!("m3u:{norm_url}");
    blake3::hash(input.as_bytes()).to_hex().to_string()
}

/// Generic source key computation.
pub fn compute_source_key(source_type: &str, server_or_url: &str, username: Option<&str>) -> String {
    if source_type.eq_ignore_ascii_case("xtream") {
        source_key_xtream(server_or_url, username.unwrap_or(""))
    } else {
        source_key_m3u(server_or_url)
    }
}

/// Identity of an IPTV **account**, to recognise the same account wherever it was added (another device
/// of the household, the Samsung TV, a second manual add): the `uuid` of a source is random per device.
///
/// - Xtream: server + username (same as [`source_key_xtream`]).
/// - M3U whose address carries `username` and `password` (`…/get.php?username=…&password=…`): that is the
///   Xtream account it reads, so it gets the Xtream identity of `<scheme>://<host>[:port]` + username.
///   [`source_key_m3u`] blanks the credentials, so two accounts of one panel would share its key.
/// - Any other M3U: [`source_key_m3u`] of its address.
///
/// Empty strings count as absent. The password never takes part: changing it keeps the same account.
pub fn account_identity_key(
    source_type: &str,
    server: Option<&str>,
    url: Option<&str>,
    username: Option<&str>,
) -> String {
    let server = present(server);
    let url = present(url);
    let username = present(username);

    if source_type.trim().eq_ignore_ascii_case("xtream") {
        if let Some(server) = server {
            if let Some(user) = username {
                return source_key_xtream(server, user);
            }
        }
        if let Some((origin, user)) = url.and_then(xtream_account_in_url) {
            return source_key_xtream(&origin, username.unwrap_or(&user));
        }
        return source_key_xtream(server.or(url).unwrap_or(""), username.unwrap_or(""));
    }

    let locator = url.or(server).unwrap_or("");
    match xtream_account_in_url(locator) {
        Some((origin, user)) => source_key_xtream(&origin, &user),
        None => source_key_m3u(locator),
    }
}

fn present(v: Option<&str>) -> Option<&str> {
    v.map(str::trim).filter(|v| !v.is_empty())
}

/// `http://host:8080/get.php?username=bob&password=x&type=m3u` → (`http://host:8080`, `bob`).
fn xtream_account_in_url(raw: &str) -> Option<(String, String)> {
    let parsed = Url::parse(raw.trim()).ok()?;
    if parsed.scheme() != "http" && parsed.scheme() != "https" {
        return None;
    }
    let mut user = None;
    let mut has_password = false;
    for (k, v) in parsed.query_pairs() {
        match k.trim().to_ascii_lowercase().as_str() {
            "username" if !v.trim().is_empty() => user = Some(v.trim().to_string()),
            "password" if !v.trim().is_empty() => has_password = true,
            _ => {}
        }
    }
    let user = user.filter(|_| has_password)?;
    let host = parsed.host_str()?;
    let origin = match parsed.port() {
        Some(port) => format!("{}://{host}:{port}", parsed.scheme()),
        None => format!("{}://{host}", parsed.scheme()),
    };
    Some((origin, user))
}

/// Computes the deterministic 256-bit content key for a channel, movie, series, or episode.
pub fn compute_content_key(source_key: &str, kind: &str, provider_id: &str) -> String {
    let norm_kind = kind.trim().to_ascii_lowercase();
    let norm_id = provider_id.trim();
    let input = format!("{source_key}:{norm_kind}:{norm_id}");
    blake3::hash(input.as_bytes()).to_hex().to_string()
}

/// Checks whether a string is a 64-character lowercase hex string (Blake3 output).
pub fn is_content_key(s: &str) -> bool {
    s.len() == 64 && s.chars().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_xtream_source_key_deterministic() {
        let k1 = source_key_xtream("http://Example.COM:8080/", "Bob");
        let k2 = source_key_xtream("http://example.com:8080", "bob ");
        assert_eq!(k1, k2);
        assert!(is_content_key(&k1));

        // Different user -> different key
        let k3 = source_key_xtream("http://example.com:8080", "alice");
        assert_ne!(k1, k3);
    }

    #[test]
    fn test_m3u_source_key_deterministic() {
        let u1 = "http://srv:8080/get.php?username=bob&password=s3cret&type=m3u";
        let u2 = "http://srv:8080/get.php?username=alice&password=other&type=m3u";
        let k1 = source_key_m3u(u1);
        let k2 = source_key_m3u(u2);
        // Sensitive credentials stripped -> canonical endpoint matches
        assert_eq!(k1, k2);
        assert!(is_content_key(&k1));
    }

    #[test]
    fn account_identity_ignores_case_slash_spaces_and_password() {
        let a = account_identity_key("xtream", Some("http://Srv.Example:8080/"), None, Some(" Bob"));
        let b = account_identity_key("XTREAM", Some("http://srv.example:8080"), Some(""), Some("bob"));
        assert_eq!(a, b);
        assert_ne!(a, account_identity_key("xtream", Some("http://srv.example:8080"), None, Some("alice")));
        assert_ne!(a, account_identity_key("xtream", Some("http://srv.example:8081"), None, Some("bob")));
    }

    #[test]
    fn account_identity_of_a_get_php_playlist_is_its_xtream_account() {
        let xtream = account_identity_key("xtream", Some("http://srv.example:8080"), None, Some("bob"));
        let playlist = account_identity_key(
            "m3u",
            None,
            Some("http://srv.example:8080/get.php?username=bob&password=s3cret&type=m3u_plus&output=ts"),
            None,
        );
        assert_eq!(xtream, playlist);
        // Two accounts of the same panel stay two accounts (`source_key_m3u` would merge them).
        let other = account_identity_key(
            "m3u",
            None,
            Some("http://srv.example:8080/get.php?username=alice&password=x&type=m3u_plus"),
            None,
        );
        assert_ne!(playlist, other);
    }

    #[test]
    fn account_identity_of_an_xtream_source_saved_with_its_playlist_address() {
        let by_server = account_identity_key("xtream", Some("http://srv.example:8080"), None, Some("bob"));
        let by_url = account_identity_key(
            "xtream",
            None,
            Some("http://srv.example:8080/get.php?username=bob&password=x&type=m3u_plus"),
            None,
        );
        assert_eq!(by_server, by_url);
    }

    #[test]
    fn account_identity_of_a_plain_playlist_is_its_address() {
        let a = account_identity_key("m3u", None, Some("https://lists.example/My.m3u"), None);
        let b = account_identity_key("m3u", Some(""), Some("https://lists.example/my.m3u/"), None);
        assert_eq!(a, b);
        assert_ne!(a, account_identity_key("m3u", None, Some("https://lists.example/other.m3u"), None));
    }

    #[test]
    fn test_content_key_deterministic() {
        let s_key = source_key_xtream("http://iptv.tv:8000", "user1");
        let c1 = compute_content_key(&s_key, "live", "456");
        let c2 = compute_content_key(&s_key, "LIVE", "456");
        assert_eq!(c1, c2);
        assert!(is_content_key(&c1));

        let c_vod = compute_content_key(&s_key, "movie", "456");
        assert_ne!(c1, c_vod);
    }
}

