# Licences des composants tiers (`THIRD_PARTY_NOTICES.md`)

Le code de Buntu est publié sous **MIT ou Apache-2.0, au choix** (voir [`LICENSE`](LICENSE)). Buntu utilise des
composants tiers qui gardent leur propre licence. Ce fichier liste les **dépendances directes** de chaque plateforme.
Les dépendances indirectes sont dans les fichiers de verrouillage (`Cargo.lock`, `tizen/package-lock.json`,
`android/gradle/libs.versions.toml`, `apple/project.yml`).

Buntu ne fournit ni chaîne, ni playlist, ni contenu vidéo, et ne contient aucun fichier de police ni de son tiers. Les icônes
(`assets/`, `tizen/public/icon.png`) sont celles du projet.

> **État de cette liste :** relevée le 2026-11-15 à partir de `cargo metadata`, des `package.json` installés de `tizen/`,
> de `android/gradle/libs.versions.toml` et de la copie locale de MPVKit. Les licences Android sont celles publiées par
> les projets amont ; elles n'ont pas été relues une par une. À refaire à chaque changement de dépendance.

---

## 1. À traiter avant de distribuer : MPVKit (LGPL-3.0), lié aux apps Apple

Les apps **macOS, iOS, tvOS et visionOS** lient **MPVKit** `1.1.0-n9.0.2` (`apple/project.yml`, produit `MPVKit`) pour lire
MKV, AVI, FLV et TS. Le dépôt MPVKit indique dans son `README.md` et son `LICENSE` que le produit `MPVKit` est sous
**GNU LGPL v3** (FFmpeg et mpv compilés sans GPL ; la variante `MPVKit-GPL` est sous GPL et **n'est pas** utilisée ici).

Ce que la LGPL-3.0 demande, la bibliothèque étant liée **statiquement** :

- **Rester sous LGPL pour MPVKit, FFmpeg et mpv** : le code de Buntu reste MIT / Apache-2.0, mais ces bibliothèques ne le
  deviennent pas.
- **Permettre de remplacer la bibliothèque** : fournir de quoi relier l'app avec une version modifiée de MPVKit (par
  exemple les sources de l'app et le projet de build, ce que ce dépôt public permet pour les builds faits par soi-même).
- **Indiquer l'usage** de ces bibliothèques et de leur licence dans l'app (page « À propos ») et dans les notes de version.
- Garder une copie du texte de la licence : <https://github.com/mpvkit/MPVKit/blob/main/LICENSE>.

**À vérifier par le mainteneur, non tranché ici :** la distribution par l'**App Store / TestFlight** (iOS, tvOS, visionOS)
avec une bibliothèque LGPL liée statiquement est un point juridique délicat, parce que les conditions de l'App Store
limitent le remplacement de la bibliothèque par l'utilisateur. Les téléchargements directs (`.dmg`, `.zip` macOS) et les
builds compilés par l'utilisateur ne posent pas ce problème de la même façon. Un avis juridique est recommandé avant toute
publication sur l'App Store.

---

## 2. Rust (`crates/`)

Dépendances directes des quatre crates (`cnd-domain`, `cnd-core`, `cnd-domain-wasm`, `cnd-cli`).

| Crate | Version | Licence |
| :--- | :--- | :--- |
| aes-gcm | 0.10.3 | Apache-2.0 OR MIT |
| async-compression | 0.4.51 | MIT OR Apache-2.0 |
| blake3 | 1.8.7 | CC0-1.0 OR Apache-2.0 OR Apache-2.0 WITH LLVM-exception |
| futures-util | 0.3.34 | MIT OR Apache-2.0 |
| hkdf | 0.12.4 | MIT OR Apache-2.0 |
| libc | 0.2.191 | MIT OR Apache-2.0 |
| qrcode | 0.14.1 | MIT OR Apache-2.0 |
| quick-xml | 0.37.5 | MIT |
| regex | 1.13.1 | MIT OR Apache-2.0 |
| reqwest | 0.12.28 | MIT OR Apache-2.0 |
| rusqlite | 0.33.0 | MIT (SQLite embarqué : domaine public) |
| serde | 1.0.229 | MIT OR Apache-2.0 |
| serde-wasm-bindgen | 0.6.5 | MIT |
| serde_json | 1.0.154 | MIT OR Apache-2.0 |
| sha2 | 0.10.9 | MIT OR Apache-2.0 |
| thiserror | 2.0.21 | MIT OR Apache-2.0 |
| tokio | 1.54.1 | MIT |
| tokio-util | 0.7.20 | MIT |
| tracing | 0.1.44 | MIT |
| tracing-subscriber | 0.3.23 | MIT |
| uniffi | 0.29.5 | **MPL-2.0** (copyleft limité aux fichiers de la bibliothèque) |
| url | 2.5.8 | MIT OR Apache-2.0 |
| wasm-bindgen | 0.2.130 | MIT OR Apache-2.0 |
| x25519-dalek | 2.0.1 | BSD-3-Clause |

Parmi les 255 paquets Rust du graphe complet : 9 sont sous MPL-2.0 et `webpki-roots` est sous CDLA-Permissive-2.0, tous
compatibles avec une distribution en binaire. Aucun n'est uniquement sous GPL ou LGPL : le seul paquet qui cite la LGPL
(`r-efi`, `MIT OR Apache-2.0 OR LGPL-2.1-or-later`) la propose en option à côté de MIT et d'Apache-2.0. Pour refaire le
relevé complet :

```bash
cargo metadata --format-version 1 | python3 -c "import json,sys; [print(p['name'], p['version'], p.get('license')) for p in json.load(sys.stdin)['packages']]"
```

---

## 3. Samsung Smart TV (`tizen/`)

| Paquet | Licence | Usage |
| :--- | :--- | :--- |
| solid-js | MIT | Interface (exécution) |
| vite, vite-plugin-solid, @vitejs/plugin-legacy | MIT | Build |
| terser | BSD-2-Clause | Build |
| typescript | Apache-2.0 | Build |
| vitest, jsdom, @types/node | MIT | Tests |

Seul `solid-js` est embarqué dans le paquet `.wgt`, avec le WebAssembly compilé depuis `crates/cnd-domain-wasm`. La lecture
vidéo passe par **AVPlay**, API de la TV soumise aux conditions du SDK Samsung (non redistribuée par Buntu).

---

## 4. Android et Android TV (`android/`)

Toutes les bibliothèques ci-dessous sont **Apache-2.0**, sauf mention contraire.

- **AndroidX** (Core, AppCompat, Activity, Lifecycle, Navigation, Paging, DataStore, WorkManager, Window, Hilt, TV, Profile
  Installer, Metrics) et **Jetpack Compose** (UI, Foundation, Material 3, icônes).
- **Media3** (ExoPlayer, HLS, DASH, session, UI) : Apache-2.0.
- **Kotlin** : kotlinx.coroutines, kotlinx.serialization, kotlinx.collections.immutable : Apache-2.0.
- **Dagger Hilt** : Apache-2.0. **Coil 3** (compose, okhttp) : Apache-2.0. **ZXing core** : Apache-2.0.
- **JNA** (liaison avec le moteur Rust) : double licence **LGPL-2.1 ou Apache-2.0** ; Buntu utilise la licence **Apache-2.0**.
- **Google Play services code scanner** (`play-services-code-scanner`, scan de QR code) : **bibliothèque propriétaire** des
  Google Play services, soumise aux conditions de Google, **pas** à une licence libre. Un build sans services Google
  (F-Droid, certains Android TV) doit remplacer ce composant.
- Tests uniquement (non livrés) : JUnit (EPL-1.0), Turbine, Espresso, UI Automator, benchmark : Apache-2.0 ou EPL-1.0.

---

## 5. Apple (`apple/`)

| Composant | Licence | Remarque |
| :--- | :--- | :--- |
| MPVKit `1.1.0-n9.0.2` | **LGPL-3.0** | Voir le point 1 ci-dessus. Embarque mpv et FFmpeg. |
| Moteur Rust (`cnd_coreFFI.xcframework`) | MIT OR Apache-2.0 + dépendances du point 2 | Compilé depuis ce dépôt, non versionné. |
| SwiftUI, AVFoundation, VideoToolbox, Keychain | Conditions Apple | Frameworks système, non redistribués. |
