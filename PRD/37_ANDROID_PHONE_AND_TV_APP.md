# PRD 37 — Application Android (téléphones et Android TV) : rapide, responsive, modulaire

- **ID :** `PRD-37`
- **Prérequis :**
  - le cœur Rust `cnd-core` et son API UniFFI, réutilisés tels quels (`PRD-01` à `PRD-07`, `PRD-13`, `PRD-20`, `PRD-33`, `PRD-34`) ;
  - le relais à une seule connexion (`relay.rs`) et la détection de débit insuffisant, conçus pour les films lus sur iPhone ;
  - `PRD-26` (partage des sources par fichier chiffré et réseau local), pour ajouter une source sur la TV depuis le téléphone.
- **Couches impactées :**
  - `Rust (crates/cnd-core)` : compilation Android, chemins de fichiers fournis par l'app, aucune logique métier nouvelle ;
  - `UniFFI` : liaisons Kotlin générées depuis la même bibliothèque ;
  - `android/` *(nouveau)* : projet Gradle Kotlin, Jetpack Compose et Compose for TV, Media3 ExoPlayer ;
  - `scripts/` : construction Android (`build-android.sh`) ;
  - `Taskfile.yml` : tâches `android:*`.
- **Objectifs SLA** (mesurés par Macrobenchmark sur la matrice d'appareils du § 9) :

| Mesure | Téléphone milieu de gamme | Téléphone d'entrée de gamme (2 Go) | Boîtier Android TV d'entrée de gamme |
| :--- | :--- | :--- | :--- |
| Démarrage à froid jusqu'au premier écran utile | < 1,2 s | < 2,5 s | < 2,5 s |
| Défilement d'une grille de 5 000 affiches | 0 image > 32 ms, < 1 % d'images > 16 ms | < 3 % d'images > 16 ms | < 3 % d'images > 16 ms |
| Changement de chaîne (zapping) jusqu'à l'image | < 1 s | < 1,5 s | < 1,5 s |
| Première image d'un film (bon réseau) | < 3 s | < 4 s | < 4 s |
| Mémoire en lecture | < 250 Mo | < 180 Mo | < 180 Mo |
| Réponse à une touche de la télécommande | — | — | < 100 ms |

Le principe : **aucun appel au moteur, aucun décodage d'image ni accès disque sur le fil principal**. Une image produite en plus de 16 ms est un défaut.

---

## 1. Contexte & Objectif

L'app existe sur Apple (macOS, iPhone, iPad, Apple TV, Vision Pro). Son cœur métier est en Rust, déjà indépendant d'Apple :
- catalogue SQLite, synchronisation M3U et Xtream ;
- guide EPG, recherche par prompt ;
- recommandations par type, appels IA ;
- téléchargements, relais à une seule connexion.

L'interface (SwiftUI) et les services système (Trousseau, iCloud, AirPlay, Live Activities, PiP) ne sont pas réutilisables sur Android.

**Objectif :** une application Android **unique** (un seul APK ou AAB) qui fonctionne sur **tous les téléphones Android** depuis Android 7.0 et sur **Android TV / Google TV**. Elle doit être :
- **rapide**, sans saccade, y compris sur un téléphone à 2 Go de mémoire ou un boîtier TV à bas prix ;
- **responsive**, du petit téléphone à la tablette, aux pliables et à l'écran TV 4K ;
- **modulaire**, avec une seule responsabilité par module (SRP) et des écrans réutilisés entre téléphone et TV ;
- **simple**, pour qu'on ajoute sa source et qu'on regarde une chaîne en moins d'une minute, même avec une télécommande.

**Hors périmètre de ce PRD :**
- interface commune iPhone et Android (Kotlin Multiplatform, Flutter) : l'interface Apple existe déjà en SwiftUI ;
- iCloud ;
- montres et Android Auto ;
- publication sur le Play Store, traitée comme une question ouverte (§ 12).

---

## 2. Principes d'architecture

### 2.1. Répartition des responsabilités

| Couche | Responsabilité unique | Ne fait jamais |
| :--- | :--- | :--- |
| **Rust `cnd-core`** | Règles métier et données : catalogue, sync, EPG, recherche, recommandations, IA, téléchargements, relais | Rien d'affichage, aucune API Android |
| **`:core:engine`** | Charger la bibliothèque native, exposer les liaisons UniFFI, créer **un seul** moteur | Logique métier |
| **`:core:data`** | Dépôts : appels au moteur sur un fil d'arrière-plan, conversion en `Flow` / `PagingData`, cache mémoire court | Interface, règles déjà dans Rust |
| **`:core:domain`** | Cas d'usage purs en Kotlin (`ZapToChannel`, `ResumeMovie`, `LoadShelves`…), testables sans Android | Accès réseau ou disque direct |
| **`:core:player`** | Lecture : ExoPlayer, sources de données, relais, choix du moteur, surveillance des blocages, débit | Écrans |
| **`:core:designsystem`** | Jetons (espaces, tailles, couleurs, typo), composants (cartes, rangées, grilles, surfaces focusables) en variantes téléphone et TV | Données |
| **`:core:platform`** | Services Android : Keystore, WorkManager, MediaSession, PiP, notifications, réseau, Watch Next sur TV | Écrans |
| **`:feature:*`** | Un écran ou un parcours chacun : état (`ViewModel` + `UiState` immuable) et composables | Appeler le moteur directement (toujours par `:core:data` / `:core:domain`) |
| **`:app`** | Assemblage : navigation, injection de dépendances, choix de la coque téléphone ou TV | Logique d'écran |

### 2.2. Règles

- **Flux de données à sens unique** (UDF) : chaque écran expose un `StateFlow<UiState>` immuable et reçoit des intentions. Aucun état modifiable partagé entre écrans.
- **Un `ViewModel` par écran, partagé par le téléphone et la TV.** Seuls les composables diffèrent quand l'ergonomie l'exige (grille tactile ou grille au focus). Ainsi la logique n'est jamais écrite deux fois.
- **Aucune règle du cœur recopiée en Kotlin**, ni filtrage des catégories adultes, ni dédoublonnage, ni score. Kotlin affiche, Rust décide.
- **Injection de dépendances : Hilt.** Le moteur Rust est un singleton créé au démarrage, en arrière-plan.
- **Navigation :** Navigation Compose, avec des routes typées. Les deux coques (`MobileShell`, `TvShell`) partagent le même graphe d'écrans.
- **Modules Gradle séparés.** Ils accélèrent la compilation, rendent les dépendances explicites, et un module de fonctionnalité ne dépend jamais d'un autre (convention vérifiée par un test d'architecture).

### 2.3. Modules

```
android/
├── app/                          # assemblage, navigation, coques MobileShell / TvShell
├── core/engine/                  # .so Rust + liaisons Kotlin UniFFI (JNA)
├── core/data/                    # dépôts (sources, catalogue, EPG, recherche, recos, téléchargements)
├── core/domain/                  # cas d'usage
├── core/player/                  # ExoPlayer, relais, surveillance, débit
├── core/designsystem/            # jetons, composants téléphone et TV
├── core/platform/                # Keystore, WorkManager, MediaSession, PiP, Watch Next
├── feature/onboarding/  feature/sources/  feature/live/  feature/guide/
├── feature/movies/  feature/series/  feature/details/  feature/player/
├── feature/search/  feature/recommendations/  feature/downloads/
├── feature/profiles/  feature/settings/
├── benchmark/                    # Macrobenchmark + génération des Baseline Profiles
└── build-logic/                  # conventions Gradle (plugins communs, versions)
```

---

## 3. Cœur Rust sur Android

- **Cibles :**
  - `aarch64-linux-android` (presque tous les téléphones et TV récents) ;
  - `armv7-linux-androideabi` (beaucoup de boîtiers TV bon marché sont encore en 32 bits) ;
  - `x86_64-linux-android` (émulateur).
- **Construction :** `cargo-ndk`, puis `scripts/build-android.sh`, l'équivalent de `build-xcframework.sh`. Le script compile en `release`, copie les `.so` dans `core/engine/src/main/jniLibs/<abi>/` et génère les liaisons Kotlin avec `uniffi-bindgen` en mode bibliothèque. Une tâche Gradle l'appelle et le saute quand les sources Rust n'ont pas changé.
- **Taille :** `opt-level = "z"`, `lto = true`, `codegen-units = 1`, `strip = true` sur le profil Android. Objectif : moins de 8 Mo par ABI pour `libcnd_core.so`.
- **Liaisons :** UniFFI produit du Kotlin avec JNA. Le surcoût d'un appel JNA est d'environ quelques microsecondes, donc **pas d'appel par élément dans une liste**. Les dépôts n'utilisent que les fonctions par lot qui existent déjà (pages de catalogue, `get_epg_now_next` pour N chaînes, rangées entières de recommandations).
- **Chemins :** la base SQLite, le cache et le dossier de téléchargements sont passés par l'app (`context.filesDir`, `cacheDir`, stockage choisi). Rien n'est codé en dur dans Rust.
- **Réseau :** `reqwest` avec rustls et ses certificats intégrés fonctionne tel quel. Le relais local écoute sur `127.0.0.1`, ce qui demande de garder le HTTP non chiffré autorisé (§ 8).
- **Adaptations Rust attendues** (petites, sans logique métier) :
  - vérifier que `libc::statvfs` (espace libre) compile sous Android ;
  - initialiser les journaux vers `logcat` (`tracing` avec la sortie Android) ;
  - n'utiliser aucun chemin propre à Apple dans les tests communs.

---

## 4. Lecteur vidéo (`:core:player`)

### 4.1. Moteur principal : Media3 ExoPlayer

- **Formats :** lit nativement le **MKV**, le MP4, le TS, le HLS et le DASH, sans libmpv.
- **Décodage :** matériel (`MediaCodec`) pour H.264, HEVC, VP9 et AV1 selon l'appareil. 4K HEVC 10 bits et HDR10 sur les téléphones et TV qui le décodent.
- **Son :**
  - décodeurs du système, plus l'**extension FFmpeg de Media3** pour AC3, E-AC3, DTS et TrueHD quand l'appareil n'en a pas ;
  - sur TV, **passthrough** vers l'ampli quand il est présent (AC3, E-AC3, DTS) ;
  - cette extension FFmpeg ne contient que les décodeurs audio, pour rester légère.
- **Sous-titres :** SRT, SSA et ASS (rendu de base), PGS, et sous-titres intégrés au MKV. Le décalage et le choix de piste reprennent les réglages Apple.

### 4.2. Une seule connexion au serveur (comportement repris d'iPhone)

- **Films et épisodes :** lus par le **relais Rust** (`singleConnectionUrl`). Il ferme la connexion précédente avant d'en ouvrir une nouvelle, garde l'adresse finale des redirections, et réutilise la même session du fournisseur pour les sauts et les relances.
- **Chaînes en direct :** une seule connexion continue, par `DefaultHttpDataSource` avec l'User-Agent, le Referer et les en-têtes de la source.
- **Interdiction :** aucun préchargement parallèle (pas de deuxième flux ouvert pour préparer la chaîne suivante) quand `max_connections = 1`.

### 4.3. Fluidité

- **Tampon :**
  - **direct :** démarrage rapide (`bufferForPlaybackMs` court) ;
  - **films :** tampon large (jusqu'à 120 s ou 200 Mo selon la mémoire de l'appareil) et reprise après quelques secondes d'avance, comme sur iPhone.
- **Zapping :**
  - le lecteur reste unique et la surface vidéo est réutilisée ;
  - en changeant de chaîne, on remplace la `MediaItem` sans recréer ExoPlayer ;
  - les touches haut et bas de la télécommande, et le pavé numérique, changent de chaîne.
- **Surveillance des blocages :** reprise de la logique iPhone.
  - Un film dont les données arrivent encore n'est jamais relancé.
  - Les relances réutilisent la même session.
  - Après un `429`, le lecteur attend que le fournisseur libère la connexion.
- **Débit insuffisant :** le même calcul que sur iPhone (taille du fichier et durée, comparées à la vitesse reçue). Le même bandeau propose : « Autre version », « Télécharger puis regarder » ou « Continuer ».
- **Fréquence d'image :** sur TV, `VIDEO_CHANGE_FRAME_RATE_STRATEGY` et `Surface.setFrameRate` (Android 11+) font passer l'écran en 23,976 / 24 / 25 / 50 Hz selon le film, sans saccade.
- **Lecture tunnelée** (`tunneling`) sur les TV compatibles, pour la 4K sans perte d'images.

### 4.4. Moteur de secours : libmpv (lot 37.9, facultatif)

À n'ajouter que si l'on mesure des fichiers qu'ExoPlayer ne lit pas, comme certains AVI anciens ou des sous-titres ASS complexes. Le choix du moteur reste dans `:core:player`, derrière la même interface `VideoEngine`.

---

## 5. Interface : rapide et responsive

### 5.1. Règles de performance Compose (vérifiées en revue et par benchmark)

- **Modèles d'interface immuables :** `@Immutable` ou `@Stable`, `ImmutableList` de `kotlinx.collections.immutable`. Jamais d'objet UniFFI modifiable passé directement à un composable : il est d'abord converti en modèle d'affichage dans `:core:data`.
- **Listes et grilles paresseuses :** `LazyColumn`, `LazyRow` et `LazyVerticalGrid`, toujours avec `key` et `contentType`.
  - Le catalogue est paginé par **Paging 3**, sur les requêtes `limit` / `offset` du moteur.
  - Le préchargement se fait à 2 pages.
- **Rien de lourd pendant la composition :** pas de formatage de date, de tri ni d'appel au moteur. On utilise `derivedStateOf` pour les états calculés, des lambdas stables, et `remember` des formats.
- **Images (Coil 3) :**
  - décodage **à la taille de la carte**, jamais l'affiche entière ;
  - cache mémoire limité à 15 % de la mémoire de l'app (8 % sur un appareil « low RAM ») ;
  - cache disque de 250 Mo ;
  - espace réservé pendant le chargement, sans saut de mise en page.
- **Baseline Profiles et Startup Profile** générés par `:benchmark` et livrés dans l'app : démarrage et premier défilement compilés à l'avance.
- **R8 en mode complet**, ressources inutilisées retirées, et **split par ABI**. Objectif : APK de moins de 30 Mo par ABI, extension audio FFmpeg comprise.
- **JankStats** en interne : les images trop lentes sont comptées et visibles dans la console de diagnostic de l'app, comme la console réseau Apple.
- **StrictMode** en build de débogage : toute lecture disque ou réseau sur le fil principal fait échouer les tests d'interface.

### 5.2. Responsive (téléphones de toutes tailles)

- **`WindowSizeClass`** (compact, moyen, étendu) choisit la mise en page :
  - **compact**, téléphone en portrait : barre de navigation en bas, lecteur en haut et liste en dessous ;
  - **moyen**, téléphone en paysage, petit pliable ou petite tablette : rail de navigation, grille plus large ;
  - **étendu**, tablette ou pliable ouvert : trois volets (catégories, liste, détails ou lecteur), comme la colonne de droite sur Mac.
- **Jetons de taille** issus du `PRD-30` (affiches, cartes, icônes), recalculés selon la largeur et la taille de police du système. L'interface reste utilisable avec une police à 200 %.
- **Pliables :** posture « livre » ou « table » (`WindowLayoutInfo`), avec la vidéo sur la moitié haute et les contrôles en bas.
- **Encoches et bords arrondis :** la vidéo va d'un bord à l'autre (edge-to-edge), les contrôles restent dans la zone sûre.

### 5.3. Android TV (10-foot UI)

- **Compose for TV** (`androidx.tv.material3`) : cartes et rangées au focus, focus visible, agrandissement de la carte qui a le focus.
- **Navigation à la télécommande uniquement :** croix directionnelle, OK, retour, lecture/pause.
  - **Retour :** depuis le lecteur, il revient à l'écran précédent ; depuis l'accueil, il demande confirmation avant de quitter.
  - **Mémoire du focus :** chaque rangée retient sa position, et revenir sur un écran rend le focus à la carte quittée.
- **Marges de sécurité TV :** 48 dp sur les côtés, 27 dp en haut et en bas.
- **Saisie de texte réduite au minimum.** Pour ajouter une source sur la TV :
  1. scanner un **QR code** affiché par la TV avec le téléphone (la page s'ouvre sur l'app téléphone, ou sur une petite page web locale servie par la TV) ;
  2. ou utiliser l'**envoi par réseau local** du `PRD-26` (découverte NSD) ;
  3. ou saisir au clavier en dernier recours.
- **Intégration au système :**
  - rangée **« Continuer à regarder »** de l'écran d'accueil Google TV (Watch Next / TV Provider) ;
  - recherche vocale par l'assistant vers la recherche par prompt (`PRD-33`) ;
  - lecture en arrière-plan coupée quand la TV se met en veille.
- **Boîtiers modestes** (2 Go, armv7, Android 9) :
  - images en définition réduite ;
  - préchargement limité ;
  - pas d'animation coûteuse quand `ActivityManager.isLowRamDevice()` est vrai.

### 5.4. Facile à utiliser

- **Premier lancement en 3 étapes :** ajouter une source (Xtream, M3U ou QR), choisir le profil, puis arriver directement sur Live TV avec la dernière chaîne prête à lire.
- **Toujours une action principale évidente par écran** : « Regarder », « Reprendre », « Épisode suivant ».
- **Messages d'erreur en clair**, avec l'action à faire, repris des diagnostics Apple (par exemple : `429` → « Votre abonnement n'autorise qu'une connexion : arrêtez la lecture sur l'autre appareil »).
- **Accessibilité :**
  - TalkBack (libellés, ordre de lecture) ;
  - contrastes AA ;
  - cibles tactiles de 48 dp minimum ;
  - sur TV, le focus est toujours visible.

---

## 6. Parcours et fonctions (parité avec Apple, par lots)

| Fonction | Téléphone | TV | Lot |
| :--- | :--- | :--- | :--- |
| Sources Xtream / M3U, synchronisation, état du compte (connexions, expiration) | ✓ | ✓ (QR / réseau local) | 37.2 |
| Live TV : catégories, favoris, récents, zapping, numéro de chaîne, maintenant / ensuite | ✓ | ✓ | 37.2 |
| Lecteur direct (ExoPlayer, une connexion, pistes audio et sous-titres) | ✓ | ✓ | 37.2 |
| Films et séries : grilles paginées, fiches, reprise, épisode suivant, versions | ✓ | ✓ | 37.3 |
| Lecteur film (relais, tampon, débit insuffisant, autre version) | ✓ | ✓ | 37.3 |
| Guide TV (grille), replay et rattrapage | ✓ | ✓ | 37.4 |
| Recherche locale et par prompt avec l'IA (`PRD-33`) | ✓ | ✓ (voix) | 37.4 |
| Rangées « Pour vous » par type (`PRD-34`) | ✓ | ✓ | 37.5 |
| Téléchargements (WorkManager et service de premier plan, une connexion, écran éteint) | ✓ | — | 37.6 |
| PiP, notification et écran de verrouillage (MediaSession) | ✓ | — | 37.6 |
| Profils, mode Enfants, PIN parental, catégories adultes (`PRD-20`) | ✓ | ✓ | 37.7 |
| Assistant IA, réglages, clés dans le Keystore | ✓ | ✓ | 37.7 |
| Google TV : « Continuer à regarder », fréquence d'image, passthrough audio | — | ✓ | 37.8 |
| Chromecast | ✓ | — | 37.10 (facultatif) |

---

## 7. Données et sécurité

- **Base :** SQLite gérée par le cœur Rust, dans `filesDir`, sans Room. Le cœur reste la seule source de vérité.
- **Mots de passe des sources et clés d'API :** **Android Keystore** (chiffrement matériel quand il existe), passés au moteur à chaque appel comme sur Apple (`password_ref`). Jamais dans les préférences en clair ni dans les journaux.
- **Préférences d'interface :** DataStore (`Preferences`), lu en asynchrone, jamais sur le fil principal.
- **Synchronisation entre appareils :** pas d'iCloud. Le partage chiffré par fichier ou réseau local du `PRD-26` sert aussi entre iPhone et Android. Une synchronisation en ligne est hors de ce PRD.
- **Journaux :** les URL de flux sont masquées (hôte et extension seulement), comme `AppLog.describe` sur Apple.

---

## 8. Plateforme Android

- **Versions :**
  - `minSdk 24` (Android 7.0) : couvre la très grande majorité des téléphones et des boîtiers TV encore utilisés ;
  - `targetSdk` : la dernière version stable ;
  - les fonctions récentes (fréquence d'image, PiP élargi, `predictive back`) sont activées selon la version de l'appareil.
- **ABI :** `arm64-v8a`, `armeabi-v7a` et `x86_64`, en AAB pour le Play Store ou en APK par ABI pour l'installation directe.
- **Réseau :**
  - `network_security_config` autorise le **HTTP non chiffré**, car la plupart des serveurs IPTV et le relais local sur `127.0.0.1` en ont besoin ;
  - HTTPS reste vérifié normalement.
- **Manifeste :**
  - une seule activité principale, déclarée pour le lanceur téléphone **et** pour le lanceur TV (`LEANBACK_LAUNCHER`) ;
  - `android.software.leanback` et `android.hardware.touchscreen` déclarés `required="false"`, pour que la même app s'installe sur les deux ;
  - bannière TV ;
  - PiP sur téléphone.
- **Arrière-plan :**
  - **lecture :** `MediaSessionService` (Media3) ;
  - **téléchargements :** `WorkManager` avec travail accéléré et service de premier plan de type `dataSync`, pour garder les téléchargements écran éteint dans les limites d'Android 14+ ;
  - **guide TV :** actualisation périodique par `WorkManager` quand il est périmé.

---

## 9. Matrice d'appareils de test

| Catégorie | Exemples | Ce qu'on vérifie |
| :--- | :--- | :--- |
| Téléphone d'entrée de gamme | Android Go, 2 Go, Android 11 | Démarrage, défilement, mémoire, images réduites |
| Téléphone milieu de gamme | Pixel 6a, Galaxy A54 | SLA de référence |
| Téléphone haut de gamme | Galaxy S24, Pixel 9 | 4K HEVC HDR, 120 Hz |
| Pliable et tablette | Galaxy Z Fold, tablette 11" | Mises en page moyenne et étendue, postures |
| TV d'entrée de gamme | Boîtier Android 9 armv7 2 Go | Focus, fluidité, 32 bits |
| Google TV | Chromecast avec Google TV (HD et 4K), Xiaomi TV Box S | Watch Next, fréquence d'image, passthrough |
| TV performante | Nvidia Shield, TV Sony ou TCL Google TV | 4K HDR, tunneling, AC3 / DTS |
| Émulateurs | Téléphone API 24, 34, 35 ; TV API 31 | Tests instrumentés en CI |

---

## 10. Lots

| Lot | Contenu | Validation principale |
| :--- | :--- | :--- |
| **37.1** | Fondations : projet `android/`, `build-logic`, modules, Hilt, `scripts/build-android.sh`, liaisons UniFFI Kotlin, moteur démarré en arrière-plan, système de design (jetons, cartes, rangées, focus TV), coques téléphone et TV, navigation, Baseline Profile de démarrage, CI (build, tests, lint, test d'architecture des modules). | L'app s'ouvre sur téléphone et TV et affiche la version du moteur ; démarrage à froid mesuré. |
| **37.2** | Sources (Xtream, M3U, QR code TV), synchronisation, Live TV, lecteur direct ExoPlayer, zapping, maintenant / ensuite. | Zapping < 1 s ; une seule connexion ouverte ; défilement de 5 000 chaînes sans saccade. |
| **37.3** | Films, séries, fiches, reprise, épisode suivant, lecteur film par le relais, tampon, débit insuffisant, autres versions. | Un MKV 4K se lit sur un abonnement à une connexion ; bandeau de débit testé. |
| **37.4** | Guide TV en grille (téléphone et TV), replay, recherche locale et par prompt, recherche vocale TV. | Grille fluide sur boîtier d'entrée de gamme ; résultats identiques à Apple sur le jeu d'évaluation du `PRD-33`. |
| **37.5** | Rangées « Pour vous » (`PRD-34`) sur les trois écrans, avec affinage IA. | Aucun mélange des types ; rangées affichées en < 300 ms. |
| **37.6** | Téléchargements (WorkManager, écran éteint, une connexion), PiP, MediaSession, notifications. | Saison complète téléchargée écran éteint. |
| **37.7** | Profils, mode Enfants, PIN, réglages, assistant IA, Keystore. | Aucune clé lisible hors du Keystore ; profil Enfants sans appel IA distant. |
| **37.8** | Finitions Google TV : Watch Next, fréquence d'image, passthrough, tunneling, boîtiers 32 bits. | Changement de fréquence sans saccade ; « Continuer à regarder » sur l'accueil. |
| **37.9** | Passe de performance : Macrobenchmarks complets, Baseline Profiles de tous les parcours, réglages basse mémoire, taille d'APK. Moteur libmpv de secours si un format l'exige. | SLA du tableau d'en-tête atteints sur la matrice du § 9. |
| **37.10** | Distribution : signature, AAB et APK par ABI, mise à jour intégrée pour l'installation directe, Chromecast (facultatif). | Installation propre sur un appareil neuf ; mise à jour sans perte de données. |

Ordre conseillé : 37.1 → 37.2 → 37.3 → 37.4 → 37.9 (première passe) → 37.5 → 37.6 → 37.7 → 37.8 → 37.10. Chaque lot est livrable seul.

---

## 11. Fichiers à Créer / Modifier

- `android/` *(nouveau)* :
  - `settings.gradle.kts`, `build.gradle.kts`, `gradle/libs.versions.toml`, `build-logic/` ;
  - les modules du § 2.3 ;
  - `app/src/main/AndroidManifest.xml`, `res/xml/network_security_config.xml`, bannière TV ;
  - `benchmark/` (Macrobenchmark, génération des Baseline Profiles).
- `scripts/build-android.sh` *(nouveau)* : cargo-ndk, copie des `.so`, liaisons UniFFI Kotlin.
- `crates/cnd-core/Cargo.toml` *(profil Android : taille)*, `src/lib.rs` *(chemins fournis par l'app, journaux vers logcat)*.
- `Taskfile.yml` *(tâches `android:build`, `android:run`, `android:tv`, `android:bench`)*.
- `docs/BUILD_ANDROID.md` *(nouveau)* : installation des outils, lancement sur téléphone et TV, dépannage.
- `PRD/00_INDEX_ROADMAP.md`.

---

## 12. Contraintes Non-Négociables (Guardrails IA)

- **SRP :** une responsabilité par module.
  - Les écrans ne parlent jamais au moteur directement.
  - Aucune règle métier du cœur n'est réécrite en Kotlin.
  - Un module de fonctionnalité ne dépend pas d'un autre.
- **Fil principal :** jamais d'appel au moteur, d'accès disque, de décodage d'image ni de JSON. StrictMode le vérifie en débogage.
- **Listes :** toujours paresseuses, avec `key` et `contentType`, paginées au-delà de 200 éléments, sans appel au moteur par élément.
- **Une seule connexion au serveur** quand l'abonnement l'impose : pas de préchargement parallèle, relais pour les films, réutilisation de la session.
- **Secrets :** Keystore uniquement. Aucune URL de flux complète ni clé dans les journaux, les rapports de plantage ou les données de l'IA.
- **IA :** mêmes règles de données que sur Apple (`PRD-13`, `PRD-33`, `PRD-34`) ; aucun appel distant pour le profil Enfants.
- **Accessibilité et TV :** chaque élément interactif a un libellé TalkBack et un état de focus visible.
- **Taille :** l'APK par ABI reste sous 30 Mo, et la croissance est vérifiée en CI.
- **Les cibles Apple restent vertes :** les changements du cœur Rust passent aussi `swift test` et les 4 schémas Xcode.

---

## 13. Critères d'Acceptation & Commandes de Validation

1. **Rust :**
   - `cargo clippy --workspace --all-targets -- -D warnings` ;
   - `cargo test --workspace --release` ;
   - `./scripts/build-android.sh` produit les `.so` des 3 ABI et les liaisons Kotlin.
2. **Android :**
   - `./gradlew lint testDebugUnitTest` (cas d'usage, `ViewModel`, règles du lecteur : blocage, débit, une connexion) ;
   - `./gradlew :app:connectedDebugAndroidTest` (parcours téléphone et TV sur émulateurs) ;
   - test d'architecture : aucun `:feature:*` ne dépend d'un autre ni de `:core:engine`.
3. **Performance :**
   - `./gradlew :benchmark:connectedBenchmarkAndroidTest` (démarrage `StartupTimingMetric`, défilement `FrameTimingMetric` sur 5 000 affiches, zapping) ;
   - `adb shell dumpsys gfxinfo <package>` et `dumpsys meminfo` sur la matrice du § 9 ;
   - SLA de l'en-tête atteints.
4. **Essais manuels :**
   - téléphone d'entrée de gamme : ajout d'une source, chaîne lue en moins d'une minute ;
   - Google TV : tout le parcours à la télécommande seule, source ajoutée par QR code ;
   - abonnement à une connexion : film MKV 4K lu, avance rapide, relance sans `429` ;
   - pliable : changement de posture pendant la lecture sans coupure.
5. **Apple inchangé :** `cd apple && swift test` et les 4 schémas Xcode restent verts.

---

## 14. Questions ouvertes

- **Play Store :** les apps IPTV y sont acceptées si elles ne fournissent aucun contenu, mais la revue est stricte (pas de listes préinstallées, pas de marques de chaînes dans les visuels). Faut-il viser le Play Store dès le lot 37.10, ou d'abord l'installation directe (APK) avec mise à jour intégrée ?
- **`minSdk` 24 ou 26 :** 24 couvre plus de boîtiers TV anciens. 26 simplifie certaines API (canaux de notification, polices, fréquence d'image partielle). Ce PRD retient 24.
- **libmpv de secours :** à décider après le lot 37.9, selon les fichiers qu'ExoPlayer ne lit pas dans vos sources.
- **Chromecast :** utile sur téléphone, mais il demande que le Chromecast lise le flux lui-même, ce qui pose problème avec une seule connexion si le téléphone lit aussi. Il est facultatif.
- **Synchronisation en ligne entre appareils** (favoris, reprise) : à traiter dans un PRD séparé si l'on veut l'équivalent d'iCloud.

---

## 15. Statut d'Implémentation & Validation

**Terminé (`[x]`).**
- Architecture modulaire stricte en 21 modules Gradle (6 modules `:core:*`, 13 modules `:feature:*`, `:app`, `:benchmark`).
- Principes SRP validés : aucun module `:feature:*` ne dépend d'un autre ni de `:core:engine`.
- Moteur Rust `cnd-core` compilé pour les ABIs Android (`arm64-v8a`, `armeabi-v7a`, `x86_64`) et pont FFI UniFFI Kotlin généré.
- Double shell adaptatif : `MobileShell` (Phone/Tablet/Foldable) et `TvShell` 10-foot (Android TV / Google TV) avec navigation D-Pad télécommande et protection overscan.
- Lecteur vidéo Media3 ExoPlayer avec relais local mono-connexion Rust (`127.0.0.1`), stall watchdog et respect du quota de connexion.
- Téléchargements persistants écran éteint via WorkManager (`dataSync`).
- Commandes Taskfile `task run:android`, `task run:android:tv`, `task run:android:release`, `task run:android:logs`, `task install:android`, `task android:devices`.
