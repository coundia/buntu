//! Requests and responses of the three provider families. No network here: this module only builds
//! the request and reads the answer, so every shape can be tested without a server.
//!
//! Keys travel in headers (`x-goog-api-key`, `Authorization`, `x-api-key`), never in the URL or body.

use crate::ai::intent::{AiProviderConfig, AiProviderKind};
use serde_json::Value;

pub use cnd_domain::ai::providers::{
    explain_http_error, is_schema_rejection, parse_decision, ANTHROPIC_VERSION,
};
pub use cnd_domain::ai::types::{ModelDecision, ProviderRequest, RequestMode, Task};

pub fn build_request(
    config: &AiProviderConfig,
    system: &str,
    user: &str,
    mode: RequestMode,
) -> Result<ProviderRequest, String> {
    cnd_domain::ai::providers::build_request(&config.to_domain(), system, user, mode)
}

pub fn build_request_for(
    config: &AiProviderConfig,
    system: &str,
    user: &str,
    mode: RequestMode,
    task: Task,
) -> Result<ProviderRequest, String> {
    cnd_domain::ai::providers::build_request_for(&config.to_domain(), system, user, mode, task)
}

pub fn extract_text(kind: AiProviderKind, body: &Value) -> Result<String, String> {
    cnd_domain::ai::providers::extract_text(kind.into(), body)
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

        let mut custom = cfg.clone();
        custom.base_url = Some("http://192.168.1.10:11434/v1/".into());
        custom.api_key = None;
        let ollama = build_request(&custom, "S", "U", RequestMode::Light).unwrap();
        assert_eq!(ollama.url, "http://192.168.1.10:11434/v1/chat/completions");
        assert!(header(&ollama, "authorization").is_none(), "Ollama does not need an Authorization header");
    }

    #[test]
    fn anthropic_request() {
        let strict = build_request(&config(AiProviderKind::Anthropic), "SYS", "USER", RequestMode::Strict).unwrap();
        assert_eq!(strict.url, "https://api.anthropic.com/v1/messages");
        assert_eq!(header(&strict, "x-api-key"), Some("sk-TEST-KEY-123"));
        assert_eq!(header(&strict, "anthropic-version"), Some(ANTHROPIC_VERSION));
        assert_key_only_in_headers(&strict);
        assert_eq!(strict.body["model"], "claude-haiku-5-5");
        assert_eq!(strict.body["system"], "SYS");
        assert_eq!(strict.body["messages"][0]["content"], "USER");
        assert_eq!(strict.body["tool_choice"]["name"], "choose_action");
        assert_eq!(strict.body["tools"][0]["input_schema"]["properties"]["action"]["enum"].as_array().unwrap().len(), 7);
    }
}
