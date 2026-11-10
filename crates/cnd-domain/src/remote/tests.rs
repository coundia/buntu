use super::handoff::*;
use super::messages::*;
use super::resolve::*;
use crate::sync::envelope::SyncMessage;

#[test]
fn test_remote_vectors_messages() {
    let raw = include_str!("vectors.json");
    let root: serde_json::Value = serde_json::from_str(raw).expect("valid vectors.json");

    let messages = root["messages"].as_object().expect("messages object");
    for (name, item) in messages {
        let json_str = item["json"].as_str().expect("json string");
        let msg: SyncMessage = serde_json::from_str(json_str)
            .unwrap_or_else(|e| panic!("Failed to parse message {name}: {e}"));

        // Roundtrip serialization
        let reserialized = serde_json::to_string(&msg).expect("serialization failed");
        let reparsed: SyncMessage = serde_json::from_str(&reserialized).expect("reparsed failed");
        assert_eq!(msg, reparsed, "Roundtrip equality failed for {name}");
    }
}

#[test]
fn test_origin_handoff_happy_path_and_timeout() {
    let mut session = OriginHandoffSession::new();
    let req_msg = session.start(
        "dev_target",
        "req_100",
        "content_key_1",
        Some("source_key_1"),
        "movie",
        Some("5002"),
        Some("Inception"),
        15_000,
        Some("u_main"),
        false,
        1000,
    );

    match req_msg {
        SyncMessage::PlayRequest { request_id, position_ms, target_device_id, .. } => {
            assert_eq!(request_id, "req_100");
            assert_eq!(target_device_id, "dev_target");
            assert_eq!(position_ms, 15_000);
        }
        _ => panic!("Expected PlayRequest"),
    }

    // Checking timeout before 5000 ms -> should be false
    assert!(!session.check_timeout(4000));

    // Receiving PlayReady at 4500 ms -> produces PlayGo with final position
    let go_msg = session.on_play_ready("req_100", 16_500, 4500).expect("PlayGo creation");
    match go_msg {
        SyncMessage::PlayGo { request_id, position_ms } => {
            assert_eq!(request_id, "req_100");
            assert_eq!(position_ms, 16_500);
        }
        _ => panic!("Expected PlayGo"),
    }

    // Now test timeout on fresh session
    let mut timeout_session = OriginHandoffSession::new();
    timeout_session.start(
        "dev_target",
        "req_timeout",
        "content_key_1",
        Some("source_key_1"),
        "movie",
        None,
        None,
        10_000,
        None,
        false,
        1000,
    );
    assert!(timeout_session.check_timeout(6001));
    if let OriginState::Failed { can_resume_at_ms, .. } = timeout_session.state {
        assert_eq!(can_resume_at_ms, Some(10_000));
    } else {
        panic!("Expected Failed state on timeout");
    }
}

#[test]
fn test_target_handoff_evaluation_and_play_go() {
    let mut target = TargetHandoffSession::new();
    let mut limiter = RateLimiter::new();

    // 1. Success evaluation
    let eval = target.evaluate_request(
        "sender_1",
        "req_200",
        "content_key_1",
        Some("source_key_1"),
        Some("Inception"),
        TargetAccessPolicy::Open,
        true,  // has content
        false, // is playing
        false, // replace
        false, // kids active
        false, // adult
        &mut limiter,
        1000,
    );

    match eval {
        TargetEvaluation::Ready { reply } => match reply {
            SyncMessage::PlayReady { request_id } => assert_eq!(request_id, "req_200"),
            _ => panic!("Expected PlayReady"),
        },
        _ => panic!("Expected TargetEvaluation::Ready"),
    }

    // 2. PlayGo received -> produces ReleaseStream broadcast and playback instruction
    let instruction = target.on_play_go("req_200", 25_000).expect("play go valid");
    assert_eq!(instruction.content_key, "content_key_1");
    assert_eq!(instruction.position_ms, 25_000);
    assert_eq!(
        instruction.broadcast_release,
        Some(SyncMessage::ReleaseStream {
            source_key: "source_key_1".to_string()
        })
    );

    // 3. Second immediate request from same sender -> RateLimited
    let eval_limited = target.evaluate_request(
        "sender_1",
        "req_201",
        "content_key_1",
        Some("source_key_1"),
        Some("Inception"),
        TargetAccessPolicy::Open,
        true,
        false,
        false,
        false,
        false,
        &mut limiter,
        1500, // within 2000 ms
    );
    assert_eq!(
        eval_limited,
        TargetEvaluation::Refused {
            reply: SyncMessage::PlayRefused {
                request_id: "req_201".to_string(),
                reason: PlayRefuseReason::RateLimited,
            },
            reason: PlayRefuseReason::RateLimited,
        }
    );

    // 4. Kids profile blocks adult content
    let eval_kids = target.evaluate_request(
        "sender_2",
        "req_202",
        "content_key_adult",
        Some("source_key_1"),
        Some("Adult Movie"),
        TargetAccessPolicy::Open,
        true,
        false,
        false,
        true, // kids active
        true, // adult content
        &mut limiter,
        3500,
    );
    assert_eq!(
        eval_kids,
        TargetEvaluation::Refused {
            reply: SyncMessage::PlayRefused {
                request_id: "req_202".to_string(),
                reason: PlayRefuseReason::KidsRestricted,
            },
            reason: PlayRefuseReason::KidsRestricted,
        }
    );
}

#[test]
fn test_single_stream_checks_from_vectors() {
    let raw = include_str!("vectors.json");
    let root: serde_json::Value = serde_json::from_str(raw).expect("valid vectors.json");

    for check in root["single_stream_checks"].as_array().expect("array") {
        let curr = check["current_source_key"].as_str();
        let rel = check["release_source_key"].as_str().expect("string");
        let expected = check["must_stop"].as_bool().expect("bool");

        let stop = should_stop_stream_on_release(curr, rel);
        assert_eq!(stop, expected);
    }
}

#[test]
fn test_xtream_url_reconstruction_from_vectors() {
    let raw = include_str!("vectors.json");
    let root: serde_json::Value = serde_json::from_str(raw).expect("valid vectors.json");

    for item in root["xtream_url_reconstruction"].as_array().expect("array") {
        let server = item["server"].as_str().expect("server");
        let username = item["username"].as_str().expect("username");
        let password = item["password"].as_str().expect("password");
        let kind = item["kind"].as_str().expect("kind");
        let pref = item["provider_ref"].as_str().expect("provider_ref");
        let cext = item["container_ext"].as_str();
        let expected = item["expected_url"].as_str().expect("expected_url");

        let url = reconstruct_xtream_url(server, username, password, kind, pref, cext);
        assert_eq!(url, expected);
    }
}

#[test]
fn test_content_key_verification_from_vectors() {
    let raw = include_str!("vectors.json");
    let root: serde_json::Value = serde_json::from_str(raw).expect("valid vectors.json");

    for item in root["content_key_verification"].as_array().expect("array") {
        let source_key = item["source_key"].as_str().expect("source_key");
        let kind = item["kind"].as_str().expect("kind");
        let provider_id = item["provider_id"].as_str().expect("provider_id");
        let expected = item["expected_content_key"].as_str().expect("expected_content_key");

        assert!(verify_content_key_match(source_key, kind, provider_id, expected));
    }
}


#[test]
fn test_running_playback_is_replaced_without_confirmation_in_household() {
    let mut limiter = RateLimiter::new();

    // "Open" target that is already playing:
    // In a household, running playback is replaced without confirmation (PRD-44 § 1.1, § 3.4).
    let mut target = TargetHandoffSession::new();
    let eval = target.evaluate_request(
        "sender_1", "req_300", "ck", Some("sk"), Some("Film"),
        TargetAccessPolicy::Open, true, true, true, false, false, &mut limiter, 1000,
    );
    assert!(matches!(eval, TargetEvaluation::Ready { .. }));
    assert!(matches!(target.state, TargetState::Reserved { .. }));

    // But if target policy is explicitly AlwaysAsk, user prompt is still required:
    let mut target_ask = TargetHandoffSession::new();
    let eval_ask = target_ask.evaluate_request(
        "sender_2", "req_301", "ck", Some("sk"), Some("Film"),
        TargetAccessPolicy::AlwaysAsk, true, true, false, false, false, &mut limiter, 5000,
    );
    assert!(matches!(eval_ask, TargetEvaluation::NeedsUserPrompt { .. }));
}

#[test]
fn test_second_request_cannot_steal_a_pending_reservation() {
    let mut limiter = RateLimiter::new();
    let mut target = TargetHandoffSession::new();

    let first = target.evaluate_request(
        "sender_1", "req_400", "ck1", Some("sk"), None,
        TargetAccessPolicy::Open, true, false, false, false, false, &mut limiter, 1000,
    );
    assert!(matches!(first, TargetEvaluation::Ready { .. }));

    // Another device asks while the first origin is about to stop its playback.
    let second = target.evaluate_request(
        "sender_2", "req_401", "ck2", Some("sk"), None,
        TargetAccessPolicy::Open, true, false, false, false, false, &mut limiter, 3000,
    );
    assert!(matches!(
        second,
        TargetEvaluation::Refused { reason: PlayRefuseReason::Busy, .. }
    ));
    // The first handoff still completes.
    assert!(target.on_play_go("req_400", 0).is_ok());

    // An expired reservation (> 10 s) no longer blocks anybody.
    let mut target = TargetHandoffSession::new();
    let _ = target.evaluate_request(
        "sender_1", "req_410", "ck1", Some("sk"), None,
        TargetAccessPolicy::Open, true, false, false, false, false, &mut limiter, 20_000,
    );
    let later = target.evaluate_request(
        "sender_2", "req_411", "ck2", Some("sk"), None,
        TargetAccessPolicy::Open, true, false, false, false, false, &mut limiter, 40_000,
    );
    assert!(matches!(later, TargetEvaluation::Ready { .. }));
}
