# PRD 18 — Dialogue Boost, normalisation du son & sous-titres OpenSubtitles

- **ID :** `PRD-18`
- **Prérequis :** `PRD-06` (IMDb ID via OMDb), `PRD-08` (Lecteur hybride), `PRD-11` (Réglages, Trousseau)
- **Couches impactées :** `SwiftUI / Player`, `Rust (crates/cnd-core/src/subtitles/)`, `UniFFI`
- **Origine :** `PRD-14` §4.4
- **Objectif SLA :** activation de Dialogue Boost **sans coupure audio perceptible** (< 300 ms), sous-titres trouvés et affichés **< 4 s** après la demande, décalage réglable par pas de 0,25 s.

Deux lots indépendants, validés séparément.

---

## Lot 18.1 — Dialogue Boost & mode nuit

### Spécifications

- **Chemin `mpv` :** chaîne de filtres audio via la propriété `af` :
  - Dialogue Boost : `lavfi=[highpass=f=100,equalizer=f=2500:t=q:w=1.2:g=6,dynaudnorm=f=200:g=15:p=0.9]` (valeurs dans des constantes, réglage d'intensité Faible / Moyen / Fort → gain 3 / 6 / 9 dB) ;
  - Mode nuit (compression de dynamique) : `lavfi=[acompressor=threshold=-24dB:ratio=6:attack=5:release=200,loudnorm=I=-23:TP=-2]` (cible EBU R128).
- **Chemin `AVPlayer` :** un `MTAudioProcessingTap` n'est pas applicable aux flux **HLS** (cas majoritaire en IPTV). Règle : si Dialogue Boost ou Mode nuit est activé pendant une lecture HLS, proposer de basculer sur `mpv` (préférence `enginePreference = .forceMpv` pour la session), avec un message explicite ; pour les fichiers locaux/progressifs, un tap `AVAudioMix` avec un EQ biquad maison peut suffire (facultatif).
- **Interface :** menu audio du HUD : « Dialogue Boost » (Désactivé / Faible / Moyen / Fort) et « Mode nuit ». Mémorisés globalement (`@AppStorage`).

### Fichiers
- `apple/Sources/CndIptvApp/Player/AudioEnhancement.swift` *(construction des chaînes de filtres, testable)*
- `Player/MpvVideoToolboxBackend.swift` *(application à chaud de `af`)*
- `Player/VideoBackendProtocol.swift`, `CndPlayerController.swift`, `CndVideoPlayerView.swift` *(API `setAudioEnhancement`, menu)*

---

## Lot 18.2 — Sous-titres OpenSubtitles

### Spécifications

- **API :** OpenSubtitles REST v1 (`https://api.opensubtitles.com/api/v1`), en-têtes `Api-Key: <clé utilisateur>` et `User-Agent: CndIPTV v1.0` ; connexion facultative (`/login`, jeton en mémoire) pour lever les quotas de téléchargement. Clé et identifiants dans le **Trousseau** (`cnd.opensubtitles.apikey`, `cnd.opensubtitles.user`). Vérifier les conditions et quotas de l'API au moment de l'implémentation.
- **Recherche (Rust, `subtitles/mod.rs`)**, par ordre de priorité :
  1. `moviehash` (hash OpenSubtitles 64 bits : taille + somme des 64 Kio de début et de fin) — pour un flux distant, calculé via deux requêtes `Range` (réutiliser la sonde de `downloader/prober.rs`) ; pour un fichier téléchargé, en local ;
  2. `imdb_id` (déjà connu par OMDb) + `season_number`/`episode_number` pour un épisode ;
  3. titre propre + année.
  Langues préférées réglables (défaut : langue du système puis anglais).
- **Téléchargement :** `/download` → lien → fichier `.srt` mis en cache dans `Caches/CndSubtitles/<hash>.<lang>.srt`. Conversion en WebVTT si nécessaire.
- **Affichage :**
  - `mpv` : commande `sub-add` sur le fichier en cache ;
  - `AVPlayer` : impossible d'injecter une piste externe dans un flux HLS distant ; rendu par une **surcouche SwiftUI** synchronisée sur `positionMs` (parseur SRT en Swift ou Rust, index par recherche dichotomique).
- **Décalage :** ±0,25 s par pas (`sub-delay` mpv / décalage de la surcouche), mémorisé par média.
- **Interface :** menu Sous-titres du HUD → « Rechercher en ligne… » (liste des résultats : langue, nom, note, téléchargements), « Décalage ». Réglages : clé OpenSubtitles, langues préférées, recherche automatique quand aucune piste intégrée n'existe dans la langue préférée (désactivée par défaut).

### Fichiers
- `crates/cnd-core/src/subtitles/{mod,hash,srt}.rs` *(client, hash, parseur)* + exports UniFFI `search_subtitles`, `download_subtitle`
- `apple/Sources/CndIptvApp/Player/SubtitleOverlay.swift`, `Features/Settings/SettingsView.swift`

---

## Contraintes Non-Négociables (Guardrails IA)

- Aucune clé ni jeton dans les journaux ou SQLite ; la clé passe uniquement en en-tête.
- Seuls le hash, l'IMDb ID, le titre/année et la langue sont envoyés à OpenSubtitles ; jamais l'URL du flux.
- Pas de nouvelle crate (hash et SRT écrits à la main, `reqwest` existant).

## Critères d'Acceptation & Commandes de Validation

1. Lot 18.1 : tests des chaînes de filtres par niveau, application à chaud sur le backend mpv (faux backend), bascule proposée en HLS sur AVPlayer.
2. Lot 18.2 : test du hash OpenSubtitles sur un fichier de référence, requêtes de recherche/téléchargement contre un faux serveur (en-têtes, paramètres, erreurs 401/429), parseur SRT (balises, multi-lignes, horodatages invalides), synchronisation de la surcouche et décalage.
3. `task check` au vert.

---

## Statut d'Implémentation & Validation (audit)

**Lot 18.1 (Dialogue Boost, mode nuit) : réalisé ✅.** Chaînes de filtres `lavfi` dans `AudioEnhancement.swift`, appliquées à chaud à mpv ; proposition de basculer sur mpv pour un flux HLS en AVPlayer.

**Lot 18.2 (OpenSubtitles) : réalisé à l'audit ✅ (à essayer avec une vraie clé).**
- Le client Rust (`subtitles/`, `search_subtitles`, `download_subtitle`, hash, parseur SRT) existait, mais **aucun écran ne l'appelait** : la recherche en ligne était inaccessible. Ajout de `Features/Subtitles/` (`SubtitleSearchModel`, `SubtitleSearchSheet`) et de l'entrée « Rechercher en ligne… » du menu Sous-titres du lecteur (hors direct) : liste des résultats (langue, version, téléchargements, note), téléchargement dans `Caches/CndSubtitles`, ajout au lecteur (mpv : `sub-add` ; AVPlayer : surcouche — la surcouche n'est plus chargée en plus de mpv, ce qui doublait le texte).
- **Clé API dans le Trousseau** (`cnd.opensubtitles.apikey`) : elle était dans les préférences (`@AppStorage`), contre la règle du PRD ; elle est migrée au premier lancement puis effacée des préférences. Seuls le titre nettoyé (« Titre 2025 ») et les langues partent chez OpenSubtitles, jamais l'adresse du flux.
- 8 tests (nettoyage du titre, absence de clé, requête envoyée, résultats vides et erreurs, téléchargement, migration).
- **Recherche par ordre de priorité (ajouté ensuite)** : 1) **`moviehash`** du fichier (`compute_remote_moviehash` : deux requêtes `Range` de 64 Kio au début et à la fin du flux, sans télécharger le fichier) ; 2) **identifiant IMDb** (connu par OMDb) ; 3) **titre nettoyé**, avec saison et épisode pour une série. La feuille indique comment les résultats ont été trouvés (« Correspondance exacte avec ce fichier », IMDb, titre). Les tests Rust servent un fichier avec un petit serveur local gérant `Range` et vérifient que le hash distant égale celui des mêmes octets ; un serveur sans `Range` ou un fichier trop petit sont refusés.
- **Garde-fou de connexions** : la recherche par hash coûte deux requêtes au fournisseur, qui comptent comme une connexion de plus à côté du flux regardé (certains serveurs coupent alors la plus ancienne). Elle n'a donc lieu que si l'abonnement est connu pour autoriser **au moins deux connexions** ; sinon elle est sautée et la recherche passe à l'IMDb puis au titre. Un test vérifie que le fournisseur n'est pas contacté quand la limite est inconnue, 0 ou 1.
- **Épisodes** : l'identifiant IMDb de la série (`parent_imdb_id`, connu une fois la série enrichie par OMDb) est utilisé avec la saison et l'épisode avant la recherche par titre.
- **Non réalisé / non vérifié** : connexion facultative `/login`, recherche automatique, décalage mémorisé par média,  aucun essai contre le vrai service OpenSubtitles.
