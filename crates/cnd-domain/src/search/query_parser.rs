//! Step 1 of the prompt search (PRD 33 § 3.1): what can be read from a sentence without any network.
//!
//! "un film d'action avec Tom Cruise ce soir" -> kind movie, genre action, person "tom cruise", an
//! evening window. What is left over (`terms`) is what names the thing looked for.

use crate::normalizer::fold_diacritics_ascii;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum Kind {
    Live,
    Program,
    Movie,
    Series,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Genre {
    /// The English word OMDb uses (`Action`, `Comedy`).
    pub omdb: &'static str,
    /// Words a playlist category uses for it (`action`, `comedie`, `news`).
    pub categories: &'static [&'static str],
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Window {
    pub from: i64,
    pub to: i64,
    /// The window is in the past: only a channel with an archive can replay it.
    pub past: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Quality {
    Uhd,
    FullHd,
    Hd,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct ParsedQuery {
    pub raw: String,
    /// Folded words that name the thing: titles, teams, channels.
    pub terms: Vec<String>,
    /// Genre words as typed ("sport", "info"): not a title, but also what a channel or a programme is called.
    pub genre_words: Vec<String>,
    /// Empty means "everything".
    pub kinds: Vec<Kind>,
    pub window: Option<Window>,
    /// Language or country codes found in playlist categories (`fr`, `uk`, `kr`).
    pub languages: Vec<String>,
    #[serde(skip_deserializing)]
    pub genres: Vec<Genre>,
    /// Folded names: after "avec" / "de" / "with" (explicit), or a capitalised pair like "Tom Cruise".
    pub people: Vec<String>,
    /// The user said "avec X" / "de X": the request is about that person's films, not channels.
    pub people_explicit: bool,
    pub year_from: Option<u32>,
    pub year_to: Option<u32>,
    pub quality: Option<Quality>,
    pub similar_to: Option<String>,
    /// "dans l'ordre" / "in order": a saga in its own order.
    pub ordered: bool,
    pub latest: bool,
}

impl ParsedQuery {
    pub fn wants(&self, kind: Kind) -> bool {
        self.kinds.is_empty() || self.kinds.contains(&kind)
    }

    /// Nothing but filters: no word names a title.
    pub fn has_no_title(&self) -> bool {
        self.terms.is_empty() && self.similar_to.is_none()
    }
}

/// The user's clock: `now` (Unix seconds) and the offset of their time zone from UTC.
#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct Clock {
    pub now: i64,
    pub utc_offset_minutes: i32,
}

impl Clock {
    fn local_midnight(&self, days_from_today: i64) -> i64 {
        let offset = i64::from(self.utc_offset_minutes) * 60;
        let local_now = self.now + offset;
        let start_of_day = local_now - local_now.rem_euclid(86_400);
        start_of_day + days_from_today * 86_400 - offset
    }

    fn local_year(&self) -> u32 {
        // Good enough for "recent": days since 1970 -> year.
        let days = (self.now + i64::from(self.utc_offset_minutes) * 60).div_euclid(86_400);
        (1970 + days / 365) as u32
    }

    /// Weekday of the local day, Monday = 0.
    fn local_weekday(&self, days_from_today: i64) -> i64 {
        let days = (self.now + i64::from(self.utc_offset_minutes) * 60).div_euclid(86_400) + days_from_today;
        (days + 3).rem_euclid(7) // 1970-01-01 was a Thursday
    }
}

const STOPWORDS: &[&str] = &[
    "le", "la", "les", "un", "une", "des", "de", "du", "d", "l", "et", "ou", "a", "au", "aux", "ce", "cet", "cette",
    "ces", "mon", "ma", "mes", "sur", "en", "dans", "pour", "par", "que", "qui", "quoi", "est", "sont", "y", "il",
    "elle", "je", "tu", "on", "nous", "vous", "moi", "me", "te", "se", "s", "qu", "n", "m", "t", "c", "j",
    "mets", "met", "mettre", "lance", "lancer", "regarde", "regarder", "voir", "veux", "voudrais", "cherche",
    "chercher", "trouve", "trouver", "donne", "montre", "afficher", "affiche", "ouvre", "ouvrir", "quelque",
    "quelques", "chose", "bon", "bonne", "bien", "bonsoir", "salut", "svp", "stp", "plait", "peux", "peut",
    "the", "an", "of", "and", "with", "on", "in", "for", "some", "something", "about", "to", "is", "are", "show",
    "find", "search", "watch", "play", "put", "me", "my", "i", "want", "would", "like", "please", "can", "you",
    "good", "great", "any", "all", "at", "tonight", "that", "this", "those", "these",
];

const KIND_WORDS: &[(&str, Kind)] = &[
    ("film", Kind::Movie), ("films", Kind::Movie), ("movie", Kind::Movie), ("movies", Kind::Movie),
    ("cinema", Kind::Movie),
    ("serie", Kind::Series), ("series", Kind::Series), ("saison", Kind::Series), ("episode", Kind::Series),
    ("episodes", Kind::Series),
    ("chaine", Kind::Live), ("chaines", Kind::Live), ("channel", Kind::Live), ("channels", Kind::Live),
    ("emission", Kind::Program), ("emissions", Kind::Program), ("programme", Kind::Program),
    ("programmes", Kind::Program), ("program", Kind::Program), ("programs", Kind::Program),
    ("journal", Kind::Program), ("jt", Kind::Program), ("match", Kind::Program), ("matchs", Kind::Program),
    ("matches", Kind::Program),
];

/// Languages and countries, with the codes playlists put in category names.
const LANGUAGES: &[(&str, &[&str])] = &[
    ("anglais", &["uk", "us", "en"]), ("anglaise", &["uk", "us", "en"]), ("english", &["uk", "us", "en"]),
    ("britannique", &["uk"]), ("americain", &["us"]), ("americaine", &["us"]),
    ("francais", &["fr"]), ("francaise", &["fr"]), ("french", &["fr"]),
    ("espagnol", &["es"]), ("espagnole", &["es"]), ("spanish", &["es"]),
    ("allemand", &["de"]), ("allemande", &["de"]), ("german", &["de"]),
    ("italien", &["it"]), ("italienne", &["it"]), ("italian", &["it"]),
    ("arabe", &["ar"]), ("arabes", &["ar"]), ("arabic", &["ar"]),
    ("portugais", &["pt"]), ("portugaise", &["pt"]), ("portuguese", &["pt"]),
    ("turc", &["tr"]), ("turque", &["tr"]), ("turkish", &["tr"]),
    ("coreen", &["kr", "ko"]), ("coreenne", &["kr", "ko"]), ("korean", &["kr", "ko"]),
    ("japonais", &["jp", "ja"]), ("japonaise", &["jp", "ja"]), ("japanese", &["jp", "ja"]),
    ("indien", &["in", "hi"]), ("indienne", &["in", "hi"]), ("belge", &["be"]), ("suisse", &["ch"]),
];

const GENRES: &[(&[&str], Genre)] = &[
    (&["action"], Genre { omdb: "Action", categories: &["action"] }),
    (&["comedie", "comedies", "comedy", "humour", "drole", "drôles"], Genre { omdb: "Comedy", categories: &["comedie", "comedy", "humour"] }),
    (&["horreur", "horror", "epouvante"], Genre { omdb: "Horror", categories: &["horreur", "horror"] }),
    (&["romance", "romantique", "romantiques", "romantic"], Genre { omdb: "Romance", categories: &["romance", "romantique"] }),
    (&["drame", "drama"], Genre { omdb: "Drama", categories: &["drame", "drama"] }),
    (&["thriller", "suspense"], Genre { omdb: "Thriller", categories: &["thriller", "suspense"] }),
    (&["policier", "policiere", "policiers", "crime", "polar"], Genre { omdb: "Crime", categories: &["policier", "crime", "polar"] }),
    (&["aventure", "aventures", "adventure"], Genre { omdb: "Adventure", categories: &["aventure", "adventure"] }),
    (&["fantastique", "fantasy"], Genre { omdb: "Fantasy", categories: &["fantastique", "fantasy"] }),
    (&["scifi", "sf", "anticipation"], Genre { omdb: "Sci-Fi", categories: &["sci", "scifi", "fiction"] }),
    (&["animation", "anime", "cartoon", "cartoons"], Genre { omdb: "Animation", categories: &["animation", "anime", "cartoon", "kids", "jeunesse"] }),
    (&["documentaire", "documentaires", "documentary", "docu"], Genre { omdb: "Documentary", categories: &["documentaire", "documentary", "docu", "discovery"] }),
    (&["guerre", "war"], Genre { omdb: "War", categories: &["guerre", "war"] }),
    (&["famille", "family"], Genre { omdb: "Family", categories: &["famille", "family", "kids", "jeunesse"] }),
    (&["musique", "music", "musical"], Genre { omdb: "Music", categories: &["musique", "music"] }),
    (&["histoire", "history", "historique"], Genre { omdb: "History", categories: &["histoire", "history"] }),
    (&["western"], Genre { omdb: "Western", categories: &["western"] }),
    (&["sport", "sports", "foot", "football", "basket", "tennis", "rugby"], Genre { omdb: "Sport", categories: &["sport", "sports"] }),
    (&["info", "infos", "actualites", "actu", "news", "informations"], Genre { omdb: "News", categories: &["info", "news", "actualites"] }),
    (&["enfants", "enfant", "kids", "jeunesse", "petits"], Genre { omdb: "Family", categories: &["kids", "jeunesse", "enfants", "cartoon"] }),
];

/// Multi-word phrases rewritten to one word before splitting.
const PHRASES: &[(&str, &str)] = &[
    ("science fiction", "scifi"), ("science-fiction", "scifi"), ("sci fi", "scifi"), ("sci-fi", "scifi"),
    ("dessins animes", "animation"), ("dessin anime", "animation"), ("dessins anime", "animation"),
    ("ce soir", "ce_soir"), ("cette nuit", "cette_nuit"), ("ce week end", "weekend"), ("ce weekend", "weekend"),
    ("week end", "weekend"), ("week-end", "weekend"), ("cet apres midi", "apres_midi"), ("apres midi", "apres_midi"),
    ("ce matin", "ce_matin"), ("dans l ordre", "dans_ordre"), ("in order", "dans_ordre"),
    ("par ordre", "dans_ordre"), ("chronologique", "dans_ordre"), ("du genre de", "comme"), ("du genre", "comme"),
    ("similaire a", "comme"), ("similaires a", "comme"), ("semblable a", "comme"), ("similar to", "comme"),
    ("quelque chose comme", "comme"), ("something like", "comme"),
    ("tonight", "ce_soir"), ("this evening", "ce_soir"), ("this weekend", "weekend"),
    ("yesterday", "hier"), ("tomorrow", "demain"), ("today", "aujourdhui"), ("right now", "maintenant"),
    ("les annees", "annees"),
];

/// The genre a word names (folded), in French or English, with its OMDb name and playlist words.
pub fn genre_for(word: &str) -> Option<Genre> {
    let folded = fold(word.trim()).replace(' ', "");
    let folded = if folded == "sci-fi" || folded == "scifi" || folded == "sciencefiction" { "scifi".to_string() } else { folded };
    GENRES.iter().find(|(words, _)| words.contains(&folded.as_str())).map(|(_, g)| g.clone())
}

/// The playlist codes (`kr`, `uk`) of a language or country written out (folded).
pub fn language_codes(word: &str) -> Option<&'static [&'static str]> {
    let folded = fold(word.trim());
    LANGUAGES.iter().find(|(w, _)| *w == folded).map(|(_, codes)| *codes)
}

fn fold(text: &str) -> String {
    let mut s = fold_diacritics_ascii(text).to_lowercase();
    for ch in ['\'', '’', '`'] {
        s = s.replace(ch, " ");
    }
    s
}

fn alnum_words(text: &str) -> Vec<String> {
    text.split(|c: char| !(c.is_alphanumeric() || c == '_'))
        .filter(|w| !w.is_empty())
        .map(str::to_string)
        .collect()
}

pub fn parse(text: &str, clock: Clock) -> ParsedQuery {
    let mut query = ParsedQuery { raw: text.trim().to_string(), ..ParsedQuery::default() };
    let mut folded = format!(" {} ", fold(text).replace(['-', ','], " "));
    // Longest phrases first so "ce week end" wins over "week end".
    let mut phrases: Vec<&(&str, &str)> = PHRASES.iter().collect();
    phrases.sort_by_key(|(from, _)| std::cmp::Reverse(from.len()));
    for (from, to) in phrases {
        let from_folded = format!(" {} ", from.replace('-', " "));
        let replacement = format!(" {to} ");
        if from_folded == replacement {
            continue;
        }
        for _ in 0..8 {
            if !folded.contains(&from_folded) {
                break;
            }
            folded = folded.replacen(&from_folded, &replacement, 1);
        }
    }
    let words = alnum_words(&folded);

    let mut kinds: Vec<Kind> = Vec::new();
    let mut remaining: Vec<String> = Vec::new();
    let mut similar_next = false;
    let mut similar: Vec<String> = Vec::new();
    let mut people_next = false;
    let mut people: Vec<String> = Vec::new();
    let mut annees_next = false;
    let mut hour: Option<(i64, i64)> = None;
    let mut day_offset: Option<i64> = None;
    let mut part_of_day: Option<(i64, i64)> = None; // hours
    let mut weekend = false;

    for (index, word) in words.iter().enumerate() {
        let w = word.as_str();

        if w == "comme" || w == "like" && words.get(index + 1).is_some() && index > 0 {
            similar_next = true;
            people_next = false;
            continue;
        }
        if w == "avec" || w == "starring" || (w == "with" && !similar_next) {
            people_next = true;
            similar_next = false;
            continue;
        }
        match w {
            "dans_ordre" => { query.ordered = true; continue; }
            "ce_soir" => { day_offset = Some(0); part_of_day = Some((18, 24)); continue; }
            "cette_nuit" => { day_offset = Some(0); part_of_day = Some((22, 30)); continue; }
            "ce_matin" => { day_offset = Some(0); part_of_day = Some((5, 12)); continue; }
            "apres_midi" => { day_offset = Some(0); part_of_day = Some((12, 18)); continue; }
            "weekend" => { weekend = true; continue; }
            "demain" => { day_offset = Some(1); continue; }
            "hier" => { day_offset = Some(-1); continue; }
            "aujourdhui" | "aujourd" => { day_offset = day_offset.or(Some(0)); continue; }
            "maintenant" | "now" | "direct" | "live" => {
                if w == "maintenant" || w == "now" { day_offset = Some(0); part_of_day = None; query.window = Some(Window { from: clock.now, to: clock.now + 1, past: false }); continue; }
                kinds.push(Kind::Live);
                continue;
            }
            "annees" => { annees_next = true; continue; }
            "recent" | "recents" | "recente" | "recentes" | "dernier" | "derniere" | "latest" | "newest" | "nouveau" | "nouveaux" | "nouveautes" => {
                query.latest = true;
                continue;
            }
            "4k" | "uhd" | "2160p" => { query.quality = Some(Quality::Uhd); continue; }
            "fhd" | "1080p" | "1080" => { query.quality = Some(Quality::FullHd); continue; }
            "hd" | "720p" => { query.quality = Some(Quality::Hd); continue; }
            _ => {}
        }

        // "20h", "20h30", "8h"
        if let Some(parsed) = parse_hour(w) {
            hour = Some(parsed);
            continue;
        }
        // Years and decades ("2022", "90", "90s").
        if let Some(year) = w.parse::<u32>().ok().filter(|y| (1900..=2099).contains(y)) {
            if query.year_from.is_none() {
                query.year_from = Some(year);
                query.year_to = Some(year);
            }
            annees_next = false;
            continue;
        }
        if annees_next || w.ends_with('s') && w[..w.len() - 1].chars().all(|c| c.is_ascii_digit()) && w.len() <= 4 && w.len() >= 3 {
            let digits: String = w.chars().filter(char::is_ascii_digit).collect();
            if let Ok(decade) = digits.parse::<u32>() {
                let start = match decade {
                    0..=29 => 2000 + decade / 10 * 10,
                    30..=99 => 1900 + decade / 10 * 10,
                    _ => decade / 10 * 10,
                };
                query.year_from = Some(start);
                query.year_to = Some(start + 9);
                annees_next = false;
                continue;
            }
        }

        if let Some((_, k)) = KIND_WORDS.iter().find(|(word, _)| *word == w) {
            if !kinds.contains(k) {
                kinds.push(*k);
            }
            // "journal" and "jt" name a programme: keep them as the word to look for.
            if matches!(w, "journal" | "jt") {
                remaining.push("journal".to_string());
            }
            continue;
        }
        if let Some((_, codes)) = LANGUAGES.iter().find(|(word, _)| *word == w) {
            for code in *codes {
                if !query.languages.contains(&(*code).to_string()) {
                    query.languages.push((*code).to_string());
                }
            }
            continue;
        }
        if w == "vostfr" || w == "vost" || w == "vf" || w == "vo" {
            continue;
        }
        if let Some((_, genre)) = GENRES.iter().find(|(words, _)| words.contains(&w)) {
            if !query.genres.contains(genre) {
                query.genres.push(genre.clone());
            }
            // A genre word is also a good search word for categories and programme titles.
            if similar_next || people_next {
                // fall through to the person / title branches below
            } else {
                query.genre_words.push(w.to_string());
                continue;
            }
        }
        if STOPWORDS.contains(&w) {
            if people_next && (w == "de" || w == "d" || w == "du") {
                continue;
            }
            // A stop word ends a name ("avec Tom Cruise en action").
            if people_next && !people.is_empty() {
                people_next = false;
            }
            continue;
        }
        if similar_next {
            similar.push(w.to_string());
            continue;
        }
        if people_next {
            people.push(w.to_string());
            continue;
        }
        remaining.push(w.to_string());
    }

    query.kinds = kinds;
    if !people.is_empty() {
        query.people = vec![people.join(" ")];
        query.people_explicit = true;
    }
    for (name, explicit) in capitalised_names(text) {
        let folded = fold(&name);
        if !query.people.contains(&folded) {
            query.people.push(folded.clone());
        }
        if explicit {
            query.people_explicit = true;
            // "un film de Christopher Nolan": the name is not part of a title.
            let name_words: Vec<String> = alnum_words(&folded);
            remaining.retain(|w| !name_words.contains(w));
        }
    }
    if !similar.is_empty() {
        query.similar_to = Some(similar.join(" "));
    }

    // Time.
    if query.window.is_none() {
        query.window = build_window(clock, day_offset, part_of_day, hour, weekend);
    }
    if query.window.is_some() && !query.kinds.contains(&Kind::Program) && query.kinds.is_empty() {
        // A time and no kind: it is about programmes.
        query.kinds = vec![Kind::Program];
    }
    if query.latest && query.year_from.is_none() {
        let year = clock.local_year();
        query.year_from = Some(year.saturating_sub(2));
    }
    // A person is not a title: when there are no other words the people are the search.
    query.terms = remaining;
    query
}

/// Runs of capitalised words in the text as typed: "Tom Cruise", and the name after "de" / "par" / "by".
/// The flag says the name followed such a word, so it surely is a person.
fn capitalised_names(text: &str) -> Vec<(String, bool)> {
    let raw: Vec<&str> = text
        .split(|c: char| c.is_whitespace() || c == '\'' || c == '’')
        .map(|w| w.trim_matches(|c: char| !c.is_alphanumeric()))
        .filter(|w| !w.is_empty())
        .collect();
    let is_cap = |w: &str| {
        let mut chars = w.chars();
        chars.next().is_some_and(char::is_uppercase) && w.chars().count() > 1 && w.chars().skip(1).any(char::is_lowercase)
    };
    let mut out = Vec::new();
    let mut i = 0;
    while i < raw.len() {
        if is_cap(raw[i]) {
            let start = i;
            while i < raw.len() && is_cap(raw[i]) {
                i += 1;
            }
            let run = &raw[start..i];
            let before = start.checked_sub(1).map(|b| fold(raw[b])).unwrap_or_default();
            let explicit = matches!(before.trim(), "de" | "d" | "par" | "by" | "avec" | "with" | "starring" | "realise" | "directed");
            if run.len() >= 2 || (explicit && start > 0) {
                out.push((run.join(" "), explicit));
            }
        } else {
            i += 1;
        }
    }
    out
}

fn parse_hour(word: &str) -> Option<(i64, i64)> {
    let (h, rest) = word.split_once('h')?;
    let hour: i64 = h.parse().ok()?;
    if !(0..=24).contains(&hour) {
        return None;
    }
    let minute: i64 = if rest.is_empty() { 0 } else { rest.parse().ok().filter(|m| (0..60).contains(m))? };
    Some((hour, minute))
}

fn build_window(
    clock: Clock,
    day_offset: Option<i64>,
    part_of_day: Option<(i64, i64)>,
    hour: Option<(i64, i64)>,
    weekend: bool,
) -> Option<Window> {
    if weekend {
        // Saturday 00:00 to Sunday 24:00 of the coming (or current) weekend.
        let weekday = clock.local_weekday(0); // Monday = 0
        let to_saturday = 5 - weekday; // Saturday this week, or yesterday when it is Sunday
        let saturday = clock.local_midnight(to_saturday);
        return Some(Window { from: saturday.max(clock.now.min(saturday + 2 * 86_400)), to: saturday + 2 * 86_400, past: false });
    }
    let day = match (day_offset, hour, part_of_day) {
        (None, None, None) => return None,
        (Some(d), _, _) => d,
        (None, Some(_), _) | (None, _, Some(_)) => 0,
    };
    let midnight = clock.local_midnight(day);
    let (from, to) = if let Some((h, m)) = hour {
        let at = midnight + h * 3600 + m * 60;
        (at, at + 1) // programmes on the air at that minute
    } else if let Some((a, b)) = part_of_day {
        (midnight + a * 3600, midnight + b * 3600)
    } else {
        (midnight, midnight + 86_400)
    };
    // "ce soir" at 21:00 starts from now, not from 18:00.
    let from = if day == 0 && from < clock.now && to > clock.now { clock.now } else { from };
    Some(Window { from, to, past: to <= clock.now })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn clock() -> Clock {
        // Friday 2026-11-06 14:00 UTC = 15:00 in Paris (UTC+1).
        Clock { now: 1_793_973_600, utc_offset_minutes: 60 }
    }

    fn p(text: &str) -> ParsedQuery {
        parse(text, clock())
    }

    #[test]
    fn kind_and_title() {
        let q = p("un film avec Tom Cruise");
        assert_eq!(q.kinds, vec![Kind::Movie]);
        assert_eq!(q.people, vec!["tom cruise".to_string()]);
        assert!(q.terms.is_empty());
    }

    #[test]
    fn a_director_after_de_is_a_person() {
        let q = p("un film de Christopher Nolan");
        assert_eq!(q.kinds, vec![Kind::Movie]);
        assert!(q.people.contains(&"christopher nolan".to_string()));
        assert!(q.people_explicit);
        assert!(q.terms.is_empty(), "{:?}", q.terms);
    }

    #[test]
    fn a_capitalised_pair_may_be_a_person_but_stays_a_title_word() {
        let q = p("Top Gun");
        assert!(q.people.contains(&"top gun".to_string()));
        assert!(!q.people_explicit, "not enough to rule out channels");
        assert_eq!(q.terms, vec!["top".to_string(), "gun".to_string()]);
        assert!(p("mets france 2").people.is_empty());
    }

    #[test]
    fn match_is_a_kind_not_a_word() {
        let q = p("le match du PSG ce soir");
        assert_eq!(q.terms, vec!["psg".to_string()]);
        assert_eq!(p("le JT de 20h").terms, vec!["journal".to_string()]);
    }

    #[test]
    fn stop_words_end_a_name() {
        let q = p("film avec Tom Cruise en action");
        assert_eq!(q.people, vec!["tom cruise".to_string()]);
        assert_eq!(q.genres.first().map(|g| g.omdb), Some("Action"));
    }

    #[test]
    fn genres_languages_and_kinds() {
        let q = p("une série coréenne romantique");
        assert_eq!(q.kinds, vec![Kind::Series]);
        assert!(q.languages.contains(&"kr".to_string()));
        assert_eq!(q.genres.first().map(|g| g.omdb), Some("Romance"));
        let q = p("les infos en anglais");
        assert!(q.languages.contains(&"uk".to_string()));
        assert_eq!(q.genres.first().map(|g| g.omdb), Some("News"));
    }

    #[test]
    fn accents_and_apostrophes_are_folded() {
        let q = p("film d'épouvante");
        assert_eq!(q.genres.first().map(|g| g.omdb), Some("Horror"));
        assert_eq!(p("science-fiction").genres.first().map(|g| g.omdb), Some("Sci-Fi"));
        assert_eq!(p("dessins animés pour les petits").genres.first().map(|g| g.omdb), Some("Animation"));
    }

    #[test]
    fn similar_to() {
        assert_eq!(p("quelque chose comme Inception").similar_to.as_deref(), Some("inception"));
        assert_eq!(p("films like The Matrix").similar_to.as_deref(), Some("matrix"));
        assert_eq!(p("un film du genre de Interstellar").similar_to.as_deref(), Some("interstellar"));
    }

    #[test]
    fn years_decades_and_recent() {
        let q = p("film d'action 2022");
        assert_eq!((q.year_from, q.year_to), (Some(2022), Some(2022)));
        let q = p("comédies des années 90");
        assert_eq!((q.year_from, q.year_to), (Some(1990), Some(1999)));
        let q = p("films 80s");
        assert_eq!((q.year_from, q.year_to), (Some(1980), Some(1989)));
        let q = p("les films récents");
        assert!(q.latest && q.year_from.is_some());
    }

    #[test]
    fn quality_and_order() {
        assert_eq!(p("film en 4K").quality, Some(Quality::Uhd));
        assert!(p("Avengers dans l'ordre").ordered);
        assert!(p("Avengers in order").ordered);
    }

    #[test]
    fn tonight_starts_at_six_pm_or_now_if_the_evening_has_begun() {
        let c = clock(); // 15:00 local
        let q = p("le match du PSG ce soir");
        let w = q.window.expect("window");
        assert!(!w.past);
        assert_eq!(w.from, c.local_midnight(0) + 18 * 3600);
        assert_eq!(w.to, c.local_midnight(0) + 24 * 3600);
        assert_eq!(q.terms, vec!["psg".to_string()]);
        assert_eq!(q.kinds, vec![Kind::Program]);

        let late = Clock { now: 1_793_991_600, utc_offset_minutes: 60 }; // 20:00 local
        let w = parse("ce soir à la télé", late).window.expect("window");
        assert_eq!(w.from, late.now, "the evening has begun: from now");
    }

    #[test]
    fn yesterday_is_past_tomorrow_is_not() {
        let past = p("le JT de 20h d'hier").window.expect("window");
        assert!(past.past);
        assert_eq!(past.to - past.from, 1);
        let c = clock();
        assert_eq!(past.from, c.local_midnight(-1) + 20 * 3600);
        let next = p("film demain soir").window;
        assert!(next.is_some());
        let tomorrow = p("programme demain").window.expect("window");
        assert_eq!(tomorrow.from, c.local_midnight(1));
        assert!(!tomorrow.past);
    }

    #[test]
    fn hours() {
        let w = p("foot à 20h30").window.expect("window");
        assert_eq!(w.from, clock().local_midnight(0) + 20 * 3600 + 30 * 60);
        assert_eq!(parse_hour("8h"), Some((8, 0)));
        assert_eq!(parse_hour("25h"), None);
        assert_eq!(parse_hour("hello"), None);
    }

    #[test]
    fn weekend_starts_on_saturday() {
        let c = clock(); // a Friday
        let w = p("films ce week-end").window.expect("window");
        assert_eq!(c.local_weekday(0), 4);
        assert_eq!(w.to - c.local_midnight(1), 2 * 86_400);
    }

    #[test]
    fn plain_title_keeps_its_words() {
        let q = p("Game of Thrones");
        assert_eq!(q.terms, vec!["game".to_string(), "thrones".to_string()]);
        assert!(q.kinds.is_empty() && q.window.is_none());
        assert_eq!(p("mets France 2").terms, vec!["france".to_string(), "2".to_string()]);
    }

    #[test]
    fn nothing_but_filters_has_no_title() {
        assert!(p("films d'action en 4K").has_no_title());
        assert!(!p("Inception").has_no_title());
        assert!(!p("comme Inception").has_no_title());
    }

    #[test]
    fn empty_and_noise() {
        let q = p("   ");
        assert!(q.terms.is_empty() && q.kinds.is_empty());
        assert!(p("s'il te plaît").terms.is_empty());
    }
}
