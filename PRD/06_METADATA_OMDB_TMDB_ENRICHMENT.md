# PRD 06 — Enrichissement Métadonnées VOD & Séries (OMDb / TMDB) avec Cache SQLite

- **ID :** `PRD-06`
- **Prérequis :** `PRD-01`, `PRD-05`
- **Couches impactées :** `Rust (cnd-core)`, `UniFFI`
- **Référence Flutter migrée :** `lib/services/movie_meta_service.dart`, logique `_explodeTitleYear` / `_fetchOmdb` / `_persistOmdbToDb` de `lib/ui/pages/movies/movie_details_page.dart`
- **Objectif SLA :** Retour depuis le cache SQLite **< 1 ms**, appel réseau OMDb à froid **< 400 ms**, zéro appel redondant pour un même film/série.

---

## 1. Contexte & Objectif

Dans la version Flutter, la logique OMDb était codée directement à l'intérieur du widget UI `MovieDetailsPage` (violant la séparation des couches) et ne stockait que 3 champs (`imdbId`, `imdbRating`, `imdbDescription`), obligeant à rappeler l'API à chaque ouverture pour récupérer le casting, le réalisateur, les genres, la durée ou le poster HD.

Ce PRD centralise l'enrichissement de métadonnées dans `cnd-core/src/metadata/` pour **les Films ET les Séries**, avec un cache SQLite complet et un mode diagnostic inspectable.

---

## 2. Fichiers à Créer / Modifier

- `crates/cnd-core/src/db/schema.rs` *(ajout table `media_metadata_cache`)*
- `crates/cnd-core/src/metadata/mod.rs` *(client OMDb + extracteur Titre/Année avancé + persistance SQLite)*
- `crates/cnd-core/src/lib.rs` *(exports UniFFI)*

---

## 3. Spécifications Techniques Détaillées

### 3.1. Table de Cache Riche (`media_metadata_cache`)
Ajouter dans `schema.rs` :
```sql
CREATE TABLE IF NOT EXISTS media_metadata_cache (
    lookup_key TEXT PRIMARY KEY, -- ex: "movie:inception:2010" ou "imdb:tt1375666"
    imdb_id TEXT,
    title TEXT NOT NULL,
    year TEXT,
    rated TEXT,
    released TEXT,
    runtime TEXT,
    genres TEXT,
    director TEXT,
    actors TEXT,
    plot TEXT,
    language TEXT,
    country TEXT,
    awards TEXT,
    poster_url TEXT,
    imdb_rating REAL,
    imdb_votes TEXT,
    metascore TEXT,
    media_type TEXT,             -- "movie" | "series"
    fetched_at INTEGER NOT NULL
);
```

### 3.2. Extracteur Intelligent Titre + Année (`explode_title_year`)
Porter et améliorer l'algorithme `_explodeTitleYear` de `movie_details_page.dart` en Rust :
1. Supprimer le contenu entre crochets/parenthèses/accolades parasites (`[FR]`, `(MULTI)`, `{4K}`), **tout en capturant une année valide `(19\d{2}|20\d{2})`** si elle s'y trouve !
2. Découper sur les séparateurs `[-|·•–—:]` en préservant les sous-titres légitimes des films.
3. Filtrer la liste noire insensible à la casse (`FR`, `VF`, `VFF`, `VFQ`, `VOSTFR`, `TRUEFRENCH`, `FRENCH`, `MULTI`, `MULTILANG`, `EN`, `ENG`, `VO`, `SUBFRENCH`, `HD`, `FHD`, `UHD`, `1080P`, `720P`, `2160P`, `4K`, `HDR`, `HEVC`, `X264`, `X265`, `WEBDL`, `WEB-DL`, `BLURAY`, `BDRIP`).
4. Stratégie de recherche OMDb en cascade (avec `HttpClientPool` de `PRD-01` pour que les requêtes apparaissent automatiquement dans la Console Réseau !) :
   - **Étape 1 :** Si `item.imdb_id` est déjà connu (`tt...`), appeler `https://www.omdbapi.com/?i={imdb_id}&plot=full&r=json&apikey={api_key}`.
   - **Étape 2 :** Sinon, appeler avec `t={title}&y={year}&type={movie|series}&plot=full`.
   - **Étape 3 (Fallback) :** Si non trouvé avec `year` (souvent décalée d'1 an sur les VOD IPTV), réessayer sans le paramètre `y`.
5. **Persistance double :**
   - Sauvegarder la fiche complète dans `media_metadata_cache` (TTL cache : 30 jours).
   - Mettre à jour `imdb_id`, `imdb_rating`, `plot` (et `poster_url` si manquant) sur `iptv_items` ou `series_catalog` afin que le tri par `Rating` du catalogue (`PRD-05`) en bénéficie immédiatement !

### 3.3. Signatures UniFFI (`CndEngine`)
```rust
#[derive(Debug, Clone, uniffi::Record)]
pub struct MediaMetadata {
    pub imdb_id: Option<String>,
    pub title: String,
    pub year: Option<String>,
    pub rated: Option<String>,
    pub runtime: Option<String>,
    pub genres: Option<String>,
    pub director: Option<String>,
    pub actors: Option<String>,
    pub plot: Option<String>,
    pub poster_url: Option<String>,
    pub imdb_rating: Option<f64>,
    pub imdb_votes: Option<String>,
    pub metascore: Option<String>,
    pub from_cache: bool,
}

#[uniffi::export(async_runtime = "tokio")]
impl CndEngine {
    pub async fn fetch_item_metadata(
        &self,
        item_id: i64,
        api_key: String,
        force_refresh: bool,
    ) -> Result<Option<MediaMetadata>, CndError>;

    pub async fn fetch_series_metadata(
        &self,
        series_id: i64,
        api_key: String,
        force_refresh: bool,
    ) -> Result<Option<MediaMetadata>, CndError>;
}
```

---

## 4. Contraintes Non-Négociables (Guardrails IA)
- Ne jamais coder en dur de clé API OMDb dans le binaire Rust (contrairement à `settings.dart` qui contenait une clé en dur). La clé est passée depuis Swift (`KeychainStore` / réglages utilisateur) ; si elle est vide, retourner `Ok(None)` immédiatement sans erreur.
- Vérifier que `apikey=...` est bien masqué (`***`) dans les logs de `TelemetryHub`.

---

## 5. Critères d'Acceptation & Commandes de Validation
1. Tests unitaires Rust validant `explode_title_year` sur au moins 10 formats de titres IPTV réels complexes (ex: `"|FR| Oppenheimer (2023) MULTi TRUEFRENCH 4K HDR"`, `"FR - Inception - 2010 - 1080p"`, `"The Dark Knight [2008] VOSTFR"`).
2. Test du cache SQLite (`from_cache == true` au second appel) et de la mise à jour de `iptv_items.imdb_rating`.
3. Exécuter :
   ```bash
   cd cnd-iptv-native
   cargo test --workspace
   cargo clippy --workspace -- -D warnings
   ./scripts/build-xcframework.sh
   cd apple/Packages/CndCoreBridge && swift test
   ```

