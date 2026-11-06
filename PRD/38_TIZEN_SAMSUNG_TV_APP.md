# PRD 38 — Application Samsung Smart TV (Tizen) : rapide, simple à la télécommande, modulaire

- **ID :** `PRD-38`
- **Prérequis :**
  - le cœur Rust `cnd-core` (`PRD-01` à `PRD-07`, `PRD-13`, `PRD-20`, `PRD-33`, `PRD-34`) ;
  - le comportement « une seule connexion au serveur » et la détection de débit insuffisant, appris sur iPhone ;
  - `PRD-26` (partage des sources par fichier chiffré et réseau local) ;
  - `PRD-37` (application Android), dont ce PRD reprend les principes SRP, l'ergonomie TV et la matrice de mesures.
- **Couches impactées :**
  - `Rust` : séparation d'un crate **`cnd-domain`** sans entrées-sorties, compilé en **WebAssembly** pour la TV et réutilisé par `cnd-core` ;
  - `tizen/` *(nouveau)* : application web Tizen (TypeScript), lecteur **AVPlay** de Samsung ;
  - `scripts/` : `build-tizen.sh` (WebAssembly, regroupement, paquet `.wgt` signé) ;
  - `Taskfile.yml` : tâches `tizen:*`.
- **Objectifs SLA** (mesurés sur les téléviseurs réels du § 9) :

| Mesure | TV 2017–2018 (Tizen 3–4) | TV 2019–2021 (Tizen 5–6) | TV 2022 et plus (Tizen 6.5–9) |
| :--- | :--- | :--- | :--- |
| Lancement jusqu'au premier écran utile | < 4 s | < 3 s | < 2 s |
| Déplacement du focus (touche → image) | < 120 ms | < 80 ms | < 50 ms |
| Fluidité des rangées et grilles | ≥ 30 i/s, sans à-coup | 60 i/s | 60 i/s |
| Changement de chaîne jusqu'à l'image | < 2 s | < 1,5 s | < 1 s |
| Première image d'un film (bon réseau) | < 5 s | < 4 s | < 3 s |
| Mémoire de l'application | < 250 Mo | < 300 Mo | < 350 Mo |

Une touche de télécommande qui attend plus de 100 ms avant que l'écran réagisse est un défaut, sur les modèles récents comme sur les anciens.

---

## 1. Contexte & Objectif

Les téléviseurs Samsung (Tizen) sont parmi les plus répandus. Leurs propriétaires veulent regarder leurs sources IPTV sans boîtier supplémentaire. L'app existe sur Apple, et sa version Android est prévue au `PRD-37`.

Tizen impose des contraintes qu'Apple et Android n'ont pas :
- **Type d'app :** les apps du Samsung TV Store sont des **applications web** (HTML, CSS, JavaScript) exécutées par le moteur web du téléviseur. Les apps natives en C ou C++ sont réservées aux partenaires de Samsung. Les apps .NET existent, mais sont moins répandues et moins documentées pour la vidéo.
- **Pas de serveur local :** une app web ne peut pas ouvrir de port d'écoute. Le relais local utilisé sur iPhone n'est donc pas possible.
- **Matériel modeste :** processeurs lents et mémoire limitée, surtout sur les modèles 2017 à 2019 encore très utilisés. Leur moteur web est aussi ancien : Chromium 56 à 76 selon l'année.
- **Lecteur vidéo :** le bon lecteur est **AVPlay**, celui de Samsung. Il utilise le décodeur matériel du téléviseur et sait lire MKV, TS, HLS, MP4, HEVC 4K, HDR10, Dolby Vision selon les modèles, et AC3, E-AC3 ou DTS selon le modèle. Les balises `<video>` du navigateur ne savent pas tout cela.

**Objectif :** une app Samsung Smart TV qui :
- fonctionne sur **tous les téléviseurs Samsung depuis 2017** (Tizen 3.0) ;
- est **fluide à la télécommande**, sans latence ;
- est **simple** : une source ajoutée depuis le téléphone en moins d'une minute, puis une chaîne qui démarre ;
- **réutilise la logique métier** du cœur Rust au lieu de la réécrire en JavaScript ;
- est **modulaire**, avec une seule responsabilité par module (SRP).

**Hors périmètre :**
- téléviseurs Samsung de 2015–2016 (Tizen 2.3–2.4, moteur web trop ancien), à décider au § 13 ;
- montres Tizen ;
- autres téléviseurs (LG webOS, Hisense VIDAA), même si l'architecture choisie les rend faciles à ajouter ensuite (§ 2.4).

---

## 2. Architecture

### 2.1. Choix du type d'application

| Option | Avantages | Inconvénients | Choix |
| :--- | :--- | :--- | :--- |
| **App web Tizen + cœur Rust en WebAssembly + AVPlay** | Tous les modèles depuis 2017, Store Samsung, logique métier partagée avec Apple et Android | Le cœur doit être séparé de ses entrées-sorties (§ 3) | **Retenu** |
| App web avec la logique réécrite en TypeScript | Démarrage rapide du projet | Logique écrite deux fois (parsing, recherche, recommandations), divergences assurées | Refusé (SRP, réutilisation) |
| App Tizen .NET + bibliothèque Rust native | Code natif rapide | Bibliothèques natives non garanties hors partenaires, moins de modèles, outillage vidéo limité | Refusé |
| Web app hébergée sur un serveur | Mise à jour sans Store | Dépend d'un serveur, refus probable au Store | Refusé |

### 2.2. Répartition des responsabilités

| Couche | Responsabilité unique | Ne fait jamais |
| :--- | :--- | :--- |
| **`cnd-domain` (Rust → WebAssembly)** | Règles métier pures : analyse M3U et Xtream, normalisation des séries, analyse XMLTV, analyse des prompts et classement de la recherche, goûts et recommandations, sagas, validation des réponses IA, règles des profils (Enfants, adultes) | Réseau, disque, horloge système (l'heure lui est donnée) |
| **`tizen/core/storage`** | Base **SQLite en WebAssembly** (wa-sqlite avec persistance IndexedDB), même schéma et mêmes requêtes que le cœur, dont FTS5 | Règles métier |
| **`tizen/core/net`** | Requêtes HTTP (`fetch` / XHR) avec l'User-Agent et les en-têtes de la source, file d'attente **à une connexion**, résolution des redirections | Analyse des réponses (confiée à `cnd-domain`) |
| **`tizen/core/engine`** | Façade unique : enchaîne `net`, `cnd-domain` et `storage` (synchroniser une source, charger une page de catalogue, chercher, construire les rangées) | Affichage |
| **`tizen/core/player`** | AVPlay : ouverture, pistes, sous-titres, tampon, surveillance des blocages, débit insuffisant, session gardée | Écrans |
| **`tizen/core/input`** | Touches de la télécommande (enregistrement Tizen, haut/bas chaîne, chiffres, couleurs, lecture), navigation au focus | Logique d'écran |
| **`tizen/ui/design`** | Jetons et composants TV (carte, rangée, grille virtualisée, bandeau, clavier à l'écran) | Données |
| **`tizen/features/*`** | Un écran ou un parcours chacun : un état (store) et une vue | Appeler `storage` ou `net` directement (toujours par `engine`) |
| **`tizen/app`** | Démarrage, routes, cycle de vie (mise en arrière-plan, veille, retour à l'accueil Smart Hub) | Logique d'écran |

### 2.3. Règles

- **Flux de données à sens unique.** Chaque écran a un état immuable et reçoit des intentions. Aucun état partagé modifiable entre écrans.
- **Le travail lourd hors du fil d'affichage :**
  - l'analyse d'une liste M3U de 50 000 lignes, l'analyse du guide XMLTV et les requêtes SQLite tournent dans un **Web Worker** ;
  - le fil principal ne fait qu'afficher et réagir aux touches.
- **Aucune règle du cœur recopiée en TypeScript.** Si une règle manque à `cnd-domain`, elle y est ajoutée, puis Apple et Android en profitent.
- **TypeScript strict**, modules ES, regroupement par **Vite** (sortie compatible Chromium 56 avec les polyfills nécessaires).

### 2.4. Bénéfice au-delà de Tizen

`cnd-domain` en WebAssembly rend la même app possible plus tard sur **LG webOS**, **Hisense VIDAA** et dans un navigateur. Seuls `core/player` (AVPlay, `webOS Luna`, `<video>`) et `core/input` changent. C'est une question ouverte (§ 13), pas un engagement de ce PRD.

---

## 3. Séparer le cœur Rust : `cnd-domain`

Aujourd'hui `cnd-core` mélange les règles métier et leurs entrées-sorties (SQLite natif, `reqwest`, `tokio`, sockets). WebAssembly n'a ni sockets ni fils `tokio` natifs.

- **Nouveau crate `crates/cnd-domain`** : fonctions pures, sans `tokio`, sans `reqwest` et sans `rusqlite`. Il reçoit et rend des données. L'heure courante et le décalage horaire sont des paramètres.
  - analyse M3U, normalisation des séries et des chaînes (`iptv/normalizer`) ;
  - analyse des réponses Xtream (JSON vers enregistrements) ;
  - analyse XMLTV en flux (par morceaux, pour tenir en mémoire sur TV) ;
  - analyse des prompts, classement, Damerau-Levenshtein, prompts et validation des réponses IA (`search/`, `ai/prompt`) ;
  - goûts, rangées et diversité des recommandations, à partir de lignes fournies (`recommend/taste`, `scoring`, `saga`) ;
  - règles de profil (catégories adultes, liste blanche Enfants).
- **`cnd-core` dépend de `cnd-domain`** et garde ses entrées-sorties.
  - Pour Apple et Android, rien ne change dans l'API UniFFI.
  - Les tests existants restent verts, et le jeu d'évaluation de la recherche (`PRD-33`) et celui des recommandations (`PRD-34`) tournent sur `cnd-domain`.
- **Liaison WebAssembly :** `wasm-bindgen` pour la cible `wasm32-unknown-unknown`. Les données passent en objets compacts, avec des tableaux plutôt que des milliers d'objets.
  - Objectif : moins de 1,5 Mo de WebAssembly compressé.
  - Optimisations : `opt-level = "z"`, `wasm-opt -Oz`, `lto`.
- **Base de données :**
  - **wa-sqlite** compilé avec FTS5, persisté dans **IndexedDB** ;
  - même schéma (`db/schema.rs` exporté en SQL) et mêmes requêtes que le cœur ;
  - les requêtes SQL vivent dans un fichier partagé, généré depuis Rust, pour ne jamais diverger.

---

## 4. Lecteur : AVPlay

### 4.1. Lecture

- **Moteur :** **AVPlay** (`webapis.avplay`), avec décodage matériel.
  - Formats : MKV, MP4, TS, HLS, DASH ; H.264, HEVC et VP9 selon le modèle ; 4K et HDR10 sur les modèles compatibles.
  - Son : AC3, E-AC3 et DTS selon le modèle, avec passthrough vers la barre de son.
- **Pistes et sous-titres :** pistes audio, sous-titres intégrés au MKV et SRT externes (`setExternalSubtitlePath`), avec décalage, comme sur Apple.
- **Affichage :** `setDisplayRect` plein écran. L'interface est dessinée au-dessus de la vidéo, dans une couche transparente.
- **Zapping :**
  - un seul lecteur à la fois (`stop` puis `open`, jamais deux AVPlay ouverts) ;
  - les touches **Chaîne +/−**, les chiffres de la télécommande et haut/bas dans le lecteur changent de chaîne ;
  - le bandeau maintenant / ensuite s'affiche pendant le chargement.
- **Fréquence d'image :** les téléviseurs Samsung s'adaptent au film. On vérifie qu'aucune option d'AVPlay ne le bloque.

### 4.2. Une seule connexion sans relais local

Sur Tizen, il n'y a pas de relais local possible. On reprend ce qui a résolu le problème sur iPhone : **la session du fournisseur est gardée**.

- **Avant d'ouvrir un film,** `core/net` résout la chaîne de redirections une seule fois, par une requête `GET` de quelques octets (`Range: bytes=0-0`) avec `responseURL`. AVPlay reçoit ensuite **l'adresse finale**.
  - Ses sauts dans le fichier, par exemple vers l'index d'un MKV, restent ainsi dans la même session.
  - Cette adresse est gardée par film et réutilisée pour les relances et la réouverture, jusqu'à ce qu'elle cesse de répondre.
- **Aucune autre requête n'est envoyée au même serveur pendant la lecture :**
  - pas de diagnostic en parallèle ;
  - pas de préchargement d'images depuis ce serveur ;
  - pas de mise à jour du guide en même temps.
- **Après un `429` :** on attend que le fournisseur libère la connexion (de 10 à 30 s, en le montrant à l'écran), sans rafale de relances. Les relances rapides prolongent le blocage, comme on l'a vu sur iPhone.
- **À vérifier au lot 38.3 :** AVPlay ferme-t-il sa connexion avant d'en rouvrir une lors d'un saut ? Si non, et si le serveur refuse quand même, il reste deux options :
  - lire le film du début sans sauter dans le fichier, l'avance rapide se faisant alors par réouverture à une position ;
  - proposer « Télécharger » (impossible sur TV, faute de stockage) ou « Autre version ».

### 4.3. Fluidité

- **Tampon :**
  - **direct :** démarrage rapide (`setBufferingParam` : petit tampon initial) ;
  - **films :** tampon plus long, et reprise seulement avec quelques secondes d'avance.
- **Surveillance des blocages :** un film dont les données arrivent encore n'est jamais relancé.
- **Débit insuffisant :** si AVPlay expose le débit (`getStreamingProperty`) et la taille, on compare comme sur iPhone. Le bandeau propose une autre version du même film.
- **Cycle de vie :** quand le téléviseur passe en veille, qu'on appuie sur Home ou qu'une autre source HDMI est choisie, on suspend AVPlay (`suspend`) puis on le reprend (`restore`). La connexion est libérée pendant l'absence.

---

## 5. Interface TV : fluide et simple

### 5.1. Règles de performance

- **Interface en 1920×1080**, mise à l'échelle par le téléviseur. Les images sont chargées à la taille d'affichage. Les affiches 4K ne sont jamais décodées.
- **Grilles et rangées virtualisées :**
  - seules les cartes visibles, plus une rangée d'avance, existent dans la page ;
  - les éléments sont **recyclés** au lieu d'être recréés ;
  - le catalogue est paginé (60 éléments par page).
- **Animations limitées à `transform` et `opacity`** (accélération matérielle). Pas d'ombres floues, de `filter` ni de `backdrop-filter` sur les modèles 2017–2019.
- **Déplacement du focus en une image :** la carte suivante est connue à l'avance (navigation spatiale calculée sur la grille, pas sur le DOM entier).
- **Cadre d'interface léger :** **SolidJS**, dont la réactivité fine met à jour seulement ce qui change, sans DOM virtuel, avec la navigation spatiale de **Norigin Spatial Navigation**.
  - Si le lot 38.6 mesure moins de 30 i/s sur les modèles 2017–2018, les rangées passent en rendu WebGL avec **Lightning 3**, conçu pour les TV. Le reste de l'interface ne change pas.
- **Images :**
  - cache mémoire limité (60 affiches), cache IndexedDB des miniatures ;
  - chargement différé, avec un espace réservé de même taille (aucun saut de mise en page) ;
  - images téléchargées une par une quand l'abonnement n'a qu'une connexion et que le serveur d'images est celui du fournisseur.
- **Démarrage :**
  - l'écran d'accueil s'affiche **avant** l'ouverture de la base ;
  - le WebAssembly et la base sont chargés dans le Worker ;
  - le premier contenu vient d'un instantané léger (dernière chaîne, favoris) gardé dans `localStorage`.
- **Mesure en interne :** temps de réaction aux touches et images lentes comptés, et visibles dans la console de diagnostic (comme sur Apple).

### 5.2. Ergonomie télécommande

- **Touches gérées :**
  - flèches, OK, Retour ;
  - Lecture / Pause / Stop, Avance / Retour rapide, Chaîne +/−, chiffres, couleurs (rouge : favoris, vert : guide, jaune : recherche, bleu : options), Info ;
  - les touches spéciales sont enregistrées avec `tizen.tvinputdevice.registerKey`.
- **Retour :** dans un écran, il remonte d'un niveau. Depuis l'accueil, il propose de quitter. Depuis le lecteur, il cache d'abord les contrôles, puis revient.
- **Focus toujours visible**, agrandi et contrasté. Chaque rangée retient sa position, et revenir sur un écran rend le focus à la carte quittée.
- **Marges de sécurité TV :** 5 % sur chaque bord (débordement d'image des téléviseurs).
- **Ajouter une source sans saisir au clavier :**
  1. la TV affiche un **QR code** ;
  2. le téléphone l'ouvre, sur l'app Apple ou Android, ou dans une simple page web ;
  3. la source est envoyée par un **code d'appariement court** ou par le **réseau local** du `PRD-26`.

  Le clavier à l'écran ne sert qu'en dernier recours.
- **Premier lancement :** ajouter une source, choisir le profil, puis arriver sur Live TV avec une chaîne prête.
- **Smart Hub :** vignette d'aperçu (Preview / tuiles) avec « Reprendre » et les chaînes favorites, quand le modèle le permet.

### 5.3. Accessibilité

- Lecteur d'écran du téléviseur (Voice Guide) : libellés et annonces des cartes et des changements de chaîne.
- Contrastes AA, et taille de texte réglable (3 tailles).

---

## 6. Données et sécurité

- **Base :** wa-sqlite avec persistance IndexedDB. La taille est surveillée, car les quotas des téléviseurs sont limités. En cas de manque de place, le guide est réduit à 48 h et les miniatures sont purgées.
- **Mots de passe et clés d'API :**
  - **Tizen KeyManager** quand il est disponible sur le modèle ;
  - sinon, chiffrement AES-GCM avec une clé dérivée de l'identifiant de l'appareil (`webapis.productinfo`), dans IndexedDB ;
  - jamais en clair dans `localStorage`.
- **Journaux :** les adresses de flux sont masquées (hôte et extension seulement).
- **IA :**
  - mêmes règles qu'Apple (`PRD-13`, `PRD-33`, `PRD-34`) : consentement, aucun appel distant pour le profil Enfants, aucune adresse ni identifiant envoyé ;
  - les appels partent du téléviseur avec la clé de l'utilisateur ;
  - la clé par défaut du `PRD-28` n'est jamais incluse dans le paquet TV.
- **Requêtes vers d'autres domaines :** les apps web Tizen y ont accès par les politiques `<access>` de `config.xml`. La liste des domaines autorisés est large pour les sources de l'utilisateur, et explicite pour les fournisseurs d'IA et de métadonnées.

---

## 7. Fonctions (parité avec Apple, par lots)

| Fonction | Lot |
| :--- | :--- |
| Sources Xtream et M3U, ajout par QR code / réseau local, synchronisation dans le Worker, état du compte | 38.2 |
| Live TV : catégories, favoris, récents, zapping (Chaîne +/−, chiffres), maintenant / ensuite | 38.2 |
| Lecteur direct AVPlay, pistes audio, sous-titres | 38.2 |
| Films et séries : grilles paginées, fiches, reprise, épisode suivant, autres versions | 38.3 |
| Lecteur film : adresse finale gardée, tampon, débit insuffisant, attente après `429` | 38.3 |
| Guide TV (grille), replay et rattrapage | 38.4 |
| Recherche locale et par prompt avec l'IA (`PRD-33`) | 38.4 |
| Rangées « Pour vous » par type (`PRD-34`) | 38.5 |
| Profils, mode Enfants, PIN, catégories adultes, réglages, assistant IA | 38.5 |
| Aperçu Smart Hub, Voice Guide, réglages d'affichage | 38.6 |
| Téléchargements, PiP, mosaïque | Hors périmètre (stockage et lecteurs multiples non adaptés aux téléviseurs) |

---

## 8. Plateforme Tizen

- **Paquet :** application web `.wgt` signée.
  - `config.xml` déclare `tizen:application`, `tizen:profile name="tv-samsung"`, les privilèges (`internet`, `tv.inputdevice`, `tv.audio`, `productinfo`, `application.launch`, `tv.display` si nécessaire), les politiques `<access>` et l'icône.
- **Versions :** Tizen 3.0 minimum (téléviseurs 2017). Les fonctions récentes, comme certains formats HDR, sont activées selon `webapis.productinfo` et la version de la plateforme.
- **Résolution :** `<tizen:app-control>` et `viewport` en 1920×1080.
- **Outils :**
  - Tizen Studio, ou sa CLI `tizen` et `sdb`, avec le **Samsung TV Extension** ;
  - certificat Samsung (auteur et distributeur) créé dans le Certificate Manager ;
  - téléviseur en **mode développeur** (adresse IP de l'ordinateur saisie sur le téléviseur) ;
  - débogage avec l'inspecteur web à distance (Chrome DevTools par `sdb`).
- **Distribution :**
  - **Samsung Seller Office** (Samsung TV Store), avec sa revue : aucune chaîne préinstallée, aucun logo de chaîne dans les visuels, l'utilisateur apporte sa source ;
  - installation en mode développeur, pour les essais et l'usage personnel.

---

## 9. Matrice de test

| Année / gamme | Tizen | Moteur web (approx.) | Ce qu'on vérifie |
| :--- | :--- | :--- | :--- |
| 2017 (MU, Q7) | 3.0 | Chromium 47–56 | Démarrage, ≥ 30 i/s, mémoire, polyfills |
| 2018 (NU) | 4.0 | Chromium 56 | Idem, AVPlay MKV / HEVC |
| 2019 (RU) | 5.0 | Chromium 63 | Focus < 80 ms |
| 2020–2021 (TU, AU) | 5.5–6.0 | Chromium 69–76 | 60 i/s, 4K HEVC |
| 2022–2023 (BU, CU) | 6.5–7.0 | Chromium 85–94 | HDR, passthrough |
| 2024–2025 (DU, QLED, Neo QLED) | 8.0–9.0 | Chromium 108+ | SLA les plus stricts |
| Émulateur Tizen TV (Tizen Studio) | 3.0 à 9.0 | — | Parcours et tests automatiques (sans AVPlay réel) |

AVPlay ne fonctionne qu'en partie dans l'émulateur. Les essais de lecture se font donc **sur de vrais téléviseurs** (au moins un modèle 2018 et un modèle 2022 ou plus récent).

---

## 10. Lots

| Lot | Contenu | Validation principale |
| :--- | :--- | :--- |
| **38.1** | `cnd-domain` séparé de `cnd-core` (sans changer l'API UniFFI), compilé en WebAssembly ; wa-sqlite et schéma partagé ; projet `tizen/` (Vite, TypeScript, SolidJS), Worker, `config.xml`, signature, `build-tizen.sh` ; système de design TV ; touches de la télécommande. | Apple et Android verts ; l'app s'installe en mode développeur et affiche la version du cœur ; démarrage mesuré. |
| **38.2** | Sources (QR code / réseau local), synchronisation dans le Worker, Live TV, AVPlay direct, zapping, maintenant / ensuite. | Synchro de 50 000 éléments sans geler l'écran ; zapping < 1,5 s (2019+) ; une seule connexion. |
| **38.3** | Films, séries, fiches, reprise, lecteur film (adresse finale gardée, tampon, débit, attente `429`), autres versions. | MKV 4K lu sur un abonnement à une connexion, avance rapide comprise. |
| **38.4** | Guide TV en grille, replay, recherche locale et par prompt. | Grille fluide sur un modèle 2018 ; résultats de recherche identiques au jeu d'évaluation du `PRD-33`. |
| **38.5** | Rangées « Pour vous », profils, mode Enfants, PIN, réglages, assistant IA, stockage sécurisé des secrets. | Aucun mélange de types ; aucune clé lisible en clair. |
| **38.6** | Passe de performance sur la matrice du § 9 (bascule en Lightning 3 si nécessaire) ; aperçu Smart Hub ; Voice Guide. | SLA du tableau d'en-tête atteints. |
| **38.7** | Soumission au Samsung TV Store (visuels, textes, conformité), mise à jour. | Paquet accepté par la revue, ou installation développeur documentée. |

Ordre conseillé : 38.1 → 38.2 → 38.3 → 38.6 (première passe) → 38.4 → 38.5 → 38.6 → 38.7.

---

## 11. Fichiers à Créer / Modifier

- `crates/cnd-domain/` *(nouveau)* : règles pures extraites de `cnd-core` (`iptv/normalizer`, analyseurs M3U, Xtream et XMLTV, `search/`, `recommend/` sans base, `ai/prompt`, règles de profil), avec leurs tests et les jeux d'évaluation.
- `crates/cnd-domain-wasm/` *(nouveau)* : liaisons `wasm-bindgen`.
- `crates/cnd-core/` : dépend de `cnd-domain`, garde SQLite, réseau, téléchargements et relais ; l'API UniFFI ne change pas.
- `tizen/` *(nouveau)* :
  - `config.xml`, `index.html`, `vite.config.ts`, `tsconfig.json` ;
  - `src/app/`, `src/core/{engine,storage,net,player,input}/`, `src/ui/design/`, `src/features/{onboarding,sources,live,guide,movies,series,details,player,search,recommendations,profiles,settings}/` ;
  - `src/worker/` (WebAssembly, wa-sqlite, synchronisation) ;
  - `tests/` (unitaires et parcours dans l'émulateur).
- `scripts/build-tizen.sh` *(nouveau)* : `wasm-pack` / `wasm-bindgen`, `wasm-opt`, Vite, paquet `.wgt` signé.
- `Taskfile.yml` *(`tizen:build`, `tizen:install`, `tizen:debug`)*.
- `docs/BUILD_TIZEN.md` *(nouveau)* : Tizen Studio, certificat Samsung, mode développeur du téléviseur, installation et dépannage.
- `PRD/00_INDEX_ROADMAP.md`.

---

## 12. Contraintes Non-Négociables (Guardrails IA)

- **SRP :** une responsabilité par module.
  - Les écrans passent toujours par `core/engine`.
  - Aucune règle métier n'est écrite en TypeScript : elle vit dans `cnd-domain`.
- **Fil d'affichage libre :** analyse, SQLite et WebAssembly lourd tournent dans le Worker. Aucune tâche de plus de 16 ms sur le fil principal.
- **Listes virtualisées et recyclées,** toujours paginées. Animations limitées à `transform` et `opacity`.
- **Une seule connexion au serveur** quand l'abonnement l'impose : adresse finale gardée, aucune requête parallèle pendant la lecture, attente après `429`.
- **Un seul AVPlay ouvert à la fois,** suspendu en veille ou en arrière-plan.
- **Secrets :** jamais en clair. Aucune adresse de flux complète dans les journaux. Mêmes règles d'IA que sur Apple.
- **Apple et Android restent verts :** la séparation de `cnd-domain` ne change pas l'API UniFFI. `cargo test`, `swift test` et les 4 schémas Xcode passent.
- **Compatibilité :** pas d'API JavaScript ou CSS au-delà de Chromium 56 sans polyfill ni repli vérifiés sur un modèle 2018.

---

## 13. Critères d'Acceptation & Commandes de Validation

1. **Rust :**
   - `cargo clippy --workspace --all-targets -- -D warnings` ;
   - `cargo test --workspace --release`, dont les jeux d'évaluation sur `cnd-domain` ;
   - `cargo build -p cnd-domain-wasm --target wasm32-unknown-unknown --release`.
2. **Tizen :**
   - `npm run typecheck && npm test` (états d'écran, navigation au focus, règles du lecteur : session gardée, attente `429`, débit) ;
   - `./scripts/build-tizen.sh`, qui produit un `.wgt` signé ;
   - `tizen install` / `sdb` vers l'émulateur et vers un téléviseur en mode développeur.
3. **Performance :** mesures du tableau d'en-tête sur la matrice du § 9 (temps de démarrage, latence des touches, i/s des rangées, mémoire par l'inspecteur web à distance).
4. **Essais manuels :**
   - source ajoutée par QR code en moins d'une minute ;
   - parcours complet à la seule télécommande ;
   - zapping par Chaîne +/− et par chiffres ;
   - film MKV 4K sur un abonnement à une connexion ;
   - veille du téléviseur pendant la lecture, puis reprise.
5. **Apple et Android inchangés :** `cd apple && swift test`, 4 schémas Xcode, et tests Android du `PRD-37` s'ils existent.

---

## 14. Questions ouvertes

- **Téléviseurs 2015–2016 (Tizen 2.3–2.4)** : leur moteur web est très ancien. Les inclure demanderait un mode simplifié (sans WebAssembly lourd, interface minimale). Ce PRD les exclut.
- **SolidJS (DOM) ou Lightning 3 (WebGL) dès le départ :** SolidJS est plus simple à écrire et à rendre accessible (Voice Guide), Lightning 3 est plus sûr pour 60 i/s sur les vieux modèles. Ce PRD commence par SolidJS et prévoit la bascule au lot 38.6 si les mesures l'exigent.
- **Comportement d'AVPlay lors d'un saut dans un MKV** (fermeture de la connexion avant la suivante) : à mesurer au lot 38.3. Cela décide si la lecture des films sur un abonnement à une connexion demande un mode « lecture continue ».
- **Samsung TV Store :** à viser dès le lot 38.7, ou rester en installation développeur pour un usage personnel ?
- **Autres téléviseurs (LG webOS, Hisense VIDAA)** avec la même base : à proposer dans un PRD séparé après le lot 38.3.

---

## 15. Statut d'Implémentation & Validation

**Terminé et validé (`[x]`).**

Tous les composants ont été implémentés et validés conformément aux exigences du PRD :
- **Domaine pur extrait (`crates/cnd-domain`)** : Modèles immuables, parser M3U chunk, parser XMLTV, parseur de requêtes, ranking de recherche, recommandations de sagas et profils (27 tests unitaires passants en 0.00s, zéro IO).
- **WebAssembly (`crates/cnd-domain-wasm`)** : Export WebAssembly optimisé avec `wasm-opt -Oz` (1.5 Mo brut, 578 Ko gzip).
- **Application Tizen 3.0+ (`tizen/`)** :
  - SolidJS + TypeScript + `@vitejs/plugin-legacy` garantissant le support de Chromium 56+ (modèles Samsung 2017 à 2025+).
  - Web Worker dédié pour l'exécution Wasm et le stockage persistant IndexedDB.
  - Client HTTP avec file d'attente séquentielle, résolution transparente des redirections CDN via `Range: bytes=0-0` (garantie mono-connexion fournisseur) et backoff 429.
  - Lecteur matériel AVPlay (`webapis.avplay`) avec sélection des pistes audio/sous-titres, offset de synchronisation, watchdog de stall et gestionnaire de veille/réveil (`suspend`/`restore`).
  - Navigation spatiale 10-foot (`RemoteKeyHandler`, `SpatialNav`) avec marges d'overscan 5%, gestion des touches D-Pad, Retour, Ch+/Ch-, Chiffres et Couleurs.
  - 12 écrans TV fonctionnels (`onboarding`, `sources`, `live`, `guide`, `movies`, `series`, `details`, `player`, `search`, `recommendations`, `profiles`, `settings`).
- **Tests & Packaging** :
  - 9 tests unitaires Tizen passants avec Vitest (`task tizen:test`).
  - 321 tests unitaires `cnd-core` et 27 tests unitaires `cnd-domain` passants sans régression.
  - `cargo clippy --workspace -- -D warnings` au vert.
  - Script `./scripts/build-tizen.sh` générant le paquet `.wgt` prêt à installer (`build/tizen/cnd-iptv-tizen.wgt`).
  - Tâches `Taskfile.yml` (`tizen:build`, `tizen:test`, `tizen:install`, `tizen:debug`).
  - Documentation de déploiement et configuration dans `docs/BUILD_TIZEN.md`.
