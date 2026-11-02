//! Requests and responses of the three provider families. No network here: this module only builds
//! the request and reads the answer, so every shape can be tested without a server.
//!
//! Keys travel in headers (`x-goog-api-key`, `Authorization`, `x-api-key`), never in the URL or body.

use crate::ai::intent::{AiProviderConfig, AiProviderKind};
use crate::ai::prompt::{decision_schema, gemini_schema};
use serde::Deserialize;
use serde_json::{json, Value};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RequestMode {
    /// Constrained decoding against the JSON schema.
    Strict,
    /// Only "answer in JSON", for servers that reject schemas; our own validation does the rest.
    Light,
}

#[derive(Debug, Clone)]
pub struct ProviderRequest {
    pub url: String,
    pub headers: Vec<(&'static str, String)>,
    pub body: Value,
}

pub const ANTHROPIC_VERSION: &str = "2023-06-01";
const GEMINI_MAX_OUTPUT_TOKENS: u32 = 1024;
const ANTHROPIC_MAX_TOKENS: u32 = 512;

pub fn build_request(
    config: &AiProviderConfig,
    system: &str,
    user: &str,
    mode: RequestMode,
) -> Result<ProviderRequest, String> {
    let key = config.key();
    if config.requires_key() && key.is_none() {
        return Err("clé API absente".to_string());
    }
    let model = config.effective_model();
    if model.is_empty() {
        return Err("aucun modèle configuré".to_string());
    }
    let base = config.effective_base_url();
    if base.is_empty() {
        return Err("adresse du fournisseur absente".to_string());
    }

    match config.kind {
        AiProviderKind::LocalOnly => Err("mode local : aucun fournisseur".to_string()),
        AiProviderKind::Gemini => {
            let mut generation = json!({
                "responseMimeType": "application/json",
                "temperature": 0,
                "maxOutputTokens": GEMINI_MAX_OUTPUT_TOKENS,
            });
            if mode == RequestMode::Strict {
                generation["responseSchema"] = gemini_schema();
            }
            Ok(ProviderRequest {
                url: format!("{base}/models/{}:generateContent", model.trim_start_matches("models/")),
                headers: vec![("x-goog-api-key", key.unwrap_or_default().to_string())],
                body: json!({
                    "systemInstruction": { "parts": [{ "text": system }] },
                    "contents": [{ "role": "user", "parts": [{ "text": user }] }],
                    "generationConfig": generation,
                }),
            })
        }
        AiProviderKind::OpenAiCompatible => {
            let response_format = match mode {
                RequestMode::Strict => json!({
                    "type": "json_schema",
                    "json_schema": { "name": "channel_action", "strict": true, "schema": decision_schema() }
                }),
                RequestMode::Light => json!({ "type": "json_object" }),
            };
            let mut headers = Vec::new();
            if let Some(key) = key {
                headers.push(("authorization", format!("Bearer {key}")));
            }
            Ok(ProviderRequest {
                url: format!("{base}/chat/completions"),
                headers,
                body: json!({
                    "model": model,
                    "messages": [
                        { "role": "system", "content": system },
                        { "role": "user", "content": user },
                    ],
                    "response_format": response_format,
                }),
            })
        }
        AiProviderKind::Anthropic => {
            let path = if base.ends_with("/v1") { "/messages" } else { "/v1/messages" };
            Ok(ProviderRequest {
                url: format!("{base}{path}"),
                headers: vec![
                    ("x-api-key", key.unwrap_or_default().to_string()),
                    ("anthropic-version", ANTHROPIC_VERSION.to_string()),
                ],
                body: json!({
                    "model": model,
                    "max_tokens": ANTHROPIC_MAX_TOKENS,
                    "system": system,
                    "messages": [{ "role": "user", "content": user }],
                    "tools": [{
                        "name": "choose_action",
                        "description": "Record the single action chosen for the user's command.",
                        "input_schema": decision_schema(),
                    }],
                    "tool_choice": { "type": "tool", "name": "choose_action" },
                }),
            })
        }
    }
}

/// The text (a JSON document) the model produced, wherever the provider puts it.
pub fn extract_text(kind: AiProviderKind, body: &Value) -> Result<String, String> {
    match kind {
        AiProviderKind::LocalOnly => Err("mode local".to_string()),
        AiProviderKind::Gemini => {
            if let Some(reason) = body.pointer("/promptFeedback/blockReason").and_then(Value::as_str) {
                return Err(format!("demande bloquée par le fournisseur ({reason})"));
            }
            let parts = body
                .pointer("/candidates/0/content/parts")
                .and_then(Value::as_array)
                .ok_or_else(|| "réponse vide du fournisseur".to_string())?;
            let text: String = parts.iter().filter_map(|p| p["text"].as_str()).collect();
            if text.trim().is_empty() {
                let finish = body.pointer("/candidates/0/finishReason").and_then(Value::as_str).unwrap_or("");
                return Err(if finish.is_empty() {
                    "réponse vide du fournisseur".to_string()
                } else {
                    format!("réponse vide ({finish})")
                });
            }
            Ok(text)
        }
        AiProviderKind::OpenAiCompatible => {
            let message = body
                .pointer("/choices/0/message")
                .ok_or_else(|| "réponse vide du fournisseur".to_string())?;
            if let Some(content) = message["content"].as_str() {
                if !content.trim().is_empty() {
                    return Ok(content.to_string());
                }
            }
            if let Some(parts) = message["content"].as_array() {
                let text: String = parts.iter().filter_map(|p| p["text"].as_str()).collect();
                if !text.trim().is_empty() {
                    return Ok(text);
                }
            }
            if message["refusal"].as_str().is_some() {
                return Err("demande refusée par le modèle".to_string());
            }
            Err("réponse vide du fournisseur".to_string())
        }
        AiProviderKind::Anthropic => {
            let blocks = body["content"].as_array().ok_or_else(|| "réponse vide du fournisseur".to_string())?;
            if let Some(tool) = blocks.iter().find(|b| b["type"] == "tool_use") {
                return Ok(tool["input"].to_string());
            }
            let text: String = blocks.iter().filter_map(|b| b["text"].as_str()).collect();
            if text.trim().is_empty() {
                Err("réponse vide du fournisseur".to_string())
            } else {
                Ok(text)
            }
        }
    }
}

#[derive(Debug, Clone, Default, Deserialize, PartialEq)]
#[serde(default)]
pub struct ModelDecision {
    pub action: String,
    #[serde(deserialize_with = "lenient_i64")]
    pub item_id: Option<i64>,
    pub query: Option<String>,
    pub reply: Option<String>,
}

/// Models sometimes answer `5.0` or `"5"` instead of `5`.
fn lenient_i64<'de, D: serde::Deserializer<'de>>(deserializer: D) -> Result<Option<i64>, D::Error> {
    let value = Option::<Value>::deserialize(deserializer)?;
    Ok(match value {
        None | Some(Value::Null) => None,
        Some(Value::Number(n)) => n.as_i64().or_else(|| n.as_f64().map(|f| f as i64)),
        Some(Value::String(s)) => s.trim().parse().ok(),
        Some(_) => None,
    })
}

/// Parses the model's JSON, tolerating Markdown fences and text around the object.
pub fn parse_decision(text: &str) -> Result<ModelDecision, String> {
    let trimmed = text.trim();
    let start = trimmed.find('{').ok_or_else(|| "réponse non JSON".to_string())?;
    let end = trimmed.rfind('}').ok_or_else(|| "réponse non JSON".to_string())?;
    if end < start {
        return Err("réponse non JSON".to_string());
    }
    let decision: ModelDecision =
        serde_json::from_str(&trimmed[start..=end]).map_err(|_| "réponse non JSON".to_string())?;
    if decision.action.trim().is_empty() {
        return Err("réponse sans action".to_string());
    }
    Ok(decision)
}

/// A readable reason for an HTTP failure. The key, should the provider echo it, is scrubbed.
pub fn explain_http_error(status: u16, body: &str, key: Option<&str>) -> String {
    let base = match status {
        401 | 403 => "clé refusée par le fournisseur",
        404 => "modèle ou adresse introuvable",
        408 => "délai dépassé côté fournisseur",
        429 => "quota ou limite de débit atteint",
        400 | 422 => "requête refusée par le fournisseur",
        500..=599 => "fournisseur indisponible",
        _ => "erreur du fournisseur",
    };
    let detail = serde_json::from_str::<Value>(body)
        .ok()
        .and_then(|v| {
            v.pointer("/error/message")
                .or_else(|| v.pointer("/error"))
                .or_else(|| v.pointer("/message"))
                .and_then(Value::as_str)
                .map(str::to_string)
        })
        .map(|m| scrub(&m, key))
        .map(|m| m.chars().take(140).collect::<String>())
        .filter(|m| !m.trim().is_empty());
    match detail {
        Some(detail) => format!("{base} (HTTP {status} : {detail})"),
        None => format!("{base} (HTTP {status})"),
    }
}

fn scrub(text: &str, key: Option<&str>) -> String {
    match key {
        Some(k) if k.len() >= 4 => text.replace(k, "***"),
        _ => text.to_string(),
    }
}

/// `true` when a 400 looks like the server not supporting the schema option (retry in light mode).
pub fn is_schema_rejection(status: u16, body: &str) -> bool {
    if !(status == 400 || status == 422) {
        return false;
    }
    let lower = body.to_ascii_lowercase();
    ["response_format", "json_schema", "responseschema", "response_schema", "responsemimetype", "schema", "unsupported"]
        .iter()
        .any(|needle| lower.contains(needle))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config(kind: AiProviderKind) -> AiProviderConfig {
        AiProviderConfig {
            kind,
            model: String::new(),
            base_url: None,
            api_key: Some("sk-TEST-KEY-123".to_string()),
            timeout_ms: 0,
        }
    }

    fn header<'a>(request: &'a ProviderRequest, name: &str) -> Option<&'a str> {
        request.headers.iter().find(|(n, _)| *n == name).map(|(_, v)| v.as_str())
    }

    fn assert_key_only_in_headers(request: &ProviderRequest) {
        assert!(!request.url.contains("TEST-KEY"), "key in URL");
        assert!(!request.body.to_string().contains("TEST-KEY"), "key in body");
    }

    #[test]
    fn gemini_request() {
        let strict = build_request(&config(AiProviderKind::Gemini), "SYS", "USER", RequestMode::Strict).unwrap();
        assert_eq!(strict.url, "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash-lite:generateContent");
        assert_eq!(header(&strict, "x-goog-api-key"), Some("sk-TEST-KEY-123"));
        assert_key_only_in_headers(&strict);
        assert_eq!(strict.body["systemInstruction"]["parts"][0]["text"], "SYS");
        assert_eq!(strict.body["contents"][0]["parts"][0]["text"], "USER");
        assert_eq!(strict.body["generationConfig"]["responseMimeType"], "application/json");
        assert_eq!(strict.body["generationConfig"]["responseSchema"]["type"], "OBJECT");

        let light = build_request(&config(AiProviderKind::Gemini), "S", "U", RequestMode::Light).unwrap();
        assert!(light.body["generationConfig"].get("responseSchema").is_none());
        assert_eq!(light.body["generationConfig"]["responseMimeType"], "application/json");

        let mut custom = config(AiProviderKind::Gemini);
        custom.model = "models/gemini-custom".into();
        custom.base_url = Some("http://localhost:9/v1beta/".into());
        assert_eq!(
            build_request(&custom, "S", "U", RequestMode::Strict).unwrap().url,
            "http://localhost:9/v1beta/models/gemini-custom:generateContent"
        );
    }

    #[test]
    fn openai_compatible_request() {
        let mut cfg = config(AiProviderKind::OpenAiCompatible);
        cfg.model = "gpt-test".into();
        let strict = build_request(&cfg, "SYS", "USER", RequestMode::Strict).unwrap();
        assert_eq!(strict.url, "https://api.openai.com/v1/chat/completions");
        assert_eq!(header(&strict, "authorization"), Some("Bearer sk-TEST-KEY-123"));
        assert_key_only_in_headers(&strict);
        assert_eq!(strict.body["model"], "gpt-test");
        assert_eq!(strict.body["messages"][0]["role"], "system");
        assert_eq!(strict.body["messages"][1]["content"], "USER");
        assert_eq!(strict.body["response_format"]["type"], "json_schema");
        assert_eq!(strict.body["response_format"]["json_schema"]["strict"], true);
        assert_eq!(strict.body["response_format"]["json_schema"]["schema"]["additionalProperties"], false);

        let light = build_request(&cfg, "S", "U", RequestMode::Light).unwrap();
        assert_eq!(light.body["response_format"]["type"], "json_object");

        // A local server needs neither key nor official URL.
        let mut local = config(AiProviderKind::OpenAiCompatible);
        local.api_key = None;
        local.base_url = Some("http://localhost:11434/v1/".into());
        local.model = "llama3.2".into();
        let request = build_request(&local, "S", "U", RequestMode::Strict).unwrap();
        assert_eq!(request.url, "http://localhost:11434/v1/chat/completions");
        assert!(request.headers.is_empty());
    }

    #[test]
    fn anthropic_request() {
        let request = build_request(&config(AiProviderKind::Anthropic), "SYS", "USER", RequestMode::Strict).unwrap();
        assert_eq!(request.url, "https://api.anthropic.com/v1/messages");
        assert_eq!(header(&request, "x-api-key"), Some("sk-TEST-KEY-123"));
        assert_eq!(header(&request, "anthropic-version"), Some("2023-06-01"));
        assert_key_only_in_headers(&request);
        assert_eq!(request.body["system"], "SYS");
        assert_eq!(request.body["messages"][0]["content"], "USER");
        assert_eq!(request.body["tool_choice"], json!({ "type": "tool", "name": "choose_action" }));
        assert_eq!(request.body["tools"][0]["name"], "choose_action");
        assert_eq!(request.body["tools"][0]["input_schema"]["type"], "object");
        assert!(request.body["max_tokens"].as_u64().unwrap() > 0);

        let mut versioned = config(AiProviderKind::Anthropic);
        versioned.base_url = Some("https://proxy.example/v1".into());
        assert_eq!(build_request(&versioned, "S", "U", RequestMode::Strict).unwrap().url, "https://proxy.example/v1/messages");
    }

    #[test]
    fn missing_pieces_are_reported_in_plain_words() {
        let mut no_key = config(AiProviderKind::Gemini);
        no_key.api_key = Some("   ".into());
        assert_eq!(build_request(&no_key, "S", "U", RequestMode::Strict).unwrap_err(), "clé API absente");
        assert!(build_request(&config(AiProviderKind::LocalOnly), "S", "U", RequestMode::Strict).is_err());
        let mut no_base = config(AiProviderKind::OpenAiCompatible);
        no_base.base_url = Some("   ".into());
        // Falls back to the official URL rather than failing.
        assert!(build_request(&no_base, "S", "U", RequestMode::Strict).is_ok());
    }

    #[test]
    fn reads_each_provider_response_shape() {
        let gemini = json!({ "candidates": [{ "content": { "parts": [{ "text": "{\"action\":\"none\"}" }] }, "finishReason": "STOP" }] });
        assert_eq!(extract_text(AiProviderKind::Gemini, &gemini).unwrap(), "{\"action\":\"none\"}");
        let blocked = json!({ "promptFeedback": { "blockReason": "SAFETY" } });
        assert!(extract_text(AiProviderKind::Gemini, &blocked).unwrap_err().contains("bloquée"));
        let empty = json!({ "candidates": [{ "content": { "parts": [] }, "finishReason": "MAX_TOKENS" }] });
        assert!(extract_text(AiProviderKind::Gemini, &empty).unwrap_err().contains("MAX_TOKENS"));

        let openai = json!({ "choices": [{ "message": { "content": "{\"action\":\"next\"}" } }] });
        assert_eq!(extract_text(AiProviderKind::OpenAiCompatible, &openai).unwrap(), "{\"action\":\"next\"}");
        let parts = json!({ "choices": [{ "message": { "content": [{ "type": "text", "text": "{\"a\":1}" }] } }] });
        assert_eq!(extract_text(AiProviderKind::OpenAiCompatible, &parts).unwrap(), "{\"a\":1}");
        let refusal = json!({ "choices": [{ "message": { "content": null, "refusal": "no" } }] });
        assert!(extract_text(AiProviderKind::OpenAiCompatible, &refusal).unwrap_err().contains("refusée"));

        let tool = json!({ "content": [{ "type": "text", "text": "ok" }, { "type": "tool_use", "id": "t", "name": "choose_action", "input": { "action": "play", "item_id": 3 } }] });
        let text = extract_text(AiProviderKind::Anthropic, &tool).unwrap();
        assert_eq!(serde_json::from_str::<Value>(&text).unwrap()["item_id"], 3);
        let plain = json!({ "content": [{ "type": "text", "text": "{\"action\":\"none\"}" }] });
        assert_eq!(extract_text(AiProviderKind::Anthropic, &plain).unwrap(), "{\"action\":\"none\"}");
    }

    #[test]
    fn decisions_are_parsed_leniently_but_must_be_json_with_an_action() {
        let ok = parse_decision("{\"action\":\"play\",\"item_id\":42,\"query\":null,\"reply\":\"ok\"}").unwrap();
        assert_eq!((ok.action.as_str(), ok.item_id, ok.reply.as_deref()), ("play", Some(42), Some("ok")));

        let fenced = parse_decision("Voici :\n```json\n{\"action\":\"play\",\"item_id\":\"7\"}\n```").unwrap();
        assert_eq!(fenced.item_id, Some(7));
        assert_eq!(parse_decision("{\"action\":\"guide\",\"item_id\":5.0}").unwrap().item_id, Some(5));
        assert_eq!(parse_decision("{\"action\":\"next\"}").unwrap().item_id, None);

        for bad in ["", "not json", "{\"item_id\":3}", "{ broken", "}{"] {
            assert!(parse_decision(bad).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn http_errors_are_explained_and_never_echo_the_key() {
        assert!(explain_http_error(401, "", None).starts_with("clé refusée"));
        assert!(explain_http_error(404, "", None).contains("introuvable"));
        assert!(explain_http_error(429, "", None).contains("quota"));
        assert!(explain_http_error(503, "", None).contains("indisponible"));
        let body = "{\"error\":{\"message\":\"Incorrect API key provided: sk-TEST-KEY-123.\"}}";
        let text = explain_http_error(401, body, Some("sk-TEST-KEY-123"));
        assert!(text.contains("HTTP 401") && text.contains("***"));
        assert!(!text.contains("TEST-KEY"));
    }

    #[test]
    fn schema_rejections_are_recognised() {
        assert!(is_schema_rejection(400, "{\"error\":\"response_format json_schema is not supported\"}"));
        assert!(is_schema_rejection(400, "Invalid value for responseSchema"));
        assert!(!is_schema_rejection(400, "context length exceeded"));
        assert!(!is_schema_rejection(401, "schema"));
        assert!(!is_schema_rejection(500, "schema"));
    }
}
