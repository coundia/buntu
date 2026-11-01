# PRD 05 — Requêtes Catalogue Avancées, Séries Normalisées, Favoris & Historique VOD

- **ID :** `PRD-05`
- **Prérequis :** `PRD-02` (et compatible `PRD-03`)
- **Couches impactées :** `Rust (cnd-core)`, `UniFFI`
- **Référence Flutter migrée :** `lib/viewmodels/iptv_vm.dart`, `lib/state/favorites_store.dart`, `lib/state/recents_store.dart`
- **Objectif SLA :** Toutes les requêtes paginées, filtres facettes (Groupes/Hosts), Favoris et Historique répondent en **< 5 ms** sur 150 000 items.

---

## 1. Contexte & Objectif

Lors de l'audit de l'application Flutter (`rapport_implementation.md`), **3 bugs majeurs d'architecture** ont été identifiés :
1. Les sections *Favoris* et *Récemment consultés* ne filtraient que les 50 premiers items chargés en mémoire : un favori situé au rang 500 n'apparaissait jamais !
2. `SeriesPage` utilisait un store de favoris séparé (`series.favs`) incompatible avec le reste de l'application.
3. Les séries étaient paginées par épisode brut et non par série complète.

Ce PRD enrichit `DatabaseManager` et `CndEngine` pour fournir à SwiftUI une **API de catalogue complète, cohérente et ultra-rapide**, exécutée à 100 % dans SQLite.

---

## 2. Fichiers à Créer / Modifier

- `crates/cnd-core/src/db/catalog_repo.rs` *(nouveau — facettes, tris dynamiques, séries/saisons/épisodes, favoris, historique/reprise)*
- `crates/cnd-core/src/db/mod.rs` *(délégation propre vers `catalog_repo`)*
- `crates/cnd-core/src/lib.rs` *(exports UniFFI)*

---

## 3. Spécifications Techniques Détaillées

### 3.1. Facettes Dynamiques avec Compteurs (Groupes & Hosts)
Au lieu de renvoyer de simples `String` sans volume, renvoyer les compteurs exacts en SQL (`GROUP BY`) pour la Sidebar style Apple :
```rust
#[derive(Debug, Clone, uniffi::Record)]
pub struct FacetCount {
    pub value: String,
    pub count: u32,
}
```
- `get_groups(kind: String, source_id: Option<i64>) -> Vec<FacetCount>` : pour `live`, `movie` ou `series` (requête sur `series_catalog` quand `kind == "series"`).
- `get_hosts(kind: String, source_id: Option<i64>) -> Vec<FacetCount>`.

### 3.2. Tri Multi-Critères & Filtres Combinés sur `query_items`
Faire évoluer la requête d'items (`IptvQueryFilter`) :
```rust
#[derive(Debug, Clone, Copy, uniffi::Enum)]
pub enum SortField {
    Name,
    Group,
    Host,
    Rating,
    RecentlyAdded,
    ChannelNumber,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct CatalogFilter {
    pub kind: String,               // "live" | "movie"
    pub source_id: Option<i64>,
    pub query: String,              // FTS5 multi-termes préfixés ("canal* sport*")
    pub group_title: Option<String>,
    pub host: Option<String>,
    pub favorites_only: bool,
    pub sort_by: SortField,
    pub sort_asc: bool,
    pub limit: u32,
    pub offset: u32,
}
```
- **Enrichissement du `IptvItemRecord` :** S'assurer que `IptvItemRecord` expose également les champs nécessaires au lecteur vidéo et aux détails (`user_agent`, `referer`, `headers_json`, `catchup_type`, `catchup_days`, `plot`, `resume_position_ms`, `duration_ms`).

### 3.3. Catalogue des Séries Normalisées & Saisons / Épisodes
```rust
#[derive(Debug, Clone, uniffi::Record)]
pub struct SeriesRecord {
    pub id: i64,
    pub source_id: i64,
    pub canonical_key: String,
    pub stable_hash: String,        // "series:" + blake3(source_uuid + canonical_key) pour Favoris/Récents !
    pub title: String,
    pub group_title: Option<String>,
    pub poster_url: Option<String>,
    pub backdrop_url: Option<String>,
    pub imdb_id: Option<String>,
    pub imdb_rating: Option<f64>,
    pub plot: Option<String>,
    pub episode_count: u32,
    pub season_count: u32,
    pub is_favorite: bool,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct SeasonSummary {
    pub season_num: u32,
    pub episode_count: u32,
}
```
- `query_series(filter: CatalogFilter) -> Vec<SeriesRecord>` : paginé sur `series_catalog` (avec recherche sur `title`/`group_title`, tri par `title` ou `imdb_rating`, et jointure `favorites`).
- `get_series_seasons(series_id: i64) -> Vec<SeasonSummary>`.
- `get_series_episodes(series_id: i64, season_num: Option<u32>) -> Vec<IptvItemRecord>` : triés par `(season_num ASC, episode_num ASC)` avec leur progression de lecture individuelle (`watch_history`).

### 3.4. Favoris Globaux & Historique / Reprise de Lecture (`Continue Watching`)
Requêtes SQL directes par `JOIN` (totalement indépendantes de l'offset de pagination du catalogue principal !) :
- `list_favorite_items(kind: String) -> Vec<IptvItemRecord>`
- `list_favorite_series() -> Vec<SeriesRecord>`
- `record_watch_progress(stable_hash: String, position_ms: i64, duration_ms: i64) -> Result<(), CndError>` :
  - Marque automatiquement `completed = 1` si `duration_ms > 0 && (position_ms as f64 / duration_ms as f64) >= 0.92`.
  - Pour une chaîne Live (`duration_ms == 0`), enregistre simplement `last_watched_at` pour alimenter la section *Récemment consultés*.
- `list_recent_items(kind: String, limit: u32) -> Vec<IptvItemRecord>` (trié par `last_watched_at DESC`).
- `list_recent_series(limit: u32) -> Vec<SeriesRecord>` (séries dont au moins un épisode a été visionné récemment, triées par `MAX(last_watched_at) DESC`).

---

## 4. Contraintes Non-Négociables (Guardrails IA)
- **Zéro concaténation SQL non sécurisée :** Pour les clauses `ORDER BY` dynamiques (`SortField`), mapper exclusivement l'enum Rust vers des constantes statiques `&'static str` ; tous les filtres utilisateurs passent par des paramètres liés `?1, ?2...`.
- **Tokenisation FTS5 Robuste :** Échapper proprement les caractères spéciaux FTS5 (`"`, `*`, `-`, `:`, `(`, `)`) saisis par l'utilisateur (ex: `"Spider-Man: No Way"` ne doit **jamais** provoquer d'erreur de syntaxe FTS5 `no such column: No` ! Envelopper chaque terme nettoyé entre guillemets `"spider"* AND "man"*`).

---

## 5. Critères d'Acceptation & Commandes de Validation
1. Tests unitaires Rust obligatoires :
   - Recherche FTS5 avec caractères spéciaux (`"Spider-Man: No Way (2021)"`, `"C+"`, `"L'Équipe"` avec/sans accent).
   - Vérification qu'un favori situé au rang 1 000 est retourné par `list_favorite_items` même quand la page courante est à `offset = 0, limit = 50`.
   - Sauvegarde de `record_watch_progress` et passage automatique à `completed = true` au-delà de 92 %.
2. Exécuter :
   ```bash
   cd cnd-iptv-native
   cargo test --workspace
   cargo clippy --workspace -- -D warnings
   ./scripts/build-xcframework.sh
   cd apple/Packages/CndCoreBridge && swift test
   ```

