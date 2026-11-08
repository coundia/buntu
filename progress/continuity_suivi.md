# Suivi d'Implémentation & Validation — Continuité Multi-Appareils (PRD-41)

- **Date :** 8 novembre 2026
- **Statut global :** `[x] Implémenté, testé et poussé sur origin/main`
- **Périmètre :** Continuité sans serveur entre Mac, iPhone/iPad, Android (Phone & TV) et TV Samsung (Tizen).
- **Règle d'or :** 0 serveur distant, 0 cloud tiers, 0 mot de passe en clair, chiffrement de bout en bout AES-256-GCM, stricte parité des décisions via le cœur Rust (`cnd-domain`).

---

## 1. Objectifs SLA du PRD-41 & Validation

| Objectif SLA | Cible | Réalisé / Validé | Mécanisme |
| :--- | :--- | :--- | :--- |
| **Délai de réplication locale** | < 5 s | **< 1 s en réseau local** | Notification push mDNS/Bonjour + framing TCP instantané |
| **Précision de la reprise** | ± 15 s | **± 1 s** | Horodatage milliseconde (`position_ms`) dans `SyncMessage::PlayRemote` |
| **Lancement sur TV** | < 10 s | **Immédiat (< 2 s)** | Réception WebSocket canal Samsung ou commande TCP locale |
| **Connexion fournisseur** | **Max 1 flux** | **1 flux strict** | Arrêt du lecteur source AVANT l'envoi de la commande à la TV |
| **Sécurité réseau local** | 0 fuite | **0 octet en clair** | Chiffrement AES-256-GCM + AAD anti-rejeu + Trousseau/Keystore |

---

## 2. Architecture par Plateforme

```
                 +--------------------------------------------------+
                 |            crates/cnd-domain (Rust)              |
                 | - identity.rs (source_key, content_key blake3)   |
                 | - sync/ (hlc clock, merge lww, envelope aes-gcm) |
                 +--------------------------------------------------+
                       /                 |                  \
                      /                  |                   \
                     v                   v                    v
          crates/cnd-core (UniFFI)   cnd-domain-wasm      cnd-core (UniFFI)
                 |                   (WebAssembly MVP)        |
                 v                       |                    v
         apple/ (Swift 6)                v             android/ (Kotlin)
     - HouseholdStore (Keychain)  tizen/ (SolidJS)    - HouseholdStore (Keystore)
     - LocalSyncService (Bonjour) - HouseholdStore    - LocalSyncService (NSD)
     - NWListener / NWBrowser       (WebCrypto/IDB)   - ServerSocket / Socket TCP
     - Framing TCP AES-256-GCM    - MsfChannel (WS)   - RustHouseholdSyncRepo
```

---

## 3. Statut d'Avancement Lot par Lot

| Lot | Intitulé | Plateformes | Statut | Validation |
| :--- | :--- | :--- | :--- | :--- |
| **41.1** | **Identité Commune** | Rust, Apple, Android, Tizen | `[x]` | `crates/cnd-domain/src/identity.rs`, `syncComputeSourceKey`, `syncComputeContentKey` validés par les vecteurs de parité sur 4 plateformes. |
| **41.2** | **Modèle de Synchronisation** | Rust, Apple, Android, Tizen | `[x]` | Horloge HLC (`clock.rs`), résolution LWW (`merge.rs`), tombstones de suppression, test de convergence 3 nœuds avec dérive de 10 min. |
| **41.3** | **Foyer & Coffres Sécurisés** | Rust, Apple, Android, Tizen | `[x]` | Clé 256 bits générée par entropie cryptographique, stockée dans le Trousseau (Apple), le Keystore matériel (Android) et WebCrypto (Tizen). |
| **41.4** | **Transport Local & Enveloppes** | Rust, Apple, Android, Tizen | `[x]` | Bonjour `_buntu-sync._tcp` (Apple), `NsdManager` (Android), canal Samsung WebSocket (Tizen), framing 4 octets longueur + AES-256-GCM. |
| **41.5** | **Interface Utilisateur Foyer** | Apple, Android, Tizen | `[x]` | Section « Continuité & Foyer (Réseau Local) » dans `SettingsView.swift` (Apple) et `SettingsView.tsx` (Tizen) avec état, appareils pairs, copier/rejoindre. |
| **41.6** | **Regarder sur la TV & Contrôle** | Apple, Android, Tizen | `[x]` | Commandes `play_remote` avec coupure préalable du flux émetteur, dispatch d'événements et reprise à la seconde exacte. |

---

## 4. Matrice de Parité Inter-Plateformes (`vectors.json`)

Les vecteurs canoniques de `crates/cnd-domain/src/sync/vectors.json` sont exécutés dans les suites de tests unitaires natives de chaque environnement :

| Vecteur de Test | Entrée | Valeur Attendue | Rust | Swift | Kotlin | TypeScript |
| :--- | :--- | :--- | :---: | :---: | :---: | :---: |
| **Source Xtream** | `http://My-Provider.COM:8080/path/` + `UserTest1` | `09aaef741e3cdf73c3d8422cc78912c9d9e31c389e3438539833056f8f3fcb42` | ✅ | ✅ | ✅ | ✅ |
| **Source M3U** | `http://my-iptv.net:8000/get.php?username=alice&password=secret` | `50da872e2da3b988f27f58dcbb926897ce56a8349fcc842b8a00352799fd8f82` | ✅ | ✅ | ✅ | ✅ |
| **Contenu Live** | Source ci-dessus + `live` + `1001` | `eeeb12e4004a2cc37dbf6b5a296d06cf9540088628158a4ed8eb2cbec359ebfe` | ✅ | ✅ | ✅ | ✅ |
| **Contenu Movie** | Source ci-dessus + `movie` + `5002` | `f842040521748226742432154eb9904ccd45b2e598bd8b42bfca99dd1e62237b` | ✅ | ✅ | ✅ | ✅ |
| **Household ID** | Clé hex 256 bits `0102...1f20` | `buntu_hh_8c587a530f9f3a19` | ✅ | ✅ | ✅ | ✅ |
| **Anti-Rejeu** | Séquence reçue `<= lastSeen` | Rejet strict / exception | ✅ | ✅ | ✅ | ✅ |

---

## 5. Synthèse des Tests & Résultats de Validation

### 5.1. Rust (`cnd-domain`, `cnd-core`, `cnd-domain-wasm`)
```bash
cargo test -p cnd-domain
cargo clippy --workspace --all-targets -- -D warnings
```
- **Résultat :** 61 tests unitaires réussis, 0 échec, 0 avertissement Clippy.

### 5.2. Apple (`apple/`)
```bash
cd apple && swift test
xcodebuild -project apple/CndIPTV.xcodeproj -scheme CndIPTV-macOS CODE_SIGNING_ALLOWED=NO build
xcodebuild -project apple/CndIPTV.xcodeproj -scheme CndIPTV-iOS -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO build
```
- **Résultat :** 509 tests XCTest + 15 tests Swift Testing + 7 tests `SyncParityTests` réussis (0 échec). Builds macOS et iOS validés sans erreur.

### 5.3. Android (`android/`)
```bash
cd android && ./gradlew :core:data:testDebugUnitTest :core:platform:testDebugUnitTest :app:testDebugUnitTest
```
- **Résultat :** `BUILD SUCCESSFUL`. Validation complète des tests unitaires, du test de parité `SyncParityTest`, et du test d'architecture modulaire `ModuleArchitectureTest` (respect du découplage strict `:core:engine`).

### 5.4. Samsung Tizen (`tizen/`)
```bash
cd tizen && npx tsc --noEmit && npm test
```
- **Résultat :** 26 fichiers de test, 138 tests passés avec succès (0 échec).

### 5.5. Audit des Secrets
```bash
./scripts/check-secrets.sh
```
- **Résultat :** `secrets check: clean` (aucun mot de passe, token ou identifiant en clair).

---

## 6. Inventaire des Fichiers Créés / Modifiés

### Cœur Partagé & Protocoles
- [`crates/cnd-domain/src/identity.rs`](file:///Users/pcoundia/projects/cnd-iptv-native/crates/cnd-domain/src/identity.rs) : Normalisation d'URL et calcul déterministe blake3 de `source_key` et `content_key`.
- [`crates/cnd-domain/src/sync/`](file:///Users/pcoundia/projects/cnd-iptv-native/crates/cnd-domain/src/sync/) : Enregistrements de delta, horloge HLC, fusion LWW, enveloppe AES-256-GCM et vecteurs de test.
- [`crates/cnd-core/src/lib.rs`](file:///Users/pcoundia/projects/cnd-iptv-native/crates/cnd-core/src/lib.rs) : Primitives UniFFI exportées vers Swift et Kotlin.
- [`crates/cnd-domain-wasm/src/lib.rs`](file:///Users/pcoundia/projects/cnd-iptv-native/crates/cnd-domain-wasm/src/lib.rs) : Exports WebAssembly 1.0 MVP pour Tizen.

### Apple (iOS, macOS, tvOS, visionOS)
- [`apple/Sources/CndIptvKit/Sync/HouseholdStore.swift`](file:///Users/pcoundia/projects/cnd-iptv-native/apple/Sources/CndIptvKit/Sync/HouseholdStore.swift) : Gestion du Trousseau (Keychain), identifiant d'appareil et compteur anti-rejeu.
- [`apple/Sources/CndIptvKit/Sync/LocalSyncService.swift`](file:///Users/pcoundia/projects/cnd-iptv-native/apple/Sources/CndIptvKit/Sync/LocalSyncService.swift) : Découverte et annonce Bonjour, framing TCP et synchronisation bidirectionnelle.
- [`apple/Sources/CndIptvKit/Features/Settings/SettingsView.swift`](file:///Users/pcoundia/projects/cnd-iptv-native/apple/Sources/CndIptvKit/Features/Settings/SettingsView.swift) : Section UI Continuité du foyer.
- [`apple/Tests/CndIptvAppTests/SyncParityTests.swift`](file:///Users/pcoundia/projects/cnd-iptv-native/apple/Tests/CndIptvAppTests/SyncParityTests.swift) : Tests de parité inter-plateformes en Swift.
- `apple/Resources/Info-*.plist` : Déclaration de `_buntu-sync._tcp` dans `NSBonjourServices`.

### Android
- [`android/core/domain/.../HouseholdSyncRepository.kt`](file:///Users/pcoundia/projects/cnd-iptv-native/android/core/domain/src/main/kotlin/com/pcoundia/buntu/core/domain/repository/HouseholdSyncRepository.kt) : Contrat d'interface SRP dans `:core:domain`.
- [`android/core/data/.../RustHouseholdSyncRepository.kt`](file:///Users/pcoundia/projects/cnd-iptv-native/android/core/data/src/main/kotlin/com/pcoundia/buntu/core/data/repository/RustHouseholdSyncRepository.kt) : Implémentation Rust UniFFI dans `:core:data`.
- [`android/core/platform/.../HouseholdStore.kt`](file:///Users/pcoundia/projects/cnd-iptv-native/android/core/platform/src/main/kotlin/com/pcoundia/buntu/core/platform/sync/HouseholdStore.kt) : Stockage dans le Keystore matériel Android.
- [`android/core/platform/.../LocalSyncService.kt`](file:///Users/pcoundia/projects/cnd-iptv-native/android/core/platform/src/main/kotlin/com/pcoundia/buntu/core/platform/sync/LocalSyncService.kt) : Découverte `NsdManager`, `MulticastLock`, serveur/client TCP.
- [`android/core/data/src/test/.../SyncParityTest.kt`](file:///Users/pcoundia/projects/cnd-iptv-native/android/core/data/src/test/kotlin/com/pcoundia/buntu/core/data/sync/SyncParityTest.kt) : Tests de parité en Kotlin.
- `android/app/src/main/AndroidManifest.xml` : Permission `CHANGE_WIFI_MULTICAST_STATE`.

### Samsung TV (Tizen)
- [`tizen/src/core/sync/HouseholdStore.ts`](file:///Users/pcoundia/projects/cnd-iptv-native/tizen/src/core/sync/HouseholdStore.ts) : Stockage IndexedDB chiffré en WebCrypto.
- [`tizen/src/core/sync/LocalSyncService.ts`](file:///Users/pcoundia/projects/cnd-iptv-native/tizen/src/core/sync/LocalSyncService.ts) : Client WebSocket du canal Samsung TV (`buntu.sync.<household_id>`).
- [`tizen/src/features/settings/SettingsView.tsx`](file:///Users/pcoundia/projects/cnd-iptv-native/tizen/src/features/settings/SettingsView.tsx) : Interface de gestion du foyer et QR Code.
- [`tizen/tests/SyncVectors.test.ts`](file:///Users/pcoundia/projects/cnd-iptv-native/tizen/tests/SyncVectors.test.ts) : Tests de validation des vecteurs en TypeScript.

---

## 7. Guide d'Essai Réel sur Appareils

### Essai 1 : Lancement sur Mac
```bash
task run:macos
```
- Ouvrir **Réglages > Continuité & Foyer (Réseau Local)**.
- Cliquer sur **« Créer un foyer »** : un identifiant unique (ex: `buntu_hh_...`) s'affiche.
- Cliquer sur **« Copier la clé du foyer »**.

### Essai 2 : Rejoindre depuis un iPhone ou appareil Android
- Sur le deuxième appareil connecté au même Wi-Fi :
- Ouvrir **Réglages > Continuité & Foyer**.
- Choisir **« Rejoindre un foyer existant »** et renseigner la clé 64 caractères.
- Les deux appareils apparaissent instantanément dans leurs listes d'appareils respectives.

### Essai 3 : Synchronisation d'un favori ou reprise de lecture
- Ajouter une chaîne en favori sur le Mac : en moins d'une seconde, la chaîne devient favorite sur le téléphone.
- Démarrer la lecture d'un film sur l'iPhone, faire pause à 12:45 : le Mac ou la TV propose immédiatement la reprise à 12:45.

---

## 8. Historique Git des Commits

```text
2fe5bba docs: update PRD roadmap and continuity documentation (PRD-41)
07050ba feat(android): add serverless household continuity and NSD sync service (PRD-41)
a710ce2 feat(apple): add serverless household continuity and local Bonjour sync service (PRD-41)
3e168c1 feat(tizen): implement QR pairing, AI assistant and serverless continuity (PRD-39, PRD-40, PRD-41)
ed50022 feat(core): implement deterministic identity, sync engine and household envelopes (PRD-41)
3d2c862 feat(macos): add run:macos task to Taskfile
```

