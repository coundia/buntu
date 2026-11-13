use wasm_bindgen::prelude::*;

#[wasm_bindgen]
pub fn wasm_version() -> String {
    "cnd-domain-wasm 0.1.0".to_string()
}

#[wasm_bindgen]
pub fn wasm_get_schema_sql() -> String {
    cnd_domain::schema::SCHEMA_SQL.to_string()
}

#[wasm_bindgen]
pub fn wasm_is_adult_category(group: &str) -> bool {
    cnd_domain::profiles::is_adult_category(group)
}

#[wasm_bindgen]
pub fn wasm_normalize_group_key(group: &str) -> String {
    cnd_domain::profiles::normalize_group_key(group)
}

#[wasm_bindgen]
pub fn wasm_normalize_title(raw: &str, group: Option<String>) -> JsValue {
    let norm = cnd_domain::normalizer::classify_and_normalize(raw, group.as_deref(), "", None);
    serde_wasm_bindgen::to_value(&norm).unwrap_or(JsValue::NULL)
}

#[wasm_bindgen]
pub fn wasm_parse_m3u_chunk(content: &str, source_uuid: &str) -> JsValue {
    let (header, items) = cnd_domain::m3u::parse_m3u_chunk(content, source_uuid);
    #[derive(serde::Serialize)]
    struct M3uChunkResult {
        header: cnd_domain::m3u::M3uHeaderInfo,
        items: Vec<cnd_domain::m3u::ParsedM3uItem>,
    }
    let res = M3uChunkResult { header, items };
    serde_wasm_bindgen::to_value(&res).unwrap_or(JsValue::NULL)
}

#[wasm_bindgen]
pub fn wasm_parse_xmltv_chunk(xml_content: &str, cutoff_ts: f64) -> Result<JsValue, JsValue> {
    match cnd_domain::xmltv::parse_xmltv_chunk(xml_content, cutoff_ts as i64) {
        Ok(progs) => serde_wasm_bindgen::to_value(&progs).map_err(|e| JsValue::from_str(&e.to_string())),
        Err(e) => Err(JsValue::from_str(&e)),
    }
}

#[wasm_bindgen]
pub fn wasm_parse_search_query(raw_query: &str, now_epoch: f64, utc_offset_minutes: i32) -> JsValue {
    let clock = cnd_domain::search::query_parser::Clock {
        now: now_epoch as i64,
        utc_offset_minutes,
    };
    let parsed = cnd_domain::search::query_parser::parse(raw_query, clock);
    serde_wasm_bindgen::to_value(&parsed).unwrap_or(JsValue::NULL)
}

#[wasm_bindgen]
pub fn wasm_rank_search(query_json: &str, candidates_json: &str) -> Result<JsValue, JsValue> {
    let query: cnd_domain::search::query_parser::ParsedQuery =
        serde_json::from_str(query_json).map_err(|e| JsValue::from_str(&e.to_string()))?;
    let candidates: Vec<cnd_domain::search::ranking::SearchCandidate> =
        serde_json::from_str(candidates_json).map_err(|e| JsValue::from_str(&e.to_string()))?;

    let ranked = cnd_domain::search::ranking::rank_candidates(&query, &candidates);
    serde_wasm_bindgen::to_value(&ranked).map_err(|e| JsValue::from_str(&e.to_string()))
}

#[wasm_bindgen]
pub fn wasm_score_recommendations(taste_json: &str, items_json: &str) -> Result<JsValue, JsValue> {
    let taste: cnd_domain::recommend::taste::Taste =
        serde_json::from_str(taste_json).map_err(|e| JsValue::from_str(&e.to_string()))?;
    let items: Vec<cnd_domain::recommend::scoring::CandidateItem> =
        serde_json::from_str(items_json).map_err(|e| JsValue::from_str(&e.to_string()))?;

    let scored = cnd_domain::recommend::scoring::score_candidates(&taste, &items);
    serde_wasm_bindgen::to_value(&scored).map_err(|e| JsValue::from_str(&e.to_string()))
}

#[wasm_bindgen]
pub fn wasm_parse_saga_title(raw_title: &str, known_year: Option<u32>) -> JsValue {
    let res = cnd_domain::recommend::saga::parse_saga_title(raw_title, known_year);
    serde_wasm_bindgen::to_value(&res).unwrap_or(JsValue::NULL)
}

#[wasm_bindgen]
pub fn wasm_system_prompt(locale: &str) -> String {
    cnd_domain::ai::system_prompt(locale)
}

// ---------------------------------------------------------------- pairing (PRD-39)
// Same protocol as Swift and Kotlin (`cnd_domain::pairing`). Results are JSON strings, so the
// worker, the vectors and the tests read exactly what the other platforms produce.

fn pairing_json<T: serde::Serialize>(value: &T) -> Result<String, JsValue> {
    serde_json::to_string(value).map_err(|e| JsValue::from_str(&e.to_string()))
}

#[wasm_bindgen]
pub fn wasm_pairing_create_offer(entropy: &[u8], tv_name: &str, transport: &str, host: &str, port: u16, now: f64) -> Result<String, JsValue> {
    let o = cnd_domain::pairing::create_offer(entropy, tv_name, transport, host, port, now as i64)
        .map_err(|e| JsValue::from_str(&e.to_string()))?;
    pairing_json(&o)
}

#[wasm_bindgen]
pub fn wasm_pairing_parse_link(link: &str, now: f64) -> Result<String, JsValue> {
    let p = cnd_domain::pairing::parse_link(link, now as i64).map_err(|e| JsValue::from_str(&e.to_string()))?;
    pairing_json(&p)
}

#[wasm_bindgen]
pub fn wasm_pairing_seal(link: &str, entropy: &[u8], share_json: &str, phone_name: &str, now: f64) -> Result<String, JsValue> {
    let s = cnd_domain::pairing::seal(link, entropy, share_json, phone_name, now as i64)
        .map_err(|e| JsValue::from_str(&e.to_string()))?;
    pairing_json(&s)
}

/// `{ "opened": {...} }` or `{ "rejected": {...} }` (never throws: a bad message is an answer, not an error).
#[wasm_bindgen]
pub fn wasm_pairing_open(state_json: &str, message_json: &str, now: f64) -> Result<String, JsValue> {
    match cnd_domain::pairing::open(state_json, message_json, now as i64) {
        Ok(o) => pairing_json(&serde_json::json!({ "opened": o })),
        Err(r) => pairing_json(&serde_json::json!({ "rejected": r })),
    }
}

#[wasm_bindgen]
pub fn wasm_pairing_seal_reply(reply_key: &str, session: &str, entropy: &[u8], result: &str, count: u32) -> Result<String, JsValue> {
    cnd_domain::pairing::seal_reply(reply_key, session, entropy, result, count).map_err(|e| JsValue::from_str(&e.to_string()))
}

#[wasm_bindgen]
pub fn wasm_pairing_open_reply(reply_key: &str, session: &str, reply_json: &str) -> Result<String, JsValue> {
    let b = cnd_domain::pairing::open_reply(reply_key, session, reply_json).map_err(|e| JsValue::from_str(&e.to_string()))?;
    pairing_json(&b)
}

// ---------------------------------------------------------------- QR code (PRD-39)

/// The modules of a QR code (error correction M), as `"<size>:<row-major 0/1 string>"`, to draw on a
/// canvas. Done here so the TV needs no JavaScript QR library.
#[wasm_bindgen]
pub fn wasm_qr_matrix(text: &str) -> Result<String, JsValue> {
    use qrcode::{Color, EcLevel, QrCode};
    let code = QrCode::with_error_correction_level(text.as_bytes(), EcLevel::M).map_err(|e| JsValue::from_str(&e.to_string()))?;
    let size = code.width();
    let bits: String = code.to_colors().iter().map(|c| if *c == Color::Dark { '1' } else { '0' }).collect();
    Ok(format!("{size}:{bits}"))
}

// ---------------------------------------------------------------- AI (PRD-40)

#[wasm_bindgen]
pub fn wasm_ai_build_request(
    config_json: &str,
    task_name: &str,
    payload_json: &str,
) -> Result<String, JsValue> {
    let config: cnd_domain::ai::AiProviderConfig = serde_json::from_str(config_json)
        .map_err(|e| JsValue::from_str(&format!("config JSON invalide : {e}")))?;
    let task = cnd_domain::ai::Task::parse_str(task_name)
        .ok_or_else(|| JsValue::from_str(&format!("tâche inconnue : {task_name}")))?;

    let payload: serde_json::Value = serde_json::from_str(payload_json)
        .map_err(|e| JsValue::from_str(&format!("payload JSON invalide : {e}")))?;

    let mode = match payload.get("mode").and_then(serde_json::Value::as_str) {
        Some("light") => cnd_domain::ai::RequestMode::Light,
        _ => cnd_domain::ai::RequestMode::Strict,
    };

    let locale = payload.get("locale").and_then(serde_json::Value::as_str).unwrap_or("fr-FR");

    let req = match task {
        cnd_domain::ai::Task::Command => {
            let command = payload.get("command").and_then(serde_json::Value::as_str).unwrap_or("");
            let playing = payload.get("playing").and_then(serde_json::Value::as_str);
            let candidates: Vec<cnd_domain::ai::AiCandidate> = payload
                .get("candidates")
                .and_then(|v| serde_json::from_value(v.clone()).ok())
                .unwrap_or_default();
            let system = cnd_domain::ai::system_prompt(locale);
            let user = cnd_domain::ai::user_prompt(command, playing, &candidates);
            cnd_domain::ai::build_request_for(&config, &system, &user, mode, task)
                .map_err(|e| JsValue::from_str(&e))?
        }
        cnd_domain::ai::Task::UnderstandSearch => {
            let command = payload.get("command").and_then(serde_json::Value::as_str).unwrap_or("");
            let now_local = payload.get("now_local").and_then(serde_json::Value::as_str).unwrap_or("");
            let catalog_has: Vec<String> = payload
                .get("catalog_has")
                .and_then(|v| serde_json::from_value(v.clone()).ok())
                .unwrap_or_default();
            let only: Vec<String> = payload
                .get("only")
                .and_then(|v| serde_json::from_value(v.clone()).ok())
                .unwrap_or_default();
            let catalog_has_refs: Vec<&str> = catalog_has.iter().map(String::as_str).collect();
            let only_refs: Vec<&str> = only.iter().map(String::as_str).collect();

            let system = cnd_domain::ai::understand_system_prompt(locale);
            let user = cnd_domain::ai::understand_user_prompt(command, now_local, &catalog_has_refs, &only_refs);
            cnd_domain::ai::build_request_for(&config, &system, &user, mode, task)
                .map_err(|e| JsValue::from_str(&e))?
        }
        cnd_domain::ai::Task::Recommend => {
            let kind = payload.get("kind").and_then(serde_json::Value::as_str).unwrap_or("movie");
            let taste = payload.get("taste").and_then(serde_json::Value::as_str).unwrap_or("");
            let recent: Vec<String> = payload
                .get("recent")
                .and_then(|v| serde_json::from_value(v.clone()).ok())
                .unwrap_or_default();
            let candidates = payload
                .get("candidates")
                .and_then(serde_json::Value::as_array)
                .cloned()
                .unwrap_or_default();
            let now_local = payload.get("now_local").and_then(serde_json::Value::as_str).unwrap_or("");

            let system = cnd_domain::ai::recommend_system_prompt(kind, locale);
            let user = cnd_domain::ai::recommend_user_prompt(taste, &recent, &candidates, now_local);
            cnd_domain::ai::build_request_for(&config, &system, &user, mode, task)
                .map_err(|e| JsValue::from_str(&e))?
        }
    };

    serde_json::to_string(&req).map_err(|e| JsValue::from_str(&e.to_string()))
}

#[wasm_bindgen]
pub fn wasm_ai_read_response(kind: &str, status: u16, body: &str) -> Result<String, JsValue> {
    let provider_kind = cnd_domain::ai::AiProviderKind::parse_str(kind)
        .ok_or_else(|| JsValue::from_str(&format!("fournisseur inconnu : {kind}")))?;

    if (200..300).contains(&status) {
        let json_val: serde_json::Value = serde_json::from_str(body)
            .map_err(|e| JsValue::from_str(&format!("réponse non JSON du fournisseur : {e}")))?;
        match cnd_domain::ai::extract_text(provider_kind, &json_val) {
            Ok(text) => serde_json::to_string(&serde_json::json!({
                "ok": true,
                "text": text
            }))
            .map_err(|e| JsValue::from_str(&e.to_string())),
            Err(err) => serde_json::to_string(&serde_json::json!({
                "ok": false,
                "error": err,
                "is_schema_rejection": false
            }))
            .map_err(|e| JsValue::from_str(&e.to_string())),
        }
    } else {
        let explanation = cnd_domain::ai::explain_http_error(status, body, None);
        let schema_rej = cnd_domain::ai::is_schema_rejection(status, body);
        serde_json::to_string(&serde_json::json!({
            "ok": false,
            "error": explanation,
            "is_schema_rejection": schema_rej
        }))
        .map_err(|e| JsValue::from_str(&e.to_string()))
    }
}

#[wasm_bindgen]
pub fn wasm_ai_validate(
    task_name: &str,
    text: &str,
    candidates_json: &str,
    profile_json: &str,
) -> Result<String, JsValue> {
    if !profile_json.trim().is_empty() {
        if let Ok(prof) = serde_json::from_str::<serde_json::Value>(profile_json) {
            if prof.get("is_kids").and_then(serde_json::Value::as_bool) == Some(true) {
                return serde_json::to_string(&serde_json::json!({
                    "ok": false,
                    "error": "profil Enfants : aucune IA distante"
                }))
                .map_err(|e| JsValue::from_str(&e.to_string()));
            }
        }
    }

    let task = cnd_domain::ai::Task::parse_str(task_name)
        .ok_or_else(|| JsValue::from_str(&format!("tâche inconnue : {task_name}")))?;

    match task {
        cnd_domain::ai::Task::Command => {
            let candidates: Vec<cnd_domain::ai::AiCandidate> = serde_json::from_str(candidates_json)
                .map_err(|e| JsValue::from_str(&format!("candidates JSON invalide : {e}")))?;
            match cnd_domain::ai::validate_command_text(text, &candidates) {
                Ok((action, reply)) => serde_json::to_string(&serde_json::json!({
                    "ok": true,
                    "action": action,
                    "reply": reply
                }))
                .map_err(|e| JsValue::from_str(&e.to_string())),
                Err(err) => serde_json::to_string(&serde_json::json!({
                    "ok": false,
                    "error": err
                }))
                .map_err(|e| JsValue::from_str(&e.to_string())),
            }
        }
        cnd_domain::ai::Task::UnderstandSearch => {
            match cnd_domain::ai::validate_understand(text) {
                Ok(res) => serde_json::to_string(&serde_json::json!({
                    "ok": true,
                    "understanding": res
                }))
                .map_err(|e| JsValue::from_str(&e.to_string())),
                Err(err) => serde_json::to_string(&serde_json::json!({
                    "ok": false,
                    "error": err
                }))
                .map_err(|e| JsValue::from_str(&e.to_string())),
            }
        }
        cnd_domain::ai::Task::Recommend => {
            let candidate_ids: Vec<String> = serde_json::from_str(candidates_json)
                .map_err(|e| JsValue::from_str(&format!("candidate_ids JSON invalide : {e}")))?;
            let kind = "movie";
            match cnd_domain::ai::validate_recommend(text, kind, &candidate_ids) {
                Ok(res) => serde_json::to_string(&serde_json::json!({
                    "ok": true,
                    "recommendations": res
                }))
                .map_err(|e| JsValue::from_str(&e.to_string())),
                Err(err) => serde_json::to_string(&serde_json::json!({
                    "ok": false,
                    "error": err
                }))
                .map_err(|e| JsValue::from_str(&e.to_string())),
            }
        }
    }
}

#[wasm_bindgen]
pub fn wasm_ai_resolve_local(
    command: &str,
    candidates_json: &str,
    context_json: &str,
) -> Result<String, JsValue> {
    let candidates: Vec<cnd_domain::ai::AiCandidate> = serde_json::from_str(candidates_json)
        .map_err(|e| JsValue::from_str(&format!("candidates JSON invalide : {e}")))?;
    let context: cnd_domain::ai::AiCommandContext = serde_json::from_str(context_json)
        .unwrap_or(cnd_domain::ai::AiCommandContext {
            playing_stable_hash: None,
            group_title: None,
            locale: "fr-FR".to_string(),
        });

    let outcome = cnd_domain::ai::resolve_local(command, &candidates, &context);
    serde_json::to_string(&outcome).map_err(|e| JsValue::from_str(&e.to_string()))
}

// -----------------------------------------------------------------------------
// PRD 41 — Continuité Multi-Appareils & Identité Commune
// -----------------------------------------------------------------------------

/// Identity of an IPTV account (`cnd_domain::identity::account_identity_key`): the same account added on
/// several devices is recognised and never stored twice. Empty strings mean "absent".
#[wasm_bindgen]
pub fn wasm_account_identity_key(source_type: &str, server: &str, url: &str, username: &str) -> String {
    cnd_domain::identity::account_identity_key(source_type, Some(server), Some(url), Some(username))
}

#[wasm_bindgen]
pub fn wasm_source_key(source_type: &str, server_or_url: &str, username: &str) -> String {
    let user_opt = if username.trim().is_empty() {
        None
    } else {
        Some(username)
    };
    cnd_domain::identity::compute_source_key(source_type, server_or_url, user_opt)
}

#[wasm_bindgen]
pub fn wasm_content_key(source_key: &str, kind: &str, provider_id: &str) -> String {
    cnd_domain::identity::compute_content_key(source_key, kind, provider_id)
}

fn parse_hex_32(hex_str: &str) -> Result<[u8; 32], JsValue> {
    let s = hex_str.trim();
    if s.len() != 64 {
        return Err(JsValue::from_str("la clé doit contenir 64 caractères hexadécimaux (32 octets)"));
    }
    let mut key = [0u8; 32];
    for (i, chunk) in s.as_bytes().chunks(2).enumerate() {
        let chunk_str = std::str::from_utf8(chunk).map_err(|e| JsValue::from_str(&e.to_string()))?;
        key[i] = u8::from_str_radix(chunk_str, 16)
            .map_err(|_| JsValue::from_str("caractère hexadécimal invalide dans la clé"))?;
    }
    Ok(key)
}

fn parse_hex_12(hex_str: &str) -> Result<[u8; 12], JsValue> {
    let s = hex_str.trim();
    if s.len() != 24 {
        return Err(JsValue::from_str("le nonce doit contenir 24 caractères hexadécimaux (12 octets)"));
    }
    let mut nonce = [0u8; 12];
    for (i, chunk) in s.as_bytes().chunks(2).enumerate() {
        let chunk_str = std::str::from_utf8(chunk).map_err(|e| JsValue::from_str(&e.to_string()))?;
        nonce[i] = u8::from_str_radix(chunk_str, 16)
            .map_err(|_| JsValue::from_str("caractère hexadécimal invalide dans le nonce"))?;
    }
    Ok(nonce)
}

#[wasm_bindgen]
pub fn wasm_sync_household_invite(key_hex: &str) -> Result<String, JsValue> {
    cnd_domain::sync::household_invite_link(key_hex)
        .ok_or_else(|| JsValue::from_str("Invitation de salon invalide"))
}

#[wasm_bindgen]
pub fn wasm_sync_household_join(scanned: &str) -> Result<String, JsValue> {
    let key = cnd_domain::sync::household_key_from_scanned(scanned)
        .ok_or_else(|| JsValue::from_str("Invitation de salon invalide"))?;
    let bytes = parse_hex_32(&key)?;
    let id = cnd_domain::sync::derive_household_id(&bytes);
    Ok(serde_json::json!({"household_key": key, "household_id": id}).to_string())
}

#[wasm_bindgen]
pub fn wasm_sync_create_household(entropy_hex: &str) -> Result<String, JsValue> {
    let entropy = parse_hex_32(entropy_hex)?;
    let household_key = cnd_domain::sync::create_household_key(&entropy);
    let key_bytes = parse_hex_32(&household_key)?;
    let household_id = cnd_domain::sync::derive_household_id(&key_bytes);

    let res = serde_json::json!({
        "household_key": household_key,
        "household_id": household_id
    });
    serde_json::to_string(&res).map_err(|e| JsValue::from_str(&e.to_string()))
}

#[wasm_bindgen]
pub fn wasm_sync_seal_envelope(
    household_key_hex: &str,
    sender_id: &str,
    sequence: f64,
    nonce_hex: &str,
    message_json: &str,
) -> Result<String, JsValue> {
    let key = parse_hex_32(household_key_hex)?;
    let nonce = parse_hex_12(nonce_hex)?;
    let message: cnd_domain::sync::SyncMessage = serde_json::from_str(message_json)
        .map_err(|e| JsValue::from_str(&format!("format message invalide : {e}")))?;

    let envelope = cnd_domain::sync::seal_envelope(&key, sender_id, sequence as u64, &nonce, &message)
        .map_err(|e| JsValue::from_str(&e.to_string()))?;

    serde_json::to_string(&envelope).map_err(|e| JsValue::from_str(&e.to_string()))
}

#[wasm_bindgen]
pub fn wasm_sync_open_envelope(
    household_key_hex: &str,
    envelope_json: &str,
    last_seen_sequence: f64,
) -> Result<String, JsValue> {
    let key = parse_hex_32(household_key_hex)?;
    let envelope: cnd_domain::sync::HouseholdEnvelope = serde_json::from_str(envelope_json)
        .map_err(|e| JsValue::from_str(&format!("format enveloppe invalide : {e}")))?;

    let message = cnd_domain::sync::open_envelope(&key, &envelope, last_seen_sequence as u64)
        .map_err(|e| JsValue::from_str(&e.to_string()))?;

    serde_json::to_string(&message).map_err(|e| JsValue::from_str(&e.to_string()))
}

#[wasm_bindgen]
pub fn wasm_sync_missing_ai_credentials(configs_json: &str, existing_json: &str) -> Result<String, JsValue> {
    let configs = serde_json::from_str(configs_json)
        .map_err(|_| JsValue::from_str("configuration IA du foyer invalide"))?;
    let existing: Vec<String> = serde_json::from_str(existing_json)
        .map_err(|_| JsValue::from_str("liste des fournisseurs invalide"))?;
    let accepted = cnd_domain::sync::missing_household_ai_credentials(configs, &existing)
        .map_err(|error| JsValue::from_str(&error.to_string()))?;
    serde_json::to_string(&accepted).map_err(|_| JsValue::from_str("configuration IA invalide"))
}

#[wasm_bindgen]
pub fn wasm_sync_missing_metadata_keys(keys_json: &str, existing_json: &str) -> Result<String, JsValue> {
    let keys = serde_json::from_str(keys_json)
        .map_err(|_| JsValue::from_str("clé de service du foyer invalide"))?;
    let existing: Vec<String> = serde_json::from_str(existing_json)
        .map_err(|_| JsValue::from_str("liste des services invalide"))?;
    let accepted = cnd_domain::sync::missing_household_metadata_keys(keys, &existing)
        .map_err(|error| JsValue::from_str(&error.to_string()))?;
    serde_json::to_string(&accepted).map_err(|_| JsValue::from_str("clé de service invalide"))
}

#[wasm_bindgen]
pub fn wasm_sync_merge_delta(
    local_state_json: &str,
    incoming_delta_json: &str,
) -> Result<String, JsValue> {
    let mut state: cnd_domain::sync::HouseholdState = if local_state_json.trim().is_empty() {
        cnd_domain::sync::HouseholdState::new()
    } else {
        serde_json::from_str(local_state_json)
            .map_err(|e| JsValue::from_str(&format!("état local invalide : {e}")))?
    };

    let delta: cnd_domain::sync::SyncDelta = serde_json::from_str(incoming_delta_json)
        .map_err(|e| JsValue::from_str(&format!("delta invalide : {e}")))?;

    let report = state.apply_delta(&delta);
    let res = serde_json::json!({
        "state": state,
        "report": report
    });
    serde_json::to_string(&res).map_err(|e| JsValue::from_str(&e.to_string()))
}

#[wasm_bindgen]
pub fn wasm_sync_export_delta(
    local_state_json: &str,
    from_hlc_str: &str,
    current_node_id: &str,
    current_physical_ms: f64,
) -> Result<String, JsValue> {
    let state: cnd_domain::sync::HouseholdState = if local_state_json.trim().is_empty() {
        cnd_domain::sync::HouseholdState::new()
    } else {
        serde_json::from_str(local_state_json)
            .map_err(|e| JsValue::from_str(&format!("état local invalide : {e}")))?
    };

    let from_hlc = if from_hlc_str.trim().is_empty() {
        None
    } else {
        cnd_domain::sync::HlcTimestamp::parse_compact(from_hlc_str.trim())
    };

    let to_hlc = cnd_domain::sync::HlcTimestamp::new(
        current_physical_ms as u64,
        0,
        current_node_id,
    );

    let delta = state.export_delta(from_hlc.as_ref(), to_hlc);
    serde_json::to_string(&delta).map_err(|e| JsValue::from_str(&e.to_string()))
}

// ---------------------------------------------------------------- remote (PRD-42)

#[wasm_bindgen]
pub fn wasm_remote_reconstruct_xtream_url(
    server: &str,
    username: &str,
    password: &str,
    kind: &str,
    provider_ref: &str,
    container_ext: Option<String>,
) -> String {
    cnd_domain::remote::resolve::reconstruct_xtream_url(
        server,
        username,
        password,
        kind,
        provider_ref,
        container_ext.as_deref(),
    )
}

#[wasm_bindgen]
pub fn wasm_remote_verify_content_key(
    source_key: &str,
    item_kind: &str,
    provider_item_id: &str,
    expected_content_key: &str,
) -> bool {
    cnd_domain::remote::resolve::verify_content_key_match(
        source_key,
        item_kind,
        provider_item_id,
        expected_content_key,
    )
}

#[wasm_bindgen]
pub fn wasm_remote_is_kids_allowed(group_title: Option<String>, is_explicit_adult: bool) -> bool {
    cnd_domain::remote::resolve::is_content_allowed_in_kids_mode(
        group_title.as_deref(),
        is_explicit_adult,
    )
}

#[wasm_bindgen]
pub fn wasm_remote_should_stop_stream(
    current_source_key: Option<String>,
    release_source_key: &str,
) -> bool {
    cnd_domain::remote::handoff::should_stop_stream_on_release(
        current_source_key.as_deref(),
        release_source_key,
    )
}

#[wasm_bindgen]
pub fn wasm_validate_source_edit(edit_json: &str) -> Result<String, JsValue> {
    let edit = serde_json::from_str(edit_json).map_err(|_| JsValue::from_str("Modification invalide"))?;
    let edit = cnd_domain::source_edit::validate_source_edit(edit).map_err(JsValue::from_str)?;
    serde_json::to_string(&edit).map_err(|_| JsValue::from_str("Modification invalide"))
}

#[wasm_bindgen]
pub fn wasm_rewrite_source_locator(locator: &str, edit_json: &str) -> Result<String, JsValue> {
    let edit = serde_json::from_str(edit_json).map_err(|_| JsValue::from_str("Modification invalide"))?;
    cnd_domain::source_edit::rewrite_source_locator(locator, edit).map_err(JsValue::from_str)
}
