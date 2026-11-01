# PRD 02 — Parseur M3U/M3U8 Streaming Zero-Copy & Normalisation des Séries

- **ID :** `PRD-02`
- **Prérequis :** `PRD-01` (Pool HTTP, Settings, Telemetry)
- **Couches impactées :** `Rust (cnd-core)`, `UniFFI`, `CLI (cnd-cli)`
- **Référence Flutter migrée :** `lib/services/m3u_parser.dart`, `lib/services/isolate_parser.dart`, `lib/data/iptv_repository.dart`, logique `_groupBySeries` / `_parseSeason` / `_parseEpisode` de `series_page.dart` & `series_details_page.dart`
- **Objectif SLA :** Ingestion et indexation SQLite + FTS5 de **100 000 entrées < 2.0 secondes**, empreinte RAM constante **< 25 Mo**.

---

## 1. Contexte & Objectif

Dans l'application Flutter existante :
1. Le fichier M3U entier était téléchargé dans une seule `String` Dart avant d'être envoyé dans un Isolate, provoquant des pics mémoire de plusieurs centaines de Mo.
2. Les séries n'étaient pas normalisées en base : `SeriesPage` regroupait uniquement les 50 items chargés en mémoire, tronquant les saisons et épisodes.

Ce PRD implémente en Rust :
- Un **parseur M3U/M3U8 asynchrone ligne par ligne en streaming** (depuis une URL HTTP ou un fichier local `.m3u` pour le Drag & Drop macOS).
- La **parité 100 %** avec toutes les directives avancées (`#EXTM3U`, `#EXTINF`, `#EXTGRP`, `#EXTVLCOPT`, `#KODIPROP`, catchup, IMDb).
- Un **normaliseur de titres et d'épisodes (`SxxExx`)** alimentant automatiquement `series_catalog` et liant chaque épisode via `series_id`.
- Un **Batch Writer SQLite transactionnel** ultra-rapide préservant les Favoris et l'Historique grâce au `stable_hash` (`blake3`).

---

## 2. Fichiers à Créer / Modifier

- `crates/cnd-core/src/iptv/mod.rs`
- `crates/cnd-core/src/iptv/normalizer.rs` *(nettoyage titres, année, détection `kind`, extraction Série/Saison/Épisode)*
- `crates/cnd-core/src/iptv/m3u_parser.rs` *(streaming parser `AsyncBufRead`)*
- `crates/cnd-core/src/db/ingestion_writer.rs` *(batch insert transactionnel + mise à jour `series_catalog` + triggers FTS5 optimisés)*
- `crates/cnd-core/src/lib.rs` *(exports UniFFI `refresh_source`, `import_local_m3u`, `delete_source`, `update_source`)*
- `crates/cnd-cli/src/main.rs` *(sous-commande ou bench d'import M3U affichant débit lignes/sec)*

---

## 3. Spécifications Techniques Détaillées

### 3.1. Parseur Streaming Ligne par Ligne (`m3u_parser.rs`)
Lire depuis n'importe quel `R: tokio::io::AsyncBufRead + Unpin` (buffer de `64 Ko`) via `read_until(b'\n', &mut line_buf)` pour tolérer les encodages UTF-8 imparfaits (`String::from_utf8_lossy`) fréquents dans les playlists IPTV :
- **`#EXTM3U`** (1re ligne) : extraire `x-tvg-url` / `url-tvg` (mettre à jour `iptv_sources.epg_url` si vide), `catchup`, `catchup-source`, `provider-name`.
- **`#EXTINF`** :
  - Parser les attributs `key="value"` ou `key=value` sans regex lourde à chaque caractère (scanner léger ou `Regex` compilée une seule fois via `std::sync::LazyLock`).
  - Extraire : `tvg-id`, `tvg-name`, `tvg-logo` / `logo`, `group-title`, `tvg-country` / `country`, `tvg-language` / `language`, `tvg-chno` / `channel-id`, `catchup`, `catchup-source`, `catchup-days` / `timeshift`, `epg-shift`.
  - Extraire les indices IMDb éventuels : `imdb-id` (`tt\d{7,9}`), `imdb-rating` (normaliser `7,4`, `7.4/10`, `74%` sur une échelle `0.0..=10.0`), `plot` / `tvg-description` / `description`.
  - Extraire le nom brut après la dernière virgule hors guillemets.
- **`#EXTGRP:`** : écrase/définit `group_title` courant.
- **`#EXTVLCOPT:`** : extraire `http-user-agent` → `user_agent`, `http-referrer` / `http-referer` → `referer`, et stocker les autres paires dans `headers_json`.
- **`#KODIPROP:`** : extraire les propriétés pertinentes (`inputstream*`, headers HTTP, IMDb/plot).
- **Ligne URL (ne commençant pas par `#`)** :
  - Extraire `host` et `container_ext` (`m3u8`, `ts`, `mp4`, `mkv`, `avi`) via `url::Url::parse`.
  - Calculer `stable_hash = blake3::hash(format!("{}:{}", source_uuid, stream_url).as_bytes()).to_hex().to_string()`.
  - Émettre l'item parsé vers le `BatchIngestionWriter` et réinitialiser l'accumulateur sans réallouer les buffers.

### 3.2. Classification & Normalisation (`normalizer.rs`)
Toutes les expressions régulières doivent être compilées **une seule fois** dans des `LazyLock<Regex>` :
1. **Détection du `kind` (`live` | `movie` | `episode`) :**
   - `episode` si : l'URL contient `/series/`, OU `group_title` contient `series`/`série`/`serie`, OU le nom matche un pattern épisode (`(?i)\bS(\d{1,2})\s*E(\d{1,3})\b`, `(?i)\b(\d{1,2})x(\d{1,3})\b`, `(?i)\bSeason\s*(\d{1,2}).*?(?:Ep|Episode)\s*(\d{1,3})\b`).
   - `movie` si : l'URL contient `/movie/`, OU `group_title` contient `vod`/`movie`/`film`, OU extension fichier VOD (`.mkv`, `.mp4`, `.avi`) sans pattern d'épisode ni flux live.
   - `live` sinon.
2. **Nettoyage du Titre (`name_clean`) & Année (`year`) :**
   - Retirer les préfixes pays/qualité fréquents (`|FR|`, `[FR]`, `(VF)`, `FHD`, `4K`, `UHD`, `HEVC`, `1080p`, `720p`, `VOSTFR`, `MULTI`, `TRUEFRENCH`).
   - Extraire l'année `(19\d{2}|20\d{2})` si présente en fin de titre.
3. **Extraction Série (`SeriesInfo`) pour les items `episode` :**
   - Extraire `(series_title_clean, canonical_key, season_num, episode_num)`.
   - `canonical_key` = `series_title_clean.to_lowercase()` normalisé (espaces simples, sans diacritiques ni tags de langue) pour regrouper de façon déterministe tous les épisodes d'une même série d'une source.

### 3.3. Batch Writer SQLite Haute Vitesse (`ingestion_writer.rs`)
Pour atteindre `< 2.0 s` sur 100 000 items :
- Stratégie de rafraîchissement sans coupure ni perte de données :
  1. Ouvrir une transaction par lot de **2 500 items** (ou une transaction globale avec `PreparedStatement` mis en cache `prepare_cached`).
  2. Supprimer les anciens `iptv_items` et `series_catalog` de `source_id` au début du refresh complet, puis insérer par lots via `INSERT OR REPLACE INTO iptv_items ...`.
  3. Maintenir une `HashMap<String, i64>` (`canonical_key -> series_id`) en mémoire durant l'ingestion (quelques milliers d'entrées max = < 1 Mo RAM) pour lier instantanément chaque épisode à sa ligne `series_catalog`, puis recalculer en une seule requête SQL finale `episode_count` et `season_count` sur `series_catalog` :
     ```sql
     UPDATE series_catalog SET
       episode_count = (SELECT COUNT(*) FROM iptv_items WHERE series_id = series_catalog.id),
       season_count = (SELECT COUNT(DISTINCT season_num) FROM iptv_items WHERE series_id = series_catalog.id)
     WHERE source_id = ?1;
     ```
  4. Mettre à jour `iptv_sources.item_count` et `last_sync_at`.

### 3.4. Signatures UniFFI (`CndEngine` — Async)
```rust
#[derive(Debug, Clone, uniffi::Record)]
pub struct SyncSummary {
    pub source_id: i64,
    pub total_items: u32,
    pub live_count: u32,
    pub movie_count: u32,
    pub series_count: u32,
    pub episode_count: u32,
    pub duration_ms: u64,
}

#[uniffi::export(async_runtime = "tokio")]
impl CndEngine {
    pub async fn refresh_source(&self, source_id: i64) -> Result<SyncSummary, CndError>;
    pub async fn import_local_m3u(&self, name: String, file_path: String) -> Result<SyncSummary, CndError>;
    pub fn update_source(
        &self,
        source_id: i64,
        name: String,
        url: Option<String>,
        epg_url: Option<String>,
    ) -> Result<(), CndError>;
    pub fn delete_source(&self, source_id: i64) -> Result<(), CndError>;
}
```

---

## 4. Contraintes Non-Négociables (Guardrails IA)
- **Interdiction absolue de `response.text().await` ou `std::fs::read_to_string`** sur une playlist M3U : utiliser exclusivement `tokio_util::io::StreamReader` sur `response.bytes_stream()` et `tokio::io::BufReader::new(tokio::fs::File::open(...))`.
- **Préservation des Favoris :** Vérifier par test unitaire qu'un favori ajouté avant un `refresh_source` reste `is_favorite == true` après ré-ingestion de la playlist grâce au `stable_hash` !
- Ajouter `tokio-util = { version = "0.7", features = ["io"] }` dans `Cargo.toml` si requis.

---

## 5. Critères d'Acceptation & Commandes de Validation
1. **Tests unitaires & Benchmark Rust :**
   - Test complet des directives `#EXTM3U`, `#EXTINF`, `#EXTGRP`, `#EXTVLCOPT`, `#KODIPROP`, IMDb, et classification `live` / `movie` / `episode`.
   - Test de regroupement d'une série multi-saisons (`S01E01`, `S01E02`, `S02E01` → 1 entrée `series_catalog` avec `season_count = 2`, `episode_count = 3`).
   - Test de performance synthétique générant un flux mémoire de **50 000 lignes `#EXTINF`** et vérifiant que l'ingestion SQLite + FTS5 se termine en `< 1.5 s`.
2. Exécuter :
   ```bash
   cd cnd-iptv-native
   cargo test --workspace --release
   cargo clippy --workspace -- -D warnings
   ./scripts/build-xcframework.sh
   cd apple/Packages/CndCoreBridge && swift test
   ```

