//! Finds and blanks the credentials a URL can carry, so a source can be shared "without identifiers".
//!
//! Three places are covered: `user:pass@host`, sensitive query parameters (`username=`, `password=`,
//! `token=`...) and Xtream stream paths (`/live/{user}/{pass}/...`). Values are blanked, not the keys,
//! so the recipient sees what is missing and can fill it in.

use url::Url;

const SENSITIVE_KEYS: &[&str] = &[
    "username", "user", "login", "password", "pass", "passwd", "pwd", "token", "apikey", "api_key",
    "key", "auth", "access_token", "secret",
];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Stripped {
    pub url: String,
    /// `true` when something was removed: the recipient has to supply it.
    pub removed: bool,
}

fn is_sensitive(key: &str) -> bool {
    SENSITIVE_KEYS.contains(&key.trim().to_ascii_lowercase().as_str())
}

/// `http://u:p@h/get.php?username=bob&password=x&type=m3u` -> `http://h/get.php?username=&password=&type=m3u`.
/// A string that is not an absolute URL is returned unchanged.
pub fn strip_credentials(raw: &str) -> Stripped {
    let Ok(mut parsed) = Url::parse(raw.trim()) else {
        return Stripped { url: raw.to_string(), removed: false };
    };
    let mut removed = false;

    if !parsed.username().is_empty() || parsed.password().is_some() {
        let _ = parsed.set_username("");
        let _ = parsed.set_password(None);
        removed = true;
    }

    let pairs: Vec<(String, String)> = parsed
        .query_pairs()
        .map(|(k, v)| (k.into_owned(), v.into_owned()))
        .collect();
    if pairs.iter().any(|(k, v)| is_sensitive(k) && !v.is_empty()) {
        let mut serializer = url::form_urlencoded::Serializer::new(String::new());
        for (key, value) in &pairs {
            if is_sensitive(key) {
                serializer.append_pair(key, "");
            } else {
                serializer.append_pair(key, value);
            }
        }
        parsed.set_query(Some(&serializer.finish()));
        removed = true;
    }

    let segments: Vec<String> = parsed
        .path_segments()
        .map(|s| s.map(str::to_string).collect())
        .unwrap_or_default();
    if segments.len() >= 4
        && matches!(segments[0].to_ascii_lowercase().as_str(), "live" | "movie" | "series" | "timeshift")
        && !segments[1].is_empty()
        && !segments[2].is_empty()
    {
        let mut rebuilt = segments;
        rebuilt[1] = "USERNAME".to_string();
        rebuilt[2] = "PASSWORD".to_string();
        parsed.set_path(&rebuilt.join("/"));
        removed = true;
    }

    Stripped { url: parsed.to_string(), removed }
}

/// `true` when the URL still contains a non-empty sensitive value.
pub fn has_credentials(raw: &str) -> bool {
    strip_credentials(raw).removed
}

/// Canonical form used to recognise the same source on two devices: scheme and host lower-cased,
/// credential values blanked, no trailing slash, no fragment.
pub fn endpoint_key(raw: &str) -> String {
    let stripped = strip_credentials(raw).url;
    match Url::parse(&stripped) {
        Ok(mut parsed) => {
            parsed.set_fragment(None);
            parsed.to_string().trim_end_matches('/').to_ascii_lowercase()
        }
        Err(_) => stripped.trim().trim_end_matches('/').to_ascii_lowercase(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn query_parameters_are_blanked_but_keys_stay() {
        let out = strip_credentials("http://srv:8080/get.php?username=bob&password=s3cret&type=m3u_plus&output=ts");
        assert_eq!(out.url, "http://srv:8080/get.php?username=&password=&type=m3u_plus&output=ts");
        assert!(out.removed);
        assert!(!out.url.contains("bob") && !out.url.contains("s3cret"));
    }

    #[test]
    fn userinfo_is_removed() {
        let out = strip_credentials("http://alice:hunter2@iptv.host:8080/playlist.m3u8");
        assert_eq!(out.url, "http://iptv.host:8080/playlist.m3u8");
        assert!(out.removed);
        let only_user = strip_credentials("http://alice@iptv.host/list.m3u");
        assert_eq!(only_user.url, "http://iptv.host/list.m3u");
        assert!(only_user.removed);
    }

    #[test]
    fn xtream_stream_paths_are_replaced_by_placeholders() {
        let out = strip_credentials("http://srv:8080/live/alice/hunter2/1234.ts");
        assert_eq!(out.url, "http://srv:8080/live/USERNAME/PASSWORD/1234.ts");
        assert!(out.removed);
        assert!(!strip_credentials("http://cdn/live/channel.m3u8").removed, "a short path is not a credential path");
    }

    #[test]
    fn a_clean_url_is_untouched_and_reports_nothing_removed() {
        for clean in ["https://example.com/list.m3u", "http://srv/get.php?username=&password=&type=m3u", "http://srv/epg.xml.gz?lang=fr"] {
            let out = strip_credentials(clean);
            assert!(!out.removed, "{clean}");
        }
        assert_eq!(strip_credentials("not a url").url, "not a url");
        assert!(!strip_credentials("not a url").removed);
    }

    #[test]
    fn tokens_and_keys_are_covered_case_insensitively() {
        let out = strip_credentials("https://api.tv/list?TOKEN=abc123&Key=zzz&lang=fr");
        assert!(out.removed);
        assert!(!out.url.contains("abc123") && !out.url.contains("zzz"));
        assert!(out.url.contains("lang=fr"));
    }

    #[test]
    fn the_same_endpoint_has_the_same_key_whatever_the_credentials() {
        let a = endpoint_key("HTTP://Srv:8080/get.php?username=bob&password=x&type=m3u_plus");
        let b = endpoint_key("http://srv:8080/get.php?username=&password=&type=m3u_plus");
        assert_eq!(a, b);
        assert_ne!(a, endpoint_key("http://other:8080/get.php?username=&password=&type=m3u_plus"));
        assert_eq!(endpoint_key("http://h/list.m3u/"), endpoint_key("http://h/list.m3u#frag"));
    }
}
