# PRD 27 — Recommandations « À suivre » sous le lecteur et film suivant (chronologie des sagas)

- **ID :** `PRD-27`
- **Prérequis :** `PRD-05` (catalogue, favoris, historique `watch_history`), `PRD-06` (métadonnées OMDb en cache), `PRD-08` (lecteur, playlist de saison), `PRD-10` (VOD), `PRD-13` (fournisseurs IA de l'utilisateur), `PRD-20` (profils, mode Enfants, catégories adultes), `PRD-21` (Apple TV)
- **Couches impactées :** `Rust (crates/cnd-core/src/recommend/, db/)`, `UniFFI`, `SwiftUI (Player/, App/AppShellView, Features/Recommendations/, Settings/)`
- **Objectif SLA :** rangée « À suivre » affichée **< 300 ms** après le début de la lecture (calcul local **< 50 ms** sur un catalogue de 50 000 entrées) ; réponse du fournisseur IA **asynchrone**, délai maximal **8 s**, jamais bloquante ; carte « Film suivant » prête **avant** la fin du film.

---

## 1. Contexte & Objectif

Aujourd'hui, quand un film se termine, l'écran reste noir : il faut revenir au catalogue et chercher la suite soi-même. Pour une saga (Avengers, Harry Potter, Fast & Furious, Star Wars…), il faut aussi connaître l'ordre des films et savoir lesquels sont dans ses sources.

Ce PRD ajoute, comme sur YouTube :

1. **Une rangée « À suivre » sous le lecteur**, mise à jour selon ce que l'on regarde : la suite de la saga, l'épisode suivant, puis des contenus proches.
2. **Une carte « Film suivant » à la fin de la lecture**, en priorité sur Apple TV, avec un compte à rebours pour enchaîner sans télécommande.
3. **Le respect de la chronologie des sagas** : si l'on regarde *Avengers* (2012), le film proposé est le suivant **dans la chronologie de la saga**, parmi les films **présents dans le catalogue de l'utilisateur**.
4. **L'usage facultatif des fournisseurs IA déjà configurés** (`PRD-13` : Gemini, compatible OpenAI dont Ollama local, Claude) pour reconnaître les sagas et ordonner leurs films. Sans IA, le moteur local fonctionne seul.

**Hors périmètre :** recommandations venant d'un serveur tiers, de contenus absents des sources de l'utilisateur, profilage partagé entre utilisateurs, publicité.

---

## 2. Expérience utilisateur

### 2.1. Rangée « À suivre » sous le lecteur

| Plateforme | Emplacement | Interaction |
| :--- | :--- | :--- |
| **macOS, lecteur dans la colonne de droite** | Sous le lecteur et ses informations, à la place de l'espace vide actuel ; défilement vertical dans la colonne (cartes en liste, comme la colonne « À suivre » de YouTube). | Clic : lecture. Menu contextuel : « Pas intéressé », « Voir la fiche », « Ajouter aux favoris ». |
| **macOS, lecteur agrandi / plein écran / mode Cinéma** | Rangée horizontale en bas, affichée avec les contrôles (masquée avec eux) ; flèches ‹ › comme les autres rangées (`HorizontalShelf`). | Idem. Jamais affichée par-dessus les sous-titres : elle remonte les sous-titres ou se masque. |
| **iPhone** | Sous le lecteur en mode portrait (liste qui défile) ; en paysage plein écran, tiroir ouvert d'un glissement vers le haut. | Toucher : lecture. Appui long : menu. |
| **iPad** | Comme macOS (colonne de droite en paysage, liste sous le lecteur en portrait). | Idem. |
| **Apple TV** | Rangée en bas de l'écran, ouverte en glissant vers le bas sur la Siri Remote (comme l'app TV d'Apple), refermée par « Menu ». | Focus et « Sélection » : lecture. Appui long : menu. |

Chaque carte montre l'affiche, le titre, l'année, et **une raison courte** : « Suite de la saga · 2/4 », « Épisode suivant », « Même réalisateur », « Parce que vous avez regardé *Inception* », « En ce moment sur … ».

### 2.2. Carte « Film suivant » à la fin de la lecture

- Apparaît **quand il reste moins de 3 % ou 4 minutes** de film (le plus court des deux), en bas à droite, sans couvrir l'image principale. Sur Apple TV, elle prend le focus sans interrompre la lecture.
- Contenu : affiche, titre, raison (« Suite de la saga Avengers »), boutons **« Lire maintenant »** et **« Regarder le générique »**.
- **Lecture automatique** à la fin réelle du fichier, après un compte à rebours de **10 s** (réglable, désactivable). Le compte à rebours ne démarre **jamais avant la fin réelle** : les scènes post-générique (très courantes dans les sagas Marvel) ne sont pas coupées ; « Regarder le générique » masque la carte jusqu'à la fin.
- Pour une série, c'est l'**épisode suivant** (la playlist de saison du `PRD-08` reste la source) ; après le dernier épisode d'une saison, le premier de la saison suivante ; après le dernier de la série, une recommandation.
- Pas de lecture automatique : en mode Enfants si le réglage parental l'interdit, si l'appareil est en veille programmée (`PlaybackSleepManager`), ou après **3 enchaînements automatiques sans interaction** (« Êtes-vous toujours là ? »).

### 2.3. Pendant un direct (Live TV)

La rangée devient **« Ailleurs en ce moment »** : programmes en cours (EPG) du même genre sur d'autres chaînes, chaînes du même groupe, puis chaînes récemment regardées. Pas de carte de fin (un direct ne se termine pas) ; à la fin d'un programme EPG, une suggestion discrète peut proposer le programme suivant d'une chaîne proche (lot 27.5).

---

## 3. Moteur de recommandation (Rust, `cnd-core/src/recommend/`)

### 3.1. Candidats

- **Uniquement des contenus présents dans les sources de l'utilisateur**, filtrés pour le profil actif : liste blanche Enfants, catégories adultes masquées, contenus marqués en panne exclus.
- **Dédoublonnage des versions** : un même film présent plusieurs fois (VF / VOSTFR / 4K, plusieurs sources) n'apparaît qu'une fois, regroupé par `imdb_id`, sinon par titre normalisé + année. La version choisie privilégie la langue et la qualité du contenu en cours, puis une version non signalée en panne.
- Exclus : le contenu en cours, les contenus terminés (`completed`) sauf pour la saga (affichés « déjà vu »), ceux marqués « Pas intéressé ».

### 3.2. Signaux et ordre de priorité

1. **Suite logique** : épisode suivant d'une série ; film suivant de la saga (§ 4).
2. **Autres films de la même saga** non encore vus.
3. **Reprise** : contenus commencés et non terminés proches du contenu en cours.
4. **Similarité de contenu** (cache OMDb `media_metadata_cache`) : genres, réalisateur, acteurs principaux, pays, langue, décennie ; catégorie IPTV (`group_title`) en secours quand il n'y a pas de métadonnées.
5. **Goûts du profil** : genres et réalisateurs les plus regardés dans `watch_history` du profil actif (pondérés par la récence et le taux de visionnage).
6. **Départage** : note IMDb, puis nouveauté d'ajout dans le catalogue.

Le score est une somme pondérée **déterministe** (même entrée, même ordre) : poids définis dans le code, couverts par des tests. Diversité : au plus 3 cartes consécutives de la même raison, hors suite de saga.

### 3.3. API UniFFI

- `recommendations_for(item_id, context, limit) -> Vec<Recommendation>` où `context` vaut `playing`, `ending` ou `live`, et `Recommendation { item, reason_kind, reason_text, saga_position: Option<(u32, u32)>, already_watched }`.
- `next_up(item_id) -> Option<Recommendation>` : le choix unique de la carte de fin.
- `dismiss_recommendation(stable_hash)` / `reset_dismissed()`.
- `saga_for(item_id) -> Option<Saga>` : nom, ordre choisi, membres présents, membres manquants (titres seuls).

---

## 4. Sagas et chronologie

### 4.1. Deux ordres possibles

- **Ordre de sortie** (dates de sortie).
- **Ordre chronologique de l'histoire** (exemple : dans l'univers Marvel, *Captain America : First Avenger* se passe avant *Iron Man*).

Réglage « Ordre des sagas » : **chronologie de l'histoire** par défaut (c'est la demande d'origine), ordre de sortie au choix. Quand l'ordre de l'histoire n'est pas connu (pas d'IA), le moteur utilise l'ordre de sortie et **le dit** sur la carte (« ordre de sortie »).

**Exemple :** l'utilisateur regarde *Avengers* (2012). Le catalogue contient *Iron Man*, *Captain America : First Avenger*, *Avengers*, *Avengers : L'ère d'Ultron*, *Avengers : Infinity War* et *Avengers : Endgame*. Le film suivant proposé est le premier film **présent dans le catalogue** qui suit *Avengers* dans l'ordre choisi. Si des films intermédiaires manquent (par exemple *Iron Man 3*, absent des sources), la carte l'indique : « 2 films de la saga absents de vos sources » ; ils ne sont pas proposés à la lecture.

**Saga ou univers :** une saga étroite (« Avengers », 4 films) et un univers large (« Marvel Cinematic Universe », 30+ films) sont deux niveaux différents. Le film suivant suit l'**univers** quand il est connu (c'est ce qui respecte la chronologie Avengers), et la rangée montre aussi les autres films de la saga étroite.

### 4.2. Sources de connaissance, par niveau

1. **Local (toujours disponible)** : racine de titre normalisée (« Avengers : Endgame », « Avengers 4 », « The Avengers (2012) », « Avengers.Endgame.2019.MULTi.1080p » → racine `avengers`), numérotation (2, II, « Partie 2 », « Chapitre 3 »), sous-titres après « : » ou « - », année. Donne des sagas simples, en ordre de sortie. Ne reconnaît pas les univers partagés (Iron Man et Avengers n'ont pas la même racine).
2. **TMDB, facultatif (lot 27.4)** : collection d'un film (`belongs_to_collection`) et ses films avec dates de sortie, avec la clé TMDB de l'utilisateur, ou l'identifiant `tmdb` que certaines sources Xtream fournissent déjà. Fiable pour l'ordre de sortie des sagas étroites. Ne connaît ni les univers ni l'ordre de l'histoire.
3. **Fournisseur IA de l'utilisateur (lot 27.3)**, s'il est connecté (`PRD-13`) et si le réglage est activé : reconnaissance de l'univers et ordre de l'histoire.

### 4.3. Appel au fournisseur IA

- **Déclenchement :** au plus **un appel par saga**, à la première lecture d'un film dont la saga n'est pas en cache. Jamais pendant le zapping rapide : seulement après **30 s** de lecture du même film.
- **Entrée envoyée :** le film en cours (titre, année, `imdb_id` s'il est connu) et **une liste bornée de candidats du catalogue** (au plus 150), présélectionnés localement (racine de titre, mêmes acteurs ou réalisateur, mots clés de l'univers). Chaque candidat a un **identifiant opaque temporaire** (`c1`, `c2`…), son titre nettoyé et son année. Rien d'autre.
- **Sortie demandée :** du JSON strict, validé par schéma comme au `PRD-13` : `{ "universe": "...", "saga": "...", "story_order": ["c12", "c3", …], "release_order": [...], "missing_titles": ["Iron Man 3", …], "confidence": 0.0-1.0 }`.
- **Validation :** uniquement des identifiants de la liste fournie (les autres sont ignorés), sans doublon ; les deux ordres doivent contenir le film en cours ; `missing_titles` ne sert qu'à l'affichage (jamais à la lecture) et est limité à 20 titres de 80 caractères. Réponse invalide, confiance < 0,6 ou délai > 8 s : repli sur le niveau local / TMDB, sans nouvel essai avant 24 h.
- **Cache :** résultat stocké en SQLite (§ 5) pendant **30 jours**, partagé entre profils (ce n'est pas une donnée personnelle). Invalidé quand une synchronisation de source ajoute un film qui correspond à la saga (même racine ou mêmes `imdb_id`), puis recalculé à la prochaine lecture.
- **Profil Enfants :** pas d'appel IA (comme l'assistant, `KidsModePolicy`) ; le moteur local suffit.

---

## 5. Données (SQLite)

- `sagas` : `saga_key` (racine normalisée ou identifiant d'univers), `name`, `level` (`saga` | `universe`), `source` (`local` | `tmdb` | `llm`), `confidence`, `fetched_at`, `missing_titles` (JSON).
- `saga_members` : `saga_key`, `work_key` (`imdb_id` ou titre normalisé + année), `release_index`, `story_index` (nullable).
- `recommendation_dismissals` : `profile_id`, `stable_hash`, `dismissed_at` (par profil, synchronisé par iCloud comme les favoris au `PRD-20` dans un lot ultérieur).
- Index nécessaires pour tenir le SLA sur 50 000 entrées : racine de titre, `imdb_id`, genres (table de jointure ou colonne normalisée).

---

## 6. Réglages (Réglages > Lecture > Recommandations)

- Afficher « À suivre » sous le lecteur (activé).
- Carte « Film suivant » en fin de lecture (activée) ; lecture automatique (activée) ; durée du compte à rebours (5, 10, 15, 30 s).
- Ordre des sagas : chronologie de l'histoire / ordre de sortie.
- Utiliser l'assistant IA pour reconnaître les sagas (désactivé tant qu'aucun fournisseur n'est configuré ; texte expliquant ce qui est envoyé : titres et années uniquement).
- Réinitialiser les contenus « Pas intéressé ».

---

## 7. Lots

| Lot | Contenu | Validation principale |
| :--- | :--- | :--- |
| **27.1** | Moteur local (§ 3, niveau local du § 4), dédoublonnage des versions, API UniFFI, rangée « À suivre » sous le lecteur sur macOS, iPhone, iPad. | Tests Rust du score, de la racine de titre et des exclusions ; rangée visible sur macOS. |
| **27.2** | Carte « Film suivant » et épisode suivant, compte à rebours, protection du générique, limite de 3 enchaînements, Apple TV (rangée par glissement vers le bas et focus). | Tests du déclenchement (seuil 3 % / 4 min, fin réelle) ; essai manuel sur Apple TV. |
| **27.3** | Sagas et univers par le fournisseur IA (§ 4.3), cache SQLite, ordre de l'histoire, films manquants. | Tests avec un faux fournisseur (réponses valides, identifiants inventés, JSON cassé, délai dépassé) ; essai réel avec la saga Avengers. |
| **27.4** | Collections TMDB (facultatif, clé de l'utilisateur ou identifiant `tmdb` Xtream). | Tests sur réponses TMDB enregistrées. |
| **27.5** | Live : « Ailleurs en ce moment » (EPG, groupe, récents) et suggestion à la fin d'un programme. | Tests sur une EPG de test. |

Chaque lot est livrable et validable seul. Ordre conseillé : 27.1 → 27.2 → 27.3 → 27.5 → 27.4.

---

## 8. Fichiers à Créer / Modifier

- `crates/cnd-core/src/recommend/mod.rs`, `scoring.rs`, `saga.rs` (racine de titre, numérotation), `llm_saga.rs` (requête, schéma, validation) *(nouveaux)*
- `crates/cnd-core/src/db/schema.rs`, `db/recommend_repo.rs` *(tables du § 5)*
- `crates/cnd-core/src/ai/` *(réutilisation des clients du `PRD-13`, nouvelle tâche « saga »)*
- `crates/cnd-core/src/lib.rs` *(exports UniFFI)* puis `scripts/build-xcframework.sh`
- `apple/Sources/CndIptvKit/Features/Recommendations/` : `UpNextModel.swift`, `UpNextShelf.swift`, `NextUpCard.swift` *(nouveaux)*
- `apple/Sources/CndIptvKit/Player/CndVideoPlayerView.swift`, `CndPlayerController.swift` *(seuil de fin, compte à rebours, enchaînement)*
- `apple/Sources/CndIptvKit/App/AppShellView.swift` *(rangée sous le lecteur dans la colonne de droite)*
- `apple/Sources/CndIptvKit/Features/Settings/SettingsView.swift`
- `apple/Tests/CndIptvAppTests/` *(modèle « À suivre », carte de fin)*
- `PRD/00_INDEX_ROADMAP.md`

---

## 9. Contraintes Non-Négociables (Guardrails IA)

- **Jamais envoyé au fournisseur IA :** URL de flux, nom ou adresse de serveur, identifiants, nom de source, historique de visionnage, profil, nom d'utilisateur. Seulement des titres nettoyés, des années et des identifiants opaques temporaires.
- **Aucun contenu hors catalogue proposé à la lecture.** Les titres manquants indiqués par l'IA sont du texte, jamais un lien.
- **L'IA ne décide pas de ce qui est lu** : elle ordonne des candidats déjà filtrés pour le profil. Le filtrage Enfants / adultes s'applique **avant** l'appel et **après** la réponse.
- **Rien ne bloque la lecture** : tout calcul et tout appel réseau sont asynchrones ; en cas d'échec, la rangée locale reste affichée.
- Rangée et carte ne couvrent jamais les sous-titres ni les contrôles de lecture ; elles se masquent avec le HUD.
- Pas de nouvelle crate Rust lourde ; pas de serveur tiers ; journaux (`AI`, `RECO`) sans titres envoyés ni réponse brute, seulement durée, taille et résultat de validation.
- Les cibles macOS, iOS, tvOS et visionOS restent vertes.

---

## 10. Critères d'Acceptation & Commandes de Validation

1. **Tests Rust :**
   - racine de titre et numérotation (« The Avengers (2012) », « Avengers.Endgame.2019.MULTi.1080p », « Fast & Furious 7 », « Harry Potter et la Chambre des secrets ») ;
   - dédoublonnage des versions et choix de la version ;
   - exclusions (en panne, terminé, « Pas intéressé », Enfants, adultes) ;
   - score déterministe et diversité ;
   - validation de la réponse IA (identifiants inventés ignorés, doublons, JSON cassé, film en cours absent, confiance faible, délai) ;
   - cache et invalidation lors d'un ajout au catalogue ;
   - SLA : `recommendations_for` < 50 ms sur 50 000 entrées (`--release`).
2. **Tests Swift :** seuil d'apparition de la carte (3 % / 4 min), compte à rebours seulement après la fin réelle, « Regarder le générique », limite de 3 enchaînements, réglages, épisode suivant d'une série.
3. **Essais manuels :**
   - macOS : *Avengers* (2012) en lecture → rangée « À suivre » avec la suite de la saga en premier, dans l'ordre choisi ;
   - Apple TV : fin d'un film → carte « Film suivant » au focus, enchaînement après 10 s, scène post-générique non coupée ;
   - iPhone : rangée sous le lecteur en portrait, tiroir en paysage ;
   - sans fournisseur IA : ordre de sortie annoncé comme tel.
4. `cargo clippy --workspace --all-targets -- -D warnings`, `cargo test --workspace --release`, `cd apple && swift test`, builds des 4 schémas Xcode, `task check` au vert.

---

## 11. Questions ouvertes

- **Ordre par défaut :** chronologie de l'histoire (demande d'origine) ou ordre de sortie, plus courant chez les autres applications ? Ce PRD retient la chronologie de l'histoire, modifiable dans les Réglages.
- **Univers ou saga pour le film suivant :** suivre l'univers Marvel complet peut proposer *Thor* après *Iron Man 2* alors que l'utilisateur voulait seulement les *Avengers*. Ce PRD retient l'univers quand il est connu ; un choix « Saga seulement » pourrait être ajouté dans le menu de la carte.
- **Séries dans un univers** (séries Marvel, *The Mandalorian*) : à intégrer à la chronologie ou non ? Exclues de ce PRD, à décider après le lot 27.3.

---

## 12. Statut d'Implémentation & Validation

**Terminé et validé (`[x]`).**

- **Rust Core & Moteur de recommandation (`crates/cnd-core/src/recommend/`, `db/recommend_repo.rs`) :**
  - Moteur local et extraction de racine de sagas (`parse_saga_title`, numérotation arabe & romaine, mots-clés "Partie", "Chapitre", "Episode").
  - Prise en charge des deux ordres de saga (`SagaOrderPreference` : chronologie de l'histoire et ordre de sortie).
  - Détection IA asynchrone (`resolve_saga_with_llm`, opaque IDs `c1`, `c2`..., validation de schéma strict, cache SQLite 30 jours, pas de données sensibles envoyées).
  - Dédoublonnage des versions de films (VF, VOSTFR, 4K) par `imdb_id` ou titre normalisé + année.
  - Exclusion des contenus en panne, terminés, et « Pas intéressé » (`recommendation_dismissals`).
  - Score pondéré et diversité (au plus 3 cartes consécutives de même type de recommandation).
  - SLA validé : `test_recommendations_sla_50k_items` s'exécute en **1.01 ms** sur un catalogue de 50 000 éléments (< 50 ms).
  - Bindings UniFFI universels (`recommendations_for`, `next_up`, `dismiss_recommendation`, `reset_dismissed_recommendations`, `saga_for`, `resolve_saga_with_ai`).

- **Composants & Modèles Swift (`apple/Sources/CndIptvKit/Features/Recommendations/`) :**
  - `UpNextModel.swift` : gestion des seuils (≤ 3% ou ≤ 4 min), compte à rebours de 10 s (configurable), limite de sécurité de 3 enchaînements sans interaction (« Êtes-vous toujours là ? »), masquage générique.
  - `NextUpCard.swift` : carte flottante avec visuel, titre, raison, compte à rebours, boutons « Lire maintenant » et « Regarder le générique ».
  - `UpNextShelf.swift` : affichage responsive en colonne verticale (docked player macOS) et étagère horizontale (HUD lecteur plein écran, Apple TV, iPhone).

- **Intégration Player, Shell & Réglages :**
  - `CndPlayerController.swift` : hooks `onMediaChanged`, `onProgressUpdate`, `onPlaybackEnded`. Protection du générique et des scènes post-générique (compte à rebours déclenché uniquement sur fin réelle).
  - `CndVideoPlayerView.swift` : carte « Film suivant » flottante en bas à droite, bouton et étagère « À suivre », navigation Siri Remote sur Apple TV.
  - `AppShellView.swift` : rangée verticale « À suivre » sous le lecteur dans la colonne de droite macOS.
  - `SettingsView.swift` : section Réglages « Recommandations & Sagas » (toggles À suivre, carte fin de film, lecture automatique, délai compte à rebours, ordre des sagas, IA, réinitialisation des contenus masqués).

- **Tests de validation :**
  - Tests Rust : 199 tests unitaires et d'intégration au vert (`cargo test --workspace --release`).
  - Clippy : zéro avertissement (`cargo clippy --workspace --all-targets -- -D warnings`).
  - Tests Swift : 313 tests XCTest + 15 tests Swift Testing au vert (`cd apple && swift test`), dont `UpNextModelTests`.
  - XCFramework universel généré pour macOS, iOS, iOS Simulator, tvOS, tvOS Simulator, visionOS, visionOS Simulator.
