# PRD-46 — Amélioration du lecteur Live TV (zapping, EPG, miroirs, mini-guide et confort)

| Champ | Valeur |
| :--- | :--- |
| **ID** | `PRD-46` |
| **Prérequis** | `PRD-05`, `PRD-07`, `PRD-08`, `PRD-17` (Miroirs / Failover), `PRD-24` (Timeshift Live Apple) |
| **Couches** | Apple (`CndIptvKit`), Android (`core:domain`, `core:data`, `core:player`, `feature:player`), Tizen (`AVPlayerService`, `CndEngine`, `PlayerView`) |
| **Objectifs mesurables** | 1. Zapping rapide sans HTTP `429` ni double connexion : retour HUD instantané + ouverture réseau débouclée à **250 ms**.<br>2. Zapping direct **0–9** et touche **Recall** (dernière chaîne) sur toutes les plateformes.<br>3. Barre **EPG temps réel** (`EN CE MOMENT`, progression, `À SUIVRE`) + bouton **« Revoir depuis le début » (Start-Over)** dans l'OSD Live.<br>4. Sélecteur **Qualité / Miroirs** (`4K · FHD · HD · SD`) et bascule automatique (**max 2 par session**) sur Android et Tizen (aligné sur Apple `PRD-17`).<br>5. **Mini-Guide** latéral dans le lecteur plein écran sans couper le flux + réglage **format vidéo** (`Ajuster / Remplir / Étirer`) et **minuteur de veille** (`15 / 30 / 60 / 90 min`). |

---

## 1. Contexte

Le lecteur Live TV de Buntu dispose déjà de bases solides mais asymétriques selon les plateformes :
- **Apple** possède `LiveZapper`, `failoverToMirror` (`find_mirrors`) et le timeshift local `mpv`, mais pas encore d'anti-rebond réseau au zapping, de touche *Recall* (dernière chaîne), de saisie directe par numéro (`0–9`), de barre EPG + bouton *Start-Over* directement dans l'OSD, de Mini-Guide latéral, ni de bascule format vidéo / minuteur de veille.
- **Android** dispose de `getAdjacentChannel` et `getChannelByNumber` dans `CatalogRepository`, mais le lecteur Live affiche seulement un badge `LIVE` statique sans EPG ni *Start-Over*, ne gère pas les miroirs/failover (`find_mirrors` existe côté Rust/UniFFI mais n'était pas câblé dans `feature:player`), n'a ni saisie `0–9`, ni *Recall*, ni Mini-Guide, ni format vidéo, ni minuteur de veille.
- **Tizen (Samsung)** affiche déjà `EN CE MOMENT` + `À SUIVRE` via `playerInfo.ts`, mais reconnecte uniquement la même URL sans basculer sur un miroir (`channelFamily` est déjà disponible dans `liveRecommendations.ts`), n'expose pas la saisie `0–9`, le *Recall*, le *Start-Over* catchup, le Mini-Guide en surimpression transparente au-dessus d'`AVPlay`, le ratio vidéo, ni le minuteur de veille.

Ce PRD harmonise l'expérience du lecteur Live TV sur Apple, Android et Tizen **sans modifier les signatures UniFFI existantes ni le module WASM** (tous les appels natifs nécessaires existent déjà côté Rust ou domaine TS).

---

## 2. Expérience utilisateur cible

1. **Zapping fluide et tolérant aux fournisseurs stricts (Lot 46.1) :**
   - Appuyer plusieurs fois de suite sur `CH+` / `CH-` (ou flèches/boutons Précédent-Suivant) met immédiatement à jour le nom et la cible affichée dans l'OSD, mais attend **250 ms** d'accalmie avant d'ouvrir la connexion réseau (évite les erreurs HTTP `429` et respecte la contrainte « 1 seule connexion simultanée »).
   - Un bouton et raccourci **Recall** (« Dernière chaîne ») ramène immédiatement sur la chaîne précédemment regardée.
   - Taper un numéro au clavier/télécommande (`0–9`) affiche un badge `CH 12` et zappe automatiquement après validation ou délai court (~1,2–1,4 s).

2. **EPG temps réel et Start-Over en un clic (Lot 46.2) :**
   - Pendant un direct, la barre inférieure du lecteur affiche l'émission en cours, le pourcentage de progression, le temps restant et le programme suivant (`À suivre : …`).
   - Si la chaîne supporte le catchup (`catchup_days > 0` / programme éligible) et dispose d'une émission en cours, un bouton **« Revoir depuis le début »** lance directement le flux catchup depuis le lecteur.

3. **Miroirs multi-qualité et bascule automatique (Lot 46.3) :**
   - Un menu/bouton **Qualité / Miroirs** liste les flux équivalents regroupés par nom normalisé (ex. `4K · FHD · HD · SD`) pour permettre un changement manuel instantané.
   - Sur Android et Tizen, lorsqu'un flux Live échoue ou décroche au démarrage/en lecture, le lecteur tente automatiquement jusqu'à **2 miroirs** alternatifs avant d'afficher une erreur bloquante (aligné sur Apple `PRD-17`).

4. **Mini-Guide dans le lecteur (Lot 46.4) :**
   - Depuis l'OSD plein écran (ou via la touche `GUIDE` / `INFO` / bouton Chaînes), un tiroir latéral liste les chaînes du groupe actif avec le titre EPG courant.
   - Choisir une chaîne ferme le tiroir et zappe immédiatement sans repasser par l'écran catalogue.
   - Sur **Tizen**, la zone hors du tiroir reste strictement transparente afin que la vidéo matérielle `AVPlay` reste visible derrière la page web.

5. **Confort d'écoute et de visionnage (Lot 46.5) :**
   - **Format vidéo :** bascule rapide entre `Ajuster` (`fit`), `Remplir` (`fill` — Apple/Android) et `16:9 / Étirer` (`stretch` — toutes plateformes ; sur Tizen, appliqué dans `applyDisplayArea`).
   - **Minuteur de veille :** choix `Désactivé`, `15 min`, `30 min`, `60 min`, `90 min` avec compte à rebours dans l'OSD ; à échéance, arrêt complet du flux et libération de l'unique connexion fournisseur.

---

## 3. Contraintes non négociables

1. **Une seule connexion fournisseur à la fois :** chaque zapping ou bascule de miroir ferme/remplace l'instance en cours avant d'ouvrir la suivante ; l'expiration du minuteur de veille appelle l'arrêt complet (`close` / `stop` / `stopPlayback`).
2. **Zéro régression UniFFI / WASM :** aucune modification des exports `#[uniffi::export]` ni de `cnd-domain-wasm` (réutilisation de `find_mirrors`, `get_epg_now_next`, `is_catchup_available`, `build_catchup_url`, et `channelFamily` côté Tizen).
3. **Architecture Android respectée :** aucun module `:feature:*` ne dépend de `:core:engine`.
4. **Règles Tizen Chromium 76 :** pas d'API CSS modernes non supportées (`inset`, `gap` flex, `aspect-ratio`), transparence complète sur la zone vidéo `AVPlay`.
5. **Confidentialité :** aucun identifiant, mot de passe ou URL contenant des secrets dans les journaux, tests ou bannières d'erreur.

---

## 4. Découpage en lots

| Lot | Périmètre | Détail technique |
| :--- | :--- | :--- |
| **46.1** | Zapping anti-429, Recall, saisie `0–9` | Debounce 250 ms sur `zap`/`zapAdjacentLive`/`zapChannel` ; historique `previousChannel` ; tampon numérique `0–9` + résolution `chno`. |
| **46.2** | EPG temps réel & Start-Over | Apple & Android : barre EPG (`nowTitle`, progression, `nextTitle`) + bouton « Revoir depuis le début » ; Tizen : ajout du bouton « Revoir depuis le début » via `buildCatchupUrl` en plus d'`EN CE MOMENT`/`À SUIVRE`. |
| **46.3** | Miroirs manuels & failover auto | Android (`RustCatalogRepository.findChannelMirrors` + `PlayerViewModel`) et Tizen (`CndEngine.findMirrors` + `PlayerView`) : liste `4K/FHD/HD/SD` + bascule auto max 2 par session ; Apple : exposition dans le menu Live de `CndVideoPlayerView`. |
| **46.4** | Mini-Guide overlay | Tiroir latéral de chaînes dans `CndVideoPlayerView` (Apple), `PlayerScreen` (Android) et `PlayerView` (Tizen, compatible focus télécommande). |
| **46.5** | Format vidéo & Minuteur de veille | Apple (`CndPlayerController` + backends AVPlayer/mpv), Android (`VideoEngine` + `ExoPlayerVideoEngine` + `BuntuVideoSurface`), Tizen (`AVPlayerService` + `PlayerView`). |

---

## 5. Fichiers concernés

- **Apple :**
  - `apple/Sources/CndIptvKit/Features/LiveTV/LiveZapper.swift`
  - `apple/Sources/CndIptvKit/Player/VideoBackendProtocol.swift`
  - `apple/Sources/CndIptvKit/Player/AVPlayerBackend.swift`
  - `apple/Sources/CndIptvKit/Player/MpvVideoToolboxBackend.swift`
  - `apple/Sources/CndIptvKit/Player/CndPlayerController.swift`
  - `apple/Sources/CndIptvKit/Player/CndVideoPlayerView.swift`
  - `apple/Sources/CndIptvKit/App/AppShellView.swift`
  - `apple/Tests/CndIptvAppTests/CndPlayerTests.swift`
- **Android :**
  - `android/core/domain/src/main/kotlin/com/pcoundia/buntu/core/domain/repository/Repositories.kt`
  - `android/core/data/src/main/kotlin/com/pcoundia/buntu/core/data/repository/RustCatalogRepository.kt`
  - `android/core/player/src/main/kotlin/com/pcoundia/buntu/core/player/VideoEngine.kt`
  - `android/core/player/src/main/kotlin/com/pcoundia/buntu/core/player/ExoPlayerVideoEngine.kt`
  - `android/core/player/src/main/kotlin/com/pcoundia/buntu/core/player/BuntuVideoSurface.kt`
  - `android/feature/player/src/main/kotlin/com/pcoundia/buntu/feature/player/PlayerViewModel.kt`
  - `android/feature/player/src/main/kotlin/com/pcoundia/buntu/feature/player/PlayerScreen.kt`
  - `android/feature/player/src/test/kotlin/com/pcoundia/buntu/feature/player/PlayerViewModelTest.kt`
- **Tizen :**
  - `tizen/src/core/player/AVPlayerService.ts`
  - `tizen/src/core/engine/livePlayerHelpers.ts`
  - `tizen/src/core/engine/CndEngine.ts`
  - `tizen/src/app/App.tsx`
  - `tizen/src/ui/design/theme.css`
  - `tizen/src/features/player/PlayerView.tsx`
  - `tizen/tests/AVPlayerService.test.ts`
  - `tizen/tests/Zapping.test.ts`

---

## 6. Critères d'acceptation et vérification

- [x] Tests unitaires ciblés Apple (`cd apple && swift test --filter CndPlayerTests`) verts : 24/24 tests passés.
- [x] Tests unitaires Android (`cd android && ./gradlew --offline :core:domain:test :core:data:testDebugUnitTest :core:player:testDebugUnitTest :feature:player:testDebugUnitTest --console=plain`) verts (`BUILD SUCCESSFUL`).
- [x] Contrôle TypeScript (`cd tizen && npx tsc --noEmit`) vert et tests ciblés lecteur/zapping (`tests/PlayerNextShelf.test.ts`, `tests/UpNextCountdown.test.ts`, `tests/AVPlayerService.test.ts`, `tests/Zapping.test.ts`) verts (24/24). Sur la suite complète `npm test`, 61/62 fichiers (344/345 tests) passent ; le seul échec observé est `tests/AiKeyStore.test.ts` (`migrates the old encrypted slot only to the selected provider`), hors périmètre PRD-46 et non modifié ici.
- [x] Mention honnête dans le statut : vérifié par tests unitaires ciblés uniquement ; non essayé sur appareils réels (Mac/iPhone/Apple TV, Android/Android TV, Samsung TV), et builds d'application laissés à l'utilisateur (`AGENTS.md § 2`).

---

## 7. Statut d'implémentation

- **État :** Implémenté (`[x]`, lots 46.1 à 46.5 sur Apple, Android et Tizen), non essayé sur appareil réel.
- **Apple (`CndIptvKit`) :** `swift test --filter CndPlayerTests` → 24 tests exécutés, 0 échec. Non essayé à l'écran ; builds `xcodebuild` non lancés (`AGENTS.md`).
- **Android (`core:domain`, `core:data`, `core:player`, `feature:player`) :** `./gradlew --offline :core:domain:test :core:data:testDebugUnitTest :core:player:testDebugUnitTest :feature:player:testDebugUnitTest --console=plain` → `BUILD SUCCESSFUL`. Non essayé sur téléphone/Android TV ; APK non assemblé.
- **Tizen (`tizen/`) :** `npx tsc --noEmit` OK ; `vitest` 24/24 sur `AVPlayerService`, `Zapping`, `PlayerNextShelf`, `UpNextCountdown` ; 61/62 fichiers (344/345 tests) sur `npm test` (seul `AiKeyStore.test.ts` échoue hors périmètre). Non essayé sur la TV Samsung (`build-tizen.sh` / `run-tizen.sh` non lancés).
