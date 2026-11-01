# Guide de Reprise pour Agent IA — `cnd-iptv-native`

> **Objectif de ce document :** Permettre à un nouvel agent IA (ou développeur) de reprendre **immédiatement et sans perte de contexte** l'implémentation séquentielle de la roadmap [`PRD/00_INDEX_ROADMAP.md`](./PRD/00_INDEX_ROADMAP.md) à partir du **PRD 07**.

---

## 1. Résumé de l'État Actuel (PRDs 01 à 06 Terminés & Validés ✅)

| Ordre | PRD | Statut | Fichiers Clés Implémentés |
| :---: | :--- | :---: | :--- |
| **01** | [`PRD/01_CORE_TELEMETRY_HTTP_SETTINGS.md`](./PRD/01_CORE_TELEMETRY_HTTP_SETTINGS.md) | `[x]` | `crates/cnd-core/src/db/settings_repo.rs`, `crates/cnd-core/src/telemetry/mod.rs`, `crates/cnd-core/src/http_client.rs` |
| **02** | [`PRD/02_STREAMING_M3U_INGESTION_SERIES_NORMALIZER.md`](./PRD/02_STREAMING_M3U_INGESTION_SERIES_NORMALIZER.md) | `[x]` | `crates/cnd-core/src/iptv/normalizer.rs`, `crates/cnd-core/src/iptv/m3u_parser.rs`, `crates/cnd-core/src/db/ingestion_writer.rs` |
| **03** | [`PRD/03_XTREAM_CODES_NATIVE_CLIENT.md`](./PRD/03_XTREAM_CODES_NATIVE_CLIENT.md) | `[x]` | `crates/cnd-core/src/iptv/xtream.rs`, `apple/Sources/CndIptvApp/Security/KeychainStore.swift`, `apple/Tests/CndIptvAppTests/KeychainStoreTests.swift` |
| **04** | [`PRD/04_XMLTV_EPG_ENGINE.md`](./PRD/04_XMLTV_EPG_ENGINE.md) | `[x]` | `crates/cnd-core/src/iptv/epg.rs`, `crates/cnd-core/src/db/epg_repo.rs` |
| **05** | [`PRD/05_CATALOG_QUERIES_FAVORITES_HISTORY.md`](./PRD/05_CATALOG_QUERIES_FAVORITES_HISTORY.md) | `[x]` | `crates/cnd-core/src/db/catalog_repo.rs` |
| **06** | [`PRD/06_METADATA_OMDB_TMDB_ENRICHMENT.md`](./PRD/06_METADATA_OMDB_TMDB_ENRICHMENT.md) | `[x]` | `crates/cnd-core/src/metadata/mod.rs` |
| **07** | [`PRD/07_MULTI_SEGMENT_DOWNLOAD_ENGINE.md`](./PRD/07_MULTI_SEGMENT_DOWNLOAD_ENGINE.md) | `[ ]` | **À implémenter maintenant** *(schéma SQL `download_tasks` / `download_parts` déjà prêt dans `schema.rs` & `db/mod.rs`)* |
| **08** | [`PRD/08_HYBRID_VIDEO_PLAYER_ENGINE.md`](./PRD/08_HYBRID_VIDEO_PLAYER_ENGINE.md) | `[ ]` | À implémenter après PRD 07 |
| **09** | [`PRD/09_SWIFTUI_SOURCES_LIVE_TV_EPG.md`](./PRD/09_SWIFTUI_SOURCES_LIVE_TV_EPG.md) | `[ ]` | À implémenter après PRD 08 |
| **10** | [`PRD/10_SWIFTUI_MOVIES_SERIES_VOD.md`](./PRD/10_SWIFTUI_MOVIES_SERIES_VOD.md) | `[ ]` | À implémenter après PRD 09 |
| **11** | [`PRD/11_SWIFTUI_DOWNLOADS_SETTINGS_CONSOLE.md`](./PRD/11_SWIFTUI_DOWNLOADS_SETTINGS_CONSOLE.md) | `[ ]` | À implémenter après PRD 10 |
| **12** | [`PRD/12_APPLE_ECOSYSTEM_PIP_AIRPLAY_CLOUDKIT.md`](./PRD/12_APPLE_ECOSYSTEM_PIP_AIRPLAY_CLOUDKIT.md) | `[ ]` | À implémenter après PRD 11 |

### État de santé actuel du repo
- **Tests Rust (`cargo test --workspace`) :** `23 passed; 0 failed` (inclut le benchmark streaming 50 000 items M3U `< 1.5s`, Xtream REST + fallback M3U+, XMLTV `.xml.gz` magic bytes, FTS5 caractères spéciaux, favori rang 1 000, cascade OMDb + cache SQLite + masquage `apikey=***`).
- **Linter Rust (`cargo clippy --workspace --all-targets -- -D warnings`) :** `0 warning, 0 error`.
- **XCFramework Universel (`./scripts/build-xcframework.sh`) :** À jour avec les bindings UniFFI des PRDs 01 à 06 (`macOS arm64+x86_64`, `iOS Simulator arm64+x86_64`, `iOS Device arm64`).
- **Tests Swift :** `apple/Packages/CndCoreBridge` (`swift test`) et `apple` (`swift test` incluant `KeychainStoreTests`) passent à 100 %.
- **Builds Xcode :** `xcodebuild -scheme CndIptvNative` passe sur `generic/platform=macOS` et `generic/platform=iOS Simulator`.

---

## 2. Informations Techniques Critiques & Pièges à Éviter (Important ⚠️)

1. **Nom du Scheme Xcode (`CndIptvNative`) :**
   Dans `apple/Package.swift`, le package s'appelle `CndIptvNative` (et non `CndIptvApp`). Utiliser systématiquement :
   ```bash
   cd apple
   xcodebuild -scheme CndIptvNative -destination 'generic/platform=macOS' -quiet build
   xcodebuild -scheme CndIptvNative -destination 'generic/platform=iOS Simulator' -quiet build
   ```

2. **Dépendances Cargo (Ne pas ajouter de nouvelles crates externes) :**
   L'index Cargo local ne contient que les versions figées dans `Cargo.lock`. **Ne pas modifier `Cargo.toml` pour ajouter de nouvelles crates** (et ne pas activer la feature `"cookies"` de `reqwest` qui requiert `cookie_store` absent du cache local — `HttpClientPool` dans `crates/cnd-core/src/http_client.rs` implémente déjà nativement `LightweightCookieJar`).
   Toutes les crates nécessaires pour les PRDs 07 à 12 sont **déjà présentes** dans `Cargo.toml` / `Cargo.lock` :
   - `tokio` (`full` : `fs`, `io`, `net`, `sync::Semaphore`, `time`, `task::spawn_blocking`)
   - `tokio-util` (`io::StreamReader`, `sync::CancellationToken`)
   - `futures-util` (`TryStreamExt`, `StreamExt`)
   - `reqwest`, `rusqlite`, `serde`, `serde_json`, `blake3`, `regex`, `url`, `thiserror`, `uniffi` (`0.29` avec `tokio`).

3. **Bloc `#[uniffi::export(async_runtime = "tokio")]` dans `crates/cnd-core/src/lib.rs` :**
   Garder un seul bloc `#[uniffi::export(async_runtime = "tokio")] impl CndEngine` regroupant les constructeurs `#[uniffi::constructor]`, les méthodes synchrones `pub fn` et les méthodes asynchrones `pub async fn`.
   Dès qu'une méthode ou structure UniFFI est ajoutée/modifiée dans `cnd-core`, **toujours** relancer `./scripts/build-xcframework.sh` avant `swift test` ou `xcodebuild`.

4. **Sécurité FTS5 SQLite (`iptv_items`) :**
   Toujours utiliser `INSERT INTO iptv_items ... ON CONFLICT(stable_hash) DO UPDATE SET ...` (et jamais `INSERT OR REPLACE`) pour préserver l'intégrité des triggers FTS5 `trg_items_au`.

---

## 3. Plan d'Action Détaillé pour la Suite (PRDs 07 à 12)

### Étape 1 — Implémenter & Valider `PRD 07` (`PRD/07_MULTI_SEGMENT_DOWNLOAD_ENGINE.md`)
- **Déjà fait dans `schema.rs` & `db/mod.rs` :**
  - Colonne `headers_json TEXT` ajoutée dans `download_tasks`.
  - Contrainte `UNIQUE(task_id, part_index)` et index `idx_download_parts_task_idx` sur `download_parts`.
  - Index `idx_download_logs_task` sur `download_logs(task_id, id DESC)`.
- **Fichiers à créer / modifier :**
  1. `crates/cnd-core/src/db/download_repo.rs` :
     - Structures UniFFI : `NewDownloadRequest`, `DownloadTaskRecord`, `DownloadPartRecord`, `DownloadLogRecord`.
     - CRUD SQLite : création de tâche, récupération/mise à jour d'état (`queued`, `running`, `paused`, `completed`, `error`), gestion des `download_parts`, insertion et lecture de `download_logs`, et `reset_running_tasks_on_startup()` (`running -> paused` au démarrage de `CndEngine`).
  2. `crates/cnd-core/src/downloader/prober.rs` :
     - `probe_download_url(http_pool, url, user_agent, referer, headers_json)` : tente `HEAD`, et si statut `>= 400` (`405`/`403`) ou `Content-Length` absent, fallback `GET` avec `Range: bytes=0-0`.
     - Extrait `final_url`, `total_bytes` (via `Content-Range` en priorité puis `Content-Length`), `accept_ranges` (`206` ou `Accept-Ranges: bytes`), et `real_file_name` (`Content-Disposition` ou dernier segment d'URL nettoyé des caractères `/\:*?"<>|`).
  3. `crates/cnd-core/src/downloader/worker.rs` :
     - Pré-alloue `<save_path>.part` (`OpenOptions::new().create(true).write(true).read(true)`, `file.set_len(total_bytes)`) partagé via `Arc<std::fs::File>`.
     - Buffer mémoire de `256 Ko` à `512 Ko` par segment, écriture parallèle sans `Mutex` via `std::os::unix::fs::FileExt::write_at(&buf, current_offset)` (`pwrite`).
     - Compteur atomique `AtomicU64` + flush SQLite toutes les `500 ms` (et sur pause/cancel/error).
     - Finalisation atomique : `file.sync_data()` puis `std::fs::rename(&temp_path, &save_path)`.
  4. `crates/cnd-core/src/downloader/mod.rs` :
     - `DownloadManager` avec `tokio::sync::Semaphore` (`max_active_files`), `CancellationToken` par tâche active, calcul EMA de la vitesse (`speed_bps`) et `eta_seconds` à 4 Hz (`250 ms`).
  5. `crates/cnd-core/src/lib.rs` & `crates/cnd-cli/src/main.rs` :
     - Exporter sur `CndEngine` : `enqueue_download`, `start_download`, `pause_download`, `retry_download`, `remove_download`, `start_all_downloads`, `pause_all_downloads`, `list_downloads`, `get_download_logs`.
  6. **Tests obligatoires PRD 07 :**
     - Serveur HTTP local `TcpListener` supportant `HEAD` et `Range: bytes=start-end`.
     - Téléchargement 8 segments d'un payload binaire aléatoire de 8 Mo + vérification hash `blake3` identique au byte près.
     - `pause_download` à ~50 %, réouverture SQLite, `start_download` (reprise Range) + vérification hash `blake3`.
     - Fallback `Prober` quand `HEAD` renvoie `405 Method Not Allowed`.

### Étape 2 — Implémenter & Valider `PRD 08` (`PRD/08_HYBRID_VIDEO_PLAYER_ENGINE.md`)
- Créer dans `apple/Sources/CndIptvApp/Player/` :
  - `PlayableMedia.swift`, `VideoBackendProtocol.swift`
  - `AVPlayerBackend.swift` (`AVURLAsset` avec `AVURLAssetHTTPHeaderFieldsKey`, sélection pistes `AVMediaSelectionGroup`, observation `timeControlStatus` / `status`)
  - `MpvVideoToolboxBackend.swift` (intégration `libmpv` LGPL via chargement dynamique `dlopen`/`dlsym` de `libmpv.2.dylib` + `hwdec=videotoolbox` + `AVSampleBufferDisplayLayer` pour garantir la compilation et l'exécution sans erreur de link sur `macOS` **et** `iOS Simulator`)
  - `CndPlayerController.swift` (`@Observable @MainActor`, routage auto `.m3u8`/`.mp4` -> `AVPlayerBackend` vs `.ts`/`.mkv`/`.avi` -> `MpvVideoToolboxBackend`, bascule auto `< 200 ms` sur échec `AVPlayer`, Stall Watchdog 4s + `NWPathMonitor` 3 retries, `PlaylistQueue`, sauvegarde `recordWatchProgress` toutes les 5s)
  - `CndVideoPlayerView.swift` (HUD auto-hide 3s, `-10s`/`+10s`, barre LIVE vs VOD, sélecteur pistes Audio/Sous-titres, vitesse, plein écran)
  - `ExternalPlayerLauncher.swift` (IINA, VLC, Infuse, Outplayer + `copyStreamUrl`, `copyFfmpegCommand`, `copyCurlCommand` avec échappement shell strict)
- Ajouter les tests unitaires dans `apple/Tests/CndIptvAppTests/CndPlayerTests.swift`.

### Étape 3 — Implémenter & Valider `PRD 09` (`PRD/09_SWIFTUI_SOURCES_LIVE_TV_EPG.md`)
- Créer :
  - `apple/Sources/CndIptvApp/Shared/ImageThumbnailCache.swift` (`actor` avec `NSCache` + cache disque `Caches/CndThumbnails/` + downsampling `CGImageSourceCreateThumbnailAtIndex` hors du Main Thread)
  - `apple/Sources/CndIptvApp/Shared/SearchFilterToolbar.swift` (debounce 120 ms, filtres Groupe/Host/Tri)
  - `apple/Sources/CndIptvApp/App/AppShellView.swift` (`NavigationSplitView` 3 colonnes sur macOS vs `TabView` sur iOS + Mini-Player ancré, `@AppStorage("shell.selectedTab")`, zéro double barre de titre)
  - `apple/Sources/CndIptvApp/Features/Sources/SourcesListView.swift` & `SourceFormSheet.swift` (création + édition M3U/Xtream, `verifyXtreamAccount` + `KeychainStore`, Drag & Drop `.m3u` + `fileImporter`)
  - `apple/Sources/CndIptvApp/Features/LiveTV/LiveTvView.swift`, `ChannelCardView.swift`, `Features/EPG/EpgGuideView.swift` (catégories adaptatives `>= 900 pt` vs chips horizontaux, Récents/Favoris/Toutes paginées par 60, Grille/Liste `@AppStorage("live.viewMode")`, batch `getEpgNowNext` avec `ProgressView`, menu contextuel).

### Étape 4 — Implémenter & Valider `PRD 10` (`PRD/10_SWIFTUI_MOVIES_SERIES_VOD.md`)
- Créer :
  - `apple/Sources/CndIptvApp/Features/Movies/MoviesCatalogView.swift`, `MoviePosterCard.swift`, `MovieDetailsView.swift` (posters 2:3, barre de reprise, enrichissement asynchrone `fetchItemMetadata` avec clé OMDb du `KeychainStore`, boutons Reprendre > 30s / Recommencer, Télécharger 1-clic `enqueueDownload`, menu lecteur externe + FFmpeg/cURL)
  - `apple/Sources/CndIptvApp/Features/Series/SeriesCatalogView.swift`, `SeriesDetailsView.swift` (`querySeries`, favoris séries unifiés, hydratation lazy `ensureXtreamSeriesEpisodes` si `episodeCount == 0`, sélecteur de saison, *"Lire toute la saison"* via `PlaylistQueue`, *"Télécharger toute la saison"* dans `<DownloadDir>/<SafeSeriesTitle>/Season <XX>/`).

### Étape 5 — Implémenter & Valider `PRD 11` (`PRD/11_SWIFTUI_DOWNLOADS_SETTINGS_CONSOLE.md`)
- Créer :
  - `apple/Sources/CndIptvApp/Security/DownloadDirectoryManager.swift` (`#if os(macOS)` `NSOpenPanel` + Security-Scoped Bookmark `.withSecurityScope` persisté dans `UserDefaults`; `#if os(iOS)` `Documents/Downloads` + `ShareLink`)
  - `apple/Sources/CndIptvApp/Features/Downloads/DownloadsDashboardView.swift`, `DownloadTaskCard.swift` (barre multi-segments `parts`, polling 4 Hz qui s'arrête totalement quand aucune tâche n'est `running`/`queued`, barre de stats globale), `AddUrlsSheet.swift`, `TaskLogsSheet.swift`
  - `apple/Sources/CndIptvApp/Features/Settings/SettingsView.swift` & `Features/Console/NetworkConsoleDrawer.swift` (polling incrémental `getLogsSince` uniquement quand visible, badges HTTP colorés, filtre par catégorie, Clear & Copy).

### Étape 6 — Implémenter & Valider `PRD 12` (`PRD/12_APPLE_ECOSYSTEM_PIP_AIRPLAY_CLOUDKIT.md`)
- Créer :
  - `crates/cnd-core/src/db/sync_repo.rs` (export/import delta Last-Write-Wins sur `updated_at` pour `iptv_sources`, `favorites`, `watch_history` — jamais `iptv_items` ni `epg_programs`) + exports UniFFI + `./scripts/build-xcframework.sh`
  - `apple/Sources/CndIptvApp/Player/PiPManager.swift` (`AVPictureInPictureController` compatible `AVPlayerLayer` et `AVSampleBufferDisplayLayer`)
  - `apple/Sources/CndIptvApp/Player/AirPlayRoutePicker.swift` (`AVRoutePickerView`)
  - `apple/Sources/CndIptvApp/Player/NowPlayingCoordinator.swift` (`MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` + `#if os(iOS)` `AVAudioSession` `.playback`/`.moviePlayback`)
  - `apple/Sources/CndIptvApp/App/KeyboardCommands.swift` (`⌘N`, `⌘O`, `⌘R`, `⌘⇧C`, Espace, M, F, flèches) + gestes tactiles iOS plein écran (double-tap ±10s, swipe vertical luminosité/volume, `UIImpactFeedbackGenerator`)
  - `apple/Sources/CndIptvApp/Sync/CloudKitSyncManager.swift` (`CKSyncEngine` avec fallback gracieux *"Mode local uniquement"* sans crash si aucun compte iCloud ou entitlement CloudKit n'est actif).

---

## 4. Commandes de Validation Obligatoires à Chaque PRD

```bash
# 1. Tests & Clippy Rust
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings

# 2. Rebuild XCFramework Universel (si cnd-core a été modifié)
./scripts/build-xcframework.sh

# 3. Tests Swift (Bridge FFI + App)
(cd apple/Packages/CndCoreBridge && swift test)
(cd apple && swift test)

# 4. Builds multiplateformes macOS & iOS Simulator
(cd apple && xcodebuild -scheme CndIptvNative -destination 'generic/platform=macOS' -quiet build)
(cd apple && xcodebuild -scheme CndIptvNative -destination 'generic/platform=iOS Simulator' -quiet build)
```

---

## 5. Prompt Recommandé pour Relancer un Agent IA

Pour reprendre le travail avec un nouvel agent IA, donnez-lui simplement :

```text
/goal Lis reprise.md et PRD/00_INDEX_ROADMAP.md, puis poursuis l'implémentation séquentielle à partir du PRD 07 jusqu'au PRD 12 inclus en respectant toutes les validations et en cochant [x] dans PRD/00_INDEX_ROADMAP.md à chaque étape.
```

