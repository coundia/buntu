/// Parsed and normalized representation of a media title for saga detection.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NormalizedTitle {
    pub raw: String,
    pub root: String,
    pub number: Option<u32>,
    pub subtitle: Option<String>,
    pub year: Option<u32>,
}

/// Normalizes a movie title into its saga root, sequence number, and optional subtitle.
pub fn parse_saga_title(raw_title: &str, known_year: Option<u32>) -> NormalizedTitle {
    let title = raw_title.trim();

    // 1. Extract year if present in parentheses or brackets like (2012) or [2019]
    let mut extracted_year = known_year;
    if let Some(pos) = title.find(['(', '[']) {
        let remainder = &title[pos..];
        if let Some(end_pos) = remainder.find([')', ']']) {
            let inside = remainder[1..end_pos].trim();
            if inside.len() == 4 && inside.chars().all(|c| c.is_ascii_digit()) {
                if let Ok(y) = inside.parse::<u32>() {
                    if (1900..=2050).contains(&y) && extracted_year.is_none() {
                        extracted_year = Some(y);
                    }
                }
            }
        }
    }

    // 2. Remove year blocks like (2012) and release brackets
    let mut clean_raw = String::new();
    let mut depth = 0;
    for c in title.chars() {
        if c == '(' || c == '[' {
            depth += 1;
        } else if (c == ')' || c == ']') && depth > 0 {
            depth -= 1;
        } else if depth == 0 {
            clean_raw.push(c);
        }
    }

    // 3. Split by subtitle delimiters (':', ' - ', or ' — ')
    let (head_raw, subtitle_raw) = if let Some(idx) = clean_raw.find(':') {
        let (h, s) = clean_raw.split_at(idx);
        (h.trim(), Some(s[1..].trim()))
    } else if let Some(idx) = clean_raw.find(" - ") {
        let (h, s) = clean_raw.split_at(idx);
        (h.trim(), Some(s[3..].trim()))
    } else if let Some(idx) = clean_raw.find(" — ") {
        let (h, s) = clean_raw.split_at(idx);
        (h.trim(), Some(s[4..].trim()))
    } else {
        (clean_raw.as_str(), None)
    };

    // 4. Clean head and subtitle by stripping tags, dots, underscores
    let mut head = clean_title_part(head_raw, &mut extracted_year);
    let mut subtitle = subtitle_raw.map(|s| clean_title_part(s, &mut extracted_year));

    // 5. If subtitle is absent, check for known franchise roots at start of head (e.g. "Avengers Endgame" or "Harry Potter et...")
    if subtitle.is_none() {
        let lower_h = head.to_lowercase();
        let known_prefixes = [
            ("harry potter et ", "Harry Potter"),
            ("harry potter and ", "Harry Potter"),
            ("avengers ", "Avengers"),
            ("star wars ", "Star Wars"),
            ("fast & furious ", "Fast & Furious"),
            ("fast and furious ", "Fast & Furious"),
            ("mission impossible ", "Mission Impossible"),
            ("transformers ", "Transformers"),
            ("john wick ", "John Wick"),
            ("jurassic park ", "Jurassic Park"),
            ("jurassic world ", "Jurassic World"),
            ("hunger games ", "Hunger Games"),
        ];

        for (pfx, franchise) in known_prefixes {
            if lower_h.starts_with(pfx) {
                let rest = head[pfx.len()..].trim().to_string();
                head = franchise.to_string();
                subtitle = Some(rest);
                break;
            }
        }
    }

    // 6. Extract sequence number (Arabic, Roman, or French/English word forms)
    let (root_text, number) = extract_number(&head);

    // If number wasn't in head, check subtitle for raw number, roman numeral, or "Episode IV", "Part 2", etc.
    let number = number.or_else(|| {
        subtitle.as_deref().and_then(|s| {
            if let Ok(n) = s.trim().parse::<u32>() {
                return Some(n);
            }
            if let Some(n) = parse_roman_numeral(s.trim()) {
                return Some(n);
            }
            extract_subtitle_number(s)
        })
    });

    // 7. Strip leading articles from root for stable grouping
    let root_lower = normalize_root_key(root_text);

    NormalizedTitle {
        raw: raw_title.to_string(),
        root: root_lower,
        number,
        subtitle,
        year: extracted_year,
    }
}

fn clean_title_part(raw: &str, year_out: &mut Option<u32>) -> String {
    let replaced = raw.replace(['.', '_'], " ");
    let release_tags = [
        "1080p", "720p", "2160p", "4k", "uhd", "bluray", "bdrip", "dvdrip", "web-dl",
        "webrip", "hdrip", "hdtv", "multi", "vostfr", "truefrench", "french", "vf",
        "vff", "vfi", "ac3", "dts", "aac", "x264", "x265", "h264", "h265", "hevc",
        "remux", "extended", "unrated", "directors cut", "director's cut", "imax",
    ];

    let mut clean_words = Vec::new();
    for word in replaced.split_whitespace() {
        let clean_w = word.trim_matches(|c: char| !c.is_alphanumeric() && c != '&' && c != '\'');
        let lower_w = clean_w.to_lowercase();
        if release_tags.contains(&lower_w.as_str()) {
            continue;
        }
        if lower_w.len() == 4 && lower_w.chars().all(|c| c.is_ascii_digit()) {
            if let Ok(y) = lower_w.parse::<u32>() {
                if (1900..=2050).contains(&y) {
                    if year_out.is_none() {
                        *year_out = Some(y);
                    }
                    continue;
                }
            }
        }
        clean_words.push(clean_w);
    }
    clean_words.join(" ")
}

/// Normalizes the saga root string: strips accents, leading articles, whitespace.
pub fn normalize_root_key(text: &str) -> String {
    let lower = text.trim().to_lowercase();
    let stripped = if let Some(rest) = lower.strip_prefix("the ") {
        rest
    } else if let Some(rest) = lower.strip_prefix("les ") {
        rest
    } else if let Some(rest) = lower.strip_prefix("le ") {
        rest
    } else if let Some(rest) = lower.strip_prefix("la ") {
        rest
    } else if let Some(rest) = lower.strip_prefix("l'") {
        rest
    } else if let Some(rest) = lower.strip_prefix("l’") {
        rest
    } else if let Some(rest) = lower.strip_prefix("un ") {
        rest
    } else if let Some(rest) = lower.strip_prefix("une ") {
        rest
    } else if let Some(rest) = lower.strip_prefix("a ") {
        rest
    } else if let Some(rest) = lower.strip_prefix("an ") {
        rest
    } else {
        &lower
    };

    // Remove diacritics / accents
    remove_diacritics(stripped).trim().to_string()
}

fn extract_number(text: &str) -> (&str, Option<u32>) {
    let trimmed = text.trim();
    let words: Vec<&str> = trimmed.split_whitespace().collect();
    if words.is_empty() {
        return (trimmed, None);
    }

    // Check last word for number or Roman numeral
    let last = words[words.len() - 1];
    if let Ok(num) = last.parse::<u32>() {
        let prefix_len = trimmed.len() - last.len();
        return (trimmed[..prefix_len].trim(), Some(num));
    }

    if let Some(num) = parse_roman_numeral(last) {
        let prefix_len = trimmed.len() - last.len();
        return (trimmed[..prefix_len].trim(), Some(num));
    }

    // Check for "Partie X", "Part X", "Chapitre X", "Chapter X"
    if words.len() >= 2 {
        let second_last = words[words.len() - 2].to_lowercase();
        if second_last == "partie" || second_last == "part" || second_last == "chapitre" || second_last == "chapter" {
            if let Ok(num) = last.parse::<u32>() {
                let suffix_len = words[words.len() - 2].len() + 1 + last.len();
                let prefix_len = trimmed.len() - suffix_len;
                return (trimmed[..prefix_len].trim(), Some(num));
            }
            if let Some(num) = parse_roman_numeral(last) {
                let suffix_len = words[words.len() - 2].len() + 1 + last.len();
                let prefix_len = trimmed.len() - suffix_len;
                return (trimmed[..prefix_len].trim(), Some(num));
            }
        }
    }

    (trimmed, None)
}

fn extract_subtitle_number(sub: &str) -> Option<u32> {
    let lower = sub.to_lowercase();
    let words: Vec<&str> = lower.split_whitespace().collect();
    for (idx, w) in words.iter().enumerate() {
        if (*w == "episode" || *w == "épisode" || *w == "part" || *w == "partie" || *w == "chapter" || *w == "chapitre")
            && idx + 1 < words.len()
        {
            let next = words[idx + 1];
            if let Ok(num) = next.parse::<u32>() {
                return Some(num);
            }
            if let Some(num) = parse_roman_numeral(next) {
                return Some(num);
            }
        }
    }
    None
}

fn parse_roman_numeral(s: &str) -> Option<u32> {
    let upper = s.trim().to_uppercase();
    match upper.as_str() {
        "I" => Some(1),
        "II" => Some(2),
        "III" => Some(3),
        "IV" => Some(4),
        "V" => Some(5),
        "VI" => Some(6),
        "VII" => Some(7),
        "VIII" => Some(8),
        "IX" => Some(9),
        "X" => Some(10),
        "XI" => Some(11),
        "XII" => Some(12),
        "XIII" => Some(13),
        "XIV" => Some(14),
        "XV" => Some(15),
        "XVI" => Some(16),
        "XVII" => Some(17),
        "XVIII" => Some(18),
        "XIX" => Some(19),
        "XX" => Some(20),
        _ => None,
    }
}

pub fn remove_diacritics(s: &str) -> String {
    s.chars()
        .map(|c| match c {
            'à' | 'á' | 'â' | 'ã' | 'ä' | 'å' => 'a',
            'ç' => 'c',
            'è' | 'é' | 'ê' | 'ë' => 'e',
            'ì' | 'í' | 'î' | 'ï' => 'i',
            'ñ' => 'n',
            'ò' | 'ó' | 'ô' | 'õ' | 'ö' => 'o',
            'ù' | 'ú' | 'û' | 'ü' => 'u',
            'ý' | 'ÿ' => 'y',
            'À' | 'Á' | 'Â' | 'Ã' | 'Ä' | 'Å' => 'a',
            'Ç' => 'c',
            'È' | 'É' | 'Ê' | 'Ë' => 'e',
            'Ì' | 'Í' | 'Î' | 'Ï' => 'i',
            'Ñ' => 'n',
            'Ò' | 'Ó' | 'Ô' | 'Õ' | 'Ö' => 'o',
            'Ù' | 'Ú' | 'Û' | 'Ü' => 'u',
            'Ý' => 'y',
            _ => c,
        })
        .collect()
}

/// Known saga ordering maps for popular multi-film sagas whose titles don't contain simple numbers.
pub fn known_saga_order(saga_root: &str, subtitle: &str) -> Option<u32> {
    let root = normalize_root_key(saga_root);
    let sub = normalize_root_key(subtitle);

    if root == "avengers" {
        if sub.contains("endgame") {
            return Some(4);
        } else if sub.contains("infinity war") {
            return Some(3);
        } else if sub.contains("ere d'ultron") || sub.contains("age of ultron") || sub.contains("ultron") {
            return Some(2);
        } else if sub.is_empty() || sub.contains("rassemblement") {
            return Some(1);
        }
    } else if root == "harry potter" {
        if sub.contains("relique") || sub.contains("deathly hallows") {
            if sub.contains("2") || sub.contains("partie 2") || sub.contains("part 2") {
                return Some(8);
            }
            return Some(7);
        } else if sub.contains("prince") || sub.contains("half-blood") {
            return Some(6);
        } else if sub.contains("ordre") || sub.contains("phoenix") {
            return Some(5);
        } else if sub.contains("coupe") || sub.contains("goblet") {
            return Some(4);
        } else if sub.contains("prisonnier") || sub.contains("azkaban") {
            return Some(3);
        } else if sub.contains("chambre") || sub.contains("chamber") {
            return Some(2);
        } else if sub.contains("ecole") || sub.contains("sorcier") || sub.contains("stone") || sub.contains("philosopher") {
            return Some(1);
        }
    } else if root == "seigneur des anneaux" || root == "lord of the rings" {
        if sub.contains("communaute") || sub.contains("fellowship") {
            return Some(1);
        } else if sub.contains("deux tours") || sub.contains("two towers") {
            return Some(2);
        } else if sub.contains("retour du roi") || sub.contains("return of the king") {
            return Some(3);
        }
    } else if root == "dark knight" || root == "batman" {
        if sub.contains("begins") {
            return Some(1);
        } else if sub.contains("dark knight rises") {
            return Some(3);
        } else if sub == "the dark knight" || sub == "dark knight" {
            return Some(2);
        }
    }

    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_title_normalization_avengers() {
        let t1 = parse_saga_title("The Avengers (2012)", None);
        assert_eq!(t1.root, "avengers");
        assert_eq!(t1.year, Some(2012));

        let t2 = parse_saga_title("Avengers.Endgame.2019.MULTi.1080p", None);
        assert_eq!(t2.root, "avengers");
        assert_eq!(t2.year, Some(2019));
        assert_eq!(known_saga_order(&t2.root, t2.subtitle.as_deref().unwrap_or("")), Some(4));
    }

    #[test]
    fn test_title_normalization_fast_and_furious() {
        let t = parse_saga_title("Fast & Furious 7", None);
        assert_eq!(t.root, "fast & furious");
        assert_eq!(t.number, Some(7));
    }

    #[test]
    fn test_title_normalization_harry_potter() {
        let t = parse_saga_title("Harry Potter et la Chambre des secrets", None);
        assert_eq!(t.root, "harry potter");
        assert_eq!(known_saga_order(&t.root, t.subtitle.as_deref().unwrap_or("")), Some(2));
    }

    #[test]
    fn test_title_normalization_roman_numerals() {
        let t = parse_saga_title("Rocky IV", None);
        assert_eq!(t.root, "rocky");
        assert_eq!(t.number, Some(4));

        let sw = parse_saga_title("Star Wars : Épisode IV - Un nouvel espoir", Some(1977));
        assert_eq!(sw.root, "star wars");
        assert_eq!(sw.number, Some(4));
        assert_eq!(sw.year, Some(1977));
    }
}
