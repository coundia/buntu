<p align="center">
  <img src="assets/AppIcon-1024.png" alt="Buntu" width="128">
</p>

<h1 align="center">Buntu</h1>

<p align="center">
  <i>Sa bunt ci lépp</i> : la porte d'entrée de tous vos médias.<br>
  Lecteur de flux et gestionnaire de médias universel pour <b>Apple</b> (macOS, iOS, iPadOS, tvOS, visionOS), <b>Android</b> (Téléphones, Tablettes, Android TV, Google TV) et <b>Samsung Smart TV</b> (Tizen 3.0+).<br>
  Moteur métier pur <b>Rust</b>, base locale <b>SQLite WAL + FTS5 / IndexedDB</b>, et moteurs de lecture matériels natifs (<code>AVPlayer</code>, <code>libmpv</code>, <code>ExoPlayer Media3</code>, <code>Samsung AVPlay</code>).<br>
  <i>Buntu est un lecteur neutre : il ne fournit aucun contenu, il lit les flux et fichiers que vous ajoutez en respectant strictement les quotas mono-connexion de vos abonnements.</i>
</p>

<p align="center">
  <a href="#plateformes-prises-en-charge"><img src="https://img.shields.io/badge/Platforms-Apple%20%7C%20Android%20%7C%20Tizen-blue" alt="Platforms"></a>
  <a href="#architecture-unifiée-monorepo"><img src="https://img.shields.io/badge/Core-Rust%20%2B%20WebAssembly-orange" alt="Rust Core"></a>
  <a href="#tests-et-qualité"><img src="https://img.shields.io/badge/Tests-350%2B%20passing-brightgreen" alt="Tests"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT%20%2F%20Apache--2.0-lightgrey" alt="License"></a>
</p>

---

## Sommaire

1. [Plateformes Prises en Charge](#plateformes-prises-en-charge)
2. [Fonctionnalités Principales](#fonctionnalités-principales)
3. [Architecture Unifiée (Monorepo)](#architecture-unifiée-monorepo)
4. [Démarrage Rapide & Initialisation](#démarrage-rapide--initialisation)
5. [Compilation et Lancement par Plateforme](#compilation-et-lancement-par-plateforme)
6. [Commandes Rapides (`Taskfile.yml`)](#commandes-rapides-taskfileyml)
7. [Structure du Dépôt](#structure-du-dépôt)
8. [Guides Détaillés par Plateforme](#guides-détaillés-par-plateforme)
9. [Emplacement des Données](#emplacement-des-données)
10. [Tests et Qualité](#tests-et-qualité)
11. [Licence](#licence)

---

## Plateformes Prises en Charge

| Écosystème | Cibles & Versions | Interface UI | Moteur de Lecture | Documentation |
| :--- | :--- | :--- | :--- | :--- |
| **Apple** | **macOS 14+** (Apple Silicon & Intel)<br>**iOS 17+** & **iPadOS 17+**<br>**tvOS 17+** (Apple TV 4K / HD)<br>**visionOS 1.0+** (Apple Vision Pro) | **SwiftUI** natif multi-fenêtres & focus 10-foot | `AVPlayer` (HLS, MP4, MOV) + `libmpv` (MKV, TS, AVI, FLV) avec rendu GPU Metal Zero-Copy | [`docs/BUILD_IPHONE.md`](docs/BUILD_IPHONE.md) |
| **Android** | **Android 7.0+** (`minSdk 24`)<br>Téléphones, Tablettes, Pliables<br>**Android TV & Google TV** (`minSdk 24`) | **Jetpack Compose** (Mobile) & **Compose for TV** (Leanback 10-foot) | **Media3 ExoPlayer** avec relais local mono-connexion (`127.0.0.1`), détection de débit & frame-rate matching | [`docs/BUILD_ANDROID.md`](docs/BUILD_ANDROID.md) |
| **Samsung TV** | **Tizen 3.0 à 8.0+**<br>(Téléviseurs Samsung 2017 à 2025+) | **SolidJS + TypeScript** (sans Virtual DOM) avec polyfills Chromium 56+ | **Samsung AVPlay (`webapis.avplay`)** matériel 4K HDR10/HLG, gestion de la veille TV (`suspend`/`restore`) | [`docs/BUILD_TIZEN.md`](docs/BUILD_TIZEN.md) |

---

## Fonctionnalités Principales

| Domaine | Description |
| :--- | :--- |
| **Gestion des Sources** | Ingestion en flux continu (zéro dépassement mémoire) de playlists M3U / M3U8 volumineuses (50 000+ items en < 1.5 s). Prise en charge native de l'API REST Xtream Codes avec synchronisation paresseuse des épisodes. |
| **Partage Sécurisé** | Export de bouquets ou de sources entières sous forme de fichiers `.cndshare`, liens profonds `cndiptv://` ou QR codes, chiffrés de bout en bout en **AES-GCM 256**. Mots de passe masqués par défaut (opt-in explicite). |
| **Live TV & Zapping** | Grille et liste avec jauges de progression des programmes, zapping instantané (touches Ch+/Ch-, télécommande ou pavé numérique), détection des flux en panne avec bascule transparente vers les serveurs miroirs. |
| **Guide des Programmes (EPG)** | Analyse XMLTV en streaming, grille chronologique interactive, fiches détaillées et programmation directe des enregistrements. |
| **Replay (Catchup)** | Rattrapage direct sur 7 jours des émissions passées via EPG sur les serveurs Xtream Codes et M3U compatibles. |
| **Multi-View** | Affichage simultané de **2 à 4 flux en direct** côte à côte sur écran de salon (tvOS, Android TV, Tizen et macOS). |
| **VOD : Films & Séries** | Regroupement automatique des saisons et épisodes, reprise de lecture avec sauvegarde de la progression à la seconde près, ordre chronologique des sagas (Marvel MCU, Star Wars, Harry Potter, etc.). |
| **Assistant IA & Recherche** | Recherche plein texte locale FTS5 instantanée, recherche en langage naturel (« Mets le match de ce soir », « Film d'action des années 90 ») analysée localement d'abord, puis enrichie via votre propre clé d'API (**Gemini**, **OpenAI / Ollama / LM Studio**, **Anthropic Claude**). |
| **Dialogue Boost & Sous-titres** | Égalisation vocale dynamique (amélioration de l'intelligibilité des dialogues), recherche et téléchargement automatique de sous-titres via **OpenSubtitles v1/v2**, et décalage manuel de synchronisation audio/sous-titres. |
| **Moteur PVR (Enregistreur)** | Planification d'enregistrements futurs en tâche de fond, gestion intelligente des conflits de chaînes et prise en charge des volumes de stockage externes (USB / SSD). |
| **Téléchargements Ininterrompus** | Moteur de téléchargement multi-segments parallèle (`Range`) avec reprise sur panne réseau. Continuité garantie **écran éteint ou appareil en veille** (`URLSessionConfiguration.background` sur iOS/macOS, `ForegroundService` sur Android). |
| **Profils & Contrôle Parental** | Multi-profils étanches (chacun ses favoris et son historique), profil Enfant restreint par catégorie, et verrouillage PIN / biométrique (Face ID, Touch ID) des catégories adultes. |
| **Médiathèque Locale** | Section « Mes fichiers » pour indexer et lire vos vidéos, musiques et photos stockées localement ou sur disque réseau (DLNA / Partage de fichiers). |

---

## Architecture Unifiée (Monorepo)

Le projet applique une séparation stricte des responsabilités (SRP) afin de maximiser la réutilisation de code sans sacrifier les performances de chaque plateforme hôte :

```mermaid
flowchart TD
    subgraph CoreDomain["Cœur Métier Pur (Rust)"]
        Domain["crates/cnd-domain<br/>(Zéro I/O · Modèles immuables · Parsers M3U/XMLTV · Ranking · Sagas · Profils)"]
    end

    subgraph NativeCore["Moteur Natif Rust (Tokio & SQLite)"]
        Domain --> Core["crates/cnd-core<br/>(SQLite WAL + FTS5 · HTTP Pool · Xtream · PVR · Subtitles · Crypto)"]
    end

    subgraph WasmCore["Moteur WebAssembly"]
        Domain --> DomainWasm["crates/cnd-domain-wasm<br/>(wasm-bindgen · wasm-opt -Oz · 578 Ko gzip)"]
    end

    subgraph AppleStack["Écosystème Apple (macOS / iOS / tvOS / visionOS)"]
        Core --> UniFFISwift["UniFFI Swift Bridge<br/>(cnd_coreFFI.xcframework)"]
        UniFFISwift --> CndIptvKit["CndIptvKit (SwiftUI)"]
        CndIptvKit --> AppleApp["CndIptvApp<br/>(AVPlayer + libmpv GPU Metal)"]
    end

    subgraph AndroidStack["Écosystème Android & Google TV"]
        Core --> UniFFIKotlin["UniFFI Kotlin Bridge<br/>(libcnd_core.so JNI)"]
        UniFFIKotlin --> AndroidModules[":core:domain · :core:data · :core:player"]
        AndroidModules --> AndroidApp[":app<br/>(Jetpack Compose · Compose for TV · ExoPlayer)"]
    end

    subgraph TizenStack["Écosystème Samsung Smart TV (Tizen 3.0+)"]
        DomainWasm --> WebWorker["Web Worker dédié<br/>(IndexedDB · cnd_domain_wasm)"]
        WebWorker --> SolidApp["tizen/ (SolidJS + TypeScript)<br/>(AVPlay 4K · SpatialNav 10-foot · RemoteKeyHandler)"]
    end
```

---

## Démarrage Rapide & Initialisation

### 1. Prérequis Généraux

- **[go-task](https://taskfile.dev)** : `brew install go-task`
- **Rust** stable (`rustup`) avec les cibles Apple, Wasm et Android :
  ```bash
  # Cibles Apple (macOS, iOS, tvOS, visionOS)
  rustup target add aarch64-apple-darwin x86_64-apple-darwin \
                    aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios \
                    aarch64-apple-tvos aarch64-apple-tvos-sim \
                    aarch64-apple-visionos aarch64-apple-visionos-sim

  # Cible WebAssembly (Samsung Smart TV Tizen)
  rustup target add wasm32-unknown-unknown

  # Cibles Android (si développement Android / Android TV)
  rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
  ```
- **Outils complémentaires selon les plateformes visées :**
  - **macOS / iOS** : Xcode 15+ (`xcode-select --install`), `brew install xcodegen` et optionnellement `brew install mpv` (pour le moteur `libmpv`).
  - **Samsung Smart TV (Tizen)** : `brew install wasm-pack binaryen node`
  - **Android** : Android Studio / SDK Command-line Tools avec le NDK.

---

### 2. Initialisation d'un Clone Neuf (`task init`)

Le framework binaire Apple (`apple/Packages/CndCoreBridge/cnd_coreFFI.xcframework/`) **n'est pas versionné dans Git** afin de garantir un dépôt ultra-léger (< 10 Mo).

Après avoir cloné le dépôt, lancez l'initialisation automatisée :
```bash
task init
```

Ce script (`./scripts/init.sh`) effectue automatiquement les 5 étapes nécessaires :
1. **Outils requis** : vérifie la présence de `cargo`, `rustc`, `rustup`, `swift`, `xcodebuild`, `xcodegen`, `task`, `node`, `npm`, `python3`.
2. **Cibles Rust** : s'assure que toutes les cibles Apple sont bien installées.
3. **Variables locales** : crée le fichier `.env` à partir de `.env.example` et génère les clés d'API par défaut masquées (`task keys`).
4. **Cœur Rust XCFramework** : compile `crates/cnd-core` en XCFramework universel (`cnd_coreFFI.xcframework`) pour macOS, iOS, tvOS et visionOS.
5. **Projet Xcode & dépendances Tizen** : génère `apple/CndIPTV.xcodeproj` avec XcodeGen et installe les modules Node pour Tizen (`npm ci`).

> [!TIP]
> - `task init FORCE=1` : force la recompilation de l'XCFramework et la réinstallation des dépendances même si elles existent.
> - `task init SKIP_CORE=1` : effectue les vérifications et génère le projet Xcode sans recompiler l'XCFramework Rust.

---

## Compilation et Lancement par Plateforme

Buntu fournit des scripts de compilation et de lancement clé en main dans le dossier `scripts/`, pilotables directement via `task` :

### 🍏 1. macOS

L'application macOS peut être compilée et lancée sous la forme d'un vrai bundle `.app` natif (icône Dock, barre de menus système, fenêtres multi-vues Metal) :

```bash
# Compilation en mode Debug et lancement immédiat
task run

# Compilation optimisée en mode Release
task run:release

# Lancement dans le terminal actuel pour afficher les journaux en direct (logs stdout)
task run:logs

# Recompiler d'abord le cœur Rust FFI, puis compiler et lancer l'app macOS
task run:fresh

# Assembler le bundle build/CndIPTV.app sans le lancer
task bundle

# Installer Buntu dans le dossier /Applications du système
task install

# Installer Buntu dans ~/Applications (utilisateur uniquement)
task install:user
```

---

### 📱 2. iPhone, iPad, Apple TV & Apple Vision Pro

```bash
# Ouvrir le projet complet dans Xcode (génère apple/CndIPTV.xcodeproj si manquant)
task xcode:open

# Lister les appareils Apple connectés (iPhone, iPad, Apple TV)
task iphone:devices

# Compiler, signer avec votre équipe Apple, installer et lancer sur l'appareil connecté
task run:iphone

# Cibler un appareil spécifique par son nom ou son UDID
task run:iphone DEVICE="Mon iPhone"

# Compilation optimisée Release sur appareil
task run:iphone:release DEVICE="Mon iPhone"

# Installer sur l'iPhone sans le lancer immédiatement
task install:iphone DEVICE="Mon iPhone"

# Recompiler manuellement le XCFramework Rust (après modification de crates/cnd-core)
task xcframework

# Régénérer le projet Xcode depuis apple/project.yml
task xcode:generate
```

---

### 🤖 3. Android & Android TV / Google TV

L'application Android est modulaire (SRP) et bascule automatiquement entre le mode mobile et le mode salon 10-foot (Leanback) :

```bash
# 1. Compiler les bibliothèques natives (.so) Rust et générer les bindings Kotlin
task android:core

# 2. Lister les téléphones, tablettes, téléviseurs et émulateurs Android connectés via adb
task android:devices

# 3. Compiler, installer et lancer sur téléphone ou tablette
task run:android

# 4. Lancer directement en mode Salon 10-foot sur Android TV / Google TV
task run:android:tv

# 5. Lancer et diffuser les journaux logcat filtrés de Buntu en direct
task run:android:logs

# Compiler tous les fichiers APK (Debug et Release sous android/app/build/outputs/apk/)
task android:build
```

---

### 📺 4. Samsung Smart TV (Tizen 3.0+)

L'application Samsung TV combine **SolidJS** (performances 60 fps sans Virtual DOM) et le moteur `cnd-domain` compilé en **WebAssembly 1.0 MVP strict** :

```bash
# Développement rapide dans le navigateur sur Mac avec rechargement à chaud (Vite)
task run:web

# Compiler le module cnd-domain-wasm et empaqueter le fichier Tizen (build/tizen/cnd-iptv-tizen.wgt)
task tizen:build

# Déployer et lancer le paquet sur la TV Samsung (en mode Développeur sur le même réseau)
task tizen:install TV_IP="192.168.1.50"

# Activer l'inspecteur Chrome DevTools distant (port 9222) pour déboguer la TV
task tizen:debug
```

---

### 💻 5. Outil CLI Rust (`cnd-cli`)

Le projet propose également un outil autonome en ligne de commande pour manipuler les playlists et vérifier le moteur natif sans interface graphique :

```bash
# Afficher l'aide et les commandes disponibles
task cli -- --help

# Exemple : tester le téléchargement d'un flux via le moteur Rust
task cli -- download <URL_FLUX> [DOSSIER_CIBLE]
```

---

## Commandes Rapides (`Taskfile.yml`)

Tableau récapitulatif des commandes courantes :

| Commande | Action |
| :--- | :--- |
| `task init` | Prépare un clone neuf : vérifie les outils, crée `.env`, compile l'XCFramework, génère le projet Xcode et installe Tizen. |
| `task doctor` | Vérifie la présence des compilateurs (`cargo`, `swift`, `xcodebuild`, etc.) et des cibles Rust. |
| `task keys` | Régénère les clés d'API par défaut masquées depuis `.env`. |
| `task run` | Compile et lance Buntu sur macOS. |
| `task run:iphone` | Compile, signe et lance Buntu sur l'iPhone / iPad branché. |
| `task run:android` | Compile et lance Buntu sur l'appareil Android connecté. |
| `task run:android:tv` | Lance Buntu en mode Salon 10-foot sur Android TV. |
| `task run:web` | Lance l'application Tizen dans le navigateur web avec rechargement à chaud. |
| `task tizen:install` | Déploie et lance le paquet `.wgt` sur une TV Samsung (`TV_IP="..."`). |
| `task lint` | Exécute `cargo clippy` en traitant les avertissements comme des erreurs. |
| `task test` | Exécute l'ensemble des tests rapides (Rust, bridge Swift, app). |
| `task check` | Validation complète de release (secrets, clés, clippy, tests SLA, xcodebuild). |

---

## Structure du Dépôt

```text
cnd-iptv-native/
├── Taskfile.yml                # Lanceur de tâches automatisées multiplateforme
├── Cargo.toml                  # Espace de travail Rust monorepo
├── crates/
│   ├── cnd-domain/             # Cœur métier pur, zéro I/O (M3U, XMLTV, sagas, recherche, profils)
│   ├── cnd-domain-wasm/        # Bindings WebAssembly légers pour environnements Web/Tizen
│   ├── cnd-core/               # Moteur natif (SQLite WAL, Tokio, client HTTP, PVR, FFI)
│   └── cnd-cli/                # Outil CLI de diagnostic et d'ingestion locale
├── apple/                      # Projet Swift & SwiftUI universel (macOS, iOS, tvOS, visionOS)
│   ├── Package.swift           # Définition des cibles et dépendances Swift
│   ├── Packages/CndCoreBridge/ # XCFramework binaire + bindings Swift UniFFI
│   └── Sources/CndIptvKit/     # Composants d'interface, lecteurs AVPlayer/libmpv, synchronisation
├── android/                    # Application Android & Android TV modulaire en SRP
│   ├── app/                    # Module hôte (MobileShell & TvShell Leanback)
│   ├── core/                   # :engine (FFI), :domain, :data, :player (ExoPlayer), :designsystem
│   └── feature/                # 13 modules d'écrans indépendants (onboarding, live, vod, pvr...)
├── tizen/                      # Application Samsung Smart TV (Tizen 3.0+)
│   ├── config.xml              # Manifeste de l'application Tizen (résolution 1080p, AVPlay)
│   ├── src/core/               # AVPlayerService, HttpClient mono-connexion, RemoteKeyHandler, Database
│   ├── src/worker/             # Web Worker exécutant cnd-domain-wasm et IndexedDB
│   └── src/features/           # 12 écrans TV en SolidJS optimisés sans Virtual DOM
├── scripts/                    # Scripts de compilation (build-xcframework, build-android, build-tizen)
├── docs/                       # Guides détaillés de build, déploiement et design
│   ├── BUILD_IPHONE.md         # Guide complet iOS (signature, provisionnement, appareils physiques)
│   ├── BUILD_ANDROID.md        # Guide complet Android (NDK, téléphones, Google TV, benchmarks)
│   ├── BUILD_TIZEN.md          # Guide complet Samsung TV (Developer Mode, certificats, sdb)
│   └── BRANDING_BUNTU.md       # Charte graphique (palette Buntu, contraste WCAG AA, design 10-foot)
├── assets/                     # Icônes de l'application (PNG 1024x1024 et ICNS)
└── PRD/                        # 38 Spécifications techniques et index de roadmap (00_INDEX_ROADMAP.md)
```

---

## Guides Détaillés par Plateforme

Pour les instructions complètes de configuration d'environnement, d'installation de certificats et de résolution des problèmes, consultez les guides dédiés :

- 🍏 **Apple (iPhone, iPad, Mac, Apple TV)** : [`docs/BUILD_IPHONE.md`](docs/BUILD_IPHONE.md)
- 🤖 **Android (Téléphone, Tablette, Android TV)** : [`docs/BUILD_ANDROID.md`](docs/BUILD_ANDROID.md)
- 📺 **Samsung Smart TV (Tizen 3.0 à 8.0+)** : [`docs/BUILD_TIZEN.md`](docs/BUILD_TIZEN.md)
- 🎨 **Identité Visuelle & Design System** : [`docs/BRANDING_BUNTU.md`](docs/BRANDING_BUNTU.md)

---

## Emplacement des Données

| Plateforme | Base de Données | Dossier de Téléchargement | Stockage des Clés & Secrets |
| :--- | :--- | :--- | :--- |
| **macOS** | `~/Library/Application Support/CndIptvNative/cnd_iptv.db` | `~/Downloads/CndIPTV` (ou signet choisi) | Trousseau macOS (`com.cnd.iptv.credentials`) |
| **iOS / iPadOS** | Conteneur d'App (Documents) | `Documents/Downloads` (accessible via l'app Fichiers) | Trousseau iOS (Keychain Services) |
| **Android** | `data/data/com.pcoundia.buntu/databases/` | `Download/Buntu/` ou stockage scoped | Android Keystore (`AES/GCM/NoPadding`) |
| **Samsung TV** | `IndexedDB` interne (W3C Storage API) | Non applicable (streaming direct) | `tizen.preference` chiffré localement |

---

## Tests et Qualité

La qualité et l'absence de régressions sont garanties par plus de **700 tests automatisés** à travers toutes les couches de la pile :

```bash
# 1. Tests unitaires du cœur métier pur (71 tests : M3U, EPG, Sagas, Profils, Appairage, IA)
cargo test -p cnd-domain

# 2. Tests d'intégration du moteur natif (SQLite, M3U, EPG, Xtream, PVR, Synchronisation)
cargo test -p cnd-core

# 3. Tests de l'application Apple (550+ tests Swift & SwiftUI, lecteurs, coordination)
task swift:test

# 4. Tests de l'application Tizen (145 tests Vitest : AVPlay, client HTTP, télécommande)
task tizen:test

# 5. Tests Android JVM et linter
task android:test

# 6. Vérification statique globale (Clippy warnings as errors)
task lint

# 7. Validation complète avant mise en production
task check
```

---

## Licence

Ce projet est distribué sous double licence **MIT OR Apache-2.0** (voir [`Cargo.toml`](Cargo.toml)).
