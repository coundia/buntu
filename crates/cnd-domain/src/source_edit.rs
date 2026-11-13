//! Local connection settings: validation and locator rewriting, with no I/O.
use serde::{Deserialize, Serialize};
use url::Url;

#[derive(Clone, Serialize, Deserialize)]
pub struct SourceConnectionEdit {
    pub source_type: String,
    #[serde(default)]
    pub server: String,
    #[serde(default)]
    pub username: String,
    #[serde(default)]
    pub password: String,
    #[serde(default)]
    pub url: String,
}

fn http_address(value: &str) -> Result<Url, &'static str> {
    let parsed = Url::parse(value.trim()).map_err(|_| "Adresse invalide")?;
    if !matches!(parsed.scheme(), "http" | "https") || parsed.host_str().is_none() {
        return Err("L’adresse doit commencer par http:// ou https://");
    }
    Ok(parsed)
}

pub fn validate_source_edit(mut edit: SourceConnectionEdit) -> Result<SourceConnectionEdit, &'static str> {
    match edit.source_type.as_str() {
        "xtream" => {
            let parsed = http_address(&edit.server)?;
            if !parsed.username().is_empty() || parsed.password().is_some() || parsed.query().is_some() || parsed.fragment().is_some() {
                return Err("Saisissez uniquement l’adresse du serveur dans HOST");
            }
            edit.server = parsed.as_str().trim_end_matches('/').to_string();
            edit.username = edit.username.trim().to_string();
            if edit.username.is_empty() || edit.password.is_empty() {
                return Err("Utilisateur et mot de passe requis");
            }
        }
        "m3u" => { edit.url = http_address(&edit.url)?.to_string(); }
        _ => return Err("Type de source non pris en charge"),
    }
    Ok(edit)
}

fn component(value: &str) -> String {
    let mut result = String::new();
    for byte in value.as_bytes() {
        if byte.is_ascii_alphanumeric() || b"-._~".contains(byte) {
            result.push(*byte as char);
        } else {
            use std::fmt::Write;
            let _ = write!(result, "%{byte:02X}");
        }
    }
    result
}

pub fn rewrite_source_locator(locator: &str, edit: SourceConnectionEdit) -> Result<String, &'static str> {
    let edit = validate_source_edit(edit)?;
    if edit.source_type != "xtream" { return Ok(locator.to_string()); }
    if let Some(raw) = locator.strip_prefix("xtream-series://") {
        let id = raw.rsplit('|').next().ok_or("Série invalide")?;
        return Ok(format!("xtream-series://{}|{}|{}|{id}", component(&edit.server), component(&edit.username), component(&edit.password)));
    }
    let parsed = match Url::parse(locator) { Ok(url) => url, Err(_) => return Ok(locator.to_string()) };
    let path: Vec<_> = parsed.path_segments().into_iter().flatten().collect();
    if path.len() >= 4 && matches!(path[0], "live" | "movie" | "series") {
        let mut rewritten = format!("{}/{}/{}/{}/{}", edit.server, path[0], component(&edit.username), component(&edit.password), path[3..].join("/"));
        if let Some(query) = parsed.query() { rewritten.push('?'); rewritten.push_str(query); }
        if let Some(fragment) = parsed.fragment() { rewritten.push('#'); rewritten.push_str(fragment); }
        return Ok(rewritten);
    }
    if let Some(endpoint @ ("player_api.php" | "get.php" | "xmltv.php")) = path.last().copied() {
        let mut target = Url::parse(&format!("{}/{endpoint}", edit.server)).map_err(|_| "Adresse invalide")?;
        let mut pairs: Vec<(String, String)> = parsed.query_pairs().filter(|(k, _)| k != "username" && k != "password").map(|(k, v)| (k.into_owned(), v.into_owned())).collect();
        pairs.push(("username".into(), edit.username));
        pairs.push(("password".into(), edit.password));
        target.query_pairs_mut().extend_pairs(pairs);
        return Ok(target.into());
    }
    Ok(locator.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn edit() -> SourceConnectionEdit {
        SourceConnectionEdit { source_type: "xtream".into(), server: "https://new.invalid/".into(), username: "local user".into(), password: "p/a?ss".into(), url: String::new() }
    }
    #[test]
    fn existing_movies_and_live_keep_their_provider_id_and_extension() {
        assert_eq!(rewrite_source_locator("http://old.invalid/movie/old/old/42.mkv?token=x", edit()).unwrap(), "https://new.invalid/movie/local%20user/p%2Fa%3Fss/42.mkv?token=x");
        assert_eq!(rewrite_source_locator("http://old.invalid/live/old/old/7.ts", edit()).unwrap(), "https://new.invalid/live/local%20user/p%2Fa%3Fss/7.ts");
    }
    #[test]
    fn series_and_api_queries_use_local_credentials() {
        assert_eq!(rewrite_source_locator("xtream-series://old|u|p|99", edit()).unwrap(), "xtream-series://https%3A%2F%2Fnew.invalid|local%20user|p%2Fa%3Fss|99");
        let value = rewrite_source_locator("http://old.invalid/player_api.php?username=old&password=old&action=get_series_info&series_id=99", edit()).unwrap();
        let parsed = Url::parse(&value).unwrap();
        let pairs: std::collections::HashMap<_, _> = parsed.query_pairs().collect();
        assert_eq!(pairs["username"], "local user");
        assert_eq!(pairs["password"], "p/a?ss");
        assert_eq!(pairs["series_id"], "99");
    }
    #[test]
    fn invalid_hosts_and_missing_credentials_are_refused_without_echoing_them() {
        let mut value = edit(); value.server = "file:///etc/hosts".into();
        assert!(validate_source_edit(value).is_err());
        let mut value = edit(); value.password.clear(); assert!(validate_source_edit(value).is_err());
    }
}
