# PRD 33 — Recherche par prompt : trouver une chaîne, un programme, un film ou une série en langage naturel

- **ID :** `PRD-33`
- **Prérequis :**
  - `PRD-13` (assistant ⌘K, fournisseurs IA de l'utilisateur, consentement) ;
  - `PRD-04` (EPG) et `PRD-05` (catalogue, FTS5) ;
  - `PRD-06` (métadonnées OMDb) et `PRD-15` (replay) ;
  - `PRD-20` (profils, mode Enfants, catégories adultes) ;
  - `PRD-27` (recommandations, sagas) et `PRD-28` (clés par défaut) ;
  - `PRD-32` (bibliothèque locale, pour le lot 33.5).
- **Couches impactées :**
  - `Rust (crates/cnd-core/src/ai/, src/search/, db/)` ;
  - `UniFFI` ;
  - `SwiftUI (Features/Assistant/, Features/Search/)` ;
  - `AppIntents` (lot 33.4).
- **Objectifs SLA :**
  - **résultats locaux** affichés en **< 150 ms** sur un catalogue de 50 000 éléments, à chaque frappe ;
  - **avec un fournisseur IA :** résultats affinés en **< 3 s au p90**, délai maximal **8 s** ;
  - les résultats locaux restent à l'écran pendant l'attente : la réponse de l'IA les **réordonne et les complète**, elle ne les remplace jamais par un écran vide.

---

## 1. Contexte & Objectif

L'assistant ⌘K actuel (`PRD-13`) **ne sait que changer de chaîne** : il propose au plus 40 chaînes en direct au modèle, et ses actions se limitent à `play`, `guide`, `search`, `next`, `previous`, `multiview` et `none`. Il ne cherche :
- ni dans les **films**, ni dans les **séries** ;
- ni dans les **programmes à venir** de l'EPG ou dans le **replay**.

Il ne comprend pas non plus une description plutôt qu'un nom.

Ce PRD transforme la palette en **recherche universelle par prompt**. Exemples de demandes :

| Prompt | Résultat attendu |
| :--- | :--- |
| « le match du PSG ce soir » | Le programme EPG du soir qui parle du PSG, sur la chaîne qui le diffuse, avec « Lire » à l'heure dite ou « Enregistrer ». |
| « un film d'action avec Tom Cruise » | Les films du catalogue de l'utilisateur avec Tom Cruise (*Top Gun : Maverick*, *Mission : Impossible*…), triés par pertinence. |
| « une série coréenne romantique » | Les séries du catalogue qui correspondent, avec la raison (« Corée du Sud · romance »). |
| « quelque chose comme Inception » | Des films proches présents dans le catalogue, avec *Inception* lui-même s'il y est. |
| « les infos en anglais » | Les chaînes d'information anglophones en direct, avec leur programme en cours. |
| « le JT de 20 h d'hier » | L'émission dans le replay, si la chaîne a une archive (`PRD-15`). |
| « dessins animés pour les petits » | Contenus pour enfants : chaînes, films, séries. |
| « Avengers dans l'ordre » | La saga dans l'ordre choisi (`PRD-27`). |

**Principe directeur :** l'IA **comprend la demande** et **propose des titres**, mais **seuls des éléments réellement présents dans les sources de l'utilisateur** sont affichés et lisibles. Sans IA, la recherche locale améliorée reste utile.

**Hors périmètre :**
- contenus absents du catalogue de l'utilisateur ;
- recherche sur le Web ;
- conversation en plusieurs tours (lot 33.6 facultatif : un seul affinage).

---

## 2. Expérience utilisateur

### 2.1. Où

- **Palette ⌘K (macOS, iPad avec clavier) et feuille de recherche (iPhone) :** la même saisie sert aux commandes (« mets France 2 ») et aux recherches (« un film comme Inception »).
- **Champs de recherche** de Live TV, Films et Séries : un bouton ✨ « Rechercher avec l'assistant » envoie la saisie à la recherche par prompt.
- **Apple TV :** champ de recherche avec la dictée de la Siri Remote.
- **Siri et Raccourcis (lot 33.4)** : « Dis Siri, cherche un film avec Tom Cruise dans Buntu ».

### 2.2. Présentation des résultats

- **Résultats groupés** par section, dans l'ordre de pertinence :
  - **Meilleur résultat :** une carte large avec l'affiche ou le logo, la raison et l'action principale.
  - **Chaînes en direct :** logo, programme en cours.
  - **Programmes :** en cours, à venir, ou en replay, avec chaîne et horaire.
  - **Films :** affiche, année, note.
  - **Séries :** affiche, nombre de saisons.
- **Une raison courte pour chaque résultat :**
  - « Avec Tom Cruise » ;
  - « Ce soir 21 h 00 sur Canal+ Sport » ;
  - « Même réalisateur qu'*Inception* » ;
  - « Corée du Sud · romance ».
- **Actions selon le type :**
  - **Chaîne :** Lire.
  - **Programme à venir :** Enregistrer ou Me rappeler.
  - **Programme en replay :** Revoir.
  - **Film :** Lire ou Reprendre, Voir la fiche, Télécharger.
  - **Série :** Ouvrir la série, Épisode suivant.
- **Commandes directes :** quand la demande en est une sans ambiguïté (« mets TF1 »), le comportement actuel est conservé : action immédiate, palette fermée.
- **Indicateurs :**
  - pendant l'attente de l'IA : « Résultats locaux · l'assistant affine… » ;
  - ensuite, la source de l'ordre : « Classés par l'assistant (Gemini) » ou « Recherche locale ».
- **Titres absents :** quand l'IA connaît des titres qui ne sont pas dans le catalogue (*Top Gun* original absent), une ligne discrète l'indique : « 2 titres connus absents de vos sources ». Ces titres ne sont jamais proposés à la lecture, comme au `PRD-27`.
- **Aucun résultat :** la palette propose une reformulation (« Essayer : *films d'action 2022* ») et la recherche locale simple.

### 2.3. Historique et suggestions

- **Historique :** les recherches récentes restent **sur l'appareil**, par profil, effaçables dans Réglages.
- **Suggestions de départ** à l'ouverture de la palette (« Ce soir à la télé », « Films ajoutés cette semaine », « Reprendre… »), calculées localement.

---

## 3. Pipeline de recherche

Quatre étapes. Les étapes 1 et 2 sont **locales** et toujours exécutées ; les étapes 3 et 4 n'ont lieu qu'avec un fournisseur IA prêt (consentement, clé, hors mode Enfants).

### 3.1. Étape 1 — Analyse locale du prompt (Rust, `search/query_parser.rs`)

Extraction sans réseau de ce qui peut l'être :
- **Type visé :** chaîne, programme, film ou série (« film », « série », « chaîne », « émission », « match »).
- **Période :**
  - « maintenant », « ce soir », « demain », « ce week-end », « hier », « à 20 h » ;
  - transformés en fenêtre EPG avec le fuseau de l'appareil.
- **Langue et pays :** « en anglais », « VOSTFR », « coréen », « arabe ». Ils sont repris de la table des langues actuelle, élargie.
- **Genre :** dictionnaire de synonymes FR, EN et wolof (lot 33.6), par exemple *action*, *comédie*, *horreur*, *romance*, *documentaire*, *dessins animés*, *sport*, *info*.
- **Année ou décennie :** « 2022 », « des années 90 ».
- **Qualité :** « 4K », « HD ».
- **Comparaisons et ordre :**
  - « comme X » (similarité) ;
  - « dans l'ordre » (saga, `PRD-27`) ;
  - « le dernier » (année la plus récente).
- **Mots restants :** titre, personne ou équipe recherchés.

Le résultat est une **requête structurée** (`SearchQuery`), qui sert telle quelle sans IA.

### 3.2. Étape 2 — Recherche locale (Rust, `search/engine.rs`)

- **Index FTS5 élargi :**
  - **ce qu'il couvre :** titres, titres nettoyés, catégories, titres et descriptions EPG ;
  - **métadonnées :** genres, acteurs, réalisateur et pays quand elles sont connues (§ 4).
- **Tolérance aux fautes :** variantes sans accents, préfixes, trigrammes pour une ou deux lettres fausses (« Avangers », « Mision Impossible »).
- **Filtres :** type, période EPG, langue (préfixes de catégorie `FR |`, `UK |` et métadonnées), genre, année, qualité.
- **Classement :**
  - **score combiné :** pertinence FTS, correspondance des filtres, favoris et historique du profil, nouveauté, programme en cours ;
  - **diversité :** au plus 3 versions d'un même titre (VF, VOSTFR, 4K), regroupées comme au `PRD-27`.
- **Respect du profil** avant tout : liste blanche Enfants, catégories adultes masquées, contenus en panne relégués en fin.

### 3.3. Étape 3 — Compréhension par l'IA (facultative)

Le modèle reçoit **le prompt et le contexte minimal** :
- la langue de l'interface ;
- la date et l'heure locales ;
- les types de contenu présents (« le catalogue contient des chaînes, des films et des séries »).

Il **ne reçoit pas le catalogue**. Il renvoie un JSON strict, validé par schéma :

```json
{
  "intent": "search",
  "kinds": ["movie"],
  "time_window": null,
  "filters": { "genres": ["action"], "people": ["Tom Cruise"], "year_from": null, "year_to": null, "languages": [], "country": null },
  "title_guesses": [{ "title": "Top Gun: Maverick", "year": 2022 }, { "title": "Mission: Impossible - Fallout", "year": 2018 }],
  "similar_to": null,
  "query_rewrite": "films action Tom Cruise",
  "reply": "Films avec Tom Cruise"
}
```

- **Ce qui en est fait :**
  - **`title_guesses` :** au plus 25 titres que le modèle associe à la demande (filmographie d'un acteur, films proches, épisodes d'une saga), recherchés **localement** dans le catalogue ;
  - **`filters` et `query_rewrite` :** ils complètent ou corrigent la requête de l'étape 1.
- **Pourquoi ce choix :** les titres que le modèle connaît comblent l'absence de métadonnées dans la plupart des playlists. C'est la clé de « film avec Tom Cruise » quand le catalogue n'a ni acteurs ni genres.
- **Commandes :** `intent` vaut aussi `play_channel`, `guide`, `record`, `next`, `previous` ou `multiview`. L'assistant actuel est absorbé, et ses tests restent valables.

### 3.4. Étape 4 — Réordonnancement par l'IA (facultatif)

- **Quand :** l'étape 2 renvoie plus de 10 résultats pour une demande descriptive (« un bon film pour ce soir en famille »).
- **Ce qui est envoyé :** les **40 meilleurs candidats** en données délimitées, comme au `PRD-13` :
  - un identifiant opaque temporaire ;
  - le titre nettoyé, le type et l'année ;
  - le programme EPG s'il y en a un ;
  - les genres connus.
- **Ce qui revient :** un ordre et une raison courte par élément. Tout identifiant inconnu est ignoré. Si la réponse est invalide, l'ordre local est conservé.
- **Un seul appel IA par recherche** dans la plupart des cas : l'étape 4 n'est faite que si l'étape 3 n'a pas suffi à ordonner. Un appel en plus pour l'étape 4, au maximum.

### 3.5. Fusion et affichage progressif

1. **Saisie :** l'étape 2 s'exécute à chaque frappe (après 150 ms sans saisie) et affiche ses résultats.
2. **Validation (Entrée) :** l'étape 3 part.
3. **Réponse de l'IA :** les titres trouvés grâce à elle sont insérés à leur place, les sections réordonnées et les raisons ajoutées. Le défilement et la sélection au clavier sont conservés.
4. **Échec ou délai dépassé :** les résultats locaux restent, avec un message discret (« Assistant indisponible : résultats locaux »).

---

## 4. Métadonnées pour chercher par genre, acteur ou pays

La recherche par description n'est bonne que si le catalogue connaît genres et acteurs. Sources, par ordre de coût :

1. **Données des sources :**
   - **Xtream :** `get_vod_streams` et `get_series` fournissent souvent `genre`, `cast`, `director`, `rating`, `releaseDate` et `tmdb`. Ces champs sont **conservés à l'import** quand ils existent ; aujourd'hui, ils sont en partie ignorés.
   - **M3U :** seules les catégories (`group-title`) servent de genre approximatif (« FR | ACTION »).
2. **Cache OMDb (`PRD-06`) :** déjà rempli à l'ouverture des fiches. Il est intégré à l'index de recherche.
3. **Enrichissement en arrière-plan (facultatif, désactivé par défaut) :**
   - **déroulement :** OMDb ou TMDB complètent les films et séries **les plus regardés et les plus récents** du catalogue ;
   - **quota :** au plus 500 requêtes par jour, plus une limite propre à la clé par défaut (`PRD-28`) ;
   - **priorité :** l'enrichissement ne passe jamais devant une lecture.
4. **Connaissance du modèle (§ 3.3) :** elle couvre le reste par les `title_guesses`, sans rien stocker.

**Nouveaux champs :**
- **films et séries :** `genres`, `cast`, `director`, `country`, `year`, `tmdb_id` ;
- **source de chaque champ :** `source_meta`, `omdb` ou `tmdb`.

---

## 5. Sécurité, confidentialité, contrôle parental

- **Envoyé au fournisseur IA :**
  - **étape 3 :** le prompt, la langue, la date et l'heure locales, et les types de contenu présents ;
  - **étape 4 :** au plus 40 titres nettoyés avec leur type, leur année et leurs genres, sous des identifiants opaques.
- **Jamais envoyé :** URL de flux, nom de source ou de serveur, identifiants, historique de visionnage, nom de profil.
- **Données de playlists :** les titres et programmes viennent de playlists tierces et peuvent contenir des instructions. Ils sont délimités et encodés en JSON, et le prompt système interdit de leur obéir (comme au `PRD-13`).
- **Validation des réponses :**
  - **types :** les `title_guesses` sont du texte à chercher, jamais des éléments lisibles ;
  - **identifiants :** seuls ceux de la liste fournie sont acceptés ;
  - **plafonds :** 25 titres, 120 caractères chacun.
- **Mode Enfants :** aucune IA distante. Recherche locale limitée à la liste blanche.
- **Catégories adultes :** masquées **avant** l'envoi et **après** la réponse, même si le prompt le demande.
- **Consentement :** celui du `PRD-13` reste exigé, et la limite quotidienne de la clé par défaut du `PRD-28` s'applique.
- **Journaux :** catégorie `AI`, sans le texte du prompt ; seulement sa longueur, les étapes exécutées, les durées et le résultat de validation.

---

## 6. Qualité : jeu d'évaluation

La qualité ne se juge pas à l'œil, elle se mesure.

- **Catalogue de test fixe** (`tests/fixtures/search_catalog.json`), environ 2 000 éléments :
  - chaînes multilingues avec EPG ;
  - films et séries connus, avec et sans métadonnées ;
  - doublons de versions ;
  - catégories adultes.
- **120 prompts annotés** (`tests/fixtures/search_prompts.json`) :
  - français, anglais et quelques-uns en wolof ;
  - fautes de frappe ;
  - demandes temporelles et descriptives ;
  - pièges : injection dans un titre, contenu adulte, mode Enfants.
- **Résultats attendus :** pour chaque prompt, les identifiants qui doivent apparaître parmi les 3 premiers.
- **Mesures :** précision top-1 et top-3, avec un fournisseur simulé dans les tests automatiques.
- **Seuils :**
  - recherche locale seule : **≥ 70 % top-3** ;
  - avec IA simulée : **≥ 90 % top-3** ;
  - **100 %** de respect des règles (adultes, Enfants, aucun élément inventé).
- **Script d'évaluation réelle** (`task ai:eval PROVIDER=gemini`), à lancer à la main avec la clé de l'utilisateur. Il compare les fournisseurs et les versions du prompt, sans jamais tourner dans `task check`.

---

## 7. Lots

| Lot | Contenu | Validation principale |
| :--- | :--- | :--- |
| **33.1** | Analyse locale du prompt (§ 3.1), recherche universelle locale (chaînes, EPG, films, séries, replay), tolérance aux fautes, résultats groupés dans la palette et la feuille iPhone, actions par type. | Jeu d'évaluation local ≥ 70 % top-3 ; SLA < 150 ms sur 50 000 éléments. |
| **33.2** | Compréhension par l'IA (§ 3.3) avec `title_guesses`, fusion progressive, commandes de l'assistant actuel absorbées, titres absents signalés. | Jeu d'évaluation avec IA simulée ≥ 90 % top-3 ; tests de validation (identifiants inventés, JSON cassé, délai). |
| **33.3** | Métadonnées des sources Xtream conservées, cache OMDb dans l'index, enrichissement en arrière-plan facultatif, réordonnancement par l'IA (§ 3.4). | Tests d'import Xtream avec `genre` / `cast` ; tests du quota. |
| **33.4** | Siri et Raccourcis (`AppIntents` : « Chercher dans Buntu », « Lire la chaîne… »), recherche Apple TV par dictée, bouton ✨ dans les champs de recherche. | Essai Siri sur iPhone et Mac. |
| **33.5** | Recherche étendue à « Mes fichiers » (`PRD-32`). | Tests sur une bibliothèque de test. |
| **33.6** *(facultatif)* | Un tour d'affinage (« plutôt récent », « en VF ») ; synonymes en wolof. | Tests de l'affinage. |

---

## 8. Fichiers à Créer / Modifier

- **Rust :**
  - `crates/cnd-core/src/search/` *(nouveau)* : `mod.rs`, `query_parser.rs`, `engine.rs`, `fuzzy.rs`, `ranking.rs` ;
  - `crates/cnd-core/src/ai/` : `prompt.rs` (prompt version 2, schémas `understand` et `rerank`), `mod.rs` (orchestration en 4 étapes), `intent.rs` (records `SearchQuery`, `SearchResult`, `SearchSection`, `SearchReason`) ;
  - `crates/cnd-core/src/db/schema.rs` *(colonnes de métadonnées, FTS élargi)* et `iptv/xtream.rs` *(conserver `genre`, `cast`, `director`, `releaseDate`, `tmdb`)* ;
  - `crates/cnd-core/src/metadata/` *(enrichissement en arrière-plan, lot 33.3)* ;
  - `crates/cnd-core/src/lib.rs` *(exports `search_local`, `search_with_ai`)*, puis `scripts/build-xcframework.sh`.
- **Swift :**
  - `apple/Sources/CndIptvKit/Features/Assistant/` : `AssistantModel.swift`, `CommandPaletteView.swift` (résultats groupés, affichage progressif) ;
  - `apple/Sources/CndIptvKit/Features/Search/SearchResultsView.swift`, `SearchResultRow.swift` *(nouveaux)* ;
  - `apple/Sources/CndIptvKit/Features/Search/SearchIntents.swift` *(nouveau, lot 33.4)*.
- **Tests et outils :**
  - `tests/fixtures/search_catalog.json`, `search_prompts.json` ;
  - `scripts/ai-eval.sh`, `Taskfile.yml` *(`ai:eval`)* ;
  - `apple/Tests/CndIptvAppTests/PromptSearchTests.swift`.
- **Index :** `PRD/00_INDEX_ROADMAP.md`.

---

## 9. Contraintes Non-Négociables (Guardrails IA)

- **Aucun élément proposé à la lecture qui ne soit pas dans les sources de l'utilisateur.** Ce que l'IA renvoie n'est que du texte à chercher ou un ordre de candidats.
- **Les règles du profil passent avant tout,** avant l'envoi et après la réponse : Enfants, catégories adultes, contenus masqués par l'utilisateur.
- **Rien de personnel ne quitte l'appareil** (§ 5) ; l'historique des recherches reste local.
- **La recherche locale fonctionne toujours :** sans réseau, sans clé et en mode Enfants.
- **Aucun blocage de l'interface :** saisie fluide, résultats locaux immédiats, IA en tâche de fond, annulée si la saisie change.
- **Pas de nouvelle crate Rust lourde** : FTS5 et trigrammes en SQL, pas de moteur de recherche externe.
- **Les cibles macOS, iOS, tvOS et visionOS restent vertes,** et les tests de l'assistant du `PRD-13` passent toujours.

---

## 10. Critères d'Acceptation & Commandes de Validation

1. **Tests Rust :**
   - analyse du prompt : périodes, langues, genres, années, qualité, « comme X », « dans l'ordre » ;
   - fautes de frappe ;
   - filtres du profil ;
   - fusion des `title_guesses` ;
   - validation des réponses IA (identifiants inventés, JSON cassé, titres trop longs, délai dépassé) ;
   - injection dans un titre de playlist ignorée ;
   - SLA : 50 000 éléments, résultats locaux en moins de 150 ms (`--release`).
2. **Jeu d'évaluation (§ 6)** au-dessus des seuils, dans `cargo test` avec le fournisseur simulé.
3. **Tests Swift :**
   - affichage progressif (résultats locaux puis IA, sélection conservée) ;
   - actions par type ;
   - commande directe qui ferme la palette ;
   - mode Enfants sans appel distant.
4. **Essais manuels avec un vrai fournisseur :** les 8 exemples du § 1 sur un vrai catalogue Xtream.
5. **Commandes :** `cargo clippy --workspace --all-targets -- -D warnings`, `cargo test --workspace --release`, `cd apple && swift test`, builds des 4 schémas Xcode, `task check` au vert.

---

## 11. Questions ouvertes

- **Enrichissement en arrière-plan (§ 4.3) :** l'activer par défaut avec la clé intégrée, ou le laisser à la demande ? Il améliore beaucoup la recherche par genre, mais consomme le quota partagé.
- **Siri (lot 33.4) :** faut-il exposer aussi « Lire la chaîne X » et « Reprendre le dernier film », ou seulement la recherche ?
- **Wolof :** faut-il viser des prompts complets en wolof, ou seulement quelques mots clés (*film*, *xibaar* pour les infos, *ndaw* pour les enfants) ? Une validation par des locuteurs sera nécessaire.

---

## 12. Statut d'Implémentation & Validation

**Lots 33.1 et 33.2 réalisés ✅ ; lot 33.3 en partie ; lots 33.4, 33.5 et 33.6 non réalisés. Non essayé avec un vrai fournisseur IA ni à l'écran.**

- **Analyse du prompt** (`search/query_parser.rs`) : type visé (film, série, chaîne, programme), fenêtre de temps (« ce soir », « demain », « hier », « à 20h30 », « ce week-end ») dans le fuseau de l'appareil, langue ou pays, genre (FR et EN, formes féminines et pluriels), année et décennie, qualité, « comme X », « dans l'ordre », personnes (« avec X », « de X », deux mots capitalisés). 17 tests.
- **Recherche locale** (`search/engine.rs`, `db/search_repo.rs`) : chaînes (index plein texte, catégorie, langue, programme en cours), programmes de l'EPG (ce soir, demain, replay seulement si la chaîne a une archive, copies d'une même chaîne comptées une fois), films (titre, métadonnées OMDb en cache : genre, acteur, réalisateur ; catégories ; année ; qualité ; « comme X »), séries (mots du titre, catégories, langue), tolérance aux fautes (distance d'édition sur les mots, courts mots exacts). Classement (titre exact, favoris, reprise, note, filtres), une seule entrée par titre, raison courte pour chaque résultat. **Toutes les requêtes appliquent le profil** : éléments et catégories masqués, adultes, liste blanche Enfants, flux en panne.
- **Assistant** (`search/ai_search.rs`, `ai/prompt.rs`, `ai/providers.rs`) : une commande directe (« mets TF1 », « chaîne suivante ») est exécutée localement sans appel réseau ; sinon le fournisseur de l'utilisateur renvoie un JSON strict (genres, personnes, années, langues, « comme X », réécriture, jusqu'à 25 titres, réponse) via les schémas Gemini, OpenAI et Claude. Rien n'est envoyé du catalogue, d'une adresse de flux ni d'une clé hors en-tête ; chaque champ est borné et nettoyé ; les filtres du modèle **complètent** la demande sans pouvoir retirer ce que l'utilisateur a écrit (un « film » ne devient pas une série) ; chaque titre proposé est **cherché dans le catalogue** : trouvé, il est classé en tête avec « Proposé par l'assistant » ; absent, il est signalé comme texte (« N titres connus absents de vos sources »), jamais lisible. Échec, délai dépassé, JSON invalide, clé absente, mode Enfants ou mode local : résultats locaux et raison du repli.
- **Application** : la palette ⌘K montre à chaque frappe les résultats locaux groupés (programmes, chaînes, films, séries), puis, après Entrée, l'assistant les affine sans jamais les remplacer ; un toucher fait ce que le résultat est (lire une chaîne ou un programme en cours, ouvrir le guide d'un programme à venir, ouvrir la fiche d'un film ou d'une série). Libellés parlés pour VoiceOver. La commande de chaîne (« chaîne 3 ») passe devant les résultats. Quand rien n'est trouvé, les mots partent vers la recherche du catalogue comme avant.
- **Évaluation** (`search/eval.rs`) : un catalogue fixe (9 chaînes, 19 films avec métadonnées, 6 séries, programmes, un film adulte, un film en panne, une copie 4K) et **48 prompts annotés** : 98 % retrouvés dans les 3 premiers sans IA (seuil du PRD : 70 %). 11 tests de règles : rien de masqué, adulte, en panne ni hors liste Enfants ne revient ; versions groupées ; raisons ; replay ; vitesse (< 150 ms mesurée). 11 tests de l'assistant contre un faux fournisseur (titres trouvés et absents, rien du catalogue envoyé, titre piégé, panne, délai, JSON invalide, Enfants et mode local sans appel, clé absente, commande directe, intention « none », titres qui comblent l'absence de métadonnées). 19 tests Swift (frappe, Entrée, commande, rien trouvé, titres absents, erreur, réponse périmée, actions de chaque type).
- **Assistant actif = assistant utilisé** : dès qu'un fournisseur est prêt, il travaille aussi **pendant la saisie**, sans Entrée : après une pause de 0,7 s (3 caractères au moins), le texte est envoyé une fois, les résultats locaux restent à l'écran et l'assistant les complète. Entrée réutilise cette réponse (pas de second appel). Une commande directe n'est jamais exécutée depuis la saisie, seulement avec Entrée ; une panne reste silencieuse pendant la frappe. Réglage « Chercher avec l'assistant pendant la saisie » (activé par défaut ; désactivé, seul Entrée envoie). Quand un fournisseur est choisi mais inutilisé (consentement, clé, quota), la palette le dit en clair avec un bouton « Autoriser » pour le cas du consentement.
- **Écarts avec le PRD** : le jeu d'évaluation compte 48 prompts en Rust dans le code, pas 120 en JSON ; la mesure « avec IA simulée ≥ 90 % » n'est pas faite (les tests de l'assistant vérifient le comportement, pas un taux) ; pas de script `task ai:eval` contre un vrai fournisseur ; le réordonnancement de l'étape 4 n'est pas fait (l'étape 3 classe les titres proposés en tête) ; les métadonnées Xtream (`genre`, `cast`…) ne sont pas conservées à l'import (seul le cache OMDb alimente la recherche par genre et acteur) ; pas d'enrichissement en arrière-plan.
- **Non fait** : Siri et Raccourcis, recherche Apple TV par dictée, bouton ✨ dans les champs de recherche (lot 33.4) ; recherche dans « Mes fichiers » (33.5) ; affinage en un tour et mots clés wolof (33.6) ; historique effaçable par profil (l'historique de la palette existe, il n'est pas par profil) ; suggestions de départ calculées localement.
- **Non vérifié** : aucun essai avec Gemini, Claude ou un serveur compatible OpenAI réels (seulement un faux serveur) ; aucun essai à l'écran ; la qualité sur un vrai catalogue Xtream (surtout les films dont les métadonnées ne sont pas en cache : sans elles, « avec Tom Cruise » repose entièrement sur les titres proposés par le modèle) ; le fuseau horaire et « ce soir » avec une EPG réelle.
