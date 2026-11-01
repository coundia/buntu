# PRD 03 — Client Natif Xtream Codes REST API & Sécurité Keychain Apple

- **ID :** `PRD-03`
- **Prérequis :** `PRD-01`, `PRD-02`
- **Couches impactées :** `Rust (cnd-core)`, `UniFFI`, `Swift (CndCoreBridge / KeychainHelper)`
- **Référence Flutter migrée :** `IptvRepository.addXtream` / `_buildXtreamM3u`, `SourceFormPage` (onglet Xtream)
- **Objectif SLA :** Synchronisation complète d'un compte Xtream (Live + VOD + Séries) **10x à 20x plus rapide** que le téléchargement M3U+, zéro mot de passe stocké en clair dans SQLite.

---

## 1. Contexte & Objectif

L'application Flutter transformait un compte Xtream Codes en simple lien `get.php?username=...&password=...&type=m3u_plus&output=ts` et stockait le mot de passe en clair dans Isar.  
Or, l'API native **`player_api.php`** de Xtream Codes :
1. Permet de télécharger en parallèle les flux Live, les Films VOD et le catalogue des Séries structuré avec **leurs vraies notes IMDb/TMDB, posters, synopsis, années et conteneurs**, sans avoir à parser un M3U géant de 150 Mo.
2. Fournit les informations du compte (statut actif/expiré, date d'expiration, nombre de connexions max/actives).
3. Doit conserver un **fallback automatique vers `get.php?type=m3u_plus`** (via le parseur du `PRD-02`) si un fournisseur bloque `player_api.php`.

---

## 2. Fichiers à Créer / Modifier

- `crates/cnd-core/src/iptv/xtream.rs` *(nouveau — client REST `player_api.php` + désérialisation Serde tolérante + fallback M3U+)*
- `crates/cnd-core/src/db/schema.rs` *(colonnes optionnelles info compte sur `iptv_sources` : `exp_date`, `max_connections`, `active_cons` ou table dédiée)*
- `crates/cnd-core/src/lib.rs` *(callback ou paramètre `SecretProvider` / passage sécurisé du mot de passe à l'exécution sans stockage SQL)*
- `apple/Sources/CndIptvApp/Security/KeychainStore.swift` *(nouveau — wrapper natif `Security.framework` / Keychain Apple)*

---

## 3. Spécifications Techniques Détaillées

### 3.1. Architecture Zéro Mot de Passe en Clair (Keychain ↔ `password_ref`)
- Dans SQLite (`iptv_sources`), la colonne `password_ref` contient uniquement une clé d'identifiant Keychain (ex: `"cnd.xtream.<source_uuid>"`), **jamais** le mot de passe brut.
- Côté Swift, `KeychainStore` stocke/lit/supprime le secret via `SecItemAdd` / `SecItemCopyMatching` / `SecItemDelete` (`kSecClassGenericPassword`, service `"com.cnd.iptv.credentials"`).
- Lors d'un `test_xtream_account` ou `refresh_xtream_source(source_id, password)`, Swift récupère le mot de passe dans le Keychain et le transmet en mémoire à Rust uniquement le temps de la synchronisation.
- Pour les sources `m3u` contenant des identifiants dans l'URL, l'URL d'origine est utilisée mais systématiquement masquée dans `TelemetryHub` (`PRD-01`).

### 3.2. Endpoints Xtream Codes (`player_api.php`)
Normaliser l'URL serveur (`http://host:port` sans slash final) :
1. **Authentification & Infos Compte :**
   - `GET {server}/player_api.php?username={u}&password={p}`
   - Extraire `user_info` (`status`, `exp_date`, `is_trial`, `active_cons`, `max_connections`) et `server_info` (`url`, `port`, `https_port`, `server_protocol`, `timezone`).
2. **Téléchargement Parallèle du Catalogue (`tokio::try_join!`) :**
   - **Catégories :** `action=get_live_categories`, `action=get_vod_categories`, `action=get_series_categories` → `HashMap<String, String>` (`category_id -> category_name`).
   - **Live TV :** `action=get_live_streams` → construit l'URL `{server}/live/{u}/{p}/{stream_id}.ts` (ou `.m3u8` selon préférence/support), récupère `name`, `stream_icon`, `epg_channel_id`, `category_id`, `tv_archive`, `tv_archive_duration`.
   - **VOD Films :** `action=get_vod_streams` → construit `{server}/movie/{u}/{p}/{stream_id}.{container_extension}`, récupère `name`, `stream_icon`, `rating` / `rating_5based`, `added`, `category_id`.
   - **Séries :** `action=get_series` → peuple directement `series_catalog` (`series_id` Xtream stocké dans `canonical_key = format!("xtream_series_{}", series_id)`, `name`, `cover`, `backdrop_path`, `plot`, `rating`, `releaseDate`, `category_id`).
3. **Chargement Paresseux (Lazy Hydration) des Épisodes d'une Série Xtream :**
   - Un fournisseur Xtream peut avoir 15 000 séries : appeler `get_series_info` 15 000 fois d'un coup ferait bannir l'IP !
   - À l'ouverture d'une série Xtream dont les épisodes ne sont pas encore en cache SQLite (ou périmés > 24h), appeler `GET {server}/player_api.php?username={u}&password={p}&action=get_series_info&series_id={xtream_id}`, insérer instantanément toutes ses saisons/épisodes (`{server}/series/{u}/{p}/{ep_id}.{ext}`) dans `iptv_items` et les retourner à l'UI en `< 250 ms` !
4. **Désérialisation Serde Ultra-Tolérante :**
   - Les panneaux Xtream renvoient souvent des types incohérents (`rating: "7.5"` en string OU `7.5` en float OU `""`, `stream_id` en int ou string, `backdrop_path` en array ou string). Utiliser des désérialiseurs personnalisés (`serde_with` ou helpers `deserialize_flexible_f64` / `deserialize_flexible_string`) pour ne **jamais** échouer sur un champ mal typé.
5. **Fallback Automatique M3U+ :**
   - Si `player_api.php` renvoie `404`/`403` ou un JSON invalide, basculer automatiquement sur `{server}/get.php?username={u}&password={p}&type=m3u_plus&output=ts` via le parseur streaming du `PRD-02`.
   - Définir automatiquement l'URL EPG XMLTV par défaut du compte Xtream : `{server}/xmltv.php?username={u}&password={p}`.

### 3.3. Signatures UniFFI (`CndEngine`)
```rust
#[derive(Debug, Clone, uniffi::Record)]
pub struct XtreamAccountInfo {
    pub status: String,
    pub exp_date_ts: Option<i64>,
    pub is_trial: bool,
    pub active_connections: u32,
    pub max_connections: u32,
    pub server_timezone: Option<String>,
}

#[uniffi::export(async_runtime = "tokio")]
impl CndEngine {
    pub async fn verify_xtream_account(
        &self,
        server: String,
        username: String,
        password: String,
    ) -> Result<XtreamAccountInfo, CndError>;

    pub async fn refresh_xtream_source(
        &self,
        source_id: i64,
        password: String,
    ) -> Result<SyncSummary, CndError>;

    pub async fn ensure_xtream_series_episodes(
        &self,
        series_db_id: i64,
        password: String,
    ) -> Result<u32, CndError>;
}
```

---

## 4. Contraintes Non-Négociables (Guardrails IA)
- **Zéro fuite d'identifiants :** Ni SQLite (`iptv_sources`), ni `TelemetryHub` ne doivent contenir le mot de passe Xtream en clair. Note : pour les `stream_url` Xtream générées localement contenant `/{u}/{p}/`, s'assurer que toute sortie log/console masque le segment mot de passe.
- **Désérialisation JSON en flux / chunked** ou désérialisation directe depuis `bytes` avec pré-allocation minimale et insertion immédiate par lots SQLite.

---

## 5. Critères d'Acceptation & Commandes de Validation
1. Tests unitaires Rust avec fixtures JSON réalistes de `player_api.php` (incluant des champs mal typés `""`, `null`, nombres en strings, arrays vides) pour Live, VOD, Series et `get_series_info`.
2. Test unitaire Swift validant l'écriture/lecture/suppression dans `KeychainStore`.
3. Exécuter :
   ```bash
   cd cnd-iptv-native
   cargo test --workspace
   cargo clippy --workspace -- -D warnings
   ./scripts/build-xcframework.sh
   cd apple/Packages/CndCoreBridge && swift test
   cd ../.. && xcodebuild -scheme CndIptvNative -destination 'generic/platform=macOS' build
   ```

