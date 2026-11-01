# PRD 04 — Moteur EPG XMLTV en Streaming (`.xml` / `.xml.gz`)

- **ID :** `PRD-04`
- **Prérequis :** `PRD-01`
- **Couches impactées :** `Rust (cnd-core)`, `UniFFI`, `CLI (cnd-cli)`
- **Référence `docs/migration.md` & `prd_migration.md` :** Section 4.1 / 4.2.C (Guide TV électronique temps réel)
- **Objectif SLA :** Empreinte RAM **< 10 Mo** même sur un fichier XMLTV décompressé de **800 Mo**, requête *Now/Next* pour 50 chaînes visibles **< 2 ms**.

---

## 1. Contexte & Objectif

Un client IPTV haut de gamme doit afficher en direct le programme en cours (*Now*), le programme suivant (*Next*), la barre de progression temporelle et la grille horaire complète.  
Les fichiers XMLTV fournis par les opérateurs IPTV (ou `xmltv.php` sur Xtream) pèsent fréquemment entre **100 Mo et 800 Mo** (souvent compressés en `.xml.gz`). Charger un DOM XML en mémoire provoquerait un crash immédiat sur iOS.

Ce PRD implémente un **moteur XMLTV 100 % événementiel (SAX/pull parser)** avec décompression Gzip à la volée, filtrage intelligent des chaînes connues et indexation SQLite.

---

## 2. Fichiers à Créer / Modifier

- `crates/cnd-core/src/iptv/epg.rs` *(nouveau — décompression `.gz` + pull parser `quick-xml` + parseur de timestamps XMLTV)*
- `crates/cnd-core/src/db/epg_repo.rs` *(nouveau — batch insert, purge expirés, requêtes Now/Next et Timeline)*
- `crates/cnd-core/src/lib.rs` *(exports UniFFI EPG)*

---

## 3. Spécifications Techniques Détaillées

### 3.1. Pipeline Réseau + Décompression Streaming
1. Supporter plusieurs URLs EPG séparées par virgule dans `iptv_sources.epg_url` (standard `x-tvg-url="url1,url2"`).
2. Détecter automatiquement une archive Gzip :
   - Soit par l'extension `.gz` / header `Content-Type: application/gzip` / `application/x-gzip`.
   - Soit par lecture des **2 premiers octets magiques** (`0x1f 0x8b`) via `BufRead::fill_buf()` ! (Beaucoup d'URLs `xmltv.php` renvoient du Gzip sans extension `.gz`).
   - Envelopper alors le flux dans `async_compression::tokio::bufread::GzipDecoder`.

### 3.2. Pull-Parsing XMLTV (`quick_xml::Reader`)
Lire uniquement les balises `<programme start="..." stop="..." channel="...">` :
- **Filtrage précoce anti-bruit :** Charger au début du sync le `HashSet<String>` des `tvg_id` réellement présents dans `iptv_items` (quelques Mo max). Si l'attribut `channel` d'un `<programme>` n'appartient pas au `HashSet` (ou si `stop_ts < now - 6h`), sauter immédiatement l'élément (`reader.read_to_end_into(...)`) sans allouer ses sous-chaînes `<title>`/`<desc>` ! Ce seul filtre accélère l'ingestion EPG d'un facteur **5x à 10x** et réduit la taille de la base SQLite de 80 %.
- **Sous-balises extraites :** `<title>`, `<sub-title>`, `<desc>`, `<category>`.
- **Parseur de Timestamp XMLTV Haute Vitesse :**
  - Format standard : `YYYYMMDDHHMMSS +HHMM` ou `YYYYMMDDHHMMSS` (ex: `"20261101205000 +0100"`).
  - Convertir directement les chiffres ASCII en timestamp Unix UTC (`i64` secondes) avec prise en compte de l'offset horaire `+HHMM` / `-HHMM` et de l'éventuel `epg_shift` de la chaîne, sans allocation de `String`.
- **Insertion par lots SQLite :** Lots de `5 000` programmes dans `epg_programs`, précédés d'une purge des programmes terminés depuis plus de 24h (`DELETE FROM epg_programs WHERE end_ts < ?1`).

### 3.3. Requêtes EPG Ultra-Rapides (`epg_repo.rs`)
```rust
#[derive(Debug, Clone, uniffi::Record)]
pub struct EpgProgramRecord {
    pub id: i64,
    pub channel_tvg_id: String,
    pub start_ts: i64,
    pub end_ts: i64,
    pub title: String,
    pub subtitle: Option<String>,
    pub description: Option<String>,
    pub category: Option<String>,
    pub progress_ratio: f64, // 0.0..=1.0 calculé par rapport à now_ts
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct ChannelNowNext {
    pub channel_tvg_id: String,
    pub now: Option<EpgProgramRecord>,
    pub next: Option<EpgProgramRecord>,
}
```
- **`get_epg_now_next_batch(tvg_ids: Vec<String>) -> Vec<ChannelNowNext>` :** Permet à SwiftUI de récupérer en **1 seul appel FFI** les programmes *En cours* et *Suivant* des 30–50 chaînes affichées à l'écran lors du scroll !
- **`get_channel_epg_timeline(tvg_id: String, from_ts: i64, to_ts: i64) -> Vec<EpgProgramRecord>` :** Pour l'affichage détaillé et la grille TV multi-heures.

### 3.4. Signatures UniFFI (`CndEngine`)
```rust
#[uniffi::export(async_runtime = "tokio")]
impl CndEngine {
    pub async fn refresh_source_epg(&self, source_id: i64, password: Option<String>) -> Result<u32, CndError>;
    pub fn get_epg_now_next(&self, tvg_ids: Vec<String>) -> Result<Vec<ChannelNowNext>, CndError>;
    pub fn get_channel_epg(&self, tvg_id: String, from_ts: i64, to_ts: i64) -> Result<Vec<EpgProgramRecord>, CndError>;
}
```

---

## 4. Contraintes Non-Négociables (Guardrails IA)
- **Zéro DOM XML en RAM :** Utiliser uniquement `quick_xml::Reader::from_reader` / lecteur asynchrone par buffer réutilisé (`buf.clear()` à chaque boucle).
- Réutiliser le même `Vec<u8>` d'événement XML pour éviter toute pression sur l'allocateur.

---

## 5. Critères d'Acceptation & Commandes de Validation
1. Tests unitaires Rust couvrant :
   - Parsing exact des timestamps XMLTV avec fuseaux horaires positifs, négatifs et sans fuseau (`+0200`, `-0500`, UTC).
   - Parsing d'un flux XMLTV compressé en **Gzip** en mémoire (avec détection des octets magiques `0x1f 0x8b`).
   - Requête `get_epg_now_next` calculant exactement `now`, `next` et `progress_ratio`.
2. Exécuter :
   ```bash
   cd cnd-iptv-native
   cargo test --workspace
   cargo clippy --workspace -- -D warnings
   ./scripts/build-xcframework.sh
   cd apple/Packages/CndCoreBridge && swift test
   ```

