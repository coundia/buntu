//! Channel assistant: turns a spoken or typed command into an action on the player.
//!
//! Order of work: resolve locally (no network) -> if unsure, send a short list of candidates to the
//! user's own model provider -> validate the answer against that list -> otherwise fall back to a
//! choice offered to the user. Nothing here can start a channel that was not in the local catalog.

pub mod candidates;
pub mod intent;
pub mod local_matcher;
pub mod prompt;
pub mod providers;
#[cfg(test)]
pub(crate) mod test_support;

pub use intent::{
    AiAction, AiCommandContext, AiCommandResult, AiProviderConfig, AiProviderKind, AiProviderStatus,
};

use crate::db::{chrono_now_ts, IptvItemRecord};
use crate::telemetry::redact_text;
use crate::{CndEngine, CndError, LogLevel};
use candidates::Candidate;
use providers::{ModelDecision, RequestMode};
use std::time::{Duration, Instant};

const MAX_ALTERNATIVES: usize = 5;
const MAX_QUERY_CHARS: usize = 100;
const MAX_REPLY_CHARS: usize = 140;
const USER_AGENT: &str = "CndIPTV/1.0 (channel assistant)";

#[derive(Clone, Copy)]
enum Lang {
    Fr,
    En,
}

impl Lang {
    fn from_locale(locale: &str) -> Self {
        if locale.to_ascii_lowercase().starts_with("fr") { Lang::Fr } else { Lang::En }
    }

    fn pick(self, fr: &str, en: &str) -> String {
        match self {
            Lang::Fr => fr.to_string(),
            Lang::En => en.to_string(),
        }
    }
}

fn describe(engine: &CndEngine, item: &IptvItemRecord, now: i64) -> String {
    let programme = item
        .tvg_id
        .as_ref()
        .filter(|id| !id.trim().is_empty())
        .and_then(|id| engine.db.get_epg_now_next_at(std::slice::from_ref(id), now).ok())
        .and_then(|list| list.into_iter().next())
        .and_then(|entry| entry.now)
        .map(|p| p.title);
    match programme {
        Some(title) => format!("{} — {}", item.name, title),
        None => item.name.clone(),
    }
}

fn clean_reply(text: &str) -> String {
    let cleaned: String = text.chars().filter(|c| !c.is_control()).collect();
    cleaned.trim().chars().take(MAX_REPLY_CHARS).collect()
}

fn base_result(action: AiAction, reply: String, resolved_by: &str, started: Instant) -> AiCommandResult {
    AiCommandResult {
        action,
        alternatives: Vec::new(),
        reply,
        resolved_by: resolved_by.to_string(),
        latency_ms: started.elapsed().as_millis() as u64,
        fallback_reason: None,
    }
}

pub(crate) async fn resolve(
    engine: &CndEngine,
    command: String,
    context: AiCommandContext,
    config: AiProviderConfig,
) -> Result<AiCommandResult, CndError> {
    let started = Instant::now();
    let now = chrono_now_ts();
    let lang = Lang::from_locale(&context.locale);
    let command = command.trim().to_string();

    if command.is_empty() {
        return Ok(base_result(
            AiAction::None,
            lang.pick("Dites ou tapez le nom d'une chaîne.", "Say or type a channel name."),
            "local",
            started,
        ));
    }

    // 1. Local resolution: no network, no provider.
    let local = local_matcher::resolve_local(&engine.db, &command, &context, now)?;
    if let Some(action) = local.action.clone() {
        let reply = match &action {
            AiAction::PlayChannel { item_id } | AiAction::ShowGuide { item_id } => engine
                .db
                .get_item_by_id(*item_id)?
                .map(|item| describe(engine, &item, now))
                .unwrap_or_default(),
            AiAction::NextChannel => lang.pick("Chaîne suivante", "Next channel"),
            AiAction::PreviousChannel => lang.pick("Chaîne précédente", "Previous channel"),
            AiAction::MultiView { item_ids } => {
                let mut names = Vec::new();
                for id in item_ids {
                    if let Ok(Some(item)) = engine.db.get_item_by_id(*id) {
                        names.push(item.name);
                    }
                }
                format!("Mosaïque : {}", names.join(" + "))
            }
            AiAction::None if local.note == Some("back_without_history") => lang.pick(
                "Aucune autre chaîne dans l'historique.",
                "No other channel in the history.",
            ),
            AiAction::Search { query } => query.clone(),
            AiAction::None => String::new(),
        };
        let result = base_result(action, reply, "local", started);
        log_outcome(engine, &config, &result);
        return Ok(result);
    }

    // 2. Provider usable?
    let unusable = match config.kind {
        AiProviderKind::LocalOnly => Some(None),
        _ if config.requires_key() && config.key().is_none() => Some(Some("clé API absente".to_string())),
        _ => None,
    };
    if let Some(reason) = unusable {
        let result = offer_choice(
            engine, lang, &command, local.candidates.to_vec(),
            "local", reason, started,
        );
        log_outcome(engine, &config, &result);
        return Ok(result);
    }

    // 3. Ask the model, with a bounded list of candidates.
    let gathered = candidates::gather(&engine.db, &command, &context, local.candidates.clone(), now)?;
    if gathered.is_empty() {
        let result = offer_choice(engine, lang, &command, Vec::new(), "local", None, started);
        log_outcome(engine, &config, &result);
        return Ok(result);
    }

    let playing_name = context
        .playing_stable_hash
        .as_deref()
        .and_then(|hash| find_by_hash(engine, hash));
    let system = prompt::system_prompt(&context.locale);
    let user = prompt::user_prompt(&command, playing_name.as_deref(), &gathered);

    let outcome = match call_provider(engine, &config, &system, &user).await {
        Ok(decision) => validate(&decision, &gathered),
        Err(reason) => Err(reason),
    };

    let provider = config.kind.label();
    let result = match outcome {
        Ok((action, model_reply)) => {
            let reply = match &action {
                AiAction::PlayChannel { item_id } | AiAction::ShowGuide { item_id } => gathered
                    .iter()
                    .find(|c| c.item.id == *item_id)
                    .map(|c| describe(engine, &c.item, now))
                    .unwrap_or_default(),
                _ => model_reply.unwrap_or_default(),
            };
            base_result(action, reply, provider, started)
        }
        Err(reason) => {
            let items = gathered.into_iter().map(|c| c.item).collect();
            offer_choice(engine, lang, &command, items, provider, Some(reason), started)
        }
    };
    log_outcome(engine, &config, &result);
    Ok(result)
}

fn find_by_hash(engine: &CndEngine, hash: &str) -> Option<String> {
    engine
        .db
        .with_conn(|conn| {
            use rusqlite::OptionalExtension;
            conn.query_row("SELECT name FROM iptv_items WHERE stable_hash = ?1", [hash], |r| r.get::<_, String>(0))
                .optional()
                .map_err(crate::db::DbError::from)
        })
        .ok()
        .flatten()
}

/// The user picks: up to five candidates, or a plain search when there is none.
fn offer_choice(
    _engine: &CndEngine,
    lang: Lang,
    command: &str,
    items: Vec<IptvItemRecord>,
    resolved_by: &str,
    fallback_reason: Option<String>,
    started: Instant,
) -> AiCommandResult {
    let alternatives: Vec<IptvItemRecord> = items.into_iter().take(MAX_ALTERNATIVES).collect();
    let (action, reply) = if alternatives.is_empty() {
        (
            AiAction::Search { query: command.chars().take(MAX_QUERY_CHARS).collect() },
            lang.pick("Aucune chaîne trouvée : recherche dans le catalogue.", "No channel found: searching the catalog."),
        )
    } else {
        (
            AiAction::None,
            lang.pick("Plusieurs chaînes possibles, choisissez-en une.", "Several channels fit, pick one."),
        )
    };
    AiCommandResult {
        action,
        alternatives,
        reply,
        resolved_by: resolved_by.to_string(),
        latency_ms: started.elapsed().as_millis() as u64,
        fallback_reason,
    }
}

/// Accepts the model's answer only if it names a candidate it was given.
fn validate(decision: &ModelDecision, candidates: &[Candidate]) -> Result<(AiAction, Option<String>), String> {
    let reply = decision.reply.as_deref().map(clean_reply).filter(|r| !r.is_empty());
    let known = |id: i64| candidates.iter().any(|c| c.item.id == id);
    match decision.action.trim().to_ascii_lowercase().as_str() {
        "play" => match decision.item_id {
            Some(id) if known(id) => Ok((AiAction::PlayChannel { item_id: id }, reply)),
            _ => Err("réponse invalide : chaîne inconnue".to_string()),
        },
        "guide" => match decision.item_id {
            Some(id) if known(id) => Ok((AiAction::ShowGuide { item_id: id }, reply)),
            _ => Err("réponse invalide : chaîne inconnue".to_string()),
        },
        "search" => {
            let query: String = decision
                .query
                .as_deref()
                .unwrap_or("")
                .chars()
                .filter(|c| !c.is_control())
                .take(MAX_QUERY_CHARS)
                .collect();
            if query.trim().is_empty() {
                Err("réponse invalide : recherche vide".to_string())
            } else {
                Ok((AiAction::Search { query: query.trim().to_string() }, reply))
            }
        }
        "next" => Ok((AiAction::NextChannel, reply)),
        "previous" => Ok((AiAction::PreviousChannel, reply)),
        "multiview" => {
            let ids = decision.item_ids.as_deref().unwrap_or(&[]);
            let valid_ids: Vec<i64> = ids.iter().copied().filter(|id| known(*id)).collect();
            if valid_ids.len() >= 2 && valid_ids.len() <= 4 {
                Ok((AiAction::MultiView { item_ids: valid_ids }, reply))
            } else {
                Err("réponse invalide : mosaïque avec moins de 2 chaînes valides".to_string())
            }
        }
        "none" => Ok((AiAction::None, reply)),
        _ => Err("réponse invalide : action inconnue".to_string()),
    }
}

/// One provider round-trip for a channel command.
async fn call_provider(
    engine: &CndEngine,
    config: &AiProviderConfig,
    system: &str,
    user: &str,
) -> Result<ModelDecision, String> {
    let text = call_provider_text(engine, config, system, user, providers::Task::Command).await?;
    providers::parse_decision(&text)
}

/// One provider round-trip, with the two retries that are worth it: a lighter response format when
/// the server rejects the schema, and a single retry after a short rate-limit pause. Returns the text
/// (a JSON document) the model produced; the caller parses and validates it.
pub(crate) async fn call_provider_text(
    engine: &CndEngine,
    config: &AiProviderConfig,
    system: &str,
    user: &str,
    task: providers::Task,
) -> Result<String, String> {
    let timeout = Duration::from_millis(config.effective_timeout_ms());
    let deadline = Instant::now() + timeout;
    let mut mode = RequestMode::Strict;
    let mut downgraded = false;
    let mut rate_limited = false;

    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err("délai dépassé".to_string());
        }
        let request = providers::build_request_for(config, system, user, mode, task)?;
        let (status, retry_after, body) = send(engine, config, &request, remaining).await?;
        if (200..300).contains(&status) {
            let json: serde_json::Value =
                serde_json::from_str(&body).map_err(|_| "réponse non JSON du fournisseur".to_string())?;
            return providers::extract_text(config.kind, &json);
        }
        if status == 429 && !rate_limited && retry_after.unwrap_or(1) <= 2 {
            rate_limited = true;
            tokio::time::sleep(Duration::from_secs(retry_after.unwrap_or(1))).await;
            continue;
        }
        if !downgraded && mode == RequestMode::Strict && providers::is_schema_rejection(status, &body) {
            downgraded = true;
            mode = RequestMode::Light;
            continue;
        }
        return Err(providers::explain_http_error(status, &body, config.key()));
    }
}

/// Sends through the shared client but **not** through `send_logged`: that one would add the
/// user's IPTV default Referer and cookies, which must never reach a model provider.
async fn send(
    engine: &CndEngine,
    config: &AiProviderConfig,
    request: &providers::ProviderRequest,
    timeout: Duration,
) -> Result<(u16, Option<u64>, String), String> {
    let client = engine.http_pool.client().map_err(|e| e.to_string())?;
    let mut builder = client
        .post(&request.url)
        .timeout(timeout)
        .header("user-agent", USER_AGENT)
        .json(&request.body);
    for (name, value) in &request.headers {
        builder = builder.header(*name, value);
    }

    let started = Instant::now();
    let outcome = builder.send().await;
    let elapsed = started.elapsed().as_millis() as u64;
    match outcome {
        Ok(response) => {
            let status = response.status().as_u16();
            let retry_after = response
                .headers()
                .get("retry-after")
                .and_then(|v| v.to_str().ok())
                .and_then(|v| v.trim().parse::<u64>().ok());
            let body = response.text().await.unwrap_or_default();
            let level = match status {
                500..=599 => LogLevel::Error,
                400..=499 => LogLevel::Warn,
                _ => LogLevel::Info,
            };
            engine.telemetry.record(
                level,
                "AI",
                Some("POST"),
                Some(&request.url),
                Some(status),
                Some(elapsed),
                format!("{} HTTP {status} ({elapsed} ms)", config.kind.label()),
            );
            Ok((status, retry_after, body))
        }
        Err(err) => {
            engine.telemetry.record(
                LogLevel::Error,
                "AI",
                Some("POST"),
                Some(&request.url),
                None,
                Some(elapsed),
                format!("{} : {}", config.kind.label(), redact_text(&err.to_string())),
            );
            Err(if err.is_timeout() {
                "délai dépassé".to_string()
            } else if err.is_connect() {
                "fournisseur injoignable".to_string()
            } else {
                "erreur réseau".to_string()
            })
        }
    }
}

/// What is logged: provider, how it was resolved and how long it took. Not the user's phrase.
fn log_outcome(engine: &CndEngine, config: &AiProviderConfig, result: &AiCommandResult) {
    let action = match &result.action {
        AiAction::PlayChannel { .. } => "play",
        AiAction::ShowGuide { .. } => "guide",
        AiAction::Search { .. } => "search",
        AiAction::NextChannel => "next",
        AiAction::PreviousChannel => "previous",
        AiAction::MultiView { .. } => "multiview",
        AiAction::None => "none",
    };
    let fallback = result
        .fallback_reason
        .as_deref()
        .map(|r| format!(", repli : {r}"))
        .unwrap_or_default();
    engine.telemetry.info(
        "AI",
        format!(
            "Commande résolue par {} (fournisseur {}) : {action} en {} ms{fallback}",
            result.resolved_by,
            config.kind.label(),
            result.latency_ms
        ),
    );
}

pub(crate) async fn test_provider(
    engine: &CndEngine,
    config: AiProviderConfig,
) -> Result<AiProviderStatus, CndError> {
    let model = config.effective_model();
    if config.kind == AiProviderKind::LocalOnly {
        return Ok(AiProviderStatus {
            ok: true,
            latency_ms: 0,
            model,
            message: "Mode local : aucun fournisseur à tester.".to_string(),
        });
    }
    let system = "Answer with a single JSON object.";
    let user = "Reply with action \"none\", item_id null, query null and reply \"ok\".";
    let started = Instant::now();
    let probe = AiProviderConfig { timeout_ms: config.timeout_ms.max(1_000), ..config.clone() };
    let outcome = call_provider(engine, &probe, system, user).await;
    let latency_ms = started.elapsed().as_millis() as u64;
    Ok(match outcome {
        Ok(_) => AiProviderStatus { ok: true, latency_ms, model, message: "Connexion réussie.".to_string() },
        Err(reason) => AiProviderStatus { ok: false, latency_ms, model, message: reason },
    })
}

#[cfg(test)]
mod tests;
