# PRD 07 — Moteur de Téléchargement HTTP Multi-Segments Sans Verrou (`DownloadEngine`)

- **ID :** `PRD-07`
- **Prérequis :** `PRD-01` (Settings, Pool HTTP, Telemetry)
- **Couches impactées :** `Rust (cnd-core)`, `UniFFI`, `CLI (cnd-cli)`
- **Référence Flutter migrée :** `lib/services/downloader_service.dart`, `lib/services/prober.dart`, `lib/services/segment_worker.dart`, `lib/data/download_repository.dart`
- **Objectif SLA :** Saturation d'une liaison **1 à 10 Gbps**, écriture disque parallèle sans `Mutex` (`pwrite` / `FileExt::write_at`), zéro fusion finale de fichiers temporaires, reprise exacte au byte près après pause ou crash.

---

## 1. Contexte & Objectif

Le gestionnaire de téléchargement ("FastDown") est le second pilier majeur de l'application (téléchargement de films VOD, saisons complètes de séries ou liens HTTP directs).  
En Rust natif sur Unix (macOS/iOS), nous pouvons surpasser radicalement l'implémentation Dart grâce à **`std::os::unix::fs::FileExt::write_at`** (appel système atomique `pwrite`) : tous les segments écrivent simultanément à leurs offsets respectifs dans le même fichier `.part` pré-alloué **sans aucun verrou mutuel ni étape de concaténation finale**.

---

## 2. Fichiers à Créer / Modifier

- `crates/cnd-core/src/downloader/mod.rs` *(orchestrateur `DownloadManager`, file `Semaphore`, états, EMA débit/ETA)*
- `crates/cnd-core/src/downloader/prober.rs` *(`HEAD` + fallback `GET Range: bytes=0-0`, `Content-Disposition`, sanitization nom fichier)*
- `crates/cnd-core/src/downloader/worker.rs` *(`SegmentWorker` async streaming + `spawn_blocking` / `write_at`, retry exponentiel)*
- `crates/cnd-core/src/db/download_repo.rs` *(CRUD `download_tasks`, `download_parts`, `download_logs`)*
- `crates/cnd-core/src/lib.rs` *(exports UniFFI complets + listener de progression optionnel)*
- `crates/cnd-cli/src/main.rs` *(test/commande de téléchargement CLI)*

---

## 3. Spécifications Techniques Détaillées

### 3.1. Sonde HTTP Robuste (`prober.rs`)
Beaucoup de serveurs VOD IPTV rejettent `HEAD` (`405 Method Not Allowed` ou `403`) ou ne renvoient la vraie taille qu'après redirection sur un `GET` :
1. Tenter `HEAD` avec `User-Agent`, `Referer` et headers personnalisés de la tâche.
2. Si statut `>= 400` ou `Content-Length` absent, exécuter immédiatement un fallback `GET` avec header `Range: bytes=0-0` (puis fermer le body dès lecture des headers !).
3. Extraire :
   - `final_url` (après redirections — crucial sur les CDN IPTV dont le token de redirection expire ou change d'hôte).
   - `total_bytes` via `Content-Range: bytes 0-0/123456789` en priorité, sinon `Content-Length`.
   - `accept_ranges = status == 206 || headers["accept-ranges"].contains("bytes")`.
   - `real_file_name` via `Content-Disposition` (`filename*=UTF-8''...` ou `filename="..."`), sinon dernier segment de `final_url`, nettoyé des caractères interdits (`/\:*?"<>|`).

### 3.2. Découpage Multi-Segments & Écriture `write_at` (`worker.rs`)
1. **Préparation du fichier :**
   - Créer le dossier cible s'il n'existe pas. Gérer les collisions de noms (`film (1).mkv`).
   - Ouvrir `temp_path` (`<save_path>.part`) avec `OpenOptions::new().create(true).write(true).read(true)`.
   - Si `total_bytes > 0`, pré-allouer `file.set_len(total_bytes)`. Partager le descripteur via `Arc<std::fs::File>`.
2. **Calcul des segments (`download_parts`) :**
   - Si reprise d'une tâche existante ayant déjà ses `download_parts` en SQLite : reprendre uniquement les parts non `completed` à partir de `byte_start + downloaded_bytes` !
   - Sinon, si `accept_ranges && total_bytes > 2 * 1024 * 1024` : créer `N = settings.segments_per_file.max(1)` segments équilibrés dans `download_parts`.
   - Sinon (`!accept_ranges` ou taille inconnue) : 1 seul segment streaming séquentiel.
3. **Boucle d'écriture haute performance :**
   - Accumuler les chunks réseau dans un buffer mémoire de **256 Ko à 512 Ko** par segment avant d'appeler `file.write_at(&buf, current_offset)` afin de minimiser le nombre d'appels système `pwrite` tout en gardant une RAM très basse (`8 segments * 512 Ko = 4 Mo` seulement !).
   - Mettre à jour un compteur atomique en mémoire `AtomicU64` pour un suivi temps réel instantané, et persister l'avancement des `download_parts` dans SQLite toutes les **500 ms** (et systématiquement lors d'un `pause` / `cancel` / `error`).
4. **Finalisation atomique :**
   - Dès que tous les segments sont `completed`, appeler `file.sync_data()`, puis `std::fs::rename(&temp_path, &save_path)` et passer la tâche à `completed`.

### 3.3. Orchestration, File d'Attente & Calcul EMA Vitesse/ETA (`mod.rs`)
- **Concurrence contrôlée :** Un `tokio::sync::Semaphore` global (ajustable selon `settings.max_active_files`) met automatiquement en file d'attente (`queued`) les tâches excédentaires et démarre la suivante dès qu'un téléchargement se termine ou est mis en pause.
- **Annulation propre :** `CancellationToken` (`tokio_util::sync::CancellationToken`) par tâche active pour interrompre instantanément tous ses `SegmentWorker` lors d'un `pause_download(task_id)` ou `remove_download(task_id, delete_file)`.
- **Lissage EMA de la vitesse :** Toutes les 250 ms (4 Hz), calculer `instant_bps` et appliquer `ema_bps = alpha * instant_bps + (1.0 - alpha) * prev_bps` (avec `alpha = settings.speed_smoothing`), puis `eta_seconds = remaining_bytes / ema_bps`.
- **Récupération au démarrage :** Au lancement de `CndEngine`, toute tâche restée à l'état `running` suite à une fermeture brutale de l'app repasse proprement à l'état `paused` (prête à reprendre sans perte).

### 3.4. Signatures UniFFI (`CndEngine`)
```rust
#[derive(Debug, Clone, uniffi::Record)]
pub struct NewDownloadRequest {
    pub url: String,
    pub file_name: Option<String>,
    pub save_dir: String,
    pub user_agent: Option<String>,
    pub referer: Option<String>,
    pub headers_json: Option<String>,
    pub auto_start: bool,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct DownloadTaskRecord {
    pub id: i64,
    pub url: String,
    pub file_name: String,
    pub save_path: String,
    pub total_bytes: u64,
    pub downloaded_bytes: u64,
    pub accept_ranges: bool,
    pub state: String,       // "queued" | "running" | "paused" | "completed" | "error"
    pub speed_bps: f64,
    pub eta_seconds: u64,
    pub parts: Vec<DownloadPartRecord>,
    pub updated_at: i64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct DownloadPartRecord {
    pub part_index: u32,
    pub byte_start: u64,
    pub byte_end: u64,
    pub downloaded_bytes: u64,
    pub state: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct DownloadLogRecord {
    pub id: i64,
    pub timestamp: i64,
    pub level: String,
    pub message: String,
}

#[uniffi::export(async_runtime = "tokio")]
impl CndEngine {
    pub async fn enqueue_download(&self, req: NewDownloadRequest) -> Result<i64, CndError>;
    pub async fn start_download(&self, task_id: i64) -> Result<(), CndError>;
    pub async fn pause_download(&self, task_id: i64) -> Result<(), CndError>;
    pub async fn retry_download(&self, task_id: i64) -> Result<(), CndError>;
    pub async fn remove_download(&self, task_id: i64, delete_files: bool) -> Result<(), CndError>;
    pub async fn start_all_downloads(&self) -> Result<(), CndError>;
    pub async fn pause_all_downloads(&self) -> Result<(), CndError>;
    pub fn list_downloads(&self, query: Option<String>) -> Result<Vec<DownloadTaskRecord>, CndError>;
    pub fn get_download_logs(&self, task_id: i64, limit: u32) -> Result<Vec<DownloadLogRecord>, CndError>;
}
```

---

## 4. Contraintes Non-Négociables (Guardrails IA)
- **Vérification d'intégrité binaire obligatoire en test :** Un fichier téléchargé en 4 ou 8 segments parallèles (y compris avec une pause/reprise au milieu !) **DOIT** avoir exactement le même hash `blake3` / `SHA-256` que le payload servi par le serveur HTTP de test local (`tokio::net::TcpListener`).
- Aucun `Mutex` global autour des écritures disque (`write_at` uniquement).

---

## 5. Critères d'Acceptation & Commandes de Validation
1. Serveur HTTP local de test dans `crates/cnd-core/src/downloader/` (supportant `HEAD` et `Range: bytes=start-end`) :
   - Test d'un téléchargement 8 segments d'un buffer binaire aléatoire de 8 Mo + vérification du hash `blake3`.
   - Test de `pause_download` à ~50 %, réouverture base SQLite, `start_download` (reprise Range) + vérification du hash `blake3` final.
   - Test du fallback `Prober` quand `HEAD` renvoie `405 Method Not Allowed`.
2. Exécuter :
   ```bash
   cd cnd-iptv-native
   cargo test --workspace
   cargo clippy --workspace -- -D warnings
   ./scripts/build-xcframework.sh
   cd apple/Packages/CndCoreBridge && swift test
   ```

