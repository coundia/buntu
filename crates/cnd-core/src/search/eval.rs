//! Evaluation of the local search (PRD 33 § 6): a fixed catalog and a table of prompts with the
//! titles that must come back in the first three results, plus the rules that must never bend.

use crate::db::DatabaseManager;
use crate::search::engine::{search_local, Lang};
use crate::search::query_parser::Clock;
use crate::search::{SearchHit, SearchKind};
use rusqlite::params;

/// Friday 2026-11-06, 20:00 in Paris (UTC+1).
pub const NOW: i64 = 1_793_991_600;
pub const CLOCK: Clock = Clock { now: NOW, utc_offset_minutes: 60 };

const HOUR: i64 = 3600;

/// (name, year, group, imdb id, rating, genres, director, actors)
type MovieSeed = (&'static str, u32, &'static str, &'static str, f64, &'static str, &'static str, &'static str);

const MOVIES: &[MovieSeed] = &[
    ("Top Gun: Maverick", 2022, "FR | ACTION", "tt1745960", 8.2, "Action, Drama", "Joseph Kosinski", "Tom Cruise, Miles Teller, Jennifer Connelly"),
    ("Mission: Impossible - Fallout", 2018, "FR | ACTION", "tt4912910", 7.7, "Action, Adventure, Thriller", "Christopher McQuarrie", "Tom Cruise, Henry Cavill, Ving Rhames"),
    ("Edge of Tomorrow", 2014, "FR | SCIENCE FICTION", "tt1631867", 7.9, "Action, Sci-Fi", "Doug Liman", "Tom Cruise, Emily Blunt, Bill Paxton"),
    ("Inception", 2010, "FR | SCIENCE FICTION", "tt1375666", 8.8, "Action, Adventure, Sci-Fi", "Christopher Nolan", "Leonardo DiCaprio, Joseph Gordon-Levitt, Elliot Page"),
    ("Interstellar", 2014, "FR | SCIENCE FICTION", "tt0816692", 8.7, "Adventure, Drama, Sci-Fi", "Christopher Nolan", "Matthew McConaughey, Anne Hathaway"),
    ("The Dark Knight", 2008, "FR | ACTION", "tt0468569", 9.0, "Action, Crime, Drama", "Christopher Nolan", "Christian Bale, Heath Ledger"),
    ("Avengers: Endgame", 2019, "FR | ACTION", "tt4154796", 8.4, "Action, Adventure, Sci-Fi", "Anthony Russo", "Robert Downey Jr., Chris Evans"),
    ("The Avengers", 2012, "FR | ACTION", "tt0848228", 8.0, "Action, Sci-Fi", "Joss Whedon", "Robert Downey Jr., Chris Evans"),
    ("Iron Man", 2008, "FR | ACTION", "tt0371746", 7.9, "Action, Adventure, Sci-Fi", "Jon Favreau", "Robert Downey Jr., Gwyneth Paltrow"),
    ("Le Roi Lion", 1994, "FR | ANIMATION", "tt0110357", 8.5, "Animation, Adventure, Drama", "Roger Allers", "Matthew Broderick, Jeremy Irons"),
    ("Toy Story", 1995, "FR | ANIMATION", "tt0114709", 8.3, "Animation, Adventure, Comedy", "John Lasseter", "Tom Hanks, Tim Allen"),
    ("Intouchables", 2011, "FR | COMEDIE", "tt1675434", 8.5, "Comedy, Drama", "Olivier Nakache", "Omar Sy, François Cluzet"),
    ("Les Visiteurs", 1993, "FR | COMEDIE", "tt0108211", 7.0, "Comedy, Fantasy", "Jean-Marie Poiré", "Christian Clavier, Jean Reno"),
    ("Le Parrain", 1972, "FR | DRAME", "tt0068646", 9.2, "Crime, Drama", "Francis Ford Coppola", "Marlon Brando, Al Pacino"),
    ("Titanic", 1997, "FR | DRAME", "tt0120338", 7.9, "Drama, Romance", "James Cameron", "Leonardo DiCaprio, Kate Winslet"),
    ("Hereditary", 2018, "US | HORROR", "tt7784604", 7.3, "Drama, Horror, Mystery", "Ari Aster", "Toni Collette, Alex Wolff"),
    ("The Conjuring", 2013, "FR | HORREUR", "tt1457767", 7.5, "Horror, Mystery, Thriller", "James Wan", "Vera Farmiga, Patrick Wilson"),
    ("Parasite", 2019, "KR | DRAMA", "tt6751668", 8.5, "Comedy, Drama, Thriller", "Bong Joon Ho", "Song Kang-ho, Lee Sun-kyun"),
    ("Train to Busan", 2016, "KR | HORROR", "tt5700672", 7.6, "Action, Horror, Thriller", "Yeon Sang-ho", "Gong Yoo, Ma Dong-seok"),
];

const SERIES: &[(&str, &str)] = &[
    ("Game of Thrones", "FR | SERIES DRAME"),
    ("Breaking Bad", "FR | SERIES POLICIER"),
    ("Squid Game", "KR | SERIES THRILLER"),
    ("Crash Landing on You", "KR | SERIES ROMANCE"),
    ("Dark", "DE | SERIES SCIENCE FICTION"),
    ("Peaky Blinders", "UK | SERIES POLICIER"),
];

/// (name, group, number, tvg id)
const CHANNELS: &[(&str, &str, u32, &str)] = &[
    ("FR: TF1 HD", "FR | GENERALISTES", 1, "tf1.fr"),
    ("FR: France 2 FHD", "FR | GENERALISTES", 2, "france2.fr"),
    ("FR: M6 HD", "FR | GENERALISTES", 6, "m6.fr"),
    ("FR: France 24", "FR | INFO", 24, "france24.fr"),
    ("FR: Canal+ Sport", "FR | SPORT", 31, "canalsport.fr"),
    ("FR: beIN Sports 1", "FR | SPORT", 32, "bein1.fr"),
    ("UK: BBC News", "UK | NEWS", 101, "bbcnews.uk"),
    ("US: CNN International", "US | NEWS", 102, "cnn.us"),
    ("FR: Disney Channel", "FR | JEUNESSE", 70, "disney.fr"),
];

pub fn catalog() -> DatabaseManager {
    let db = DatabaseManager::open_in_memory().expect("db");
    seed(&db);
    db
}

/// Fills `db` with the evaluation catalog.
pub fn seed(db: &DatabaseManager) {
    let source = db.add_source("Eval", "m3u", Some("http://x/l.m3u"), None, None, None).expect("source");
    db.with_conn(|conn| {
        for (i, (name, group, chno, tvg)) in CHANNELS.iter().enumerate() {
            // TF1 keeps a week of replay.
            let catchup: Option<i64> = (*tvg == "tf1.fr").then_some(7);
            conn.execute(
                "INSERT INTO iptv_items (source_id, stable_hash, kind, name, name_clean, group_title, tvg_id, chno, catchup_days, host, stream_url, created_at, updated_at)
                 VALUES (?1, ?2, 'live', ?3, ?3, ?4, ?5, ?6, ?7, 'h', ?8, 1, 1)",
                params![source, format!("live{i}"), name, group, tvg, chno, catchup, format!("http://h/live{i}.ts")],
            )?;
        }
        for (i, (name, year, group, imdb, rating, genres, director, actors)) in MOVIES.iter().enumerate() {
            conn.execute(
                "INSERT INTO iptv_items (source_id, stable_hash, kind, name, name_clean, year, group_title, imdb_id, imdb_rating, host, stream_url, created_at, updated_at)
                 VALUES (?1, ?2, 'movie', ?3, ?3, ?4, ?5, ?6, ?7, 'h', ?8, 1, 1)",
                params![source, format!("movie{i}"), name, year, group, imdb, rating, format!("http://h/movie{i}.mp4")],
            )?;
            conn.execute(
                "INSERT INTO media_metadata_cache (lookup_key, imdb_id, title, year, genres, director, actors, imdb_rating, media_type, fetched_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, 'movie', 1)",
                params![format!("movie:{}", name.to_lowercase()), imdb, name, year.to_string(), genres, director, actors, rating],
            )?;
        }
        // A 4K copy of Inception: the versions of a title appear once.
        conn.execute(
            "INSERT INTO iptv_items (source_id, stable_hash, kind, name, name_clean, year, group_title, host, stream_url, created_at, updated_at)
             VALUES (?1, 'movie_inception_4k', 'movie', 'Inception 4K', 'Inception', 2010, 'FR | UHD', 'h', 'http://h/inc4k.mp4', 1, 1)",
            params![source],
        )?;
        // A film in an adult category, and a broken one: never offered.
        conn.execute(
            "INSERT INTO iptv_items (source_id, stable_hash, kind, name, name_clean, year, group_title, host, stream_url, created_at, updated_at)
             VALUES (?1, 'movie_adult', 'movie', 'Inception Adult Parody', 'Inception Adult Parody', 2015, 'XXX | ADULTES', 'h', 'http://h/a.mp4', 1, 1)",
            params![source],
        )?;
        conn.execute(
            "INSERT INTO iptv_items (source_id, stable_hash, kind, name, name_clean, year, group_title, host, stream_url, created_at, updated_at)
             VALUES (?1, 'movie_broken', 'movie', 'Inception Broken Copy', 'Inception Broken Copy', 2010, 'FR | ACTION', 'h', 'http://h/b.mp4', 1, 1)",
            params![source],
        )?;
        conn.execute("INSERT INTO broken_flags (stable_hash, item_kind, flagged_at) VALUES ('movie_broken', 'movie', 1)", [])?;
        for (i, (title, group)) in SERIES.iter().enumerate() {
            conn.execute(
                "INSERT INTO series_catalog (source_id, canonical_key, stable_hash, title, group_title, season_count, episode_count, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, 3, 30, 1)",
                params![source, format!("series{i}"), format!("series_hash{i}"), title, group],
            )?;
        }
        // Programmes around "now" (20:00 Friday).
        let programmes: &[(&str, &str, i64, i64)] = &[
            ("tf1.fr", "Journal de 20h", NOW, NOW + 2700),
            ("tf1.fr", "Journal de 20h", NOW - 24 * HOUR, NOW - 24 * HOUR + 2700),
            ("france2.fr", "Envoyé spécial", NOW - 600, NOW + 3000),
            ("bein1.fr", "Ligue 1 : PSG - Marseille", NOW + HOUR, NOW + 3 * HOUR),
            ("canalsport.fr", "Top 14 : Toulouse - Racing 92", NOW + 2 * HOUR, NOW + 4 * HOUR),
            ("m6.fr", "Capital", NOW + HOUR, NOW + 2 * HOUR),
            ("france24.fr", "Le journal de l'Afrique", NOW - 300, NOW + 1500),
            ("bbcnews.uk", "BBC World News Today", NOW - 300, NOW + 1500),
            ("disney.fr", "Dessins animés du soir", NOW, NOW + 2 * HOUR),
            ("bein1.fr", "Ligue 1 : PSG - Lyon", NOW + 22 * HOUR, NOW + 24 * HOUR),
        ];
        for (tvg, title, start, end) in programmes {
            conn.execute(
                "INSERT INTO epg_programs (channel_tvg_id, start_ts, end_ts, title) VALUES (?1, ?2, ?3, ?4)",
                params![tvg, start, end, title],
            )?;
        }
        Ok(())
    })
    .expect("seed");
}

pub fn run(db: &DatabaseManager, prompt: &str) -> Vec<SearchHit> {
    search_local(db, prompt, CLOCK, Lang::Fr, 40)
}

pub fn title(hit: &SearchHit) -> String {
    if let Some(p) = &hit.program {
        return format!("{} @ {}", p.title, hit.item.as_ref().map(|i| i.name.as_str()).unwrap_or(""));
    }
    if let Some(item) = &hit.item {
        return item.name.clone();
    }
    hit.series.as_ref().map(|s| s.title.clone()).unwrap_or_default()
}

/// Each prompt with words that must all appear in one of the first three results' titles.
const CASES: &[(&str, &[&str])] = &[
    // Titles, exact and typo.
    ("Inception", &["inception"]),
    ("inception", &["inception"]),
    ("Interstellar", &["interstellar"]),
    ("Avangers", &["avengers"]),
    ("mision impossible", &["mission"]),
    ("intersteler", &["interstellar"]),
    ("le roi lion", &["roi lion"]),
    ("les visiteurs", &["visiteurs"]),
    ("Game of Thrones", &["game of thrones"]),
    ("breaking bad", &["breaking bad"]),
    ("squid game", &["squid game"]),
    ("mets TF1", &["tf1"]),
    ("france 24", &["france 24"]),
    ("BBC News", &["bbc news"]),
    // People.
    ("un film avec Tom Cruise", &["top gun"]),
    ("film avec Tom Cruise", &["mission"]),
    ("films avec Tom Cruise", &["edge of tomorrow"]),
    ("un film de Christopher Nolan", &["interstellar"]),
    ("film avec Leonardo DiCaprio", &["titanic"]),
    ("film avec Omar Sy", &["intouchables"]),
    // Genres and kinds.
    ("un film d'action", &["dark knight"]),
    ("film d'horreur", &["conjuring"]),
    ("film d'épouvante", &["hereditary"]),
    ("une comédie", &["intouchables"]),
    ("film d'animation", &["roi lion"]),
    ("dessins animés pour les petits", &["disney"]),
    ("film de science fiction", &["inception"]),
    ("une série coréenne", &["squid game"]),
    ("série coréenne romantique", &["crash landing"]),
    ("une série policière", &["breaking bad"]),
    ("film coréen", &["parasite"]),
    // Years and decades.
    ("film d'action 2022", &["top gun"]),
    ("film de 2019", &["avengers"]),
    ("comédie des années 90", &["visiteurs"]),
    ("films des années 70", &["parrain"]),
    // Similar.
    ("quelque chose comme Inception", &["interstellar"]),
    ("un film comme Inception", &["inception"]),
    ("films du genre de Interstellar", &["inception"]),
    // Channels by topic and language.
    ("les infos en anglais", &["bbc news"]),
    ("chaîne d'info", &["france 24"]),
    ("chaînes de sport", &["canal+ sport"]),
    ("chaîne jeunesse", &["disney"]),
    // Programmes.
    ("le match du PSG ce soir", &["psg - marseille"]),
    ("match PSG", &["psg - marseille"]),
    ("le journal de 20h", &["journal de 20h"]),
    ("Envoyé spécial", &["envoye special"]),
    ("le JT de 20h d'hier", &["journal de 20h"]),
    ("PSG demain", &["psg - lyon"]),
];

fn fold(text: &str) -> String {
    crate::ai::local_matcher::words(text).join(" ")
}

pub fn passes(db: &DatabaseManager, prompt: &str, expected: &[&str]) -> bool {
    let hits = run(db, prompt);
    hits.iter().take(3).any(|hit| {
        let t = fold(&title(hit));
        expected.iter().all(|e| t.contains(&fold(e)))
    })
}

#[test]
fn local_search_finds_the_expected_titles_in_the_top_three() {
    let db = catalog();
    let mut failed: Vec<String> = Vec::new();
    for (prompt, expected) in CASES {
        if !passes(&db, prompt, expected) {
            let got: Vec<String> = run(&db, prompt).iter().take(4).map(title).collect();
            failed.push(format!("  « {prompt} » (attendu {expected:?}) -> {got:?}"));
        }
    }
    let total = CASES.len();
    let ok = total - failed.len();
    let rate = ok as f64 / total as f64;
    println!("local search: {ok}/{total} in the top 3 ({:.0} %)", rate * 100.0);
    for line in &failed {
        println!("{line}");
    }
    assert!(rate >= 0.70, "local search under the 70 % bar: {ok}/{total}\n{}", failed.join("\n"));
}

#[test]
fn nothing_hidden_adult_or_broken_ever_comes_back() {
    let db = catalog();
    for prompt in ["Inception", "inception adult", "Inception Broken Copy", "film parodie", "film d'action", "xxx", "adultes"] {
        for hit in run(&db, prompt) {
            let t = title(&hit);
            assert!(!t.contains("Adult Parody"), "{prompt}: {t}");
            assert!(!t.contains("Broken Copy"), "{prompt}: {t}");
        }
    }
}

#[test]
fn the_versions_of_a_title_appear_once() {
    let db = catalog();
    let hits = run(&db, "Inception");
    let inceptions = hits.iter().filter(|h| title(h).to_lowercase().starts_with("inception")).count();
    assert_eq!(inceptions, 1, "{:?}", hits.iter().map(title).collect::<Vec<_>>());
}

#[test]
fn a_prompt_with_nothing_to_search_returns_nothing() {
    let db = catalog();
    assert!(run(&db, "   ").is_empty());
    assert!(run(&db, "s'il te plaît").is_empty());
}

#[test]
fn a_hit_says_why_it_is_there() {
    let db = catalog();
    let top_gun = run(&db, "un film avec Tom Cruise");
    assert!(!top_gun.is_empty());
    assert!(top_gun.iter().take(3).all(|h| !h.reason.is_empty()), "{:?}", top_gun.iter().map(|h| &h.reason).collect::<Vec<_>>());
    assert!(top_gun[0].reason.contains("Tom Cruise"), "{}", top_gun[0].reason);
    let programme = run(&db, "le match du PSG ce soir");
    assert_eq!(programme[0].kind, SearchKind::Program);
    assert!(programme[0].reason.contains("beIN"), "{}", programme[0].reason);
    assert!(programme[0].reason.contains("Aujourd'hui 21:00"), "{}", programme[0].reason);
}

#[test]
fn a_replay_needs_a_channel_with_an_archive() {
    let db = catalog();
    let yesterday = run(&db, "le JT de 20h d'hier");
    assert!(yesterday.iter().any(|h| h.reason.starts_with("Replay")), "{:?}", yesterday.iter().map(title).collect::<Vec<_>>());
    // Nothing aired yesterday on a channel without an archive.
    let nothing = run(&db, "capital hier");
    assert!(nothing.iter().all(|h| h.kind != SearchKind::Program));
}

#[test]
fn kids_profile_sees_nothing_outside_its_allow_list() {
    let db = catalog();
    db.with_conn(|conn| {
        conn.execute("UPDATE temp.catalog_flags SET kids_only = 1", [])?;
        Ok(())
    })
    .expect("kids");
    for prompt in ["Inception", "mets TF1", "film d'action", "le match du PSG ce soir"] {
        assert!(run(&db, prompt).is_empty(), "{prompt}");
    }
}

#[test]
fn local_search_is_fast_enough_for_each_keystroke() {
    let db = catalog();
    let started = std::time::Instant::now();
    for _ in 0..20 {
        run(&db, "un film avec Tom Cruise ce soir");
    }
    let each = started.elapsed() / 20;
    assert!(each.as_millis() < 150, "{each:?}");
}

// ---------------------------------------------------------------- scope: nothing mixes

fn scoped_context(kinds: Vec<SearchKind>) -> crate::search::SearchContext {
    crate::search::SearchContext { playing_stable_hash: None, group_title: None, locale: "fr-FR".into(), utc_offset_minutes: 60, kinds }
}

fn run_scoped(db: &DatabaseManager, prompt: &str, kinds: Vec<SearchKind>) -> Vec<SearchHit> {
    crate::search::engine::search_for_palette(db, prompt, &scoped_context(kinds), CLOCK, Lang::Fr, 40)
}

fn kinds_of(hits: &[SearchHit]) -> std::collections::HashSet<String> {
    hits.iter().map(|h| format!("{:?}", h.kind)).collect()
}

#[test]
fn searching_films_never_returns_channels_programmes_or_series() {
    let db = catalog();
    for prompt in ["Inception", "tf1", "psg", "game of thrones", "action", "journal", "une série coréenne", "mets TF1", "chaîne 3"] {
        let hits = run_scoped(&db, prompt, vec![SearchKind::Movie]);
        assert!(hits.iter().all(|h| h.kind == SearchKind::Movie), "{prompt}: {:?}", kinds_of(&hits));
    }
    assert!(run_scoped(&db, "Inception", vec![SearchKind::Movie]).iter().any(|h| title(h).starts_with("Inception")));
    assert!(run_scoped(&db, "tf1", vec![SearchKind::Movie]).is_empty(), "TF1 is a channel, not a film");
}

#[test]
fn searching_series_returns_only_series() {
    let db = catalog();
    for prompt in ["Game of Thrones", "inception", "tf1", "une série coréenne", "film d'action"] {
        let hits = run_scoped(&db, prompt, vec![SearchKind::Series]);
        assert!(hits.iter().all(|h| h.kind == SearchKind::Series), "{prompt}: {:?}", kinds_of(&hits));
    }
    assert!(run_scoped(&db, "squid game", vec![SearchKind::Series]).iter().any(|h| title(h) == "Squid Game"));
}

#[test]
fn searching_tv_returns_channels_and_programmes_but_no_films_or_series() {
    let db = catalog();
    let tv = vec![SearchKind::Live, SearchKind::Program];
    for prompt in ["Inception", "Game of Thrones", "film d'action", "un film avec Tom Cruise", "série coréenne"] {
        let hits = run_scoped(&db, prompt, tv.clone());
        assert!(hits.iter().all(|h| matches!(h.kind, SearchKind::Live | SearchKind::Program)), "{prompt}: {:?}", kinds_of(&hits));
    }
    let hits = run_scoped(&db, "le match du PSG ce soir", tv.clone());
    assert!(hits.iter().any(|h| h.kind == SearchKind::Program));
    assert!(run_scoped(&db, "tf1", tv).iter().any(|h| title(h).contains("TF1")));
}

#[test]
fn the_scope_wins_over_the_kind_the_sentence_names() {
    let db = catalog();
    // "une série" typed while browsing films is still a film search.
    let hits = run_scoped(&db, "une série policière", vec![SearchKind::Movie]);
    assert!(hits.iter().all(|h| h.kind == SearchKind::Movie), "{:?}", kinds_of(&hits));
}

#[test]
fn without_a_scope_everything_may_come_back() {
    let db = catalog();
    let all = kinds_of(&run_scoped(&db, "dark", Vec::new())); // a film (The Dark Knight) and a series (Dark)
    assert!(all.len() >= 2, "{all:?}");
}
