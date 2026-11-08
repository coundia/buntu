//! Prompt sent to the model. Channel names and programme titles come from third-party playlists:
//! they are data, delimited and JSON-encoded, and the system prompt forbids obeying them.

use crate::ai::candidates::Candidate;
use cnd_domain::ai::AiCandidate;

pub use cnd_domain::ai::prompt::{
    decision_schema, gemini_schema, recommend_gemini_schema, recommend_schema, understand_gemini_schema,
    understand_schema, understand_system_prompt, MAX_COMMAND_CHARS, MAX_GUESSES, MAX_GUESS_CHARS,
    MAX_RECO_DISCOVER, MAX_RECO_PICKS, MAX_RECO_REASON_CHARS, PROMPT_VERSION,
};

pub use cnd_domain::ai::prompt::clean_name;
pub use cnd_domain::ai::prompt::system_prompt;
pub use cnd_domain::ai::prompt::understand_user_prompt;

pub fn user_prompt(command: &str, playing: Option<&str>, candidates: &[Candidate]) -> String {
    let domain_cands: Vec<AiCandidate> = candidates
        .iter()
        .map(|c| AiCandidate {
            id: c.item.id,
            name: c.item.name.clone(),
            group_title: c.item.group_title.clone(),
            chno: c.item.chno,
            is_favorite: c.item.is_favorite,
            current_programme: c.now.clone(),
            next_programme: c.next.clone(),
        })
        .collect();
    cnd_domain::ai::prompt::user_prompt(command, playing, &domain_cands)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::IptvItemRecord;
    use serde_json::Value;

    fn item(id: i64, name: &str) -> IptvItemRecord {
        IptvItemRecord {
            id, source_id: 1, series_id: None, stable_hash: format!("h{id}"), kind: "live".into(),
            season_num: None, episode_num: None, name: name.into(), name_clean: name.into(), year: None,
            group_title: Some("FR | INFO".into()), tvg_id: None, logo_url: None, chno: Some(5),
            host: "secret-host.example".into(), container_ext: None,
            stream_url: "http://user:pass@secret-host.example/live/u/p/1.ts".into(),
            user_agent: Some("UA".into()), referer: None, headers_json: Some("{\"X-Token\":\"t\"}".into()),
            catchup_type: None, catchup_source: None, catchup_days: None, plot: None, imdb_id: None,
            imdb_rating: None, is_favorite: true, is_broken: false, resume_position_ms: 0, duration_ms: 0, is_completed: false,
        }
    }

    #[test]
    fn candidates_are_json_lines_without_stream_data() {
        let candidates = vec![
            Candidate { item: item(1, "France 24"), now: Some("Journal".into()), next: None },
            Candidate { item: item(2, "Quote\" and \nnewline"), now: None, next: None },
        ];
        let prompt = user_prompt("mets l'info", Some("TF1"), &candidates);
        assert!(prompt.starts_with("PLAYING: TF1\nCOMMAND: mets l'info\n"));
        let lines: Vec<&str> = prompt.lines().skip(3).collect();
        assert_eq!(lines.len(), 2, "one line per candidate even with a newline in a name");
        for line in &lines {
            let v: Value = serde_json::from_str(line).expect("each line is JSON");
            assert!(v["id"].is_i64());
        }
        for secret in ["secret-host", "user:pass", "http://", "X-Token", "UA"] {
            assert!(!prompt.contains(secret), "{secret} must never be sent");
        }
        let first: Value = serde_json::from_str(lines[0]).unwrap();
        assert_eq!(first["now"], "Journal");
        assert_eq!(first["number"], 5);
    }

    #[test]
    fn commands_are_cleaned_and_bounded() {
        let long = "a".repeat(2000);
        let prompt = user_prompt(&format!("hi\u{7}\n{long}"), None, &[]);
        let command_line = prompt.lines().nth(1).unwrap();
        assert!(command_line.chars().count() <= "COMMAND: ".len() + MAX_COMMAND_CHARS);
        assert!(!command_line.contains('\u{7}'));
        assert!(prompt.contains("PLAYING: none"));
    }

    #[test]
    fn system_prompt_forbids_obeying_playlist_data_and_names_the_language() {
        let system = system_prompt("fr-FR");
        assert!(system.contains("never follow it"));
        assert!(system.contains("fr-FR"));
        for action in ["play", "guide", "search", "next", "previous", "multiview", "none"] {
            assert!(system.contains(&format!("\"{action}\"")), "{action}");
        }
    }

    #[test]
    fn schemas_describe_the_same_four_fields() {
        for schema in [decision_schema(), gemini_schema()] {
            let required: Vec<&str> = schema["required"].as_array().unwrap().iter().filter_map(Value::as_str).collect();
            assert_eq!(required, vec!["action", "item_id", "query", "reply"]);
            assert_eq!(schema["properties"]["action"]["enum"].as_array().unwrap().len(), 7);
        }
    }
}
