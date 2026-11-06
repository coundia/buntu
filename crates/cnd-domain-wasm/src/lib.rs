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
