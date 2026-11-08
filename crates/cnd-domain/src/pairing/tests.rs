use super::*;

const NOW: i64 = 1_800_000_000;
const SHARE: &str = r#"{"format":"cnd-source-share","version":1,"sources":[{"name":"Premium","type":"xtream","server":"http://srv.example:8080","username":"alice","password":"s3cret"}]}"#;

fn bytes(from: u8, len: usize) -> Vec<u8> {
    (0..len).map(|i| from.wrapping_add(i as u8)).collect()
}

fn offer() -> Offer {
    create_offer(&bytes(0, 40), "Salon TV", "msf", "192.168.1.9", 8001, NOW).unwrap()
}

fn seal_for(offer: &Offer) -> Sealed {
    seal(&offer.link, &bytes(100, 44), SHARE, "iPhone de Papa", NOW + 5).unwrap()
}

#[test]
fn a_phone_and_a_tv_agree_and_the_document_comes_out_intact() {
    let offer = offer();
    let sealed = seal_for(&offer);
    let opened = open(&offer.state, &sealed.message, NOW + 6).expect("opens");
    assert_eq!(opened.share_json, SHARE);
    assert_eq!(opened.from, "iPhone de Papa");
    assert_eq!(opened.reply_key, sealed.reply_key, "both sides derived the same key");
}

#[test]
fn ai_config_and_text_messages_seal_and_open_intact() {
    let offer = offer();
    let ai_payload = serde_json::to_string(&SealedPayload::AiConfig {
        provider: "gemini".to_string(),
        model: Some("gemini-3.5-flash-lite".to_string()),
        base_url: None,
        api_key: "sk-secret-ai-key-42".to_string(),
    })
    .unwrap();

    let sealed = seal(&offer.link, &bytes(100, 44), &ai_payload, "Pixel de Paul", NOW + 5).unwrap();
    let opened = open(&offer.state, &sealed.message, NOW + 6).expect("opens ai config");
    assert_eq!(opened.from, "Pixel de Paul");

    let parsed: SealedPayload = serde_json::from_str(&opened.share_json).expect("valid sealed payload");
    match parsed {
        SealedPayload::AiConfig { provider, model, base_url, api_key } => {
            assert_eq!(provider, "gemini");
            assert_eq!(model, Some("gemini-3.5-flash-lite".to_string()));
            assert_eq!(base_url, None);
            assert_eq!(api_key, "sk-secret-ai-key-42");
        }
        _ => panic!("expected AiConfig payload"),
    }

    // Text message test
    let offer2 = create_offer(&bytes(50, 40), "Salon TV", "msf", "192.168.1.9", 8001, NOW).unwrap();
    let text_payload = serde_json::to_string(&SealedPayload::Text {
        text: "Mets France 2".to_string(),
    })
    .unwrap();
    let sealed2 = seal(&offer2.link, &bytes(100, 44), &text_payload, "iPhone", NOW + 5).unwrap();
    let opened2 = open(&offer2.state, &sealed2.message, NOW + 6).expect("opens text message");
    let parsed2: SealedPayload = serde_json::from_str(&opened2.share_json).unwrap();
    assert_eq!(parsed2, SealedPayload::Text { text: "Mets France 2".to_string() });

    // HouseholdJoin message test
    let offer3 = create_offer(&bytes(60, 40), "Salon TV", "msf", "192.168.1.9", 8001, NOW).unwrap();
    let hj_payload = serde_json::to_string(&SealedPayload::HouseholdJoin {
        household_id: "hh_abc123".to_string(),
        household_key: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef".to_string(),
        household_name: "Foyer Principal".to_string(),
        sender_device_name: Some("MacBook de Paul".to_string()),
        sender_device_id: Some("dev_mac_1".to_string()),
    })
    .unwrap();
    let sealed3 = seal(&offer3.link, &bytes(100, 44), &hj_payload, "MacBook", NOW + 5).unwrap();
    let opened3 = open(&offer3.state, &sealed3.message, NOW + 6).expect("opens household join message");
    let parsed3: SealedPayload = serde_json::from_str(&opened3.share_json).unwrap();
    match parsed3 {
        SealedPayload::HouseholdJoin { household_id, household_key, household_name, .. } => {
            assert_eq!(household_id, "hh_abc123");
            assert_eq!(household_name, "Foyer Principal");
            assert_eq!(household_key.len(), 64);
        }
        _ => panic!("expected HouseholdJoin payload"),
    }
}

#[test]
fn the_link_holds_everything_the_phone_needs_and_nothing_secret() {
    let offer = offer();
    let link = parse_link(&offer.link, NOW + 1).unwrap();
    assert_eq!((link.tv_name.as_str(), link.transport.as_str(), link.host.as_str(), link.port), ("Salon TV", "msf", "192.168.1.9", 8001));
    assert_eq!(link.expires_at, NOW + SESSION_SECONDS);
    assert!(offer.link.len() < 300, "a QR a phone reads from 3 m: {} chars", offer.link.len());
    let state: SessionState = serde_json::from_str(&offer.state).unwrap();
    assert!(!offer.link.contains(&state.secret_key), "the private key never leaves the TV");
}

#[test]
fn the_android_tv_form_of_the_link_is_read_too() {
    let offer = offer();
    let query = offer.link.split_once('?').unwrap().1;
    let http = format!("http://192.168.1.20:41234/pair#{query}");
    assert_eq!(parse_link(&http, NOW + 1).unwrap().session, offer.session);
}

#[test]
fn a_link_is_refused_when_expired_malformed_or_with_a_bad_key() {
    let offer = offer();
    assert_eq!(parse_link(&offer.link, NOW + SESSION_SECONDS), Err(PairingError::Expired));
    assert_eq!(parse_link("https://example.com", NOW), Err(PairingError::BadLink));
    assert_eq!(parse_link("buntu://pair", NOW), Err(PairingError::BadLink));
    assert_eq!(parse_link(&offer.link.replace("t=msf", "t=ftp"), NOW), Err(PairingError::BadLink));
    assert_eq!(parse_link(&offer.link.replace("v=1", "v=2"), NOW), Err(PairingError::BadLink));
    let short_key = offer.link.replacen("k=", "k=AAAA", 1);
    assert_eq!(parse_link(&short_key, NOW), Err(PairingError::BadLink));
}

#[test]
fn a_message_altered_in_any_part_is_rejected() {
    let offer = offer();
    let sealed = seal_for(&offer);
    let original: Message = serde_json::from_str(&sealed.message).unwrap();
    type Change = Box<dyn Fn(&mut Message)>;
    let tamper: [(&str, Change); 4] = [
        ("ciphertext", Box::new(|m| m.ct.replace_range(0..1, if m.ct.starts_with('A') { "B" } else { "A" }))),
        ("sender name", Box::new(|m| m.from = "Mallory".into())),
        ("nonce", Box::new(|m| m.nonce = b64_encode(&[0u8; 12]))),
        ("key", Box::new(|m| m.epk = b64_encode(&[9u8; 32]))),
    ];
    for (what, change) in tamper {
        let mut m = original.clone();
        change(&mut m);
        let result = open(&offer.state, &serde_json::to_string(&m).unwrap(), NOW + 6);
        assert!(result.is_err(), "{what} was accepted");
    }
}

#[test]
fn a_message_for_another_session_is_rejected() {
    let a = offer();
    let b = create_offer(&bytes(50, 40), "Chambre", "msf", "192.168.1.10", 8001, NOW).unwrap();
    let sealed = seal_for(&a);
    assert!(open(&b.state, &sealed.message, NOW + 6).is_err());
}

#[test]
fn a_session_serves_one_message_only_and_a_replay_finds_it_closed() {
    let offer = offer();
    let sealed = seal_for(&offer);
    let opened = open(&offer.state, &sealed.message, NOW + 6).unwrap();
    let again = open(&opened.state, &sealed.message, NOW + 7).unwrap_err();
    assert!(again.closed);
    assert!(!opened.state.contains("\"secret_key\":\"A"), "state kept: {}", opened.state);
    let state: SessionState = serde_json::from_str(&opened.state).unwrap();
    assert!(state.secret_key.is_empty(), "the private key is wiped after use");
}

#[test]
fn three_bad_messages_close_the_session() {
    let offer = offer();
    let sealed = seal_for(&offer);
    let mut state = offer.state.clone();
    for attempt in 1..=3 {
        let rejected = open(&state, "{not json", NOW + 6).unwrap_err();
        assert_eq!(rejected.closed, attempt == 3, "attempt {attempt}");
        state = rejected.state;
    }
    // Even the good message is refused now.
    assert!(open(&state, &sealed.message, NOW + 7).is_err());
}

#[test]
fn an_expired_session_refuses_everything() {
    let offer = offer();
    let sealed = seal_for(&offer);
    let rejected = open(&offer.state, &sealed.message, NOW + SESSION_SECONDS).unwrap_err();
    assert!(rejected.closed);
    assert!(rejected.error.contains("expir"));
}

#[test]
fn the_message_and_the_input_are_bounded() {
    let offer = offer();
    let huge = "x".repeat(MAX_MESSAGE_CHARS);
    assert_eq!(seal(&offer.link, &bytes(100, 44), &huge, "p", NOW + 1), Err(PairingError::TooLarge));
    assert!(open(&offer.state, &"y".repeat(MAX_MESSAGE_CHARS + 5000), NOW + 1).is_err());
    assert_eq!(create_offer(&bytes(0, 10), "t", "msf", "h", 1, NOW), Err(PairingError::NotEnoughEntropy));
    assert_eq!(seal(&offer.link, &bytes(0, 10), SHARE, "p", NOW + 1), Err(PairingError::NotEnoughEntropy));
}

#[test]
fn the_tv_answers_and_only_the_right_phone_reads_it() {
    let offer = offer();
    let sealed = seal_for(&offer);
    let opened = open(&offer.state, &sealed.message, NOW + 6).unwrap();
    let reply = seal_reply(&opened.reply_key, &offer.session, &bytes(200, 12), "added", 2).unwrap();
    let body = open_reply(&sealed.reply_key, &offer.session, &reply).unwrap();
    assert_eq!(body, ReplyBody { result: "added".into(), count: 2 });
    assert!(open_reply(&b64_encode(&[1u8; 32]), &offer.session, &reply).is_err(), "wrong key");
    assert!(open_reply(&sealed.reply_key, "OTHER", &reply).is_err(), "wrong session");
}

#[test]
fn the_phones_name_is_cleaned_and_bounded() {
    let offer = offer();
    let sealed = seal(&offer.link, &bytes(100, 44), SHARE, &format!("Bad\u{7}\nName{}", "z".repeat(100)), NOW + 1).unwrap();
    let opened = open(&offer.state, &sealed.message, NOW + 2).unwrap();
    assert!(opened.from.chars().count() <= 40 && !opened.from.chars().any(char::is_control));
}

#[test]
fn base64url_round_trips_every_length() {
    for len in 0..70 {
        let data = bytes(7, len);
        assert_eq!(b64_decode(&b64_encode(&data)).unwrap(), data, "{len}");
    }
    assert!(b64_decode("not base64!").is_none());
    assert!(b64_decode("A").is_none());
}

/// Every platform (Swift, Kotlin, TypeScript) must produce these exact bytes from these inputs.
#[test]
fn the_shared_vectors_are_stable() {
    let offer = offer();
    let sealed = seal_for(&offer);
    let opened = open(&offer.state, &sealed.message, NOW + 6).unwrap();
    let reply = seal_reply(&opened.reply_key, &offer.session, &bytes(200, 12), "added", 2).unwrap();
    let produced = serde_json::json!({
        "now": NOW,
        "offer": { "entropy": bytes(0, 40), "tv_name": "Salon TV", "transport": "msf", "host": "192.168.1.9", "port": 8001,
                   "link": offer.link, "session": offer.session, "state": offer.state },
        "seal": { "entropy": bytes(100, 44), "share_json": SHARE, "phone_name": "iPhone de Papa", "message": sealed.message, "reply_key": sealed.reply_key },
        "reply": { "entropy": bytes(200, 12), "result": "added", "count": 2, "reply": reply },
    });
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/src/pairing/vectors.json");
    if std::env::var_os("WRITE_PAIRING_VECTORS").is_some() {
        std::fs::write(path, serde_json::to_string_pretty(&produced).unwrap() + "\n").unwrap();
    }
    let stored: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(path).expect("vectors.json")).unwrap();
    assert_eq!(stored, produced, "the vectors changed: every platform would stop understanding the others");
}
