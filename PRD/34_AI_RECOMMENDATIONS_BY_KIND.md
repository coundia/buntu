# PRD 34 — Recommandations par l'IA (Gemini, IA locale ou autre), séparées pour les films, les séries et la TV

- **ID :** `PRD-34`
- **Prérequis :**
  - `PRD-27` (moteur « À suivre », sagas, carte « Film suivant ») ;
  - `PRD-13` (fournisseurs IA, consentement) et `PRD-33` (recherche par prompt : `resolve_guesses`, tâches IA, filtre par type) ;
  - `PRD-04` (EPG), `PRD-05` (historique `watch_history`), `PRD-06` (métadonnées OMDb / TMDB) ;
  - `PRD-20` (profils, mode Enfants, catégories adultes) et `PRD-28` (clés par défaut).
- **Couches impactées :**
  - `Rust (crates/cnd-core/src/recommend/, src/ai/, db/)` ;
  - `UniFFI` ;
  - `SwiftUI (Features/Recommendations/, Movies/, Series/, LiveTV/, Settings/, App/AppShellView)`.
- **Objectifs SLA :**
  - rangées locales affichées en **< 300 ms** (calcul **< 50 ms** sur 50 000 éléments, comme le `PRD-27`) ;
  - affinage par l'IA **asynchrone**, **< 4 s au p90**, délai maximal **8 s** ; la rangée locale reste à l'écran pendant l'attente ;
  - **zéro mélange** : 100 % des cartes d'une rangée ont le type de la rangée, mesuré par le jeu d'évaluation (§ 10).

---

## 1. Contexte & Objectif

Le `PRD-27` a livré un moteur local (sagas, épisode suivant, reprise) et n'utilise l'IA que pour **ordonner les films d'une saga**. En lisant le code actuel (`recommend/mod.rs`, `db/recommend_repo.rs`), on constate :

1. **Séries :** les recommandations sont des **épisodes isolés d'autres séries** (« Dans la même catégorie »), triés par `imdb_rating`, que les épisodes n'ont presque jamais. On obtient un S03E07 d'une série jamais commencée plutôt que la série elle-même.
2. **Films :** hors saga, le moteur complète avec la même catégorie IPTV puis les « mieux notés » du catalogue. Il n'y a pas de goûts du profil (le § 3.2.5 du `PRD-27` n'est pas implémenté), et la similarité n'existe que si OMDb a déjà mis le film en cache.
3. **TV :** même groupe de chaînes et chaînes récentes, sans EPG (le lot 27.5 n'est pas fait). Il n'y a rien dans l'écran Live TV, et la rangée sous le lecteur est masquée pendant un direct.
4. **IA :** Gemini, Ollama ou Claude ne servent jamais à proposer quelque chose « pour vous », seulement à ordonner une saga.
5. **Pas de rangée « Pour vous »** dans les écrans Films, Séries ou Live TV : les recommandations n'existent que sous le lecteur et dans la fiche d'un film.
6. **Rien ne garantit la séparation des types** au-delà d'un `WHERE i.kind = ?` dans chaque requête : une évolution (IA, recherche par titre comme au `PRD-33`) pourrait faire entrer un film dans une rangée de séries.

**Objectif :** trois systèmes de recommandation **séparés**, Films, Séries et TV, chacun avec ses propres signaux, ses propres goûts du profil et ses propres rangées, et un **affinage par le fournisseur IA choisi par l'utilisateur** : Gemini, une IA locale (Ollama, LM Studio, ou le modèle intégré d'Apple, lot 34.5) ou un autre fournisseur compatible. Sans IA, le moteur local donne déjà de bonnes rangées.

**Hors périmètre :** recommandations de contenus absents des sources de l'utilisateur, serveur de recommandation tiers, profilage partagé entre utilisateurs, publicité, bibliothèque locale (`PRD-32`).

---

## 2. Règle de séparation (non négociable)

| Rangée affichée dans… | Ne contient que… | Unité recommandée |
| :--- | :--- | :--- |
| Écran **Films**, fiche d'un film, lecteur d'un film | des **films** (`kind = movie`) | un film (une version choisie parmi les doublons) |
| Écran **Séries**, fiche d'une série, lecteur d'un épisode | des **séries** et, pour la suite, des **épisodes de la série en cours** | une **série** (jamais un épisode d'une autre série) |
| Écran **Live TV**, Guide TV | des **chaînes** et des **programmes EPG** de ces chaînes | une chaîne, ou un programme en cours ou à venir |

- Un film n'apparaît **jamais** dans une rangée Séries ou TV, une série jamais dans une rangée Films ou TV, une chaîne jamais dans une rangée Films ou Séries. Cela vaut aussi pour un film diffusé sur une chaîne : dans une rangée TV, c'est le **programme** qui est proposé, pas le film VOD du même nom.
- **Trois verrous :**
  1. en SQL, chaque requête de candidats prend un type unique ;
  2. dans le moteur, `RecoShelf` porte un `kind` et rejette toute carte d'un autre type avant de la renvoyer, avec un `debug_assert` et un journal `RECO` ;
  3. en Swift, le modèle de rangée refiltre par type avant l'affichage (défense en profondeur, testée).
- **L'IA ne voit qu'un type par appel** : la liste de candidats envoyée et le schéma de réponse ne concernent qu'un seul type. Un titre proposé par l'IA qui n'existe que dans un autre type est **ignoré**, jamais « converti » (même règle que dans le `PRD-33`).

---

## 3. Expérience utilisateur

### 3.1. Rangées « Pour vous » dans chaque écran

| Écran | Rangées, dans l'ordre | Remarques |
| :--- | :--- | :--- |
| **Films** | « Reprendre » (films commencés), « Pour vous », « Suite de vos sagas », « Parce que vous avez regardé *X* » (au plus 2 rangées, sur les 2 derniers films terminés), « Nouveautés pour vous » (ajouts récents du catalogue qui correspondent à vos goûts) | En haut de l'écran, au-dessus des catégories ; repliables comme les catégories. |
| **Séries** | « Continuer » (épisode suivant de chaque série commencée), « Pour vous », « Nouvelle saison disponible », « Parce que vous avez regardé *Y* » | Une carte = une série, avec l'affiche de la série et le prochain épisode à lire (« S2:E4 ») si elle est commencée. |
| **Live TV** | « En ce moment pour vous » (programmes en cours, selon vos genres et vos habitudes horaires), « Bientôt » (programmes qui commencent dans les 2 h), « Vos chaînes à cette heure-ci » | Carte = chaîne + programme en cours, barre de progression du programme. Sans EPG à jour, seule la dernière rangée s'affiche et le texte le dit (« Guide TV non à jour »). |

- Chaque carte garde **une raison courte** (comme au `PRD-27`) : « Comme *Inception* », « Thriller coréen · vos goûts », « Vous regardez souvent France 2 vers 20 h ».
- Quand l'IA a affiné la rangée, un petit signe ✨ apparaît à côté du titre de la rangée, avec en info-bulle le fournisseur (« Affiné par Gemini », « Affiné en local par Ollama »).
- Menu contextuel de chaque carte : « Pas intéressé », « Voir la fiche », « Ajouter aux favoris », et « Moins de ce genre » (baisse le poids du genre principal pour ce type seulement).
- Profil sans historique pour ce type : rangée « Populaires dans vos sources » (note IMDb, puis ajouts récents) au lieu de « Pour vous », avec une ligne qui explique pourquoi.

### 3.2. Sous le lecteur et en fin de lecture

- La rangée « À suivre » du `PRD-27` garde son emplacement et prend le **type du contenu en cours** : film → films, épisode → épisodes suivants de la série puis séries proches, direct → aucune rangée sur l'image.
- **Direct :** aucune fenêtre ni carte par-dessus l'image (l'utilisateur a demandé de retirer la fenêtre de recommandation sur une chaîne). Dans la colonne de droite sur macOS, sous les informations de la chaîne, la rangée « Ailleurs en ce moment » (programmes en cours similaires) est **désactivée par défaut**, et on peut l'activer dans les Réglages.
- La carte « Film suivant » reste celle du `PRD-27`. Si l'IA a affiné la rangée « Pour vous » des films, la carte peut proposer ce choix **seulement s'il n'y a pas de suite de saga** : la saga passe toujours en premier.

### 3.3. Apple TV

Les rangées « Pour vous » sont en haut des écrans Films, Séries et Live TV et suivent le focus de la Siri Remote (`HorizontalShelf`). L'appui long ouvre le menu contextuel.

---

## 4. Goûts du profil, un par type (Rust, `recommend/taste.rs`)

Les goûts sont calculés **localement**, par profil et **par type**, à partir de `watch_history`, des favoris et des « Pas intéressé » / « Moins de ce genre ». Ils ne sont jamais mélangés : aimer les films d'horreur ne change pas les séries recommandées.

| Type | Signaux |
| :--- | :--- |
| **Films** | genres, réalisateurs, acteurs principaux, pays et langue, décennie, durée, catégorie IPTV (si pas de métadonnées), taux de visionnage (terminé > abandonné tôt) |
| **Séries** | les mêmes, **agrégés au niveau de la série** (une série regardée sur 10 épisodes compte une fois, avec un poids selon la progression), séries abandonnées après 1 ou 2 épisodes comptées en négatif |
| **TV** | chaînes et groupes regardés, **plages horaires** (jour de semaine / week-end × tranche de 2 h), genres EPG des programmes regardés (catégories XMLTV), durée moyenne de visionnage |

- **Poids :** récence (demi-vie de 30 jours), puis taux de visionnage ; en dessous de 2 minutes de lecture, rien n'est compté (zapping).
- **Stockage :** table `taste_profile` (§ 7), recalculée de façon incrémentale à la fin de chaque lecture ; calcul complet < 20 ms sur 5 000 entrées d'historique.
- **Résumé texte des goûts** (pour l'IA, § 6) : « genres : thriller 0,32, science-fiction 0,21… ; décennies : 2010 ; langues : fr, ko ». Ce sont des agrégats, pas des titres.

---

## 5. Moteur local amélioré, un par type

### 5.1. Films (`recommend/movies.rs`)

1. Suite de la saga (inchangé, `PRD-27`).
2. **Similarité de contenu** : genres, réalisateur, acteurs, pays, décennie (métadonnées OMDb / TMDB). Pour les films sans métadonnées, mots du titre et de la catégorie IPTV. Les métadonnées des 200 meilleurs candidats sont **préchargées en arrière-plan** (dans la limite de quota du `PRD-06`).
3. **Affinité avec les goûts** du profil Films (§ 4).
4. Départage : note IMDb, nouveauté dans le catalogue.
5. Dédoublonnage des versions (inchangé) ; diversité : au plus 2 films de suite du même genre principal ou de la même saga dans « Pour vous ».

### 5.2. Séries (`recommend/series.rs`)

- **Unité = la série** (`series_id`, table des séries Xtream ou séries regroupées par le normaliseur du `PRD-02`) : on ne renvoie plus d'épisodes d'autres séries.
- « Continuer » : pour chaque série commencée, le **prochain épisode non terminé** (même logique que l'épisode suivant du `PRD-27`, y compris le passage à la saison suivante).
- « Nouvelle saison disponible » : une série terminée ou rattrapée dont une synchronisation a ajouté une saison.
- « Pour vous » : séries non commencées, similarité avec les séries aimées (genres, créateurs, acteurs, pays), affinité avec le profil Séries.
- Sous le lecteur d'un épisode : épisode suivant, puis autres épisodes de la saison, puis séries proches (cartes « série »).

### 5.3. TV (`recommend/live.rs`)

- **Programmes en cours** dont le genre EPG ou les mots du titre correspondent aux goûts TV, sur des chaînes du profil (favoris d'abord).
- **Habitudes horaires** : chaînes souvent regardées à cette tranche horaire et ce type de jour.
- **Bientôt** : programmes qui commencent dans les 2 h sur les chaînes aimées, avec le bouton « Me rappeler » ou « Enregistrer » si le PVR (`PRD-19`) est disponible.
- **Dépendance à l'EPG :** si l'EPG est périmé (aucun programme pour l'heure actuelle, comme constaté le 6 novembre 2026 sur la source de test, importée le 2 novembre), les rangées de programmes sont masquées et l'écran propose « Actualiser le guide ». Le rafraîchissement automatique de l'EPG est un besoin séparé, cité au § 12.
- Diversité : au plus 2 chaînes du même groupe de suite ; une chaîne n'apparaît qu'une fois, avec sa meilleure version (HD avant SD, non signalée en panne).

---

## 6. Affinage par l'IA (Rust, `recommend/ai_rerank.rs`)

### 6.1. Fournisseurs

On réutilise les fournisseurs du `PRD-13`, sans nouvelle crate :

| Fournisseur | Où tourne le modèle | Remarque |
| :--- | :--- | :--- |
| **Gemini** | serveur Google | clé de l'utilisateur ou clé par défaut (`PRD-28`) |
| **IA locale : Ollama, LM Studio** | sur la machine ou le réseau local (`OpenAiCompatible`, adresse `localhost` ou réseau local) | aucune donnée ne quitte le réseau local |
| **IA locale : modèle intégré d'Apple** (lot 34.5) | sur l'appareil (framework Foundation Models, macOS / iOS / visionOS compatibles) | appelé côté Swift, puis la réponse est validée par le même code Rust ; masqué si l'appareil ne le propose pas |
| **Autres** : OpenAI, Mistral, Groq, OpenRouter, Claude | serveur du fournisseur | comme au `PRD-13` |

Le fournisseur des recommandations est **le fournisseur actif de l'assistant** par défaut, et on peut en choisir un autre dans les Réglages (par exemple Gemini pour la recherche et Ollama pour les recommandations).

### 6.2. Principe : l'IA trie et explique, elle ne fournit pas le catalogue

1. Le moteur local calcule, **pour un seul type**, une liste de **au plus 60 candidats** déjà filtrés pour le profil (Enfants, adultes, en panne, « Pas intéressé », déjà vus).
2. Chaque candidat reçoit un **identifiant opaque temporaire** (`m1`, `s1`, `t1`…), avec son titre nettoyé, son année, ses genres et, pour la TV, le titre et le genre du programme en cours.
3. L'IA reçoit le **résumé des goûts de ce type** (§ 4) et, si l'utilisateur l'autorise (§ 6.4), les titres des **10 derniers contenus de ce type** regardés.
4. Elle renvoie du JSON strict, validé par schéma comme au `PRD-13` :

```json
{
  "kind": "movie",
  "picks": [{ "id": "m12", "reason": "Même tension que Prisoners" }],
  "discover": [{ "title": "Memories of Murder", "year": 2003 }],
  "confidence": 0.0
}
```

5. **Validation :**
   - `kind` doit être le type demandé, sinon la réponse entière est rejetée ;
   - seuls les identifiants de la liste envoyée sont gardés, sans doublon, 30 au plus ;
   - `reason` est nettoyé (texte seul, 60 caractères au plus, aucune URL), sinon on garde la raison locale ;
   - `discover` (au plus 10 titres) est cherché dans le catalogue **du même type** par `resolve_guesses` du `PRD-33`. Un titre trouvé seulement dans un autre type est ignoré, un titre introuvable n'est jamais affiché ;
   - les filtres du profil sont **réappliqués après** la réponse.
6. **Fusion :** l'ordre de l'IA remplace celui de la rangée « Pour vous », mais les rangées « Reprendre », « Continuer », « Suite de vos sagas » et l'épisode suivant restent **calculés localement** (l'IA ne les déplace jamais). Les candidats locaux non choisis par l'IA complètent la rangée en fin de liste.

### 6.3. Quand l'IA est appelée

- Au plus **un appel par type et par profil** à l'ouverture de l'écran correspondant, si le cache est expiré. Validité : **12 h** pour Films et Séries, **jusqu'au prochain changement de tranche EPG** (30 min au plus) pour la TV.
- Le cache est invalidé quand une lecture ajoute un contenu terminé de ce type, ou quand une synchronisation ajoute plus de 20 éléments de ce type.
- Délai maximal 8 s ; échec, JSON invalide ou `confidence < 0,5` : on garde la rangée locale, sans nouvel essai avant 1 h.
- **Plafond :** 30 appels par jour et par fournisseur distant pour les recommandations, réglable ; pas de plafond pour une IA locale.
- Aucun appel en mode Enfants vers un fournisseur distant ; avec une IA locale, autorisé seulement si le réglage parental le permet.

### 6.4. Données envoyées et consentement

| Donnée | IA locale | IA distante |
| :--- | :--- | :--- |
| Titres, années, genres des candidats (identifiants opaques) | oui | oui |
| Résumé agrégé des goûts (genres, décennies, langues) | oui | oui, après le consentement de l'assistant (`PRD-13`) |
| Titres des 10 derniers contenus regardés de ce type | oui par défaut | **non par défaut** : réglage « Envoyer mes derniers titres regardés », désactivé, avec une explication |
| URL de flux, serveur, identifiants, nom de source, nom de profil, dates et heures de visionnage | **jamais** | **jamais** |

---

## 7. Données (SQLite)

- `taste_profile` : `profile_id`, `kind` (`movie` | `series` | `live`), `feature` (`genre:thriller`, `director:…`, `channel:…`, `slot:we-20h`…), `weight`, `updated_at`. Clé primaire (`profile_id`, `kind`, `feature`).
- `reco_ai_cache` : `profile_id`, `kind`, `provider`, `candidates_hash`, `picks` (JSON validé, identifiants **réels** et non opaques), `created_at`, `expires_at`.
- `reco_feedback` : `profile_id`, `kind`, `feature`, `delta`, `created_at` (« Moins de ce genre »).
- `recommendation_dismissals` (`PRD-27`) gagne une colonne `kind`.
- Index : `watch_history(profile_id, kind, last_watched_at)`, `epg_programs(start_ts, stop_ts)` s'il manque, `iptv_items(kind, series_id)`.

---

## 8. API UniFFI

- `RecoKind { Movies, Series, Live }`.
- `recommendation_shelves(kind: RecoKind, limit_per_shelf: u32) -> Vec<RecoShelf>`, avec `RecoShelf { id, kind, title, reason_kind, items: Vec<RecoCard>, refined_by: Option<String> }`. Calcul local seulement, synchrone, < 50 ms.
- `refine_shelves_with_ai(kind: RecoKind, config: AiProviderConfig) -> Vec<RecoShelf>` : asynchrone, renvoie les rangées affinées ou les rangées locales en cas d'échec, jamais une erreur bloquante.
- `RecoCard { item: Option<IptvItemRecord>, series: Option<SeriesRecord>, program: Option<EpgProgram>, next_episode: Option<IptvItemRecord>, reason_text, ai_reason: bool }` : un seul des trois premiers champs est rempli, selon le `kind` de la rangée.
- `less_like_this(kind, stable_hash)`, `reset_taste(kind)`.
- `recommendations_for(item_id, context, limit)` du `PRD-27` est conservé ; il renvoie désormais des séries pour un épisode (hors épisodes de la série en cours) et garantit le type du contenu en cours.
- Lot 34.5 : `rerank_prompt(kind) -> String` et `validate_rerank_answer(kind, json) -> Vec<RecoShelf>` pour que le modèle d'Apple, appelé en Swift, passe par la même validation.

---

## 9. Réglages (Réglages > Lecture > Recommandations)

- Rangées « Pour vous » : activées, **séparément** pour Films, Séries et Live TV.
- Affiner avec l'IA : désactivé tant qu'aucun fournisseur n'est configuré ; choix du fournisseur (« Comme l'assistant », Gemini, Ollama…, « Modèle d'Apple sur l'appareil » si disponible).
- Envoyer mes derniers titres regardés à une IA distante (désactivé).
- « Ailleurs en ce moment » dans la colonne pendant un direct (désactivé).
- Réinitialiser mes goûts : Films / Séries / TV, séparément.
- Texte d'information : ce qui est envoyé, à qui, et que rien ne part avec une IA locale.

---

## 10. Évaluation

On crée un jeu fixe (`recommend/eval.rs`, comme `search/eval.rs` au `PRD-33`) : un catalogue de test d'environ 400 films, 120 séries (avec épisodes), 150 chaînes et une EPG à une heure fixe, plus 6 historiques types (fan de thrillers, famille, sport, séries coréennes, nouveau profil, profil Enfants).

| Mesure | Seuil |
| :--- | :--- |
| Cartes d'un autre type dans une rangée (local et IA, y compris réponses IA piégées) | **0** |
| Épisodes d'une autre série dans une rangée Séries | **0** |
| « Continuer » : prochain épisode correct pour chaque série commencée | 100 % |
| Suite de saga en tête de « Suite de vos sagas » | 100 % |
| Profil Enfants : aucun contenu hors liste blanche, aucun appel distant | 100 % |
| Précision des goûts : au moins 3 des 5 premières cartes « Pour vous » dans les 2 genres dominants du profil | ≥ 80 % des profils |
| TV avec EPG périmé : aucune rangée de programmes, message affiché | 100 % |

Les tests IA utilisent un faux fournisseur (`MockProvider`) qui couvre ces cas :
- une réponse valide ;
- un `kind` faux ;
- des identifiants inventés ;
- un film dans `discover` pour une rangée Séries ;
- du JSON cassé ;
- une confiance faible ;
- un délai dépassé ;
- une raison avec une URL.

---

## 11. Lots

| Lot | Contenu | Validation principale |
| :--- | :--- | :--- |
| **34.1** | Règle de séparation (§ 2, trois verrous), Séries au niveau de la série (§ 5.2), goûts par type (§ 4), API `recommendation_shelves`, rangées « Pour vous » Films et Séries en local. | Jeu d'évaluation : 0 mélange, « Continuer » correct ; rangées visibles sur macOS. |
| **34.2** | TV (§ 5.3) : programmes en cours selon les goûts, habitudes horaires, « Bientôt », gestion de l'EPG périmé ; rangées dans Live TV ; rangée facultative pendant un direct. | Tests sur EPG de test (à jour et périmée). |
| **34.3** | Affinage par l'IA (§ 6) : Gemini, compatible OpenAI (Ollama, LM Studio), Claude ; cache, plafond, consentement, signe ✨. | Tests `MockProvider` (§ 10) ; essai réel avec Gemini et avec Ollama. |
| **34.4** | « Moins de ce genre », nouveautés pour vous, nouvelle saison disponible, préchargement des métadonnées. | Tests du poids négatif et de la détection de nouvelle saison. |
| **34.5** | Modèle d'Apple sur l'appareil (Foundation Models), appelé en Swift, validé par Rust ; masqué si indisponible. | Essai sur un Mac compatible ; build vert sur les cibles qui ne l'ont pas. |

Chaque lot est livrable et validable seul. Ordre conseillé : 34.1 → 34.3 → 34.2 → 34.4 → 34.5.

---

## 12. Fichiers à Créer / Modifier

- `crates/cnd-core/src/recommend/` : `taste.rs`, `movies.rs`, `series.rs`, `live.rs`, `shelves.rs`, `ai_rerank.rs`, `eval.rs` *(nouveaux)* ; `mod.rs`, `scoring.rs` *(découpage par type, retrait des épisodes d'autres séries)*
- `crates/cnd-core/src/db/recommend_repo.rs`, `db/schema.rs` *(tables du § 7, requêtes séries et EPG)*
- `crates/cnd-core/src/ai/providers.rs`, `ai/prompt.rs` *(nouvelle tâche `Task::Recommend`, prompt et schéma par type)*
- `crates/cnd-core/src/search/ai_search.rs` *(réutilisation de `resolve_guesses` avec un type imposé)*
- `crates/cnd-core/src/lib.rs` *(exports UniFFI)* puis `scripts/build-xcframework.sh`
- `apple/Sources/CndIptvKit/Features/Recommendations/` : `ForYouModel.swift`, `ForYouShelves.swift`, `RecoCardView.swift` *(nouveaux)* ; `UpNextModel.swift` *(type du contenu en cours)*
- `apple/Sources/CndIptvKit/Features/VOD/VodCatalogView.swift`, `Movies/`, `Series/`, `LiveTV/` *(rangées en haut des écrans)*
- `apple/Sources/CndIptvKit/App/AppShellView.swift` *(rangée facultative pendant un direct)*
- `apple/Sources/CndIptvKit/Features/Settings/SettingsView.swift`, `AiProviderSettings.swift`
- `apple/Sources/CndIptvKit/Features/Recommendations/AppleOnDeviceReranker.swift` *(lot 34.5)*
- `apple/Tests/CndIptvAppTests/` *(filtre par type, modèle « Pour vous », affinage)*
- `PRD/00_INDEX_ROADMAP.md`

---

## 13. Contraintes Non-Négociables (Guardrails IA)

- **Pas de mélange des types** (§ 2), y compris quand l'IA se trompe : la validation rejette, elle ne corrige pas.
- **Aucun contenu hors catalogue proposé à la lecture** ; un titre `discover` introuvable n'est jamais affiché.
- **L'IA ordonne des candidats déjà filtrés pour le profil** ; les filtres Enfants et adultes sont réappliqués après la réponse.
- **Données envoyées** : uniquement celles du § 6.4. Jamais d'URL de flux, de serveur, d'identifiants, de nom de source ou de profil, ni de dates de visionnage.
- **Rien ne bloque l'interface** : calcul local synchrone et borné, IA asynchrone, et la rangée locale reste affichée en cas d'échec.
- **Aucune fenêtre ni carte par-dessus l'image d'un direct.**
- Journaux `RECO` et `AI` sans titres envoyés ni réponse brute : seulement le type, la durée, la taille et le résultat de la validation.
- Pas de nouvelle crate Rust lourde, pas de serveur tiers ; les cibles macOS, iOS, tvOS et visionOS restent vertes.

---

## 14. Critères d'Acceptation & Commandes de Validation

1. **Tests Rust :**
   - jeu d'évaluation du § 10 avec ses seuils ;
   - goûts par type (récence, zapping ignoré, séries agrégées, poids négatif) ;
   - séries au niveau de la série, « Continuer », nouvelle saison ;
   - TV : correspondance genre EPG, tranches horaires, EPG périmé ;
   - validation des réponses IA (tous les cas `MockProvider`), cache, plafond, invalidation ;
   - SLA : `recommendation_shelves` < 50 ms par type sur 50 000 éléments (`--release`).
2. **Tests Swift :** refiltrage par type dans le modèle, rangées masquées quand le réglage est désactivé, signe ✨ seulement après un affinage réussi, aucun appel distant en mode Enfants, rangée du direct désactivée par défaut.
3. **Essais manuels :**
   - macOS : écran Films avec Gemini → « Pour vous » affiné, raisons lisibles, aucune série ni chaîne ;
   - écran Séries → cartes de séries, « Continuer » sur le bon épisode, aucun épisode d'une autre série ;
   - Live TV avec un EPG à jour → programmes en cours pertinents ; avec un EPG périmé → message et bouton « Actualiser le guide » ;
   - Ollama sur la machine → affinage sans réseau extérieur (vérifié en coupant Internet) ;
   - Apple TV → rangées au focus.
4. Commandes de validation :
   - `cargo clippy --workspace --all-targets -- -D warnings` ;
   - `cargo test --workspace --release` ;
   - `cd apple && swift test` ;
   - builds des 4 schémas Xcode ;
   - `task check` au vert.

---

## 15. Questions ouvertes

- **Plafond d'appels distants :** 30 par jour suffisent-ils, ou faut-il un affinage seulement à la demande (bouton ✨) pour les clés gratuites de Gemini ?
- **Titres récents vers une IA distante :** ce PRD les envoie seulement si l'utilisateur l'active. Sans eux, l'affinage distant s'appuie sur les agrégats et sera moins précis.
- **Rafraîchissement automatique de l'EPG :** il conditionne les rangées TV (§ 5.3). Il est à traiter dans un PRD ou un correctif à part (actualisation au lancement si le guide est périmé, puis périodique).
- **Séries dans les sagas** (séries Marvel) : toujours exclues, comme au `PRD-27`. Le type « série » reste séparé même si l'univers est le même.
- **Modèle d'Apple :** sa qualité sur une tâche de tri en français est à mesurer avec le jeu du § 10 avant de le proposer par défaut sur les appareils compatibles.

---

## 16. Statut d'Implémentation & Validation

**Partiel : lots 34.1 à 34.4 côté Rust et Swift ; lot 34.5 non fait.**

- **Fait (Rust, 306 tests au vert, clippy sans avertissement) :**
  - goûts par type, calculés à la demande, sans la table `taste_profile` ;
  - rangées Films, Séries et TV : `recommend/{taste,movies,series,live,shelves}.rs` ;
  - affinage par l'IA : `recommend/ai_rerank.rs`, avec `Task::Recommend` pour Gemini, compatible OpenAI (Ollama, LM Studio) et Claude ;
  - validation, cache `reco_ai_cache`, plafond de 30 appels par jour pour un fournisseur distant, aucun appel pour le profil Enfants ;
  - « Moins de ce genre » et réinitialisation des goûts ;
  - jeu d'évaluation `recommend/eval.rs` : 0 carte d'un autre type, bon épisode suivant, EPG périmé, réponses IA piégées ;
  - SLA mesuré sur 50 000 films, 3 000 séries et 5 000 chaînes : Films ≈ 28 ms, Séries ≈ 4 ms, TV ≈ 36 ms.
- **Fait (Swift) :** `ForYouModel`, `ForYouShelves` (verrou de type, ✨, bannière « Actualiser le guide »), rangées dans Films, Séries et Live TV, section de Réglages. Le paquet Swift compile.
- **Écarts avec le texte du PRD :**
  - pas de table `taste_profile` ni de colonne `kind` sur `recommendation_dismissals` ;
  - le fournisseur des recommandations est celui de l'assistant (pas de choix séparé) ;
  - la TV ne connaît que le dernier créneau horaire par chaîne ;
  - le profil Enfants n'appelle jamais d'IA, même locale ;
  - `recommendation_shelves` prend en plus le décalage horaire.
- **Non fait :** lot 34.5 (modèle d'Apple sur l'appareil), rangée facultative sous le lecteur pendant un direct, tests Swift, builds Xcode des 4 schémas, essai avec un vrai fournisseur (Gemini, Ollama), essai à l'écran.
