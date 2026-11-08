use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum AiProviderKind {
    #[serde(rename = "local_only", alias = "local")]
    LocalOnly,
    #[serde(rename = "gemini")]
    Gemini,
    #[serde(rename = "openai_compatible", alias = "openai", alias = "open_ai_compatible")]
    OpenAiCompatible,
    #[serde(rename = "anthropic", alias = "claude")]
    Anthropic,
}

impl AiProviderKind {
    pub fn label(self) -> &'static str {
        match self {
            AiProviderKind::LocalOnly => "local",
            AiProviderKind::Gemini => "gemini",
            AiProviderKind::OpenAiCompatible => "openai_compatible",
            AiProviderKind::Anthropic => "anthropic",
        }
    }

    pub fn default_model(self) -> &'static str {
        match self {
            AiProviderKind::LocalOnly => "",
            AiProviderKind::Gemini => "gemini-3.5-flash-lite",
            AiProviderKind::OpenAiCompatible => "gpt-4o-mini",
            AiProviderKind::Anthropic => "claude-haiku-5-5",
        }
    }

    pub fn default_base_url(self) -> Option<&'static str> {
        match self {
            AiProviderKind::LocalOnly => None,
            AiProviderKind::Gemini => Some("https://generativelanguage.googleapis.com/v1beta"),
            AiProviderKind::OpenAiCompatible => Some("https://api.openai.com/v1"),
            AiProviderKind::Anthropic => Some("https://api.anthropic.com"),
        }
    }

    pub fn parse_str(s: &str) -> Option<Self> {
        match s.trim().to_ascii_lowercase().as_str() {
            "local" | "local_only" | "localonly" => Some(AiProviderKind::LocalOnly),
            "gemini" => Some(AiProviderKind::Gemini),
            "openai_compatible" | "openai" => Some(AiProviderKind::OpenAiCompatible),
            "anthropic" | "claude" => Some(AiProviderKind::Anthropic),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AiProviderConfig {
    pub kind: AiProviderKind,
    #[serde(default)]
    pub model: String,
    #[serde(default)]
    pub base_url: Option<String>,
    #[serde(default)]
    pub api_key: Option<String>,
    #[serde(default)]
    pub timeout_ms: u32,
}

impl AiProviderConfig {
    pub const DEFAULT_TIMEOUT_MS: u32 = 8_000;

    pub fn effective_model(&self) -> String {
        let trimmed = self.model.trim();
        if trimmed.is_empty() {
            self.kind.default_model().to_string()
        } else {
            trimmed.to_string()
        }
    }

    pub fn effective_base_url(&self) -> String {
        let custom = self
            .base_url
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty());
        custom
            .or(self.kind.default_base_url())
            .unwrap_or_default()
            .trim_end_matches('/')
            .to_string()
    }

    pub fn effective_timeout_ms(&self) -> u64 {
        let value = if self.timeout_ms == 0 {
            Self::DEFAULT_TIMEOUT_MS
        } else {
            self.timeout_ms
        };
        u64::from(value.clamp(1_000, 30_000))
    }

    pub fn key(&self) -> Option<&str> {
        self.api_key.as_deref().map(str::trim).filter(|k| !k.is_empty())
    }

    pub fn requires_key(&self) -> bool {
        matches!(self.kind, AiProviderKind::Gemini | AiProviderKind::Anthropic)
    }

    pub fn is_local(&self) -> bool {
        if self.kind != AiProviderKind::OpenAiCompatible {
            return false;
        }
        let base = self.effective_base_url();
        let host = base
            .split("://")
            .nth(1)
            .unwrap_or(&base)
            .split(['/', '?'])
            .next()
            .unwrap_or("")
            .rsplit('@')
            .next()
            .unwrap_or("");
        let host = if let Some(rest) = host.strip_prefix('[') {
            rest.split(']').next().unwrap_or("")
        } else {
            host.split(':').next().unwrap_or("")
        };
        if host == "localhost" || host == "::1" || host.ends_with(".local") || host == "127.0.0.1" || host.starts_with("127.") {
            return true;
        }
        let parts: Vec<u32> = host.split('.').filter_map(|p| p.parse().ok()).collect();
        match parts.as_slice() {
            [10, ..] | [192, 168, ..] => true,
            [172, b, ..] => (16..=31).contains(b),
            _ => false,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Task {
    Command,
    UnderstandSearch,
    Recommend,
}

impl Task {
    pub fn parse_str(s: &str) -> Option<Self> {
        match s.trim().to_ascii_lowercase().as_str() {
            "command" => Some(Task::Command),
            "understand_search" | "search" => Some(Task::UnderstandSearch),
            "recommend" | "reco" => Some(Task::Recommend),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RequestMode {
    Strict,
    Light,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ProviderRequest {
    pub url: String,
    pub method: String,
    pub headers: Vec<(String, String)>,
    pub body: serde_json::Value,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct AiCandidate {
    pub id: i64,
    pub name: String,
    #[serde(default)]
    pub group_title: Option<String>,
    #[serde(default)]
    pub chno: Option<u32>,
    #[serde(default)]
    pub is_favorite: bool,
    #[serde(default)]
    pub current_programme: Option<String>,
    #[serde(default)]
    pub next_programme: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "action", rename_all = "snake_case")]
pub enum AiAction {
    PlayChannel { item_id: i64 },
    ShowGuide { item_id: i64 },
    Search { query: String },
    NextChannel,
    PreviousChannel,
    MultiView { item_ids: Vec<i64> },
    None,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct ModelDecision {
    pub action: String,
    #[serde(deserialize_with = "lenient_i64")]
    pub item_id: Option<i64>,
    pub item_ids: Option<Vec<i64>>,
    pub query: Option<String>,
    pub reply: Option<String>,
}

fn lenient_i64<'de, D: serde::Deserializer<'de>>(deserializer: D) -> Result<Option<i64>, D::Error> {
    let value = Option::<serde_json::Value>::deserialize(deserializer)?;
    Ok(match value {
        None | Some(serde_json::Value::Null) => None,
        Some(serde_json::Value::Number(n)) => n.as_i64().or_else(|| n.as_f64().map(|f| f as i64)),
        Some(serde_json::Value::String(s)) => s.trim().parse().ok(),
        Some(_) => None,
    })
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AiCommandContext {
    #[serde(default)]
    pub playing_stable_hash: Option<String>,
    #[serde(default)]
    pub group_title: Option<String>,
    #[serde(default)]
    pub locale: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct TitleGuess {
    pub title: String,
    #[serde(default)]
    pub year: Option<u32>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SearchUnderstanding {
    pub intent: String,
    #[serde(default)]
    pub kinds: Vec<String>,
    #[serde(default)]
    pub time_hint: Option<String>,
    #[serde(default)]
    pub genres: Vec<String>,
    #[serde(default)]
    pub people: Vec<String>,
    #[serde(default)]
    pub year_from: Option<i32>,
    #[serde(default)]
    pub year_to: Option<i32>,
    #[serde(default)]
    pub languages: Vec<String>,
    #[serde(default)]
    pub similar_to: Option<String>,
    #[serde(default)]
    pub query_rewrite: Option<String>,
    #[serde(default)]
    pub title_guesses: Vec<TitleGuess>,
    #[serde(default)]
    pub reply: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct RecoValidationPick {
    pub id: String,
    #[serde(default)]
    pub reason: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct RecoValidationResult {
    pub kind: String,
    #[serde(default)]
    pub picks: Vec<RecoValidationPick>,
    #[serde(default)]
    pub discover: Vec<TitleGuess>,
    pub confidence: f64,
}
