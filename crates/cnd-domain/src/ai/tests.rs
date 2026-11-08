use super::*;
use serde_json::Value;

#[test]
fn test_system_prompt() {
    let prompt = system_prompt("fr-FR");
    assert!(prompt.contains("fr-FR"));
    assert!(prompt.contains("play"));
    assert!(prompt.contains("guide"));
    assert!(prompt.contains("search"));
}

#[test]
fn test_clean_command_and_name() {
    assert_eq!(clean_name("France 2\u{0000}\n"), "France 2");
    assert_eq!(clean_command("  mets la 1\u{0007}  "), "mets la 1");
}

#[test]
fn test_build_request_and_vectors() {
    let vectors_str = include_str!("vectors.json");
    let v: Value = serde_json::from_str(vectors_str).expect("vectors.json is valid");

    // Gemini
    let gemini_vec = &v["build_request"]["gemini"];
    let config: AiProviderConfig = serde_json::from_value(gemini_vec["config"].clone()).unwrap();
    let req = build_request(&config, "SYS_PROMPT", "USER_PROMPT", RequestMode::Strict).unwrap();
    assert_eq!(req.url, gemini_vec["expected_url"].as_str().unwrap());
    assert_eq!(req.headers[0].0, gemini_vec["expected_header_key"].as_str().unwrap());
    assert_eq!(req.headers[0].1, gemini_vec["expected_header_val"].as_str().unwrap());

    // OpenAI
    let openai_vec = &v["build_request"]["openai"];
    let config: AiProviderConfig = serde_json::from_value(openai_vec["config"].clone()).unwrap();
    let req = build_request(&config, "SYS_PROMPT", "USER_PROMPT", RequestMode::Strict).unwrap();
    assert_eq!(req.url, openai_vec["expected_url"].as_str().unwrap());
    assert_eq!(req.headers[0].0, openai_vec["expected_header_key"].as_str().unwrap());
    assert_eq!(req.headers[0].1, openai_vec["expected_header_val"].as_str().unwrap());

    // Anthropic
    let ant_vec = &v["build_request"]["anthropic"];
    let config: AiProviderConfig = serde_json::from_value(ant_vec["config"].clone()).unwrap();
    let req = build_request(&config, "SYS_PROMPT", "USER_PROMPT", RequestMode::Strict).unwrap();
    assert_eq!(req.url, ant_vec["expected_url"].as_str().unwrap());
    assert_eq!(req.headers[0].0, ant_vec["expected_header_key"].as_str().unwrap());
    assert_eq!(req.headers[0].1, ant_vec["expected_header_val"].as_str().unwrap());
}

#[test]
fn test_explain_error_vectors() {
    let vectors_str = include_str!("vectors.json");
    let v: Value = serde_json::from_str(vectors_str).unwrap();

    for item in v["explain_error"].as_array().unwrap() {
        let status = item["status"].as_u64().unwrap() as u16;
        let body = item["body"].as_str().unwrap();
        let expected = item["expected_contains"].as_str().unwrap();
        let explanation = explain_http_error(status, body, None);
        assert!(explanation.contains(expected), "status {status}: {explanation}");
    }
}

#[test]
fn test_extract_text_vectors() {
    let vectors_str = include_str!("vectors.json");
    let v: Value = serde_json::from_str(vectors_str).unwrap();

    let gemini_body = &v["extract_text"]["gemini"]["body"];
    let text = extract_text(AiProviderKind::Gemini, gemini_body).unwrap();
    assert_eq!(text, v["extract_text"]["gemini"]["expected"].as_str().unwrap());

    let openai_body = &v["extract_text"]["openai"]["body"];
    let text = extract_text(AiProviderKind::OpenAiCompatible, openai_body).unwrap();
    assert_eq!(text, v["extract_text"]["openai"]["expected"].as_str().unwrap());

    let ant_body = &v["extract_text"]["anthropic"]["body"];
    let text = extract_text(AiProviderKind::Anthropic, ant_body).unwrap();
    let dec = parse_decision(&text).unwrap();
    assert_eq!(dec.action, v["extract_text"]["anthropic"]["expected_action"].as_str().unwrap());
    assert_eq!(dec.item_id, Some(v["extract_text"]["anthropic"]["expected_item_id"].as_i64().unwrap()));
}

#[test]
fn test_validate_command_vectors() {
    let vectors_str = include_str!("vectors.json");
    let v: Value = serde_json::from_str(vectors_str).unwrap();

    let play_vec = &v["validate_command"]["valid_play"];
    let cands: Vec<AiCandidate> = serde_json::from_value(play_vec["candidates"].clone()).unwrap();
    let res = validate_command_text(play_vec["json"].as_str().unwrap(), &cands).unwrap();
    assert_eq!(res.0, AiAction::PlayChannel { item_id: 42 });

    let unknown_vec = &v["validate_command"]["unknown_channel"];
    let cands: Vec<AiCandidate> = serde_json::from_value(unknown_vec["candidates"].clone()).unwrap();
    let err = validate_command_text(unknown_vec["json"].as_str().unwrap(), &cands).unwrap_err();
    assert_eq!(err, unknown_vec["expected_error"].as_str().unwrap());

    let search_vec = &v["validate_command"]["valid_search"];
    let cands: Vec<AiCandidate> = serde_json::from_value(search_vec["candidates"].clone()).unwrap();
    let res = validate_command_text(search_vec["json"].as_str().unwrap(), &cands).unwrap();
    assert_eq!(res.0, AiAction::Search { query: "documentaire nature".to_string() });
}

#[test]
fn test_resolve_local_vectors() {
    let vectors_str = include_str!("vectors.json");
    let v: Value = serde_json::from_str(vectors_str).unwrap();

    let ctx = AiCommandContext {
        playing_stable_hash: None,
        group_title: None,
        locale: "fr-FR".to_string(),
    };

    for item in v["resolve_local"].as_array().unwrap() {
        let command = item["command"].as_str().unwrap();
        let candidates: Vec<AiCandidate> = serde_json::from_value(item["candidates"].clone()).unwrap();
        let outcome = resolve_local(command, &candidates, &ctx);

        let expected_action = item["expected_action"].as_str().unwrap();
        match expected_action {
            "play_channel" => {
                let id = item["expected_item_id"].as_i64().unwrap();
                assert_eq!(outcome.action, Some(AiAction::PlayChannel { item_id: id }), "cmd {command}");
            }
            "next_channel" => {
                assert_eq!(outcome.action, Some(AiAction::NextChannel), "cmd {command}");
            }
            "previous_channel" => {
                assert_eq!(outcome.action, Some(AiAction::PreviousChannel), "cmd {command}");
            }
            other => panic!("unknown expected action: {other}"),
        }
    }
}
