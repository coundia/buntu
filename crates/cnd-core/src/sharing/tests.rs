use super::*;
use serde_json::Value;
use std::sync::Arc;

fn engine() -> Arc<CndEngine> {
    CndEngine::in_memory().expect("engine")
}

fn opt(source_id: i64, credentials: bool, password: Option<&str>, playlist: bool) -> ShareSourceOption {
    ShareSourceOption {
        source_id,
        include_credentials: credentials,
        password: password.map(str::to_string),
        include_playlist: playlist,
    }
}

fn add_xtream(e: &CndEngine, name: &str, server: &str, user: &str) -> i64 {
    e.db.add_source(name, "xtream", None, Some(server), Some(user), Some("cnd.xtream.local")).unwrap()
}

fn export_one(e: &CndEngine, option: ShareSourceOption) -> ShareExport {
    e.export_share_document(vec![option], "Le Mac de Papa".into(), 3_600).unwrap()
}

fn tmp() -> PathBuf {
    let dir = std::env::temp_dir().join(format!("cnd-share-{}", std::process::id())).join(format!("{:?}", std::thread::current().id()).replace(['(', ')'], ""));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn mutate(json: &str, change: impl FnOnce(&mut Value)) -> String {
    let mut value: Value = serde_json::from_str(json).unwrap();
    change(&mut value);
    value.to_string()
}

#[test]
fn an_xtream_source_travels_with_its_password_only_when_asked() {
    let a = engine();
    let b = engine();
    let id = add_xtream(&a, "Premium", "http://srv.example:8080", "alice");

    let with = export_one(&a, opt(id, true, Some("s3cret-pw"), false));
    assert!(with.warnings.is_empty(), "{:?}", with.warnings);
    let imported = b.import_share_document(with.json.clone(), vec![], tmp().display().to_string()).unwrap();
    assert_eq!(imported.imported.len(), 1);
    assert_eq!(imported.imported[0].password.as_deref(), Some("s3cret-pw"));
    let source = b.db.get_source_by_id(imported.imported[0].source_id).unwrap();
    assert_eq!((source.source_type.as_str(), source.server.as_deref(), source.username.as_deref()), ("xtream", Some("http://srv.example:8080"), Some("alice")));
    assert_eq!(source.passwordRef_for_test(), None, "the password reference is set by the app, which stores the secret");

    let without = export_one(&a, opt(id, false, Some("s3cret-pw"), false));
    assert!(!without.json.contains("s3cret-pw"), "the password must not be in the document");
    assert!(without.warnings.iter().any(|w| w.kind == "password_not_included"));
    let no_password = b.import_share_document(without.json, vec![ShareDecision { index: 0, action: ShareImportAction::Import }], tmp().display().to_string()).unwrap();
    assert_eq!(no_password.imported[0].password, None);
}

trait SourceExt {
    #[allow(non_snake_case)]
    fn passwordRef_for_test(&self) -> Option<String>;
}
impl SourceExt for IptvSourceRecord {
    #[allow(non_snake_case)]
    fn passwordRef_for_test(&self) -> Option<String> {
        self.password_ref.clone()
    }
}

#[test]
fn credentials_in_a_playlist_url_are_removed_unless_included() {
    let a = engine();
    let url = "http://srv:8080/get.php?username=bob&password=hunter2&type=m3u_plus";
    let id = a.db.add_source("Playlist", "m3u", Some(url), None, None, None).unwrap();

    let plain = export_one(&a, opt(id, false, None, false));
    assert!(!plain.json.contains("hunter2") && !plain.json.contains("bob"), "{}", plain.json);
    assert!(plain.json.contains("username=&password="));
    assert!(plain.warnings.iter().any(|w| w.kind == "url_credentials_removed"));
    let doc: Value = serde_json::from_str(&plain.json).unwrap();
    assert_eq!(doc["sources"][0]["needs_credentials"], true);

    let full = export_one(&a, opt(id, true, None, false));
    assert!(full.json.contains("hunter2"));
    assert!(full.warnings.is_empty());
    assert_eq!(serde_json::from_str::<Value>(&full.json).unwrap()["sources"][0]["needs_credentials"], false);
}

#[test]
fn the_guide_url_is_treated_like_the_playlist_url() {
    let a = engine();
    let id = a.db.add_source("P", "m3u", Some("http://h/list.m3u"), None, None, None).unwrap();
    a.db.update_source(id, "P", Some("http://h/list.m3u"), Some("http://h/xmltv.php?username=u1&password=p1")).unwrap();
    let plain = export_one(&a, opt(id, false, None, false));
    assert!(!plain.json.contains("p1") && plain.json.contains("xmltv.php"));
}

#[test]
fn a_local_playlist_is_attached_and_recreated_on_the_other_device() {
    let a = engine();
    let b = engine();
    let dir = tmp();
    let file = dir.join("mine.m3u");
    std::fs::write(&file, "#EXTM3U\n#EXTINF:-1,Chaine\nhttp://h/1.ts\n").unwrap();
    let id = a.db.add_source("Locale", "m3u", Some(&format!("file://{}", file.display())), None, None, None).unwrap();

    let not_attached = a.export_share_document(vec![opt(id, false, None, false)], "x".into(), 3_600);
    assert!(not_attached.is_err(), "nothing shareable: the only source is a local file left out");

    let two = a.db.add_source("Distante", "m3u", Some("http://h/l.m3u"), None, None, None).unwrap();
    let mixed = a.export_share_document(vec![opt(id, false, None, false), opt(two, false, None, false)], "x".into(), 3_600).unwrap();
    assert_eq!(mixed.source_count, 1);
    assert!(mixed.warnings.iter().any(|w| w.kind == "local_file_not_shared"));

    let shared = export_one(&a, opt(id, false, None, true));
    assert!(shared.json.contains("#EXTINF"));
    let imports = dir.join("imports");
    let result = b.import_share_document(shared.json, vec![], imports.display().to_string()).unwrap();
    let created = b.db.get_source_by_id(result.imported[0].source_id).unwrap();
    let path = created.url.unwrap().strip_prefix("file://").unwrap().to_string();
    assert!(path.starts_with(&imports.display().to_string()), "{path}");
    assert_eq!(std::fs::read_to_string(path).unwrap(), "#EXTM3U\n#EXTINF:-1,Chaine\nhttp://h/1.ts\n");
}

#[test]
fn missing_or_huge_local_playlists_are_reported_not_attached() {
    let a = engine();
    let dir = tmp();
    let remote = a.db.add_source("Remote", "m3u", Some("http://h/l.m3u"), None, None, None).unwrap();
    let missing = a.db.add_source("Gone", "m3u", Some("file:///no/such/file.m3u"), None, None, None).unwrap();
    let huge_path = dir.join("huge.m3u");
    let file = std::fs::File::create(&huge_path).unwrap();
    file.set_len(MAX_PLAYLIST_BYTES + 1).unwrap();
    let huge = a.db.add_source("Huge", "m3u", Some(&format!("file://{}", huge_path.display())), None, None, None).unwrap();

    let export = a.export_share_document(vec![opt(remote, false, None, true), opt(missing, false, None, true), opt(huge, false, None, true)], "x".into(), 3_600).unwrap();
    let kinds: Vec<&str> = export.warnings.iter().map(|w| w.kind.as_str()).collect();
    assert!(kinds.contains(&"local_file_missing") && kinds.contains(&"playlist_too_large"), "{kinds:?}");
    assert_eq!(export.source_count, 1);
}

#[test]
fn a_document_is_validated_before_anything_is_imported() {
    let a = engine();
    let b = engine();
    let id = add_xtream(&a, "Premium", "http://srv:80", "alice");
    let good = export_one(&a, opt(id, false, None, false)).json;
    let dir = tmp().display().to_string();
    let before = b.db.list_sources().unwrap().len();

    let bad: Vec<(&str, String)> = vec![
        ("expired", mutate(&good, |v| v["expires_at"] = 1.into())),
        ("format", mutate(&good, |v| v["format"] = "other".into())),
        ("version", mutate(&good, |v| v["version"] = 99.into())),
        ("type", mutate(&good, |v| v["sources"][0]["type"] = "ftp".into())),
        ("no name", mutate(&good, |v| v["sources"][0]["name"] = "  ".into())),
        ("no user", mutate(&good, |v| v["sources"][0]["username"] = Value::Null)),
        ("file url epg", mutate(&good, |v| v["sources"][0]["epg_url"] = "file:///etc/passwd".into())),
        ("script url", mutate(&good, |v| { v["sources"][0]["type"] = "m3u".into(); v["sources"][0]["url"] = "javascript:alert(1)".into(); })),
        ("m3u with both", mutate(&good, |v| { v["sources"][0]["type"] = "m3u".into(); v["sources"][0]["url"] = "http://h/l.m3u".into(); v["sources"][0]["playlist"] = "#EXTM3U".into(); })),
        ("m3u with none", mutate(&good, |v| { v["sources"][0]["type"] = "m3u".into(); })),
        ("empty", mutate(&good, |v| v["sources"] = Value::Array(vec![]))),
        ("too many", mutate(&good, |v| { let one = v["sources"][0].clone(); v["sources"] = Value::Array(vec![one; 51]); })),
        ("not json", "definitely not json".to_string()),
    ];
    for (label, json) in bad {
        assert!(b.preview_share_document(json.clone()).is_err(), "preview accepted: {label}");
        assert!(b.import_share_document(json, vec![], dir.clone()).is_err(), "import accepted: {label}");
    }
    assert_eq!(b.db.list_sources().unwrap().len(), before, "a rejected document creates nothing");
    assert!(b.preview_share_document(good).is_ok());
}

#[test]
fn expiry_error_is_readable() {
    let a = engine();
    let id = add_xtream(&a, "P", "http://srv:80", "u");
    let json = mutate(&export_one(&a, opt(id, false, None, false)).json, |v| v["expires_at"] = 1.into());
    let message = a.preview_share_document(json).unwrap_err().to_string();
    assert!(message.contains("expiré"), "{message}");
}

#[test]
fn the_same_source_is_recognised_and_skipped_by_default() {
    let a = engine();
    let b = engine();
    let id = add_xtream(&a, "Premium", "http://Srv.Example:8080/", "Alice");
    let mine = add_xtream(&b, "Ancien nom", "http://srv.example:8080", "alice");
    let json = export_one(&a, opt(id, true, Some("pw"), false)).json;

    let preview = b.preview_share_document(json.clone()).unwrap();
    assert_eq!(preview.sources[0].duplicate_of, Some(mine));
    assert_eq!(preview.sources[0].duplicate_name.as_deref(), Some("Ancien nom"));
    assert_eq!(preview.from, "Le Mac de Papa");

    let default = b.import_share_document(json.clone(), vec![], tmp().display().to_string()).unwrap();
    assert!(default.imported.is_empty());
    assert_eq!(default.skipped, 1);
    assert_eq!(b.db.list_sources().unwrap().len(), 1);

    let replaced = b.import_share_document(json.clone(), vec![ShareDecision { index: 0, action: ShareImportAction::Replace }], tmp().display().to_string()).unwrap();
    assert!(replaced.imported[0].replaced);
    assert_eq!(replaced.imported[0].source_id, mine);
    assert_eq!(replaced.imported[0].password.as_deref(), Some("pw"));
    assert_eq!(b.db.get_source_by_id(mine).unwrap().name, "Premium");
    assert_eq!(b.db.list_sources().unwrap().len(), 1, "replace does not create a second source");

    // Even "Import" never adds the same account a second time: it lands on the existing one.
    let again = b.import_share_document(json, vec![ShareDecision { index: 0, action: ShareImportAction::Import }], tmp().display().to_string()).unwrap();
    assert!(!again.imported[0].replaced);
    assert_eq!(again.imported[0].source_id, mine);
    assert_eq!(b.db.list_sources().unwrap().len(), 1);
}

#[test]
fn playlist_urls_match_whatever_the_credentials() {
    let a = engine();
    let b = engine();
    let id = a.db.add_source("X", "m3u", Some("http://srv:8080/get.php?username=bob&password=p1&type=m3u_plus"), None, None, None).unwrap();
    let mine = b.db.add_source("Mienne", "m3u", Some("http://srv:8080/get.php?username=carl&password=p2&type=m3u_plus"), None, None, None).unwrap();
    let json = export_one(&a, opt(id, false, None, false)).json;
    let preview = b.preview_share_document(json).unwrap();
    assert_eq!(preview.sources[0].duplicate_of, Some(mine));
    assert_eq!(preview.sources[0].url_display.as_deref(), Some("http://srv:8080/get.php?username=&password=&type=m3u_plus"));
}

#[test]
fn the_preview_and_logs_never_expose_secrets() {
    let a = engine();
    let b = engine();
    let id = add_xtream(&a, "Premium", "http://srv:80", "alice");
    let json = export_one(&a, opt(id, true, Some("topsecret-pw"), false)).json;
    let preview = b.preview_share_document(json.clone()).unwrap();
    assert!(preview.sources[0].has_password);
    assert!(!format!("{preview:?}").contains("topsecret"));

    b.import_share_document(json, vec![], tmp().display().to_string()).unwrap();
    let logs = format!("{:?}", b.get_logs_since(0, 500));
    assert!(logs.contains("SHARE"));
    assert!(!logs.contains("topsecret") && !logs.contains("Premium"), "the log carries counts only");
}

#[test]
fn names_are_cleaned_and_several_sources_travel_together() {
    let a = engine();
    let b = engine();
    let one = a.db.add_source("Une\u{7}\nsource", "m3u", Some("http://h/1.m3u"), None, None, None).unwrap();
    let two = add_xtream(&a, "Deux", "http://srv:80", "u");
    let export = a.export_share_document(vec![opt(one, false, None, false), opt(two, false, None, false)], "Papa\u{7}".into(), 86_400).unwrap();
    assert_eq!(export.source_count, 2);
    let result = b.import_share_document(export.json, vec![], tmp().display().to_string()).unwrap();
    assert_eq!(result.imported.len(), 2);
    assert_eq!(result.imported[0].name, "Unesource");
    let preview_from = b.preview_share_document(a.export_share_document(vec![opt(two, false, None, false)], "Papa\u{7}".into(), 3_600).unwrap().json).unwrap().from;
    assert_eq!(preview_from, "Papa");
}

#[test]
fn bounds_on_the_export_request() {
    let a = engine();
    assert!(a.export_share_document(vec![], "x".into(), 3_600).is_err());
    let id = add_xtream(&a, "P", "http://srv:80", "u");
    assert!(a.export_share_document(vec![opt(9_999, false, None, false)], "x".into(), 3_600).is_err(), "unknown source");
    let too_many: Vec<_> = (0..51).map(|_| opt(id, false, None, false)).collect();
    assert!(a.export_share_document(too_many, "x".into(), 3_600).is_err());

    let short = serde_json::from_str::<Value>(&a.export_share_document(vec![opt(id, false, None, false)], "x".into(), 1).unwrap().json).unwrap();
    assert!(short["expires_at"].as_i64().unwrap() - short["created_at"].as_i64().unwrap() >= 60, "validity is at least a minute");
}

#[test]
fn replaced_sources_are_never_touched_without_the_matching_decision() {
    let a = engine();
    let b = engine();
    let id = add_xtream(&a, "Nouveau", "http://srv:80", "u");
    let mine = add_xtream(&b, "Garder", "http://srv:80", "u");
    let json = export_one(&a, opt(id, false, None, false)).json;
    b.import_share_document(json, vec![ShareDecision { index: 5, action: ShareImportAction::Replace }], tmp().display().to_string()).unwrap();
    assert_eq!(b.db.get_source_by_id(mine).unwrap().name, "Garder");
}
