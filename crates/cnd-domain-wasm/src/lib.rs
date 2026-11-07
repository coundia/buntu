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
