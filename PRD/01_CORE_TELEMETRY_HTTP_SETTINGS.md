# PRD 01 — Runtime Settings, Pool HTTP Haute Performance & Télémétrie Réseau

- **ID :** `PRD-01`
- **Prérequis :** Baseline Phase 1 (déjà en place)
- **Couches impactées :** `Rust (cnd-core)`, `UniFFI`, `CLI (cnd-cli)`
- **Référence Flutter migrée :** `lib/core/settings.dart`, `lib/core/settings_store.dart`, `lib/services/global_logger.dart`
- **Objectif SLA :** Overhead télémétrie `< 50 µs` par requête, réutilisation des connexions TLS/TCP Keep-Alive, mémoire bornée du Ring-Buffer (`max 1 000 entrées`).

---

## 1. Contexte & Objectif

Toutes les fonctionnalités suivantes (ingestion M3U/Xtream/EPG, OMDb, moteur de téléchargement multi-segments) ont besoin de trois briques transverses :
1. **Configuration Runtime persistée (`RuntimeSettings`)** dans SQLite (remplaçant `SharedPreferences` + variables globales mutables de Flutter).
2. **Client HTTP partagé haute performance (`HttpClientPool`)** basé sur `reqwest` + `rustls`, configuré avec Keep-Alive agressif, gestion des cookies, timeouts dynamiques et injection automatique des headers (`User-Agent` par défaut `VLC/3.0.21 LibVLC/3.0.21`, `Referer`).
3. **Système de Télémétrie & Logs Réseau (`TelemetryHub`)** remplaçant `GlobalLogInterceptor` : un anneau mémoire thread-safe (`VecDeque` borné) capturant chaque requête HTTP (méthode, URL masquant les mots de passe, code statut, durée en ms, octets, erreurs) consultable en temps réel depuis SwiftUI.

---

## 2. Fichiers à Créer / Modifier

- `crates/cnd-core/src/db/schema.rs` *(ajout table `app_settings`)*
- `crates/cnd-core/src/db/settings_repo.rs` *(nouveau)*
- `crates/cnd-core/src/telemetry/mod.rs` *(nouveau — Ring-Buffer + masquage secrets URL)*
- `crates/cnd-core/src/http_client.rs` *(nouveau — wrapper `reqwest::Client` instrumenté)*
- `crates/cnd-core/src/lib.rs` *(export UniFFI des settings et de la télémétrie sur `CndEngine`)*
- `crates/cnd-cli/src/main.rs` *(affichage des settings et test de log télémétrie)*

---

## 3. Spécifications Techniques Détaillées

### 3.1. Persistance `RuntimeSettings` (SQLite)
Ajouter dans `INIT_SQL` (`schema.rs`) :
```sql
CREATE TABLE IF NOT EXISTS app_settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    updated_at INTEGER NOT NULL
);
```

Structure Rust exportée via UniFFI :
```rust
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct RuntimeSettings {
    pub segments_per_file: u32,       // défaut: 4 (au lieu de 1 sur Flutter pour exploiter le multi-segment)
    pub part_size_bytes: u64,         // défaut: 10 * 1024 * 1024 (10 Mo)
    pub max_active_files: u32,        // défaut: 2
    pub default_user_agent: String,   // défaut: "VLC/3.0.21 LibVLC/3.0.21"
    pub default_referer: Option<String>,
    pub download_dir: Option<String>,
    pub connect_timeout_ms: u64,      // défaut: 10_000
    pub receive_timeout_ms: u64,      // défaut: 30_000
    pub speed_smoothing: f64,         // défaut: 0.2
    pub omdb_api_key_ref: Option<String>, // identifiant Keychain ou clé configurée
    pub show_network_console: bool,   // défaut: false
}
```
- Conserver une copie en mémoire dans `Arc<RwLock<RuntimeSettings>>` pour une lecture sans accès disque à chaque requête HTTP, synchronisée vers `app_settings` lors d'un `update_settings(...)`.

### 3.2. `TelemetryHub` (Ring-Buffer Borné & Sécurisé)
```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum LogLevel {
    Debug,
    Info,
    Warn,
    Error,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct NetworkLogEntry {
    pub seq_id: u64,
    pub timestamp_ms: i64,
    pub level: LogLevel,
    pub category: String,       // "HTTP", "M3U", "XTREAM", "EPG", "DOWNLOAD", "DB"
    pub method: Option<String>, // "GET", "HEAD", "POST"
    pub url_redacted: Option<String>,
    pub status_code: Option<u16>,
    pub duration_ms: Option<u64>,
    pub message: String,
}
```
- **Capacité stricte :** `MAX_ENTRIES = 1_000` dans un `Mutex<VecDeque<NetworkLogEntry>>` avec compteur monotone `AtomicU64` (`seq_id`).
- **Sécurité (Redaction obligatoire) :** Toute URL enregistrée dans les logs doit masquer automatiquement les query params sensibles (`password=...`, `apikey=...`, `token=...` remplacés par `***`) pour ne jamais exposer les identifiants Xtream ou OMDb dans l'UI ou les captures d'écran.
- **Polling incrémental ultra-léger :** Méthode `get_logs_since(after_seq_id: u64, limit: u32) -> Vec<NetworkLogEntry>` et `clear_logs()`.

### 3.3. `HttpClientPool` (`reqwest` + `rustls` + Cookies)
- Ajouter la feature `cookies` à `reqwest` dans `Cargo.toml` du workspace si nécessaire (`features = ["rustls-tls", "stream", "json", "cookies", "gzip"]`).
- Configurer `reqwest::Client::builder()` avec :
  - `pool_idle_timeout(Duration::from_secs(90))`
  - `pool_max_idle_per_host(16)` (crucial pour le zapping rapide et le téléchargement multi-segments)
  - `tcp_nodelay(true)`
  - `redirect(reqwest::redirect::Policy::limited(10))`
  - `cookie_store(true)`
- Fournir des helpers :
  - `send_logged(&self, category: &str, req: RequestBuilder) -> Result<reqwest::Response, CndError>` qui mesure le `Instant::now()`, injecte `User-Agent` / `Referer` par défaut s'ils sont absents, exécute la requête et pousse automatiquement une `NetworkLogEntry` dans `TelemetryHub`.
  - Reconstruction propre du `reqwest::Client` lorsque `connect_timeout_ms` ou `default_user_agent` change via `update_settings`.

### 3.4. Nouvelles Méthodes UniFFI sur `CndEngine`
```rust
#[uniffi::export]
impl CndEngine {
    pub fn get_settings(&self) -> RuntimeSettings;
    pub fn update_settings(&self, settings: RuntimeSettings) -> Result<(), CndError>;
    pub fn get_logs_since(&self, after_seq_id: u64, limit: u32) -> Vec<NetworkLogEntry>;
    pub fn clear_logs(&self);
}
```

---

## 4. Contraintes Non-Négociables (Guardrails IA)
- **Zéro secret en clair dans les logs :** Tester explicitement la fonction `redact_url("http://srv:8080/get.php?username=bob&password=secret123&apikey=abcd")`.
- **Aucune allocation illimitée :** Le `VecDeque` ne doit jamais dépasser `1 000` entrées (`pop_front` systématique).
- **Pas de `unwrap()` en production :** Toutes les erreurs remontent proprement via `CndError`.

---

## 5. Critères d'Acceptation & Commandes de Validation
1. Tests unitaires Rust couvrant :
   - Sauvegarde et rechargement de `RuntimeSettings` depuis SQLite.
   - Rotation du Ring-Buffer à > 1 000 entrées et récupération incrémentale via `get_logs_since`.
   - Masquage des paramètres `password`, `pass`, `apikey`, `token` dans `redact_url`.
2. Exécuter et valider sans erreur :
   ```bash
   cd cnd-iptv-native
   cargo test --workspace
   cargo clippy --workspace -- -D warnings
   ./scripts/build-xcframework.sh
   cd apple/Packages/CndCoreBridge && swift test
   cd ../.. && xcodebuild -scheme CndIptvNative -destination 'generic/platform=macOS' build
   ```

