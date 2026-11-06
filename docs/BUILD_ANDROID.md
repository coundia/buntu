# Guide de Build & Exécution Android (Téléphone, Tablette & Android TV)

Ce document décrit comment compiler, tester, profiler et installer l'application native **Buntu** (`com.pcoundia.buntu`) pour **Android 7.0+ (`minSdk 24`)** et **Android TV / Google TV (`LEANBACK_LAUNCHER`)**, conformément au [`PRD-37`](../PRD/37_ANDROID_PHONE_AND_TV_APP.md).

---

## 1. Prérequis

- **Rust stable** (`rustup`) avec les cibles Android installées :
  ```bash
  rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
  ```
- **JDK 17+** (`java -version`).
- **Android SDK** (`compileSdk 35`) & **Android NDK r27+** (ex. `29.0.14206865` dans `$ANDROID_SDK_ROOT/ndk/`).
- Optionnel : [`go-task`](https://taskfile.dev) (`task --list`) et `adb` dans le `PATH`.

---

## 2. Architecture Modulaire en SRP (`android/`)

Un seul projet Gradle multi-modules produit les APK pour téléphone, tablette, pliable et Android TV :

| Couche | Modules | Responsabilité unique (SRP) |
| :--- | :--- | :--- |
| **Pont FFI** | `:core:engine` | Charge `libcnd_core.so` + bindings UniFFI Kotlin et expose un singleton `CndEngine` initialisé hors du thread principal. |
| **Domaine pur** | `:core:domain` | Modèles immuables, interfaces de repositories et UseCases unitaires (zéro dépendance `android.*` ni `:core:engine`). |
| **Données** | `:core:data` | Implémentations `Dispatchers.IO`, Paging 3 (`Live`, `Movies`, `Series`), `DataStore<Preferences>`, relais VOD mono-connexion (`127.0.0.1`). |
| **Lecteur** | `:core:player` | Singleton Media3 `ExoPlayer` réutilisé au zapping, `StallWatchdog` respectueux des octets reçus, backoff HTTP `429`, détection de débit insuffisant, frame-rate matching & tunneling TV. |
| **Design System** | `:core:designsystem` | Palette Buntu (contraste WCAG AA), jetons adaptatifs `BuntuMetrics` (marges overscan TV `48dp × 27dp`, cibles `48dp+`), cartes Coil 3 décodées à la taille exacte. |
| **Plateforme** | `:core:platform` | `KeystoreSecretStore` (`AES/GCM/NoPadding`), `DownloadForegroundWorker` (`dataSync` écran éteint), `EpgRefreshWorker`, `PipHelper`, Google TV `WatchNext`, serveur QR local TV, `JankStats` & logs masqués. |
| **Écrans** | `:feature:*` (13 modules) | `onboarding`, `sources`, `live`, `guide`, `movies`, `series`, `details`, `player`, `search`, `recommendations`, `downloads`, `profiles`, `settings`. Aucun module `:feature:*` ne dépend de `:core:engine` ni d'un autre `:feature:*` (vérifié par `ModuleArchitectureTest`). |
| **Assemblage** | `:app` | Hilt, Coil 3, `MobileShell` (`WindowWidthSizeClass`) & `TvShell` (navigation 10-foot télécommande + double-Retour), `StrictMode` debug, `baseline-prof.txt`. |
| **Performance** | `:benchmark` | `StartupBenchmark`, `CatalogScrollBenchmark` (`FrameTimingMetric`) & `BaselineProfileGenerator`. |

---

## 3. Commandes Rapides (`Taskfile.yml`)

Depuis la racine du dépôt :

```bash
# Lister les téléphones, tablettes, Android TV et émulateurs connectés via adb
task android:devices

# Compiler, installer l'APK correspondant à l'ABI de l'appareil et lancer Buntu
task run:android
# Cibler un appareil précis (numéro de série adb, IP:port ou modèle) :
task run:android DEVICE="SM-S908N"

# Compiler en mode Release (minifié R8), installer et lancer sur l'appareil connecté
task run:android:release

# Installer uniquement sans lancer l'application
task install:android

# Lancer en mode Salon 10-foot (Leanback) sur Android TV / Google TV
task run:android:tv

# Lancer sur l'appareil et afficher les journaux Buntu en direct (adb logcat)
task run:android:logs

# Compiler uniquement le moteur Rust (.so Android + .dylib/.so hôte JNA + bindings Kotlin UniFFI)
task android:core

# Exécuter tous les tests unitaires JVM, d'intégration FFI Rust et Lint Android
task android:test

# Assembler tous les APK Debug et Release (arm64-v8a, armeabi-v7a, x86_64 + universel)
task android:build

# Lancer les mesures Macrobenchmark sur un appareil physique Android
task android:bench
```

Sans `task`, les commandes directes équivalentes sont :

```bash
./scripts/build-android.sh
cd android
./gradlew testDebugUnitTest lintDebug
./gradlew assembleDebug assembleRelease
```

Les APK signés de release (minifiés par R8) sont générés dans `android/app/build/outputs/apk/release/`.

---

## 4. Dépannage

- **Erreur NDK introuvable :** exportez `ANDROID_SDK_ROOT="$HOME/Library/Android/sdk"` (macOS) ou `ANDROID_NDK_HOME` pointant vers un NDK `r27+`.
- **Flux IPTV en HTTP clair refusé :** vérifiez que `android/app/src/main/res/xml/network_security_config.xml` est bien référencé dans `AndroidManifest.xml` (`cleartextTrafficPermitted="true"`).
- **Erreur HTTP 429 du fournisseur :** ouvrez **Réglages → Abonnement & Affichage** et vérifiez que « Connexions simultanées autorisées » est réglé sur `1` (valeur par défaut). Buntu met alors automatiquement les téléchargements en pause pendant la lecture et fait passer la VOD par le relais mono-connexion Rust (`127.0.0.1`).

