use super::prompt::{
    decision_schema, gemini_schema, recommend_gemini_schema, recommend_schema, understand_gemini_schema, understand_schema,
};
use super::types::{AiProviderConfig, AiProviderKind, ModelDecision, ProviderRequest, RequestMode, Task};
use serde_json::{json, Value};

pub const ANTHROPIC_VERSION: &str = "2023-06-01";
const GEMINI_MAX_OUTPUT_TOKENS: u32 = 1024;
const ANTHROPIC_MAX_TOKENS: u32 = 512;
const UNDERSTAND_MAX_TOKENS: u32 = 1024;
const RECOMMEND_MAX_TOKENS: u32 = 2048;

pub fn build_request(
    config: &AiProviderConfig,
    system: &str,
    user: &str,
    mode: RequestMode,
) -> Result<ProviderRequest, String> {
    build_request_for(config, system, user, mode, Task::Command)
}

pub fn build_request_for(
    config: &AiProviderConfig,
    system: &str,
    user: &str,
    mode: RequestMode,
    task: Task,
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
                "maxOutputTokens": if task == Task::Recommend { RECOMMEND_MAX_TOKENS } else { GEMINI_MAX_OUTPUT_TOKENS },
            });
            if mode == RequestMode::Strict {
                generation["responseSchema"] = match task {
                    Task::Command => gemini_schema(),
                    Task::UnderstandSearch => understand_gemini_schema(),
                    Task::Recommend => recommend_gemini_schema(),
                };
            }
            Ok(ProviderRequest {
                url: format!("{base}/models/{}:generateContent", model.trim_start_matches("models/")),
                method: "POST".to_string(),
                headers: vec![("x-goog-api-key".to_string(), key.unwrap_or_default().to_string())],
                body: json!({
                    "systemInstruction": { "parts": [{ "text": system }] },
                    "contents": [{ "role": "user", "parts": [{ "text": user }] }],
                    "generationConfig": generation,
                }),
            })
        }
        AiProviderKind::OpenAiCompatible => {
            let response_format = match mode {
                RequestMode::Strict => match task {
                    Task::Command => json!({
                        "type": "json_schema",
                        "json_schema": { "name": "channel_action", "strict": true, "schema": decision_schema() }
                    }),
                    Task::UnderstandSearch => json!({
                        "type": "json_schema",
                        "json_schema": { "name": "search_understanding", "strict": true, "schema": understand_schema() }
                    }),
                    Task::Recommend => json!({
                        "type": "json_schema",
                        "json_schema": { "name": "recommendations", "strict": true, "schema": recommend_schema() }
                    }),
                },
                RequestMode::Light => json!({ "type": "json_object" }),
            };
            let mut headers = Vec::new();
            if let Some(key) = key {
                headers.push(("authorization".to_string(), format!("Bearer {key}")));
            }
            Ok(ProviderRequest {
                url: format!("{base}/chat/completions"),
                method: "POST".to_string(),
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
            let (tool_name, description, schema, max_tokens) = match task {
                Task::Command => (
                    "choose_action",
                    "Record the single action chosen for the user's command.",
                    decision_schema(),
                    ANTHROPIC_MAX_TOKENS,
                ),
                Task::UnderstandSearch => (
                    "understand_search",
                    "Record what the user is looking for and the titles that fit.",
                    understand_schema(),
                    UNDERSTAND_MAX_TOKENS,
                ),
                Task::Recommend => (
                    "recommend",
                    "Record the candidates to show, best first, and the titles worth discovering.",
                    recommend_schema(),
                    RECOMMEND_MAX_TOKENS,
                ),
            };
            Ok(ProviderRequest {
                url: format!("{base}{path}"),
                method: "POST".to_string(),
                headers: vec![
                    ("x-api-key".to_string(), key.unwrap_or_default().to_string()),
                    ("anthropic-version".to_string(), ANTHROPIC_VERSION.to_string()),
                ],
                body: json!({
                    "model": model,
                    "max_tokens": max_tokens,
                    "system": system,
                    "messages": [{ "role": "user", "content": user }],
                    "tools": [{ "name": tool_name, "description": description, "input_schema": schema }],
                    "tool_choice": { "type": "tool", "name": tool_name },
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

