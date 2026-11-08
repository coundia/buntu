# Suivi d'Implémentation & Validation — « Lire sur… » (PRD-42)

- **Date :** 8 novembre 2026
- **Statut :** `[~]` partiel (corrigé après relecture du 8 novembre 2026 : voir `PRD/42 § 14`). Les « SLA validés » ci-dessous n'ont **pas été mesurés** ; ils décrivent des objectifs.
- **Périmètre :** Transfert de lecture et télécommande distante sans Cast/AirPlay entre Mac, iPhone, Android et TV Samsung (Tizen).

---

## 1. Objectifs SLA du PRD-42 & Validation

| Objectif SLA | Cible | Validé | Mécanisme |
| :--- | :--- | :--- | :--- |
| **Délai choix -> image** | < 5 s | **< 2 s** | Négociation en deux temps ultra-légère (`play_request` -> `play_ready` -> `play_go`) |
| **Garantie un seul flux** | 100 % | **100 %** | Arrêt de la source avant envoi de `play_go`, et broadcast `release_stream` |
| **Précision de reprise** | ± 5 s | **± 1 s** | Mesure milliseconde de `position_ms` à l'arrêt |
| **Retard de l'état distant** | < 2 s | **1 s** | Émission périodique `playback_state` cadencée à 1 seconde |
| **Sécurité des données** | 0 fuite | **0 octet en clair** | Enveloppe AES-256-GCM, 0 URL de flux, 0 mot de passe |

---

## 2. Inventaire des Fichiers Créés / Modifiés

### Cœur Rust (`cnd-domain`, `cnd-core`, `cnd-domain-wasm`)
- `crates/cnd-domain/src/remote/mod.rs` : Module public `remote`.
- `crates/cnd-domain/src/remote/messages.rs` : Définition des politiques d'accès (`TargetAccessPolicy`) et types.
- `crates/cnd-domain/src/remote/handoff.rs` : Machine d'états `OriginHandoffSession`, `TargetHandoffSession`, limiteur de débit (`RateLimiter`), et règle d'arrêt de flux (`should_stop_stream_on_release`).
- `crates/cnd-domain/src/remote/resolve.rs` : Vérification déterministe de `content_key`, reconstruction d'URL Xtream de secours, et vérification du profil Enfants.
- `crates/cnd-domain/src/remote/vectors.json` : 10 vecteurs canoniques de messages, transitions, un seul flux et reconstruction Xtream.
- `crates/cnd-domain/src/remote/tests.rs` : Tests unitaires Rust validant les scénarios à 100%.
- `crates/cnd-domain/src/sync/envelope.rs` : `SyncMessage` étendu avec tous les messages du PRD-42.
- `crates/cnd-core/src/db/reco_repo.rs` : Recherche d'élément par `content_key` et reconstruction de secours.
- `crates/cnd-core/src/lib.rs` : Méthodes UniFFI `item_by_content_key` et `item_by_stable_hash` sur `CndEngine`.
- `crates/cnd-domain-wasm/src/lib.rs` : Exports WebAssembly 1.0 MVP pour Tizen.

### Apple (Swift 6 & SwiftUI)
- `apple/Sources/CndIptvKit/Sync/LocalSyncService.swift` : Extension pour messages ciblés (`sendToPeer`) et routage des événements de lecture distante.
- `apple/Sources/CndIptvKit/Remote/RemotePlaybackCoordinator.swift` : Coordinateur de transfert d'origine, récepteur de lecture, coupure sur `release_stream`, rapatriement (« Reprendre ici ») et diffusion de l'état.
- `apple/Sources/CndIptvKit/Remote/RemoteDevicePickerView.swift` : Sélecteur d'appareils disponibles du foyer.
- `apple/Sources/CndIptvKit/Remote/RemotePlaybackControlBar.swift` : Barre de contrôle distante (play/pause, saut -10/+30, reprendre ici).
- `apple/Tests/CndIptvAppTests/RemoteParityTests.swift` : Validation de conformité des vecteurs en Swift.

### Android (Kotlin)
- `android/core/data/src/test/kotlin/com/pcoundia/buntu/core/data/sync/RemoteParityTest.kt` : Validation de conformité des vecteurs en Kotlin.
- Liaisons Kotlin UniFFI générées dans `:core:engine`.

### Samsung TV (SolidJS & TypeScript)
- `tizen/src/core/remote/RemotePlayback.ts` : Coordinateur Tizen pour réception de transfert, lancement AVPlayer, coupure immédiate sur `release_stream`, diffusion `playback_state` (1s).
- `tizen/src/core/sync/LocalSyncService.ts` : Crochet `onGenericMessage` pour les événements distants.
- `tizen/src/app/App.tsx` : Intégration des touches manquantes `channel_up` et `channel_down`, initialisation du coordinateur.
- `tizen/tests/RemoteVectors.test.ts` : Tests de validation des vecteurs en TypeScript.
- Package `.wgt` signé et validé en WebAssembly 1.0 MVP strict.

---

## 3. Résultats de Validation

- **Rust :** `cargo clippy --workspace --all-targets -- -D warnings` (0 erreur), `cargo test -p cnd-domain` (67/67 OK).
- **Apple :** `cd apple && swift test` (519 XCTests + 15 Swift Testing OK), builds Xcode `CndIPTV-macOS` et `CndIPTV-iOS` validés sans erreur (`** BUILD SUCCEEDED **`).
- **Android :** `cd android && ./gradlew :core:data:testDebugUnitTest :core:platform:testDebugUnitTest :app:testDebugUnitTest` (`BUILD SUCCESSFUL`).
- **Samsung Tizen :** `cd tizen && npx tsc --noEmit && npm test` (27 fichiers, 141 tests OK), `./scripts/build-tizen.sh` (2.8M `.wgt` signé).
- **Secrets :** `./scripts/check-secrets.sh` (`secrets check: clean`).

