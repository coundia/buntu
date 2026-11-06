pub fn normalize_group_key(group: &str) -> String {
    group.trim().to_lowercase()
}

pub fn is_adult_category(group: &str) -> bool {
    let lower = group.trim().to_lowercase();
    let keywords = [
        "adult", "adults", "adulte", "adultes", "xxx", "+18", "18+", "porn", "porno",
        "erotic", "erotique", "nsfw", "for adults", "pour adultes",
    ];
    keywords.iter().any(|&kw| {
        if kw == "+18" || kw == "18+" || kw == "xxx" {
            lower.contains(kw)
        } else {
            lower.split(|c: char| !c.is_alphanumeric()).any(|w| w == kw)
        }
    })
}

pub fn is_kids_allowed(group: &str, allowlist: &[String]) -> bool {
    if is_adult_category(group) {
        return false;
    }
    let norm = normalize_group_key(group);
    allowlist.iter().any(|allowed| normalize_group_key(allowed) == norm)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_adult_detection() {
        assert!(is_adult_category("FR | Adultes"));
        assert!(is_adult_category("XXX Channels"));
        assert!(is_adult_category("VOD 18+"));
        assert!(!is_adult_category("Canal+ Cinema"));
        assert!(!is_adult_category("Documentaires"));
    }

    #[test]
    fn test_kids_allowlist() {
        let allowed = vec!["Jeunesse".to_string(), "Dessins Animes".to_string()];
        assert!(is_kids_allowed("Jeunesse", &allowed));
        assert!(!is_kids_allowed("Adultes", &allowed));
        assert!(!is_kids_allowed("Sport", &allowed));
    }
}

