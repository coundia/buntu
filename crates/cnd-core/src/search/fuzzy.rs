//! Typo tolerance (PRD 33 § 3.2) without a trigram index: an edit distance on whole words, run on the
//! visible titles of one kind only when the full-text search found little.

/// Damerau–Levenshtein distance (adjacent swaps count as one edit), stopping early above `max`.
pub fn distance(a: &str, b: &str, max: usize) -> Option<usize> {
    let a: Vec<char> = a.chars().collect();
    let b: Vec<char> = b.chars().collect();
    if a.len().abs_diff(b.len()) > max {
        return None;
    }
    let (n, m) = (a.len(), b.len());
    let mut previous2: Vec<usize> = vec![0; m + 1];
    let mut previous: Vec<usize> = (0..=m).collect();
    let mut current: Vec<usize> = vec![0; m + 1];
    for i in 1..=n {
        current[0] = i;
        let mut row_min = current[0];
        for j in 1..=m {
            let cost = usize::from(a[i - 1] != b[j - 1]);
            let mut value = (previous[j] + 1).min(current[j - 1] + 1).min(previous[j - 1] + cost);
            if i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1] {
                value = value.min(previous2[j - 2] + 1);
            }
            current[j] = value;
            row_min = row_min.min(value);
        }
        if row_min > max {
            return None;
        }
        std::mem::swap(&mut previous2, &mut previous);
        std::mem::swap(&mut previous, &mut current);
    }
    let d = previous[m];
    (d <= max).then_some(d)
}

/// How many edits a typo may contain, by word length: short words must be exact.
pub fn allowed_edits(len: usize) -> usize {
    match len {
        0..=3 => 0,
        4..=6 => 1,
        _ => 2,
    }
}

/// Total edits to match every query word against some word of the title (`None` if one word fits nowhere).
/// A query word also matches a title word it is the start of.
pub fn match_edits(query_words: &[String], title_words: &[String]) -> Option<usize> {
    let mut total = 0;
    for q in query_words {
        let allowed = allowed_edits(q.chars().count());
        let best = title_words
            .iter()
            .filter_map(|t| {
                if t.starts_with(q.as_str()) {
                    return Some(0);
                }
                let prefix: String = t.chars().take(q.chars().count()).collect();
                distance(q, t, allowed).or_else(|| distance(q, &prefix, allowed))
            })
            .min()?;
        total += best;
    }
    Some(total)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn w(s: &str) -> Vec<String> {
        s.split_whitespace().map(str::to_string).collect()
    }

    #[test]
    fn distances() {
        assert_eq!(distance("avengers", "avangers", 2), Some(1));
        assert_eq!(distance("mission", "mision", 2), Some(1));
        assert_eq!(distance("inception", "incpetion", 2), Some(1), "a swap is one edit");
        assert_eq!(distance("matrix", "matrix", 2), Some(0));
        assert_eq!(distance("matrix", "avatar", 2), None);
        assert_eq!(distance("a", "abcdef", 2), None);
    }

    #[test]
    fn short_words_must_be_exact() {
        assert_eq!(allowed_edits(3), 0);
        assert_eq!(allowed_edits(5), 1);
        assert_eq!(allowed_edits(9), 2);
        assert_eq!(match_edits(&w("psg"), &w("psg marseille")), Some(0));
        assert_eq!(match_edits(&w("psx"), &w("psg marseille")), None);
    }

    #[test]
    fn a_typo_in_a_title_still_matches() {
        assert_eq!(match_edits(&w("avangers"), &w("avengers endgame")), Some(1));
        assert_eq!(match_edits(&w("mision impossible"), &w("mission impossible fallout")), Some(1));
        assert_eq!(match_edits(&w("interstelar"), &w("interstellar")), Some(1));
    }

    #[test]
    fn a_prefix_is_free_and_an_unrelated_word_fails() {
        assert_eq!(match_edits(&w("aveng"), &w("avengers")), Some(0));
        assert_eq!(match_edits(&w("zorro"), &w("avengers")), None);
        assert_eq!(match_edits(&w("avengers zorro"), &w("avengers")), None, "every word must fit");
    }
}
