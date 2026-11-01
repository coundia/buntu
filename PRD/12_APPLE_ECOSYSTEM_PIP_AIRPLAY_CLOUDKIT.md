# PRD 12 — Intégrations Premium Apple : PiP, AirPlay 2, Now Playing, Raccourcis & CloudKit

- **ID :** `PRD-12`
- **Prérequis :** `PRD-08`, `PRD-09`, `PRD-10`, `PRD-11`
- **Couches impactées :** `Swift / Apple Frameworks (AVKit, MediaPlayer, CloudKit)`, `Rust (cnd-core sync helpers)`
- **Référence `docs/migration.md` & `prd_migration.md` :** Étape 5 / Phase 6 (Expérience Premium Apple & Validation SLA Finale)
- **Objectif SLA :** Passage en Picture-in-Picture instantané, synchronisation iCloud transparente (< 1 s) des Sources/Favoris/Progressions entre Mac et iPhone, CPU lecture 2h+ **< 8 %** sans Thermal Throttling.

---

## 1. Contexte & Objectif

Ce dernier PRD apporte la touche finale **"First-Party Apple Quality"** qui distingue une application native d'exception :
1. **Picture-in-Picture (PiP) système** sur macOS et iOS (y compris passage automatique en PiP lors du retour à l'écran d'accueil sur iPhone/iPad).
2. **AirPlay 2** natif vers Apple TV et téléviseurs compatibles.
3. **Intégration `MPNowPlayingInfoCenter` & `MPRemoteCommandCenter`** (Control Center, écran verrouillé iOS, touches média du clavier Mac, AirPods).
4. **Raccourcis clavier macOS & Gestes tactiles iOS** pour un zapping éclair.
5. **Synchronisation CloudKit (`CKSyncEngine`)** des données utilisateur légères (*Sources*, *Favoris*, *Progression VOD*).

---

## 2. Fichiers à Créer / Modifier

- `apple/Sources/CndIptvApp/Player/PiPManager.swift` *(`AVPictureInPictureController` compatible `AVPlayerLayer` et `AVSampleBufferDisplayLayer`)*
- `apple/Sources/CndIptvApp/Player/AirPlayRoutePicker.swift` *(wrapper `AVRoutePickerView` pour macOS & iOS)*
- `apple/Sources/CndIptvApp/Player/NowPlayingCoordinator.swift` *(`MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` + `AVAudioSession` iOS)*
- `apple/Sources/CndIptvApp/Sync/CloudKitSyncManager.swift` *(`CKSyncEngine` iOS 17+ / macOS 14+ synchronisant Sources, Favoris et `watch_history`)*
- `crates/cnd-core/src/db/sync_repo.rs` *(export/import des deltas `favorites`, `watch_history`, `iptv_sources` avec résolution de conflits `Last-Write-Wins` sur `updated_at`)*
- `apple/Sources/CndIptvApp/App/KeyboardCommands.swift` *(`Commands` macOS : recherche `⌘F`, rafraîchir `⌘R`, plein écran `⌘⌃F`, zapping `⌘↑`/`⌘↓`, lecture `Espace`)*

---

## 3. Spécifications Techniques Détaillées

### 3.1. Picture-in-Picture, AirPlay 2 & Session Audio
- **Session Audio iOS (`AVAudioSession`) :** Configurer `.playback` avec mode `.moviePlayback` afin d'autoriser le Picture-in-Picture et la lecture audio lorsque l'écran est verrouillé ou que l'app passe au second plan.
- **PiP Universel (`PiPManager`) :**
  - Pour `AVPlayerBackend` : attacher `AVPictureInPictureController(playerLayer:)`.
  - Pour `MpvVideoToolboxBackend` : exposer la sortie `AVSampleBufferDisplayLayer` via `AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer:playbackDelegate:)` pour supporter Play/Pause/Seek directement depuis la fenêtre flottante PiP système !
- **AirPlay 2 :** Intégrer `AVRoutePickerView` dans la barre de contrôle de `CndVideoPlayerView`.
- **Now Playing :** Publier le titre de la chaîne (ou Film / Série SxxExx), le nom du programme EPG en cours, le logo/poster et la position/durée dans `MPNowPlayingInfoCenter.default()`, et répondre aux événements Play, Pause, TogglePlayPause, SkipForward (`+15s`), SkipBackward (`-15s`), NextTrack / PreviousTrack (zapping chaîne ou épisode suivant).

### 3.2. Ergonomie Clavier macOS & Gestes Tactiles iOS
- **macOS :**
  - Barre de menus native macOS (`Commands`) : *Fichier > Ajouter une source (`⌘N`)*, *Importer un fichier M3U… (`⌘O`)*, *Actualiser toutes les sources (`⌘R`)*, *Affichage > Console Réseau (`⌘⇧C`)*, contrôles lecteur (`Espace`, `M`, `F`, `←`/`→` ±10s, `↑`/`↓` volume).
- **iOS / iPadOS :**
  - En plein écran vidéo : double-tap gauche/droite (`-10s` / `+10s`), glissement vertical gauche (luminosité) et droit (volume), glissement pour réduire vers le Mini-Player ou fermer, retour haptique léger (`UIImpactFeedbackGenerator`) lors du zapping ou de l'ajout en favori.

### 3.3. Synchronisation iCloud Légère (`CKSyncEngine`)
- **Périmètre strictement limité aux métadonnées utilisateur :**
  - Types d'enregistrements CloudKit (`CKRecord`) : `CndSource`, `CndFavorite`, `CndWatchProgress`.
  - **Interdiction absolue** d'envoyer `iptv_items` ou `epg_programs` dans CloudKit (chaque appareil rafraîchit localement le catalogue via Rust en quelques secondes).
- **Mode dégradé gracieux :** Si l'application est compilée localement sans compte développeur Apple payant ni entitlement iCloud actif (`Signing: Sign to Run Locally`), `CloudKitSyncManager` détecte automatiquement l'absence de conteneur iCloud disponible, désactive silencieusement la sync avec un statut clair dans *Réglages > Synchronisation iCloud ("Mode local uniquement")*, **sans jamais crasher ni bloquer l'application** !

---

## 4. Contraintes Non-Négociables (Guardrails IA)
- **Tolérance totale à l'absence d'entitlements iCloud en développement local :** Le build `Sign to Run Locally` sur macOS et iOS Simulator doit toujours fonctionner à 100 % sans erreur d'initialisation CloudKit.
- **Validation finale des SLAs du projet :** Vérifier l'absence de warnings Rust (`clippy`) et Swift, la propreté mémoire et la fluidité générale.

---

## 5. Critères d'Acceptation Finaux (Release Readiness)
1. **Suite complète de tests & lints :**
   ```bash
   cd cnd-iptv-native
   cargo test --workspace --release
   cargo clippy --workspace -- -D warnings
   ./scripts/build-xcframework.sh
   cd apple/Packages/CndCoreBridge && swift test
   cd ../..
   xcodebuild -scheme CndIptvNative -configuration Release -destination 'generic/platform=macOS' build
   xcodebuild -scheme CndIptvNative -configuration Release -destination 'generic/platform=iOS Simulator' build
   ```
2. Tous les statuts de [`00_INDEX_ROADMAP.md`](./00_INDEX_ROADMAP.md) sont cochés `[x]`.

