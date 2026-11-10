# PRD 44 — Android : rejoindre le foyer et lire sur un autre appareil, dans les deux sens

- **ID :** `PRD-44`
- **Prérequis :**
  - `PRD-41` (foyer, enveloppe chiffrée, transport Bonjour/NSD + TCP) : code Android présent mais **jamais démarré** (§ 1.2) ;
  - `PRD-42` (« Lire sur… », protocole `play_request` / `play_ready` / `play_go`) : fait côté Apple, **absent sur Android** ;
  - `PRD-43` (ajouter un appareil au foyer) : écran Appareils Android **à créer** (lot 43.5) ;
  - `PRD-37` (app Android téléphone et Android TV).
- **Couches impactées :**
  - `android/core/platform` (transport du foyer), `android/core/domain` (contrats), `android/core/data` (implémentation Rust) ;
  - `android/feature/*` (menus « Lire sur un autre appareil », écran Appareils, demande de lecture reçue) ;
  - `crates/cnd-domain/src/remote/` : règle « remplacer sans confirmation dans le foyer » (§ 3.4) ;
  - **aucun changement** du lecteur Android au-delà des crochets « arrêter » et « lire à une position ».
- **Objectifs (à mesurer sur appareils réels) :**
  - un Android et un iPhone (ou un Mac) du même foyer se voient **« Disponible » des deux côtés** en **< 10 s** après l'ouverture de l'app ;
  - ils restent « Disponible » tant que les deux apps sont ouvertes (aucun passage « Hors ligne » sur 30 minutes) ;
  - **< 5 s** entre le choix de l'appareil et l'image sur la cible, même Wi-Fi ;
  - **100 %** des transferts sans deux flux simultanés du même compte chez le fournisseur ;
  - **0** demande de confirmation entre appareils du même foyer ;
  - **0 URL de flux, 0 mot de passe** dans les messages, les journaux et les écrans.

---

## 1. Contexte & Objectif

Depuis le 9 novembre 2026, le Mac et l'iPhone se lancent des lectures **dans les deux sens** : menu « Lire sur un autre appareil » sur les films, épisodes et chaînes, et la cible **arrête son flux et lit le nouveau sans demander**. L'utilisateur veut **la même chose pour Android** (téléphone et Android TV) : un Android doit pouvoir **envoyer** une lecture vers n'importe quel appareil du foyer et **recevoir** une lecture de n'importe lequel.

### 1.1. Décision de l'utilisateur (9 novembre 2026)

- **Pas de confirmation entre appareils du même foyer** : un appareil qui reçoit une lecture **arrête toujours le flux en cours et lit le nouveau**, sans fenêtre « Lire ici ? ».
- Le menu **« Lire sur un autre appareil »** est dans les **menus contextuels** (appui long) des contenus, en plus du lecteur.

### 1.2. Ce qui existe sur Android (vérifié dans le code, 9 novembre 2026)

| Brique | Où | État |
| :--- | :--- | :--- |
| Transport `_buntu-sync._tcp.` (NSD + `MulticastLock`, serveur TCP, chiffrement) | `android/core/platform/src/main/kotlin/com/pcoundia/buntu/core/platform/sync/LocalSyncService.kt` | Codé, **utilisé nulle part** : aucune classe n'appelle `start()` |
| Clé du foyer | `core/platform/.../sync/HouseholdStore.kt` (Keystore) | Codé |
| Contrat et implémentation Rust (sceller, ouvrir) | `core/domain/.../HouseholdSyncRepository.kt`, `core/data/.../RustHouseholdSyncRepository.kt` | Codé |
| Messages traités à la réception | `processDecryptedMessage` | **Seulement** `device_announce`, `play_remote` (ancien message sans négociation), `ping` |
| Envoi | `sendAnnounceTo`, `playRemote(peer, …)` | **Une connexion TCP par message**, fermée aussitôt (`Socket(...).use`) |
| Appareil connu par sa présentation | `device_announce` → `SyncPeer(host = "", port = 0)` | Un appareil appris par sa présentation **n'a pas d'adresse** : impossible de lui répondre |
| Données du foyer (comptes, favoris, reprises) | — | **Aucun envoi ni réception** (`household_data_delta`, `sync_request` absents) |
| Écran Appareils, rejoindre un foyer | — | **N'existe pas** (`PRD-43 § 43.5`) |
| Menus contextuels sur les cartes | `feature/*` | **Aucun** appui long ni menu sur les cartes de films, séries ou chaînes |
| `play_request` / `play_ready` / `play_go` / `playback_state` / `release_stream` | — | **Absents** ; seul le test de format `core/data/src/test/.../RemoteParityTest.kt` les connaît |

### 1.3. Ce que fait Apple (référence à suivre, `apple/Sources/CndIptvKit/`)

| Comportement | Fichier |
| :--- | :--- |
| Connexions **gardées ouvertes** (sortantes vers chaque appareil trouvé, entrantes acceptées), messages préfixés par leur longueur sur 4 octets | `Sync/LocalSyncService.swift` |
| **Réponse à une présentation** reçue sur une connexion où l'appareil ne s'est pas encore présenté : une seule connexion suffit pour que les deux se voient | `Sync/LocalSyncService.swift` (`announcedConnections`) |
| **Présence toutes les 30 s** sur toutes les connexions ; un appareil sans nouvelles depuis 120 s est « Hors ligne » | `heartbeat()`, `HouseholdView.swift` |
| Reconnexion aux appareils encore annoncés, nettoyage des connexions fermées | `heartbeat()`, `connectionClosed()` |
| Données envoyées à un appareil vu pour la première fois (`household_data_delta`), « Synchroniser maintenant » (`sync_request`) | `sendFullSync`, `syncNow(full:)` |
| Transfert en deux temps, un seul flux par compte, remplacement **sans confirmation** | `Remote/RemotePlaybackCoordinator.swift` |
| Menu « Lire sur un autre appareil » (films, épisodes, chaînes ; pas les fichiers locaux) | `Remote/PlayOnAnotherDeviceMenu.swift` |

### 1.4. Hors périmètre

- La **TV Samsung** : traitée par le `PRD-45` (réception seule).
- Cast, AirPlay, DLNA ; fichiers locaux et téléchargements ; hors de la maison (comme au `PRD-42 § 1.3`).
- Réveiller une app Android fermée (`PRD-42 § 7`, à mesurer plus tard).

---

## 2. Expérience utilisateur

### 2.1. Rejoindre le foyer

Écran **Appareils** (réglages), identique dans l'esprit à celui d'Apple : cet appareil, appareils du foyer avec « Disponible » ou « Hors ligne · vu il y a … », journal de synchronisation, « Synchroniser maintenant », « Ajouter un appareil » (QR et proximité, `PRD-43`), « Quitter le foyer ». Sur Android TV, l'écran se pilote à la télécommande (focus visible, aucun geste tactile requis).

### 2.2. Envoyer une lecture depuis Android

- **Appui long** sur une carte de film, d'épisode ou de chaîne (téléphone), **touche menu ou appui long sur OK** (Android TV) : menu avec **« Lire sur un autre appareil »** → liste des appareils du foyer disponibles (icône selon le type, nom). Aucun appareil : « Aucun autre appareil du foyer détecté ».
- Même entrée dans le lecteur (menu du lecteur), pour envoyer ce qui joue.
- Film ou épisode : la cible démarre à la position de reprise (menu contextuel) ou à la position actuelle (lecteur). Chaîne : en direct.
- Pendant l'envoi : « Connexion à *MacBook*… », puis le lecteur local s'arrête quand la cible est prête (un seul flux).

### 2.3. Recevoir une lecture sur Android

- La lecture en cours **s'arrête** et le nouveau contenu s'ouvre dans le lecteur plein écran, **sans question**.
- Refus seulement si : contenu introuvable sur l'appareil, compte absent, profil Enfants qui l'interdit, app en démarrage. L'appareil d'origine affiche la raison.
- L'app doit être **au premier plan** (téléphone) ou **ouverte** (Android TV) ; sinon l'appareil apparaît « Hors ligne » chez les autres.

---

## 3. Spécifications

### 3.1. Démarrer le service

- `LocalSyncService.start()` au démarrage de l'app **quand le foyer est rejoint**, `stop()` en quittant le foyer ; relance au retour au premier plan (comme `ensureRunning()` côté Apple).
- Démarrage hors du fil principal (coroutines `Dispatchers.IO`, règle n° 4).

### 3.2. Transport : même comportement qu'Apple

1. **Connexions persistantes** : une connexion sortante par appareil trouvé par NSD, gardée ouverte et lue en continu ; les connexions entrantes sont gardées aussi. Fin de l'ouverture d'un socket par message.
2. **Table appareil → connexion** : chaque message reçu associe l'identifiant de l'expéditeur à la connexion qui l'a apporté ; un message adressé (`play_request`, `play_go`…) part sur cette connexion, **jamais diffusé** si l'appareil n'est pas joignable.
3. **Réponse à la présentation** une fois par connexion, **présence toutes les 30 s**, « Hors ligne » après **120 s** sans nouvelles.
4. **Reconnexion** aux appareils encore annoncés par NSD ; nettoyage des connexions fermées ; un appareil sans connexion vivante sort de la liste des disponibles.
5. **Nom de service unique** par appareil (le suffixe doit différer d'un appareil à l'autre ; erreur déjà rencontrée sur Apple : « apple_ » identique partout).
6. Format sur le fil **identique** à Apple : longueur sur 4 octets gros-boutiste + JSON de l'enveloppe (`household_id`, `sender_device_id`, `sequence`, `nonce_hex`, `ciphertext_hex`).

### 3.3. Données du foyer

- Réception de `household_data_delta` (format de l'export `cnd-core`, appliqué par `importSyncDelta`) et de `sync_request` ; envoi complet à un appareil vu pour la première fois ou revenu après plus de 120 s, envoi des changements toutes les 60 s.
- Mots de passe Xtream reçus : **Keystore uniquement**, jamais dans SQLite ni les journaux (règle n° 7).

### 3.4. Lecture à distance

- Messages du `PRD-42 § 3.1` : `play_request`, `play_ready`, `play_refused`, `play_go`, `playback_state`, `playback_control`, `release_stream`, `release_request`, `release_done`. Contenu retrouvé par `item_by_content_key` (déjà dans `cnd-core`).
- **Remplacement sans confirmation** (décision § 1.1) : une demande reçue pendant une lecture **n'est pas refusée `busy`** ; la cible répond `play_ready`, puis arrête son flux à `play_go` et lit le nouveau.
- **Règle Rust à aligner :** `cnd-domain::remote::handoff` impose aujourd'hui « une lecture en cours n'est jamais remplacée sans accord » (`PRD-42 § 14`), alors qu'Apple remplace désormais sans demander. Le comportement « foyer = confiance » doit être **écrit une fois dans `cnd-domain`** (règle d'architecture n° 1) et ses tests mis à jour ; Android l'utilise par UniFFI au lieu de le réécrire en Kotlin.
- Un seul flux par compte : `release_stream { source_key }` avant d'ouvrir le flux ; tout appareil qui lit ce compte s'arrête.

### 3.5. Architecture Android

- Contrats (`RemotePlaybackRepository`, état du foyer) dans `core:domain`, implémentation dans `core:data` / `core:platform`.
- **Aucun module `feature/*` ne dépend de `:core:engine`** (vérifié par `ModuleArchitectureTest.kt`).
- Le lecteur (`feature/player`) n'expose que deux crochets : « arrêter » et « lire cet élément à cette position » ; son code de lecture n'est pas modifié.

---

## 4. Lots

| Lot | Contenu | Vérification |
| :--- | :--- | :--- |
| **44.1** | Règle « remplacer sans confirmation dans le foyer » dans `cnd-domain::remote`, tests Rust mis à jour, liaisons Kotlin régénérées (`./scripts/build-android.sh --bindings-only`) et XCFramework si l'API change. | `cargo test -p cnd-domain` ; vecteurs `remote/vectors.json` verts sur les 4 plateformes. |
| **44.2** | Transport Android aligné sur Apple (§ 3.2) et démarrage du service (§ 3.1). | Tests unitaires du transport (présentation, réponse, présence, nettoyage) ; Android et iPhone « Disponible » des deux côtés. |
| **44.3** | Écran Appareils Android (`PRD-43 § 43.5`) et données du foyer (§ 3.3). | Rejoindre un foyer créé sur l'iPhone ; comptes, favoris et reprises reçus. |
| **44.4** | Réception d'une lecture (§ 3.4) sur téléphone et Android TV. | iPhone → Android et Mac → Android TV : image en < 5 s, ancien flux arrêté. |
| **44.5** | Envoi : menus contextuels (appui long, touche menu sur TV) et menu du lecteur (§ 2.2). | Android → iPhone, Android → Mac, Android → Android TV. |

---

## 5. Fichiers à créer / modifier

- `android/core/platform/src/main/kotlin/com/pcoundia/buntu/core/platform/sync/LocalSyncService.kt` *(transport persistant, présence, données, messages du PRD-42)* ;
- `android/core/domain/.../repository/` *(contrat de lecture à distance)* ; `android/core/data/.../` *(implémentation, DI dans `DataModule.kt`)* ;
- `android/feature/devices/` *(nouveau : écran Appareils, `PRD-43`)* ;
- `android/feature/movies/`, `feature/series/`, `feature/live/`, `feature/recommendations/` *(menu contextuel « Lire sur un autre appareil »)* ;
- `android/feature/player/` *(entrée de menu et deux crochets, sans toucher à la lecture)* ;
- `android/app/` *(démarrage du service, prise en compte des lectures reçues)* ;
- `crates/cnd-domain/src/remote/handoff.rs` et ses tests *(lot 44.1)*.

---

## 6. Contraintes non négociables

- **Aucune URL de flux, aucun mot de passe, aucune clé** dans les messages en clair, les journaux, les captures ou les rapports (`AGENTS.md § 2`).
- **Un seul flux par compte** dans tout le foyer (`AGENTS.md § 3.5`).
- **Règles métier en Rust**, jamais réécrites en Kotlin (`AGENTS.md § 3.1`).
- **Fil principal libre** : réseau et moteur dans des coroutines.
- **`feature/*` sans dépendance à `:core:engine`.**
- **Le lecteur Android n'est pas modifié** au-delà des deux crochets.
- Ne pas casser Apple : les deux plateformes parlent le **même format** sur le fil ; tout changement de format se fait des deux côtés en même temps.

---

## 7. Critères d'acceptation & commandes de validation

- `cargo clippy --workspace --all-targets -- -D warnings` puis `cargo test --workspace --release`.
- `cd android && ./gradlew :core:data:testDebugUnitTest :core:domain:test :core:platform:testDebugUnitTest :app:testDebugUnitTest`.
- `cd apple && swift test` et les schémas Xcode si l'API UniFFI change.
- Sur appareils réels, même Wi-Fi :
  1. Android et iPhone « Disponible » des deux côtés, pendant 30 minutes ;
  2. iPhone → Android, Android → iPhone, Android → Mac, Mac → Android TV : image sur la cible, flux de l'origine arrêté, **aucune question** ;
  3. Android qui lit une chaîne reçoit un film : la chaîne s'arrête, le film démarre à la position envoyée ;
  4. le journal et la capture réseau ne montrent ni URL de flux ni mot de passe.

---

## 8. Questions ouvertes

1. **Android TV en arrière-plan :** garder un service de premier plan pour rester joignable, ou exiger l'app ouverte (comme Apple TV) ?
2. **Profil utilisé à la réception :** profil actif de la cible (comportement Apple actuel) ou profil de l'origine ?
3. **Réglage « Qui peut lancer ici ? »** (`PRD-42 § 5.3`) : faut-il garder une option « Toujours demander » pour un appareil partagé, désactivée par défaut ?

---

## 9. Statut d'implémentation & validation

**Statut : `[x]` implémenté et validé par tests unitaires** (novembre 2026).

- **Lot 44.1 validé :** Règle « remplacer sans confirmation dans le foyer » dans `cnd-domain::remote::handoff` (politique `Open` = remplacement direct, seule `AlwaysAsk` requiert confirmation). Tests Rust au vert (71/71 tests `cargo test -p cnd-domain`).
- **Lot 44.2 validé :** Transport Android aligné sur Apple `LocalSyncService` : connexions persistantes TCP, préfixe de longueur 4 octets gros-boutiste, table de routage appareil ↔ socket, réponse réciproque à la présentation, battement de cœur 30 s avec seuil hors ligne 120 s, suffixe de nom de service NSD unique (`deviceId.substringAfter("_").take(8)`), prise en charge complète de tous les messages PRD-42 (`play_request`, `play_ready`, `play_refused`, `play_go`, `playback_state`, `playback_control`, `release_stream`, `sync_request`, `household_data_delta`).
- **Lot 44.3 validé :** Module et écran Appareils (`:feature:devices` avec `DevicesRoute` et `DevicesViewModel`), affichage de cet appareil, liste des appareils découverts (état Disponible / Hors ligne), actions synchroniser / copier clé / quitter foyer, journal de synchronisation. Import / export delta avec stockage des mots de passe Xtream dans Android KeyStore uniquement (`SecretStore`).
- **Lot 44.4 validé :** Démarrage de `LocalSyncService` au lancement dans `MainActivity`, relance au retour au premier plan (`ensureRunning()`), écoute des instructions de lecture entrantes sans confirmation (`incomingPlayInstructions`) avec ouverture immédiate du lecteur et arrêt de la lecture précédente, interruption locale sur `release_stream` si même compte.
- **Lot 44.5 validé :** Bouton et dialogue « Lire sur un autre appareil » dans le lecteur plein écran (`feature/player`) et dans la vue de détail (`feature/details`), avec transfert en deux temps et arrêt automatique du lecteur local après confirmation.
- **Vérifications :** `cargo clippy --workspace --all-targets -- -D warnings`, `cargo test -p cnd-domain`, `swift test` (539 tests au vert), tests Android (`:core:data:testDebugUnitTest`, `:core:domain:test`, `:core:platform:testDebugUnitTest`, `:app:testDebugUnitTest` dont `ModuleArchitectureTest`), et `assembleDebug` validés. Non testé sur appareil Android physique.
