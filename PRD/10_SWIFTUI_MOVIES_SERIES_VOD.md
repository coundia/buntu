# PRD 10 — UI SwiftUI : Catalogue Films (VOD) & Séries Multi-Saisons

- **ID :** `PRD-10`
- **Prérequis :** `PRD-05` (Catalogue/Séries/Progression), `PRD-06` (OMDb Metadata), `PRD-07` (Download Engine), `PRD-08` (Lecteur Vidéo), `PRD-09` (AppShell & Cache Images)
- **Couches impactées :** `SwiftUI (apple/Sources/CndIptvApp/Features/Movies/ & Series/)`
- **Référence Flutter migrée :** `lib/ui/pages/movies_page.dart`, `lib/ui/pages/movies/movie_details_page.dart`, `lib/ui/pages/series_page.dart`, `lib/ui/pages/series_details_page.dart`, `lib/ui/pages/seriesCard.dart`
- **Objectif SLA :** Grille de posters 120 fps, ouverture d'une fiche Film ou Série **< 50 ms** (puis enrichissement asynchrone OMDb fluide), téléchargement interne en **1 clic** (corrigeant le bug `launchUrl` externe de Flutter).

---

## 1. Contexte & Objectif

Ce PRD implémente l'expérience complète Vidéo à la Demande (**Films** et **Séries**) de style Apple TV / Infuse :
- Navigation par catégories, recherche FTS5, filtre par serveur (`host`) et tri par **Note IMDb**, Nom ou Ajouts récents.
- Fiches détaillées riches avec synopsis, note IMDb, casting, réalisateur, reprise de lecture (*"Reprendre à 42:15"*), ouverture lecteur externe et **envoi direct au gestionnaire de téléchargement multi-segments Rust** (pour un film, un épisode ou une saison entière).

---

## 2. Fichiers à Créer / Modifier

- `apple/Sources/CndIptvApp/Features/Movies/MoviesCatalogView.swift` *(grille adaptative de posters 2:3 & vue liste, Sidebar catégories, sections Reprendre / Favoris / Tous les films)*
- `apple/Sources/CndIptvApp/Features/Movies/MoviePosterCard.swift` *(poster downsamplé, badge note IMDb `★ 8.2`, barre de progression de lecture entamée, hover macOS & menu contextuel)*
- `apple/Sources/CndIptvApp/Features/Movies/MovieDetailsView.swift` *(hero backdrop/poster flouté, métadonnées OMDb, panneau debug OMDb optionnel, actions Lire / Reprendre / Télécharger / Externe / Copier FFmpeg)*
- `apple/Sources/CndIptvApp/Features/Series/SeriesCatalogView.swift` *(catalogue paginé sur `SeriesRecord` normalisé, badges nombre de saisons & épisodes, favoris unifiés)*
- `apple/Sources/CndIptvApp/Features/Series/SeriesDetailsView.swift` *(sélecteur par Saison `S1, S2...`, hydratation auto Xtream si nécessaire, lecture d'épisode ou *"Lire toute la saison"*, téléchargement unitaire ou *"Télécharger toute la saison"*)*

---

## 3. Spécifications Techniques Détaillées

### 3.1. Catalogue Films (`MoviesCatalogView` & `MovieDetailsView`)
1. **Grille Responsive & Mode Liste :**
   - Grille d'affiches ratio `2:3` utilisant `LazyVGrid(columns: [GridItem(.adaptive(minimum: 155, maximum: 210), spacing: 16)])` sur macOS/iPad et 2–3 colonnes sur iPhone, avec bascule Mode Liste mémorisée dans `@AppStorage("movies.viewMode")`.
   - Afficher sur chaque affiche une barre de progression si `resumePositionMs > 0` (*Continue Watching*).
2. **Enrichissement OMDb Automatique (`MovieDetailsView`) :**
   - Dès l'ouverture de la fiche d'un film, afficher instantanément les infos SQLite existantes, puis déclencher en tâche de fond `engine.fetchItemMetadata(itemId, apiKey, forceRefresh: false)` (clé lue depuis `KeychainStore`).
   - Afficher : Titre propre, Année, Classification (`PG-13`...), Durée, Genres sous forme de pills, Note IMDb & Metascore, Réalisateur, Acteurs, Synopsis complet.
3. **Actions Complètes (Correction du Bug Flutter) :**
   - **Lire / Reprendre :** Si `resumePositionMs > 30_000` et non terminé, proposer *"Reprendre (HH:MM:SS)"* ET *"Recommencer depuis le début"*.
   - **Télécharger (Interne !) :** Contrairement à `MoviesPage._download` sur Flutter qui ouvrait un navigateur externe, le bouton *Télécharger* (sur la carte ET dans la fiche détail) appelle directement `engine.enqueueDownload(...)` (`PRD-07`) avec les headers HTTP du film et affiche un toast de confirmation avec lien vers l'onglet *Téléchargements* !
   - **Menu Avancé :** *Ouvrir dans IINA / VLC / Infuse*, *Copier l'URL*, *Copier la commande FFmpeg*, *Copier la commande cURL*, *Rafraîchir les métadonnées OMDb*.

### 3.2. Catalogue Séries & Saisons (`SeriesCatalogView` & `SeriesDetailsView`)
1. **Catalogue Basé sur `series_catalog` :**
   - Affiche chaque série une seule fois avec son nombre total de saisons et d'épisodes exact (`seasonCount`, `episodeCount`), même sur une playlist de 80 000 épisodes !
   - Favoris unifiés via `engine.toggleFavorite(stableHash: series.stableHash, itemKind: "series")`.
2. **Fiche Série Multi-Saisons (`SeriesDetailsView`) :**
   - Si la source est de type `xtream` et `episodeCount == 0`, appeler automatiquement `engine.ensureXtreamSeriesEpisodes(seriesDbId, password)` avec un indicateur de chargement fluide.
   - Onglets / Picker segmenté par Saison (`Saison 1`, `Saison 2`, ... via `getSeriesSeasons`).
   - Enrichissement OMDb de la série via `fetchSeriesMetadata`.
   - **Actions Globales de Saison :**
     - **"Lire toute la saison" / "Lire toute la série"** : charge tous les épisodes dans la `PlaylistQueue` du lecteur (`PRD-08`).
     - **"Télécharger toute la saison"** : ajoute proprement tous les épisodes de la saison sélectionnée dans un sous-dossier dédié `<DownloadDir>/<Nom de la Série>/Season <XX>/` via `enqueueDownload` !
   - **Actions par Épisode :** Lecture directe, reprise au timecode, téléchargement individuel, ouverture externe, copie commande `ffmpeg`.

---

## 4. Contraintes Non-Négociables (Guardrails IA)
- **Noms de fichiers téléchargés sains :** Toujours nettoyer les titres de films/séries/épisodes avant de construire `save_dir` et `file_name` (ex: `S01E01 - Titre.mkv`).
- Aucune requête OMDb déclenchée en boucle pendant le simple scroll de la grille (uniquement à l'ouverture de la fiche détail ou sur action explicite, les notes déjà en cache s'affichant directement depuis SQLite).

---

## 5. Critères d'Acceptation & Commandes de Validation
1. Vérifier que le clic sur *Télécharger* depuis la grille Films, la fiche Film, un épisode ou une saison complète crée bien les tâches dans `DownloadEngine` avec les bons chemins et headers HTTP.
2. Vérifier la compilation sur macOS et iOS Simulator :
   ```bash
   cd cnd-iptv-native/apple
   xcodebuild -scheme CndIptvNative -destination 'generic/platform=macOS' build
   xcodebuild -scheme CndIptvNative -destination 'generic/platform=iOS Simulator' build
   ```

