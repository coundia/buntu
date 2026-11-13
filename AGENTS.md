# AGENTS.md — Guide pour les agents IA qui travaillent sur Buntu (`cnd-iptv-native`)

Ce fichier s'adresse à tout agent IA (Claude, Codex, Gemini, Cursor, Copilot…) qui modifie ce dépôt. Il résume ce qu'il faut savoir **avant** de toucher au code. Les détails sont dans les documents cités.

---

## 1. Le projet en bref

**Buntu** (nom de code `cnd-iptv-native`) est un lecteur IPTV natif multiplateforme : chaînes en direct, guide TV, films, séries, sur des comptes Xtream Codes ou des playlists M3U fournis par l'utilisateur.

| Dossier | Contenu | Langage |
| :--- | :--- | :--- |
| `crates/cnd-domain/` | **Règles métier pures, sans entrées-sorties** : normalisation, M3U, XMLTV, recherche, recommandations, appairage (`pairing`), prompts d'IA. Partagé par toutes les plateformes. | Rust |
| `crates/cnd-core/` | Moteur avec entrées-sorties : SQLite (WAL + FTS5), HTTP (`reqwest`), Xtream, EPG, téléchargements, relais, IA. Exposé par **UniFFI** à Swift et Kotlin. | Rust |
| `crates/cnd-domain-wasm/` | `cnd-domain` compilé en **WebAssembly** pour la TV Samsung (exports `wasm_*`). | Rust |
| `crates/cnd-cli/` | Outil en ligne de commande pour tester le moteur. | Rust |
| `apple/` | App SwiftUI : macOS, iOS/iPadOS, tvOS, visionOS (lecteur mpv / VideoToolbox). | Swift 6 |
| `android/` | App téléphone et Android TV (Compose, Hilt, modules SRP). | Kotlin |
| `tizen/` | App TV Samsung (Tizen 3.0+) : SolidJS + TypeScript, lecteur AVPlay, WebAssembly. | TypeScript |
| `PRD/` | Spécifications, une fonctionnalité par fichier. **Lire `PRD/00_INDEX_ROADMAP.md` d'abord.** | Markdown (français) |
| `docs/` | Guides : build par plateforme, appairage, IA sur Tizen, pilotage de la TV. | Markdown (français) |
| `scripts/` | Build, installation, lancement, contrôle des secrets. | Bash |

Commandes courantes : `task --list` (voir `Taskfile.yml`).

---

## 2. Règles de conduite

- **Répondre à l'utilisateur en français**, simplement, et être **honnête sur ce qui n'est pas vérifié** : dire « non essayé à l'écran », « non testé sur la TV » quand c'est le cas. Ne jamais présenter une supposition comme un résultat.
- **Ne jamais saisir, afficher ou journaliser** un identifiant, un mot de passe, une clé d'API ou une URL de flux (les URL Xtream contiennent l'identifiant et le mot de passe). Dans les tests et rapports : noms et états seulement.
- **Ne rien commiter ni pousser sans demande explicite.** Quand c'est demandé : commits par sujet, messages en anglais au format Conventional Commits (`feat(tizen): …`, `fix(core): …`, `docs: …`, `perf(…)`), et `./scripts/check-secrets.sh` avant le commit.
- **Demander avant tout geste hors du dépôt** : installer un outil, modifier les réglages d'un appareil, télécharger un gros fichier (annoncer nom, source, taille).
- **Appareils de l'utilisateur** (iPhone, TV) : n'installer **que sur l'appareil désigné par l'utilisateur**. L'adresse IP de la TV change souvent ; si elle ne répond plus, la chercher, mais **demander confirmation** avant d'installer sur une autre adresse.
- **Ne pas « réparer en passant »** ce qui est hors du sujet ; le signaler.
- **Suivi des tâches dans [`progress.md`](progress.md)** : noter chaque tâche, y compris les tâches de fond (tests, builds, scripts lancés en arrière-plan), avec son état (⏳ en cours, ✅ terminé, ❌ échec et pourquoi). Mettre l'état à jour dès que la tâche se termine.
- **Ne pas lancer de build : l'utilisateur les fait lui-même** (`xcodebuild`, `build-xcframework.sh`, `build-android.sh`, `build-tizen.sh`, `assembleDebug`, `task run:*`, installation d'un APK ou d'une app). Quand un build est nécessaire (changement d'API UniFFI, de `cnd-domain` utilisé par la TV, nouveaux fichiers Swift…), **dire lequel et pourquoi** dans le récapitulatif et le noter dans `progress.md` (« à faire par l'utilisateur »). Les tests ciblés des modules touchés restent permis.
- **Annoncer chaque fin de tâche à l'utilisateur**, réussie ou non, avec le résultat (« Terminé : tests `:feature:player`, 8/8 »). Une tâche de fond ne se termine jamais en silence.

### 2.1. Plusieurs agents travaillent dans ce même dossier

C'est fréquent : une autre session peut modifier des fichiers en même temps que vous.
- Lire **`git status`** avant de commencer et avant de commiter.
- **Ne jamais annuler, écraser ni supprimer** un changement que vous n'avez pas fait. Un fichier qui change « tout seul » sur le disque vient sans doute d'un autre agent : le prendre comme l'état actuel.
- **Ne commiter que vos propres fichiers** (`git add <chemins>`, jamais `git add -A` sur un arbre partagé sans vérifier).
- Signaler à l'utilisateur les changements inconnus plutôt que de les intégrer.

---

## 3. Règles d'architecture

1. **Une seule implémentation des décisions.** Tout ce qui décide ou valide (normalisation, identité des contenus, recherche, recommandations, protocole d'appairage, requêtes et validation d'IA, synchronisation) est écrit **une fois en Rust dans `cnd-domain`**, puis utilisé par UniFFI (Swift, Kotlin) et WebAssembly (Tizen). **Ne pas réécrire une règle métier en TypeScript, Swift ou Kotlin.** Les mêmes vecteurs de test (`*/vectors.json`) sont vérifiés sur chaque plateforme.
2. **`cnd-domain` n'a aucune entrée-sortie** (ni réseau, ni disque, ni horloge, ni hasard : ils sont passés en paramètres). Les entrées-sorties vivent dans `cnd-core` ou dans l'app.
3. **Anti-saturation mémoire :** ne jamais charger une playlist M3U, un XMLTV ou un gros JSON en entier ; lire en flux et écrire par lots (2 000 à 5 000 lignes).
4. **Fil principal libre :** aucun disque, réseau ou appel lourd au moteur sur le fil principal (`@MainActor` côté Swift, coroutines côté Kotlin, worker côté Tizen).
5. **Une seule connexion chez le fournisseur :** beaucoup d'abonnements IPTV n'autorisent qu'un flux à la fois. Arrêter un flux avant d'en ouvrir un autre ; ne jamais ouvrir deux connexions pour le même contenu.
6. **Android :** les modules `feature/*` ne dépendent jamais de `:core:engine` (vérifié par `android/app/src/test/kotlin/com/pcoundia/buntu/ModuleArchitectureTest.kt`) ; les contrats sont dans `core:domain`, les implémentations Rust dans `core:data`.
7. **Secrets :** Trousseau (Apple), Keystore (Android), stockage chiffré WebCrypto (Tizen). Jamais dans SQLite, les journaux, les exports ou les messages de synchronisation.

> **Note sur l'index des PRD :** la règle « zéro technologie web » de `PRD/00_INDEX_ROADMAP.md § 2` date d'avant l'app Samsung. Elle vaut pour Apple et Android ; **`tizen/` est une app web par nécessité** (`PRD-38`), mais ses règles métier restent en Rust (WebAssembly).

---

## 4. Pièges propres à la TV Samsung (`tizen/`)

La TV de référence est une **UN43AU8000 (Tizen 6.0, Chromium 76)** ; les TV plus anciennes ont Chromium 56 à 69.
- **CSS non supportés** avant Chromium 79 à 88 : `clamp()`, `min()`/`max()`, `aspect-ratio`, `inset`, `gap` en flexbox. Le build ajoute une valeur de repli à chaque `clamp()` (`tizen/build-plugins/clampFallback.cjs`) ; pour le reste, utiliser des marges, `padding-top: 56.25%` pour un 16:9, `top/right/bottom/left`.
- **JavaScript :** pas de `?.` ni `??` dans le code évalué à distance ; le code de l'app est transpilé par Vite (`plugin-legacy`). `AbortController` absent avant Chromium 66.
- **WebAssembly :** doit rester en **WebAssembly 1.0 MVP strict** (contrôlé par `scripts/build-tizen.sh`, voir `PRD-39 § 12`).
- **Worker :** format classique (`iife`), avec repli sur le fil principal si le worker ne démarre pas.
- **Vidéo AVPlay :** l'image est dessinée **derrière la page web**. La zone vidéo doit être transparente (rien d'opaque au-dessus, même un fond semi-transparent). Dans une **fenêtre plus petite que l'écran**, utiliser le mode d'affichage `PLAYER_DISPLAY_MODE_FULL_SCREEN` (le mode letter-box n'affiche que le son sur cette TV) et ajuster le format à la main (`fitRect`).
- **Chargement :** les écrans ne doivent pas interroger la base avant la fin de `engine.init()`.
- **Pilotage à distance :** installation, inspecteur, simulation de la télécommande et mesures sont décrits dans [`docs/TIZEN_CONTROLE_A_DISTANCE.md`](docs/TIZEN_CONTROLE_A_DISTANCE.md). L'image vidéo n'est pas visible à distance : la faire confirmer par l'utilisateur.

---

## 5. Validation avant de dire « terminé »

Lancer ce qui correspond aux couches touchées :

| Couche | Commande |
| :--- | :--- |
| Rust | `cargo clippy --workspace --all-targets -- -D warnings` puis `cargo test --workspace --release` |
| Apple | `cd apple && swift test` ; schémas `CndIPTV-iOS`, `CndIPTV-tvOS`, `CndIPTV-macOS`, `CndIPTV-visionOS` avec `xcodebuild -project apple/CndIPTV.xcodeproj -scheme <schéma> CODE_SIGNING_ALLOWED=NO build` |
| Android | les modules touchés, par exemple `cd android && ./gradlew :core:data:testDebugUnitTest :core:domain:test :app:testDebugUnitTest` (le build complet `task android:test` est long) |
| Tizen | `cd tizen && npx tsc --noEmit && npm test` ; pour la TV : `./scripts/run-tizen.sh <IP>` |
| Tout | `task check` (release complète, long) |

**Pièges connus :**
- **Clone neuf :** `task init` (outils, `.env`, XCFramework, projet Xcode). Le XCFramework `apple/Packages/CndCoreBridge/cnd_coreFFI.xcframework` n'est **pas versionné** (ignoré par git) ; ne jamais le recommiter.
- Après tout changement d'API **UniFFI** (`#[uniffi::export]`, `Record`, `Enum`, `Error`) : reconstruire le XCFramework (`./scripts/build-xcframework.sh`, plusieurs minutes) **et** les liaisons Kotlin (`./scripts/build-android.sh --bindings-only`).
- Après l'ajout de fichiers Swift : `xcodegen generate` dans `apple/` (voir `reprise.md` pour l'équipe de signature).
- Après un changement de `cnd-domain` utilisé par la TV : `./scripts/build-tizen.sh` (reconstruit le `.wasm`).
- Le test de performance `test_recommendations_sla_50k_items` (`PRD-27`) échoue déjà sur cette machine ; ne pas le « réparer » en passant.
- Disque presque plein sur le Mac de développement : nettoyer les dossiers temporaires de `xcodebuild` après usage.

---

## 6. Écrire ou mettre à jour un PRD

- Un fichier par fonctionnalité, `PRD/NN_NOM.md`, en **français simple**, au format des PRD existants : en-tête (ID, prérequis, couches, objectifs mesurables), contexte, expérience, spécifications, lots, fichiers, contraintes non négociables, critères d'acceptation, questions ouvertes, **statut d'implémentation**.
- Ajouter ou mettre à jour la ligne du PRD dans `PRD/00_INDEX_ROADMAP.md` (statut `[ ]`, `[x]`, ou partiel avec le détail).
- Vérifier chaque fait cité dans le code (fichier, fonction, valeur) et indiquer ce qui a été **mesuré** et ce qui ne l'a pas été.
- Quand l'utilisateur demande un PRD ou une étude, **ne pas coder**.

---

## 7. Où trouver quoi

- **Plan et règles :** `PRD/00_INDEX_ROADMAP.md`.
- **Passation entre agents :** `reprise.md` (état, pièges, procédures d'installation sur la TV et l'iPhone).
- **Tâches en cours des agents :** `progress.md` (qui fait quoi, état de chaque tâche, y compris les tâches de fond).
- **Build par plateforme :** `docs/BUILD_IPHONE.md`, `docs/BUILD_ANDROID.md`, `docs/BUILD_TIZEN.md`.
- **Appairage téléphone → TV :** `docs/PAIRING.md` (`PRD-39`).
- **IA sur la TV :** `docs/AI_TIZEN.md` (`PRD-40`).
- **Continuité entre appareils :** `PRD/41_CONTINUITE_MULTI_APPAREILS.md`.
- **Lire sur un autre appareil (sans Cast) :** `PRD/42_LIRE_SUR_UN_AUTRE_APPAREIL.md`.
- **Ajouter un appareil au foyer par QR code :** `PRD/43_AJOUTER_UN_APPAREIL_PAR_QR_CODE.md`.
- **Pilotage de la TV depuis le Mac :** `docs/TIZEN_CONTROLE_A_DISTANCE.md`.
- **Marque Buntu :** `docs/BRANDING_BUNTU.md`.
