//! Public (UniFFI) types of the channel assistant.

use crate::db::IptvItemRecord;

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum AiProviderKind {
    /// No model: only the local resolution runs.
    LocalOnly,
    Gemini,
    /// Any `/chat/completions` server: OpenAI, Mistral, Groq, OpenRouter, Ollama, LM Studio...
    OpenAiCompatible,
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

    /// Fast, inexpensive default; always editable in Settings (model names change often).
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
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct AiProviderConfig {
    pub kind: AiProviderKind,
    /// Empty means "use the provider's default".
    pub model: String,
    /// Override of the API root (required to reach a local server). `None` means the official one.
    pub base_url: Option<String>,
    /// Passed in for each call from the Keychain; never stored on the Rust side.
    pub api_key: Option<String>,
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

    /// Gemini and Anthropic need a key; an OpenAI-compatible server may not (Ollama, LM Studio).
    pub fn requires_key(&self) -> bool {
        matches!(self.kind, AiProviderKind::Gemini | AiProviderKind::Anthropic)
    }

    pub fn to_domain(&self) -> cnd_domain::ai::AiProviderConfig {
        cnd_domain::ai::AiProviderConfig {
            kind: self.kind.into(),
            model: self.model.clone(),
            base_url: self.base_url.clone(),
            api_key: self.api_key.clone(),
            timeout_ms: self.timeout_ms,
        }
    }
}

impl From<AiProviderKind> for cnd_domain::ai::AiProviderKind {
    fn from(kind: AiProviderKind) -> Self {
        match kind {
            AiProviderKind::LocalOnly => cnd_domain::ai::AiProviderKind::LocalOnly,
            AiProviderKind::Gemini => cnd_domain::ai::AiProviderKind::Gemini,
            AiProviderKind::OpenAiCompatible => cnd_domain::ai::AiProviderKind::OpenAiCompatible,
            AiProviderKind::Anthropic => cnd_domain::ai::AiProviderKind::Anthropic,
        }
    }
}

impl From<cnd_domain::ai::AiProviderKind> for AiProviderKind {
    fn from(kind: cnd_domain::ai::AiProviderKind) -> Self {
        match kind {
            cnd_domain::ai::AiProviderKind::LocalOnly => AiProviderKind::LocalOnly,
            cnd_domain::ai::AiProviderKind::Gemini => AiProviderKind::Gemini,
            cnd_domain::ai::AiProviderKind::OpenAiCompatible => AiProviderKind::OpenAiCompatible,
            cnd_domain::ai::AiProviderKind::Anthropic => AiProviderKind::Anthropic,
        }
    }
}

impl From<cnd_domain::ai::AiAction> for AiAction {
    fn from(action: cnd_domain::ai::AiAction) -> Self {
        match action {
            cnd_domain::ai::AiAction::PlayChannel { item_id } => AiAction::PlayChannel { item_id },
            cnd_domain::ai::AiAction::ShowGuide { item_id } => AiAction::ShowGuide { item_id },
            cnd_domain::ai::AiAction::Search { query } => AiAction::Search { query },
            cnd_domain::ai::AiAction::NextChannel => AiAction::NextChannel,
            cnd_domain::ai::AiAction::PreviousChannel => AiAction::PreviousChannel,
            cnd_domain::ai::AiAction::MultiView { item_ids } => AiAction::MultiView { item_ids },
            cnd_domain::ai::AiAction::None => AiAction::None,
        }
    }
}

impl From<AiAction> for cnd_domain::ai::AiAction {
    fn from(action: AiAction) -> Self {
        match action {
            AiAction::PlayChannel { item_id } => cnd_domain::ai::AiAction::PlayChannel { item_id },
            AiAction::ShowGuide { item_id } => cnd_domain::ai::AiAction::ShowGuide { item_id },
            AiAction::Search { query } => cnd_domain::ai::AiAction::Search { query },
            AiAction::NextChannel => cnd_domain::ai::AiAction::NextChannel,
            AiAction::PreviousChannel => cnd_domain::ai::AiAction::PreviousChannel,
            AiAction::MultiView { item_ids } => cnd_domain::ai::AiAction::MultiView { item_ids },
            AiAction::None => cnd_domain::ai::AiAction::None,
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct AiCommandContext {
    /// Channel currently playing, used by "next", "previous" and "go back".
    pub playing_stable_hash: Option<String>,
    /// Category on screen, a relevance hint only.
    pub group_title: Option<String>,
    /// UI language such as `fr-FR`; the short reply is written in it.
    pub locale: String,
}

#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum AiAction {
    PlayChannel { item_id: i64 },
    ShowGuide { item_id: i64 },
    Search { query: String },
    NextChannel,
    PreviousChannel,
    MultiView { item_ids: Vec<i64> },
    None,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct AiCommandResult {
    pub action: AiAction,
    /// 0 to 5 channels to offer when the request is ambiguous or the provider failed.
    pub alternatives: Vec<IptvItemRecord>,
    pub reply: String,
    /// `"local"`, `"gemini"`, `"openai_compatible"` or `"anthropic"`.
    pub resolved_by: String,
    pub latency_ms: u64,
    pub fallback_reason: Option<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct AiProviderStatus {
    pub ok: bool,
    pub latency_ms: u64,
    pub model: String,
    /// Human readable: "Connexion réussie" or the reason of the failure.
    pub message: String,
}
