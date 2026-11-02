//! Sharing of IPTV sources between devices or with someone else.
//!
//! This module builds, reads and imports the **plain** share document (JSON). Encryption, the
//! share code, files, links and QR codes are handled on the Swift side with CryptoKit.
//!
//! A document holds only what defines a source: name, type, server, user name, URLs and, when the
//! sender asks for it, the password or the content of a local playlist. Never the catalog, the
//! guide, favorites, history, downloads or API keys.

pub mod credentials;

use crate::db::{chrono_now_ts, DbError, IptvSourceRecord};
use crate::iptv::xtream::normalize_server_base;
use crate::{CndEngine, CndError};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

pub const FORMAT: &str = "cnd-source-share";
pub const VERSION: u32 = 1;
pub const MAX_SOURCES: usize = 50;
pub const MAX_PLAYLIST_BYTES: u64 = 20 * 1024 * 1024;
const MAX_FIELD_CHARS: usize = 4096;
const MAX_NAME_CHARS: usize = 200;
const SHARE_PLAYLIST_SOURCE_PREFIX: &str = "file://";

// MARK: - Document

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
struct ShareDocument {
    format: String,
    version: u32,
    created_at: i64,
    expires_at: i64,
    from: String,
    sources: Vec<ShareSourceDoc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(default)]
struct ShareSourceDoc {
    name: String,
    #[serde(rename = "type")]
    source_type: String,
    server: Option<String>,
    username: Option<String>,
    password: Option<String>,
    url: Option<String>,
    epg_url: Option<String>,
    /// Content of a local playlist, when the sender attached it.
    playlist: Option<String>,
    /// Something was removed from a URL or the password is missing: the recipient must fill it in.
    needs_credentials: bool,
}

// MARK: - UniFFI types

#[derive(Debug, Clone, uniffi::Record)]
pub struct ShareSourceOption {
    pub source_id: i64,
    /// Include the password and the credentials found in URLs (inside the encrypted envelope).
    pub include_credentials: bool,
    /// The password read from the Keychain by the app; used only when `include_credentials`.
    pub password: Option<String>,
    /// For a local (`file://`) playlist: attach its content.
    pub include_playlist: bool,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct ShareWarning {
    pub source_name: String,
    /// `url_credentials_removed`, `password_not_included`, `local_file_not_shared`,
    /// `local_file_missing`, `playlist_too_large`.
    pub kind: String,
    pub detail: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct ShareExport {
    pub json: String,
    pub source_count: u32,
    pub warnings: Vec<ShareWarning>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct SharePreviewSource {
    pub index: u32,
    pub name: String,
    pub source_type: String,
    pub server: Option<String>,
    pub username: Option<String>,
    /// Address with its credentials blanked, for display only.
    pub url_display: Option<String>,
    pub has_password: bool,
    pub has_playlist: bool,
    pub needs_credentials: bool,
    pub duplicate_of: Option<i64>,
    pub duplicate_name: Option<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct SharePreview {
    pub from: String,
    pub created_at: i64,
    pub expires_at: i64,
    pub sources: Vec<SharePreviewSource>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ShareImportAction {
    Skip,
    /// Create a new source (even when one like it exists).
    Import,
    /// Update the existing source recognised as the same.
    Replace,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct ShareDecision {
    pub index: u32,
    pub action: ShareImportAction,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct ShareImportedSource {
    pub source_id: i64,
    pub uuid: String,
    pub name: String,
    pub source_type: String,
    /// To be stored in the Keychain by the app (`cnd.xtream.<uuid>`); never persisted here.
    pub password: Option<String>,
    pub replaced: bool,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct ShareImportResult {
    pub imported: Vec<ShareImportedSource>,
    pub skipped: u32,
}

// MARK: - Helpers

fn parse_error(message: impl Into<String>) -> CndError {
    CndError::Parse { message: message.into() }
}

fn clean(text: &str) -> String {
    text.chars().filter(|c| !c.is_control()).collect::<String>().trim().to_string()
}

fn is_http_url(value: &str) -> bool {
    let lower = value.trim().to_ascii_lowercase();
    (lower.starts_with("http://") || lower.starts_with("https://")) && url::Url::parse(value.trim()).is_ok()
}

fn local_path(url: &str) -> Option<PathBuf> {
    url.strip_prefix(SHARE_PLAYLIST_SOURCE_PREFIX).map(PathBuf::from)
}

/// The key two devices use to recognise the same source.
fn duplicate_key(source_type: &str, server: Option<&str>, username: Option<&str>, url: Option<&str>) -> Option<String> {
    if source_type == "xtream" {
        let server = normalize_server_base(server?).to_ascii_lowercase();
        Some(format!("xtream|{server}|{}", username.unwrap_or("").trim().to_ascii_lowercase()))
    } else {
        let url = url?;
        if url.starts_with(SHARE_PLAYLIST_SOURCE_PREFIX) {
            return None;
        }
        Some(format!("m3u|{}", credentials::endpoint_key(url)))
    }
}

fn existing_key(source: &IptvSourceRecord) -> Option<String> {
    duplicate_key(&source.source_type, source.server.as_deref(), source.username.as_deref(), source.url.as_deref())
}

fn find_duplicate(existing: &[IptvSourceRecord], doc: &ShareSourceDoc) -> Option<IptvSourceRecord> {
    let key = duplicate_key(&doc.source_type, doc.server.as_deref(), doc.username.as_deref(), doc.url.as_deref())?;
    existing.iter().find(|s| existing_key(s).as_deref() == Some(key.as_str())).cloned()
}

fn read_playlist(path: &Path) -> Result<String, &'static str> {
    let meta = std::fs::metadata(path).map_err(|_| "local_file_missing")?;
    if meta.len() > MAX_PLAYLIST_BYTES {
        return Err("playlist_too_large");
    }
    std::fs::read_to_string(path).map_err(|_| "local_file_missing")
}

// MARK: - Export

pub(crate) fn export(
    engine: &CndEngine,
    options: Vec<ShareSourceOption>,
    from: String,
    valid_for_seconds: u32,
) -> Result<ShareExport, CndError> {
    if options.is_empty() {
        return Err(parse_error("Aucune source à partager."));
    }
    if options.len() > MAX_SOURCES {
        return Err(parse_error(format!("Au plus {MAX_SOURCES} sources par partage.")));
    }
    let now = chrono_now_ts();
    let mut warnings = Vec::new();
    let mut sources = Vec::new();

    for option in &options {
        let record = engine.db.get_source_by_id(option.source_id)?;
        let warn = |kind: &str, detail: &str| ShareWarning {
            source_name: record.name.clone(),
            kind: kind.to_string(),
            detail: detail.to_string(),
        };
        let mut doc = ShareSourceDoc {
            name: clean(&record.name).chars().take(MAX_NAME_CHARS).collect(),
            source_type: record.source_type.clone(),
            username: record.username.clone(),
            ..Default::default()
        };

        // URLs: kept as they are only when the sender included the credentials.
        let shape = |url: &str, doc_flag: &mut bool, warnings: &mut Vec<ShareWarning>| -> String {
            if option.include_credentials {
                return url.to_string();
            }
            let stripped = credentials::strip_credentials(url);
            if stripped.removed {
                *doc_flag = true;
                warnings.push(warn("url_credentials_removed", "Les identifiants contenus dans l'adresse ont été retirés."));
            }
            stripped.url
        };

        let mut needs = false;
        doc.epg_url = record.epg_url.as_deref().map(|u| shape(u, &mut needs, &mut warnings));

        if record.source_type == "xtream" {
            doc.server = record.server.clone();
            if option.include_credentials {
                doc.password = option.password.clone().filter(|p| !p.is_empty());
            }
            if doc.password.is_none() {
                needs = true;
                warnings.push(warn("password_not_included", "Le destinataire devra saisir le mot de passe."));
            }
        } else {
            let url = record.url.clone().unwrap_or_default();
            if let Some(path) = local_path(&url) {
                if !option.include_playlist {
                    warnings.push(warn("local_file_not_shared", "Playlist locale : joignez son contenu pour la partager."));
                    continue;
                }
                match read_playlist(&path) {
                    Ok(content) => doc.playlist = Some(content),
                    Err(kind) => {
                        let detail = if kind == "playlist_too_large" { "Playlist de plus de 20 Mo." } else { "Fichier introuvable." };
                        warnings.push(warn(kind, detail));
                        continue;
                    }
                }
            } else {
                doc.url = Some(shape(&url, &mut needs, &mut warnings));
            }
        }
        doc.needs_credentials = needs;
        sources.push(doc);
    }

    if sources.is_empty() {
        return Err(parse_error("Aucune des sources choisies ne peut être partagée."));
    }
    let valid_for = i64::from(valid_for_seconds.clamp(60, 30 * 86_400));
    let document = ShareDocument {
        format: FORMAT.to_string(),
        version: VERSION,
        created_at: now,
        expires_at: now + valid_for,
        from: clean(&from).chars().take(MAX_NAME_CHARS).collect(),
        sources,
    };
    let json = serde_json::to_string(&document).map_err(|e| CndError::Internal { message: e.to_string() })?;
    Ok(ShareExport { json, source_count: document.sources.len() as u32, warnings })
}

// MARK: - Validation

fn read_document(json: &str, now: i64) -> Result<ShareDocument, CndError> {
    let document: ShareDocument =
        serde_json::from_str(json).map_err(|_| parse_error("Ce fichier n'est pas un partage de sources valide."))?;
    if document.format != FORMAT {
        return Err(parse_error("Ce fichier n'est pas un partage de sources CND IPTV."));
    }
    if document.version != VERSION {
        return Err(parse_error(format!(
            "Version de partage non prise en charge ({}). Mettez l'application à jour.",
            document.version
        )));
    }
    if document.expires_at <= now {
        return Err(parse_error("Ce partage a expiré."));
    }
    if document.sources.is_empty() || document.sources.len() > MAX_SOURCES {
        return Err(parse_error("Nombre de sources invalide dans ce partage."));
    }
    for source in &document.sources {
        validate_source(source)?;
    }
    Ok(document)
}

fn validate_source(source: &ShareSourceDoc) -> Result<(), CndError> {
    let name = clean(&source.name);
    if name.is_empty() || name.chars().count() > MAX_NAME_CHARS {
        return Err(parse_error("Nom de source invalide."));
    }
    let check_url = |value: &Option<String>, label: &str| -> Result<(), CndError> {
        if let Some(value) = value.as_deref().filter(|v| !v.trim().is_empty()) {
            if value.chars().count() > MAX_FIELD_CHARS || !is_http_url(value) {
                return Err(parse_error(format!("{label} invalide : seules les adresses http:// et https:// sont acceptées.")));
            }
        }
        Ok(())
    };
    check_url(&source.epg_url, "Adresse du guide")?;
    match source.source_type.as_str() {
        "xtream" => {
            let server = source.server.as_deref().unwrap_or("").trim();
            if server.is_empty() || source.username.as_deref().unwrap_or("").trim().is_empty() {
                return Err(parse_error("Source Xtream incomplète (serveur ou utilisateur manquant)."));
            }
            check_url(&Some(normalize_server_base(server)), "Adresse du serveur")?;
        }
        "m3u" => {
            let has_url = source.url.as_deref().map(|u| !u.trim().is_empty()).unwrap_or(false);
            let has_playlist = source.playlist.as_deref().map(|p| !p.is_empty()).unwrap_or(false);
            if has_url == has_playlist {
                return Err(parse_error("Une source M3U doit avoir une adresse ou une playlist jointe, pas les deux."));
            }
            check_url(&source.url, "Adresse de la playlist")?;
            if source.playlist.as_deref().map(|p| p.len() as u64 > MAX_PLAYLIST_BYTES).unwrap_or(false) {
                return Err(parse_error("Playlist jointe trop volumineuse."));
            }
        }
        other => return Err(parse_error(format!("Type de source inconnu : {other}."))),
    }
    Ok(())
}

// MARK: - Preview

pub(crate) fn preview(engine: &CndEngine, json: &str) -> Result<SharePreview, CndError> {
    let document = read_document(json, chrono_now_ts())?;
    let existing = engine.db.list_sources()?;
    let sources = document
        .sources
        .iter()
        .enumerate()
        .map(|(index, source)| {
            let duplicate = find_duplicate(&existing, source);
            SharePreviewSource {
                index: index as u32,
                name: clean(&source.name),
                source_type: source.source_type.clone(),
                server: source.server.clone(),
                username: source.username.clone(),
                url_display: source.url.as_deref().map(|u| credentials::strip_credentials(u).url),
                has_password: source.password.as_deref().map(|p| !p.is_empty()).unwrap_or(false),
                has_playlist: source.playlist.is_some(),
                needs_credentials: source.needs_credentials,
                duplicate_of: duplicate.as_ref().map(|d| d.id),
                duplicate_name: duplicate.map(|d| d.name),
            }
        })
        .collect();
    Ok(SharePreview { from: document.from, created_at: document.created_at, expires_at: document.expires_at, sources })
}

// MARK: - Import

fn safe_file_name(name: &str) -> String {
    let cleaned: String = name
        .chars()
        .map(|c| if c.is_alphanumeric() || c == '-' || c == '_' || c == ' ' { c } else { '_' })
        .collect();
    let trimmed = cleaned.trim().chars().take(60).collect::<String>();
    if trimmed.is_empty() { "playlist".to_string() } else { trimmed }
}

pub(crate) fn import(
    engine: &CndEngine,
    json: &str,
    decisions: Vec<ShareDecision>,
    imports_dir: &str,
) -> Result<ShareImportResult, CndError> {
    let document = read_document(json, chrono_now_ts())?;
    let existing = engine.db.list_sources()?;
    let mut imported = Vec::new();
    let mut skipped = 0u32;

    for (index, source) in document.sources.iter().enumerate() {
        let duplicate = find_duplicate(&existing, source);
        let action = decisions
            .iter()
            .find(|d| d.index as usize == index)
            .map(|d| d.action)
            .unwrap_or(if duplicate.is_some() { ShareImportAction::Skip } else { ShareImportAction::Import });
        let name = clean(&source.name);
        let epg = source.epg_url.as_deref().map(str::trim).filter(|e| !e.is_empty());

        match (action, duplicate) {
            (ShareImportAction::Skip, _) => skipped += 1,
            (ShareImportAction::Replace, Some(current)) => {
                if source.source_type == "xtream" {
                    engine.db.update_xtream_source(
                        current.id,
                        &name,
                        &normalize_server_base(source.server.as_deref().unwrap_or("")),
                        source.username.as_deref().unwrap_or("").trim(),
                        None,
                        epg,
                    )?;
                } else if let Some(url) = source.url.as_deref() {
                    engine.db.update_source(current.id, &name, Some(url.trim()), epg)?;
                } else {
                    skipped += 1;
                    continue;
                }
                imported.push(ShareImportedSource {
                    source_id: current.id,
                    uuid: current.uuid,
                    name,
                    source_type: source.source_type.clone(),
                    password: source.password.clone().filter(|p| !p.is_empty()),
                    replaced: true,
                });
            }
            // "Replace" with nothing to replace behaves like "Import".
            (ShareImportAction::Import, _) | (ShareImportAction::Replace, None) => {
                let (id, record) = create_source(engine, source, &name, epg, imports_dir)?;
                imported.push(ShareImportedSource {
                    source_id: id,
                    uuid: record.uuid,
                    name,
                    source_type: source.source_type.clone(),
                    password: source.password.clone().filter(|p| !p.is_empty()),
                    replaced: false,
                });
            }
        }
    }

    engine.telemetry.info("SHARE", format!("Imported {} source(s), skipped {skipped}", imported.len()));
    Ok(ShareImportResult { imported, skipped })
}

fn create_source(
    engine: &CndEngine,
    source: &ShareSourceDoc,
    name: &str,
    epg: Option<&str>,
    imports_dir: &str,
) -> Result<(i64, IptvSourceRecord), CndError> {
    let id = if source.source_type == "xtream" {
        let id = engine.db.add_source(
            name,
            "xtream",
            None,
            Some(&normalize_server_base(source.server.as_deref().unwrap_or(""))),
            Some(source.username.as_deref().unwrap_or("").trim()),
            None,
        )?;
        if epg.is_some() {
            let created = engine.db.get_source_by_id(id)?;
            engine.db.update_xtream_source(
                id,
                name,
                created.server.as_deref().unwrap_or(""),
                created.username.as_deref().unwrap_or(""),
                None,
                epg,
            )?;
        }
        id
    } else {
        let url = match (&source.url, &source.playlist) {
            (Some(url), _) if !url.trim().is_empty() => url.trim().to_string(),
            (_, Some(content)) => {
                let dir = Path::new(imports_dir);
                std::fs::create_dir_all(dir).map_err(|e| CndError::Io { message: format!("Création du dossier d'import impossible : {e}") })?;
                let nanos = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|d| d.as_nanos())
                    .unwrap_or(0);
                let path = dir.join(format!("shared-{nanos}-{}.m3u", safe_file_name(name)));
                std::fs::write(&path, content)
                    .map_err(|e| CndError::Io { message: format!("Écriture de la playlist impossible : {e}") })?;
                format!("{SHARE_PLAYLIST_SOURCE_PREFIX}{}", path.display())
            }
            _ => return Err(parse_error("Source M3U sans adresse.")),
        };
        let id = engine.db.add_source(name, "m3u", Some(&url), None, None, None)?;
        if epg.is_some() {
            engine.db.update_source(id, name, Some(&url), epg)?;
        }
        id
    };
    let record = engine.db.get_source_by_id(id).map_err(|e: DbError| CndError::from(e))?;
    Ok((id, record))
}

#[cfg(test)]
mod tests;
