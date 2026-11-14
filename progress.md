# Suivi des tâches des agents IA (`progress.md`)

Ce fichier dit, à tout moment, **ce que les agents IA font dans ce dépôt et où ils en sont**. Plusieurs agents travaillent souvent en même temps (`AGENTS.md § 2.1`) : chacun tient ici ses propres tâches, pour que l'utilisateur et les autres agents sachent ce qui est en cours, fini ou en échec.

## Règles

- **Une section par chantier**, avec la date et l'agent ou la session (« Claude, alignement Android »). On ajoute en haut ; on ne modifie pas la section d'un autre agent.
- **Chaque tâche a un état** :
  - ⏳ en cours ;
  - ✅ terminé ;
  - ❌ échec ;
  - ⏸️ en attente de l'utilisateur ;
  - 🚫 abandonné.

  Une tâche en échec dit pourquoi, en une phrase.
- **Les tâches de fond comptent aussi** : tests, builds, scripts lancés en arrière-plan. Les noter quand on les lance, puis mettre à jour leur état **dès qu'elles se terminent**.
- **Prévenir l'utilisateur** à chaque fin de tâche, réussie ou non, dans la conversation, avec le résultat : « Terminé : tests `:feature:player`, 8/8 ». Ne jamais laisser une tâche se finir en silence.
- **Distinguer vérifié et non vérifié** : « testé unitairement », « compilé », « non essayé sur l'appareil ».
- **Jamais de secret** : ni identifiant, ni mot de passe, ni clé, ni URL de flux.
- Quand un chantier est fini et commité, le résumer en quelques lignes ou le retirer. Le détail durable va dans le PRD concerné ou dans `reprise.md`.

---

## 2026-11-14 — Antigravity, Constantes version & build sur toutes les apps

- ✅ **Apple** : constantes `AppBrand.appVersion` (`"1.0.0"`) et `AppBrand.appBuild` (`"1"`) dans [`AppBrand.swift`](apple/Sources/CndIptvKit/Shared/Design/AppBrand.swift) ; `SettingsModel.appVersion` dans [`SettingsModel.swift`](apple/Sources/CndIptvKit/Features/Settings/SettingsModel.swift) utilise ces constantes en repli et formate `version (build X)` ; assertions ajoutées dans [`AppBrandTests.swift`](apple/Tests/CndIptvAppTests/AppBrandTests.swift).
- ✅ **Android** : constantes `BuntuAboutInfo.APP_VERSION` (`"1.0.0"`) et `BuntuAboutInfo.APP_BUILD` (`"1"`) et affichage `Version : 1.0.0 (build 1)` dans [`SettingsScreen.kt`](android/feature/settings/src/main/kotlin/com/pcoundia/buntu/feature/settings/SettingsScreen.kt) ; assertions dans [`SettingsViewModelTest.kt`](android/feature/settings/src/test/kotlin/com/pcoundia/buntu/feature/settings/SettingsViewModelTest.kt).
- ✅ **Tizen** : constantes `APP_VERSION`, `APP_BUILD` et `APP_VERSION_LABEL` dans [`appInfo.ts`](tizen/src/core/appInfo.ts), affichées dans [`SettingsView.tsx`](tizen/src/features/settings/SettingsView.tsx) ; test ajouté dans [`TizenNiceToHave.test.ts`](tizen/tests/TizenNiceToHave.test.ts).
- ✅ **Tests** : `AppBrandTests` (Apple) → **7/7 passés** ; `:feature:settings:testDebugUnitTest` (Android) → **BUILD SUCCESSFUL** ; `tsc --noEmit` + `TizenNiceToHave.test.ts` (Tizen) → **9/9 passés** (0 échec).

---

## 2026-11-14 — Antigravity, Bouton Actualiser dans Foyer & Commande TV

- ✅ **Apple** : ajout de `refreshPeers()` dans [`LocalSyncService.swift`](apple/Sources/CndIptvKit/Sync/LocalSyncService.swift) (relance Bonjour + Samsung transport + heartbeat) et du bouton « Actualiser » dans les en-têtes « Appareils du foyer » et « Appareils connectés » de [`HouseholdView.swift`](apple/Sources/CndIptvKit/Features/Household/HouseholdView.swift).
- ✅ **Android** : ajout de `refreshPeers()` dans [`HouseholdRepository.kt`](android/core/domain/src/main/kotlin/com/pcoundia/buntu/core/domain/repository/HouseholdRepository.kt), [`LocalSyncService.kt`](android/core/platform/src/main/kotlin/com/pcoundia/buntu/core/platform/sync/LocalSyncService.kt) (relance NSD + heartbeat) et [`DevicesViewModel.kt`](android/feature/devices/src/main/kotlin/com/pcoundia/buntu/feature/devices/DevicesViewModel.kt) ; bouton « Actualiser » ajouté dans « Appareils découverts » et « Appareil cible » de [`DevicesScreen.kt`](android/feature/devices/src/main/kotlin/com/pcoundia/buntu/feature/devices/DevicesScreen.kt) ; test `refreshPeersCallsRepository` dans [`DevicesViewModelTest.kt`](android/feature/devices/src/test/kotlin/com/pcoundia/buntu/feature/devices/DevicesViewModelTest.kt).
- ✅ **Tests** : `swift test --filter "SamsungChannelTransportTests|PromptSearchTests"` (Apple) → **19/19 passés** (0 échec) ; `./gradlew --offline :core:domain:test :core:platform:testDebugUnitTest :feature:devices:testDebugUnitTest` (Android) → **BUILD SUCCESSFUL**.
- ⏸️ **À faire par l’utilisateur** : recompiler les apps Apple (`CndIPTV-macOS` / `iOS`) et Android (`assembleDebug`) ; non testé à l’écran sur les appareils physiques.

---

## 2026-11-14 — Antigravity, Réception `remote_text` côté Apple (macOS/iOS/tvOS)

- ✅ **Apple (`LocalSyncService` + `AppShellView` + `AssistantModel`)** : ajout de `onRemoteText`, du `case "remote_text":` et du helper `shouldAcceptRemoteText(_:localDeviceId:)` dans [`LocalSyncService.swift`](apple/Sources/CndIptvKit/Sync/LocalSyncService.swift) (filtrage optionnel sur `target_device_id`, trim et rejet des textes vides) ; branchement de `state.localSync?.onRemoteText` dans [`AppShellView.swift`](apple/Sources/CndIptvKit/App/AppShellView.swift) vers `openAssistant(startingWith: text, scope: .all)` puis `await assistant.submit(autoPlayFirstHit: true)` ; ajout de `autoPlayFirstHit` dans [`AssistantModel.swift`](apple/Sources/CndIptvKit/Features/Assistant/AssistantModel.swift) pour lancer le premier résultat lorsqu'un fournisseur IA est indisponible (ex. HTTP 503) et bascule sur la recherche locale.
- ✅ **Tests unitaires** : `swift test --filter "PromptSearchTests|SamsungChannelTransportTests"` → **19/19 passés** (`PromptSearchTests` 10/10, `SamsungChannelTransportTests` 9/9, 0 échec).
- ⏸️ **À faire par l’utilisateur** : recompiler l'app macOS/iOS via Xcode (`xcodebuild` / `CndIPTV-macOS`), puis retester l'envoi de « Mets France 2 » depuis Android vers macOS (non testé à l'écran sur Mac + Android physiques).

---

## 2026-11-14 — Antigravity (Swarm), Écran Commande TV dédié + ciblage appareil foyer

- ✅ **Tizen (`tizen-remote-target`)** : filtrage de `remote_text` par `target_device_id` dans [`LocalSyncService.ts`](tizen/src/core/sync/LocalSyncService.ts) (ignore si `target_device_id` non vide et différent de `getLocalDeviceId()`, conserve la diffusion si absent/vide) ; test unitaire ajouté dans [`TizenNiceToHave.test.ts`](tizen/tests/TizenNiceToHave.test.ts).
- ✅ **Apple (`apple-remote-cmd`)** : `remoteTextPayload(_:targetDeviceId:)` et `sendRemoteText(_:targetPeerId:)` dans [`LocalSyncService.swift`](apple/Sources/CndIptvKit/Sync/LocalSyncService.swift) (routage ciblé `sendToPeer` ou diffusion `broadcastMessage`) ; `RemoteCommandTargetResolver` (sélection auto si 1 appareil connecté, « Tous » si >1) et écran dédié `#if !os(tvOS) RemoteCommandView` dans [`HouseholdView.swift`](apple/Sources/CndIptvKit/Features/Household/HouseholdView.swift) ; onglet/entrée de menu `remoteCommand` (« Commande TV », `mic.fill`) dans [`AppShellView.swift`](apple/Sources/CndIptvKit/App/AppShellView.swift) ; tests dans [`SamsungChannelTransportTests.swift`](apple/Tests/CndIptvAppTests/SamsungChannelTransportTests.swift). Aucun nouveau `.swift`.
- ✅ **Android (`android-remote-cmd`)** : contrat `sendRemoteText(text, targetPeerId)` dans [`HouseholdRepository.kt`](android/core/domain/src/main/kotlin/com/pcoundia/buntu/core/domain/repository/HouseholdRepository.kt) et implémentation dans [`LocalSyncService.kt`](android/core/platform/src/main/kotlin/com/pcoundia/buntu/core/platform/sync/LocalSyncService.kt) ; `connectedPeers`, `selectedTargetId` (sélection auto si 1 connecté, `null` = tous si >1) et `selectTargetDevice` dans [`DevicesViewModel.kt`](android/feature/devices/src/main/kotlin/com/pcoundia/buntu/feature/devices/DevicesViewModel.kt) ; écran accessible `RemoteCommandRoute` (dictée `RecognizerIntent.ACTION_RECOGNIZE_SPEECH`, puces rapides, sélection d'appareil) dans [`DevicesScreen.kt`](android/feature/devices/src/main/kotlin/com/pcoundia/buntu/feature/devices/DevicesScreen.kt) ; route `BuntuRoutes.REMOTE_COMMAND` et entrée menu « Commande TV » dans [`BuntuRoutes.kt`](android/app/src/main/kotlin/com/pcoundia/buntu/navigation/BuntuRoutes.kt), [`BuntuNavHost.kt`](android/app/src/main/kotlin/com/pcoundia/buntu/navigation/BuntuNavHost.kt), [`MobileShell.kt`](android/app/src/main/kotlin/com/pcoundia/buntu/ui/MobileShell.kt) et [`SettingsScreen.kt`](android/feature/settings/src/main/kotlin/com/pcoundia/buntu/feature/settings/SettingsScreen.kt) ; tests dans [`DevicesViewModelTest.kt`](android/feature/devices/src/test/kotlin/com/pcoundia/buntu/feature/devices/DevicesViewModelTest.kt).
- ✅ **Vérification (`verifier-3`)** :
  - `./scripts/check-secrets.sh` → `secrets check: clean`
  - Tizen : `npx tsc --noEmit` (0 erreur, code Chromium 56–76 sûr) ; `npx vitest run tests/TizenNiceToHave.test.ts tests/HomeNavigation.test.ts tests/NoUselessIcons.test.ts` → 3/3 fichiers, 25/25 tests passés (suite complète `npm test` : 63/64 fichiers, 367/368 tests passés, 1 échec préexistant hors périmètre dans `tests/AiKeyStore.test.ts`).
  - Apple : `swift test` → `CndIptvAppTests.xctest` : 565 exécutés, 2 ignorés, 0 échec + Swift Testing : 15/15 tests dans 5 suites passés.
  - Android : `./gradlew --offline :core:domain:test :core:platform:testDebugUnitTest :feature:devices:testDebugUnitTest :app:testDebugUnitTest --console=plain` → `BUILD SUCCESSFUL` ; `:app:testDebugUnitTest --tests com.pcoundia.buntu.ModuleArchitectureTest --rerun-tasks --console=plain` → `BUILD SUCCESSFUL in 22s` (357/357 tasks executed).
- ⏸️ **À faire par l’utilisateur** : `./scripts/build-tizen.sh` + `./scripts/run-tizen.sh <IP_TV>`, `xcodebuild` (Apple) et `./gradlew assembleDebug` (Android) ; non testé à l’écran sur TV Samsung, iPhone/Mac ni téléphone Android physiques.

---

## 2026-11-14 — Antigravity (Swarm), Dictée vocale / IME Samsung & RemoteText téléphone → TV

- ✅ **Tizen (`tizen-voice`)** : champ réel `#assistant-ime-input` + `#btn-assistant-submit`, prop `initialPhrase` et abonnement `onRemoteText` dans [`AssistantModal.tsx`](tizen/src/features/assistant/AssistantModal.tsx) ; routage `onRemoteText` dans [`App.tsx`](tizen/src/app/App.tsx) ; champ réel `#search-ime-input` dans [`SearchView.tsx`](tizen/src/features/search/SearchView.tsx) ; transmission `ENTER` (`13`) et Samsung IME Done (`65376`) au champ focalisé dans [`RemoteKeyHandler.ts`](tizen/src/core/input/RemoteKeyHandler.ts) ; tests dans [`TizenNiceToHave.test.ts`](tizen/tests/TizenNiceToHave.test.ts).
- ✅ **Apple (`apple-voice`)** : `remoteTextPayload` / `sendRemoteText` (`type: "remote_text"`) dans [`LocalSyncService.swift`](apple/Sources/CndIptvKit/Sync/LocalSyncService.swift) ; section « Commande vocale / texte vers la TV » (`#if !os(tvOS)`) dans [`HouseholdView.swift`](apple/Sources/CndIptvKit/Features/Household/HouseholdView.swift) ; tests dans [`SamsungChannelTransportTests.swift`](apple/Tests/CndIptvAppTests/SamsungChannelTransportTests.swift). Aucun nouveau `.swift`.
- ✅ **Android (`android-voice`)** : contrat `sendRemoteText` dans [`HouseholdRepository.kt`](android/core/domain/src/main/kotlin/com/pcoundia/buntu/core/domain/repository/HouseholdRepository.kt) et implémentation dans [`LocalSyncService.kt`](android/core/platform/src/main/kotlin/com/pcoundia/buntu/core/platform/sync/LocalSyncService.kt) ; `sendRemoteText` dans [`DevicesViewModel.kt`](android/feature/devices/src/main/kotlin/com/pcoundia/buntu/feature/devices/DevicesViewModel.kt) ; section « Commande vocale / texte vers la TV » + `RecognizerIntent.ACTION_RECOGNIZE_SPEECH` (`fr-FR`, repli `ActivityNotFoundException`) dans [`DevicesScreen.kt`](android/feature/devices/src/main/kotlin/com/pcoundia/buntu/feature/devices/DevicesScreen.kt) ; tests dans [`DevicesViewModelTest.kt`](android/feature/devices/src/test/kotlin/com/pcoundia/buntu/feature/devices/DevicesViewModelTest.kt). Architecture sans `:core:engine` respectée.
- ✅ **Vérification (`verifier-2`)** :
  - `./scripts/check-secrets.sh` → `secrets check: clean`
  - Tizen : `npx tsc --noEmit` (0 erreur) ; `vitest run` (8 fichiers ciblés : `TizenNiceToHave`, `HomeNavigation`, `NoUselessIcons`, `SearchEngineButton`, `RemoteKeyHandler`, `TvKeyboard`, `SearchMode`, `Search` → 60/60 tests passés ; + `AssistantSettings`, `UiSounds`, `PairingView` → 3/3 fichiers, 13/13 tests passés)
  - Apple : `swift test --filter SamsungChannelTransportTests` → 6/6 tests passés (0 échec)
  - Android : `./gradlew --offline :core:domain:test :core:platform:testDebugUnitTest :feature:devices:testDebugUnitTest :app:testDebugUnitTest --rerun-tasks --console=plain` → `BUILD SUCCESSFUL in 24s` (375 tasks executed ; 50/50 tests sur ces 4 modules, dont `:feature:devices` 7/7 et `ModuleArchitectureTest` 2/2)
- ⏸️ **À faire par l’utilisateur** : `./scripts/build-tizen.sh` + `./scripts/run-tizen.sh <IP_TV>`, `xcodebuild` (Apple) et `./gradlew assembleDebug` (Android) ; non testé à l’écran ni au micro sur TV Samsung, iPhone ou téléphone Android physiques.

## 2026-11-14 — Antigravity, Nice-to-have Tizen (Passer l'intro, Écran noir, Sous-titres, Jauge Xtream)

- ✅ **Passer l'intro (+85 s)** dans l'OSD VOD/Séries (`#btn-osd-skip-intro` → `seekDelta(85000)`) : [`tizen/src/features/player/PlayerView.tsx`](tizen/src/features/player/PlayerView.tsx).
- ✅ **Mode audio uniquement / écran noir** (`#btn-osd-audio-only`, `#audio-only-curtain` dans [`theme.css`](tizen/src/ui/design/theme.css)) réveillé par OK / Retour / flèches : [`tizen/src/features/player/PlayerView.tsx`](tizen/src/features/player/PlayerView.tsx).
- ✅ **Sous-titres personnalisables** (taille, couleur, fond opaque) : [`tizen/src/core/player/subtitlePrefs.ts`](tizen/src/core/player/subtitlePrefs.ts), [`SettingsView.tsx`](tizen/src/features/settings/SettingsView.tsx), [`PlayerView.tsx`](tizen/src/features/player/PlayerView.tsx).
- ✅ **Jauge compte Xtream** (date d'expiration avec rappel J-7 + `max_connections`) dans Sources **et sur l'écran Home** (`.buntu-home-expirations`) via le helper partagé [`sourceExpiry.ts`](tizen/src/features/sources/sourceExpiry.ts) : [`SourcesView.tsx`](tizen/src/features/sources/SourcesView.tsx), [`HomeView.tsx`](tizen/src/features/home/HomeView.tsx).
- ✅ Vérification : `npx tsc --noEmit` OK ; `npx vitest run tests/TizenNiceToHave.test.ts tests/HomeNavigation.test.ts tests/AccessibilityPrefs.test.ts tests/NoUselessIcons.test.ts` → 4/4 fichiers, 23/23 tests passés. Non testé à l’écran sur la TV physique.
- ⏸️ **À faire par l’utilisateur** : `./scripts/build-tizen.sh` puis `./scripts/run-tizen.sh <IP_TV>`.

## 2026-11-14 — Antigravity, Accessibilité visuelle Tizen (Contraste élevé + Taille du texte)

- ✅ Préférences persistantes (`localStorage` `buntu.ui.accessibility`) et application au démarrage sur `document.documentElement` (`data-high-contrast`, `data-text-size` : `standard`, `large`, `xlarge`) : [`tizen/src/ui/design/accessibilityPrefs.ts`](tizen/src/ui/design/accessibilityPrefs.ts), [`tizen/src/index.tsx`](tizen/src/index.tsx).
- ✅ Section **Accessibilité visuelle** dans Réglages > Système (`#btn-high-contrast`, `#btn-text-size`) + navigation spatiale : [`tizen/src/features/settings/SettingsView.tsx`](tizen/src/features/settings/SettingsView.tsx).
- ✅ Tokens contraste élevé opaques + bordures de focus renforcées + mise à l’échelle typographique sans `zoom` (préserve les coordonnées `getBoundingClientRect()` d’AVPlay) : [`tizen/src/ui/design/theme.css`](tizen/src/ui/design/theme.css).
- ✅ Vérification : `npx tsc --noEmit` OK ; `npx vitest run tests/AccessibilityPrefs.test.ts tests/NoUselessIcons.test.ts tests/SettingsHouseholdTransfer.test.ts` → 3/3 fichiers, 18/18 tests passés. Non testé à l’écran sur la TV physique.
- ⏸️ **À faire par l’utilisateur** : `./scripts/build-tizen.sh` puis `./scripts/run-tizen.sh <IP_TV>` pour tester sur la TV Samsung.

## 2026-11-14 — Antigravity, DESIGN.md et refonte design solide (anti-IA)

| Tâche / Fond | Fichiers | État | Détail |
| :--- | :--- | :--- | :--- |
| Rédaction du guide de design | [`DESIGN.md`](DESIGN.md) | ✅ | Charte « Sobriété Matérielle — Anti-IA » : palette 100 % opaque, boutons solides, règles focus 10-foot, compatibilité Chromium 56–76, exception unique de transparence AVPlay. |
| Refonte CSS solide (Tizen) | [`theme.css`](tizen/src/ui/design/theme.css), [`AssistantModal.tsx`](tizen/src/features/assistant/AssistantModal.tsx), [`SearchView.tsx`](tizen/src/features/search/SearchView.tsx), [`PairingView.tsx`](tizen/src/features/pairing/PairingView.tsx), [`SettingsView.tsx`](tizen/src/features/settings/SettingsView.tsx) | ✅ | Suppression de tous les `linear-gradient`, `radial-gradient`, `backdrop-filter` et boutons/panneaux `rgba(...)` translucides au profit de surfaces et boutons 100 % solides (sauf les zones vidéo AVPlay qui restent `transparent`). |
| Non-régression design solide | [`NoUselessIcons.test.ts`](tizen/tests/NoUselessIcons.test.ts) | ✅ | Vérifie l'absence de `backdrop-filter`/`linear-gradient`/`radial-gradient` dans `theme.css` et des fonds solides sans `rgba(` sur les boutons principaux. |
| Validation TypeScript + Vitest ciblée | `npx tsc --noEmit` + `vitest run` (5 fichiers) | ✅ | `tsc --noEmit` (0 erreur) ; 5 fichiers, 30/30 tests passés (`NoUselessIcons`, `HomeNavigation`, `SearchEngineButton`, `LiveReturnFromPlayer`, `MoviePanelFocus`). |
| Build + test sur la TV Samsung | `./scripts/build-tizen.sh` / `./scripts/run-tizen.sh <IP>` | ⏳ À faire par l'utilisateur | Non essayé à l'écran ni sur la TV (`AGENTS.md § 2`). |

## 2026-11-14 — Antigravity, logo Buntu de retour à l'accueil (Tizen)

| Tâche | État | Détail |
| :--- | :--- | :--- |
| Logo Buntu de retour à l'accueil sur `LiveView`, `MoviesView`, `SeriesView` | ✅ | Bouton icône `*-brand-home` (`live-brand-home`, `mv-brand-home`, `s-brand-home`) avec uniquement le logo `./icon.png` (sans texte `Buntu`) ajouté en tête de `.buntu-toolbar-left` et en ligne 0 de `toolbarRow` (y compris à l'état vide Live TV), relié à `onHome={() => navigateTo('home', { reset: true })}` dans `App.tsx`, et stylé dans `theme.css` (compatible Chromium 76). Non testé sur la TV (`build-tizen.sh` à faire par l'utilisateur). |
| Validation Tizen (`tsc --noEmit` + tests Vitest) | ✅ | `tsc --noEmit` sans erreur ; tests ciblés `NoUselessIcons`, `HomeNavigation`, `SearchEngineButton`, `LiveReturnFromPlayer`, `MoviePanelFocus` : 5/5 fichiers (28/28) réussis. Suite complète `npm test` : 61/62 fichiers (352/353) réussis ; 1 échec hors périmètre dans `tests/AiKeyStore.test.ts` (`migrates the old encrypted slot only to the selected provider`). |

## 2026-11-14 — Antigravity, collage dans Sources et clavier TV Tizen

| Tâche | État | Détail |
| :--- | :--- | :--- |
| Collage dans `TvKeyboard`, `ManualSourceForm` et `SourceEditForm` | ✅ | Touche `📋 Coller` (`#kb-paste`) et fonction `applyPastedText` dans `tvKeyboardLogic.ts`, support `navigator.clipboard.readText()` + écouteur `paste` dans `TvKeyboard.tsx`, collage direct sur les champs focalisés (`ManualSourceForm.tsx`, `SourceEditForm.tsx`) via `listenFocusedFieldPaste` et `pasteEventIntoField` sans double collage. Non essayé sur TV Samsung ni avec SmartThings réel. |
| Validation Tizen | ✅ | `npx tsc --noEmit` (0 erreur) et `npx vitest run tests/TvKeyboard.test.ts tests/SourcesView.test.ts tests/AssistantSettings.test.ts` : **3 fichiers / 24 tests passés** (`TvKeyboard` 14/14, `SourcesView` 7/7, `AssistantSettings` 3/3). |
| Build `.wgt` (à faire par l'utilisateur) | ⏸️ | Lancer `./scripts/build-tizen.sh` puis `./scripts/run-tizen.sh --no-build <IP_TV>` pour installer et tester sur la TV Samsung. |

---

## 2026-11-14 — Antigravity (Swarm), page À propos sur Tizen, Apple et Android

| Tâche | État | Détail |
| :--- | :--- | :--- |
| Tizen (`SettingsView.tsx`, `config.xml`, `SettingsHouseholdTransfer.test.ts`) | ✅ | Page « À propos de Buntu » (`#about-page` via `#settings-about`), identité `Buntu` (`« Sa bunt ci lépp »`), créateur `Papa COUNDIA`, `papacoundia@gmail.com`, `Sénégal`, `MIT / Apache-2.0`, mention lecteur neutre, ligne créateur dans « Informations système » et `<author>` dans `config.xml`. Retour/`BACK` restaure le focus sur `settings-about` ; règles Chromium 76 respectées. Non essayé sur la TV Samsung. |
| Apple (`AppBrand.swift`, `SettingsView.swift`, `AppBrandTests.swift`) | ✅ | Constantes ajoutées à `AppBrand` (`authorName`, `authorEmail`, `authorCountry`, `license`, `neutralPlayerNotice`), affichées dans `aboutSection` et dans `AboutDetailView` (via `NavigationLink`), tests `AppBrandTests` étendus sans créer de nouveau fichier `.swift`. Non compilé via `xcodebuild` et non essayé sur appareil. |
| Android (`SettingsScreen.kt`, `SettingsViewModelTest.kt`) | ✅ | Objet `BuntuAboutInfo` et carte `about_section` dans `SettingsRoute` (lisible sur téléphone et focus D-pad sur Android TV avec `BuntuPalette`), test unitaire dédié dans `SettingsViewModelTest` ; aucune dépendance vers `:core:engine`. Non essayé sur téléphone ni Android TV. |
| Validations unitaires ciblées (vérificateur) | ✅ | Tizen : `npx tsc --noEmit` (0 erreur) et `npx vitest run tests/SettingsHouseholdTransfer.test.ts tests/AssistantSettings.test.ts tests/UiSounds.test.ts` (`Test Files 3 passed (3)`, `Tests 16 passed (16)` : `SettingsHouseholdTransfer` 6/6, `UiSounds` 7/7, `AssistantSettings` 3/3) ; Apple : `swift test --filter AppBrandTests` (`Executed 7 tests, with 0 failures`) ; Android : `./gradlew --offline :feature:settings:testDebugUnitTest --rerun-tasks --console=plain` (`BUILD SUCCESSFUL in 13s`, `50 actionable tasks: 50 executed`, `SettingsViewModelTest` : `tests="8" skipped="0" failures="0" errors="0"`). |
| Builds d'application (à faire par l'utilisateur) | ⏸️ | Aucune modification UniFFI/`cnd-domain` ni ajout de fichier Swift : lancer si souhaité `./scripts/build-tizen.sh` / `./scripts/run-tizen.sh <IP>`, `xcodebuild -project apple/CndIPTV.xcodeproj -scheme <schéma> CODE_SIGNING_ALLOWED=NO build` et `cd android && ./gradlew :app:assembleDebug`. |

---

## 2026-11-13 — Antigravity, PRD-46 amélioration du lecteur Live TV

| Tâche | État | Détail |
| :--- | :--- | :--- |
| PRD-46 + index roadmap | ✅ | `PRD/46_AMELIORATION_LECTEUR_LIVE_TV.md` finalisé et passé à `[x]` dans `PRD/00_INDEX_ROADMAP.md` (lots 46.1–46.5). |
| Apple (`CndIptvKit`) | ✅ | Anti-429 zapping (250 ms), Recall, saisie `0–9`, EPG temps réel + Start-Over, ratios vidéo, minuteur de veille, Mini-Guide overlay (`CndPlayerTests`: 24/24 verts). Non essayé sur appareil. |
| Android (`domain`/`data`/`player`/`feature:player`) | ✅ | Miroirs & failover auto (max 2), anti-429 zapping (250 ms), Recall, saisie `0–9`, EPG temps réel + Start-Over, Mini-Guide, ratios vidéo, minuteur de veille (`core:domain`, `core:data`, `core:player`, `feature:player` : `BUILD SUCCESSFUL`). Non essayé sur appareil. |
| Tizen (`AVPlayerService`/`CndEngine`/`PlayerView`) | ✅ | Miroirs & failover auto (max 2), anti-429 zapping (250 ms), Recall, saisie `0–9`, Start-Over catchup, Mini-Guide transparent AVPlay, ratios, minuteur de veille, correction `untrack` / `preserveFocus` dans `updateGrid`, correction Pause Live TV, et barre de progression interactive (`#osd-progress-bar` + `-10s`/`+10s`) sur film, direct TV et série (`AVPlayerService.ts`, `CndEngine.ts`, `SeriesDetailsView.tsx`, `PlayerView.tsx`, `theme.css`). Non essayé sur TV Samsung. |
| Tests unitaires ciblés | ✅ | Apple `swift test --filter CndPlayerTests` : 24/24 ✅ ; Android `:core:domain:test :core:data:testDebugUnitTest :core:player:testDebugUnitTest :feature:player:testDebugUnitTest` : `BUILD SUCCESSFUL` ✅ ; Tizen `npx tsc --noEmit` ✅, 8 fichiers (`AVPlayerService`, `Zapping`, `PlayerNextShelf`, `UpNextCountdown`, `LiveReconnect`, `MovieBuffering`, `SeriesDetails`, `ResumePlayback`) 48/48 ✅. |
| Builds d'application (à faire par l'utilisateur) | ⏸️ | Aucune modification UniFFI/WASM ni ajout de fichier Swift : lancer si souhaité `xcodebuild -project apple/CndIPTV.xcodeproj -scheme <schéma> CODE_SIGNING_ALLOWED=NO build`, `cd android && ./gradlew :app:assembleDebug` et `./scripts/build-tizen.sh` / `./scripts/run-tizen.sh <IP>`. |

---

## 2026-11-13 — Codex, profils simples et clés IA du foyer

| Tâche | État | Détail |
| :--- | :--- | :--- |
| Simplifier Profils Tizen | ✅ | Deux cartes, profil actif distinct du focus, contrôle parental replié, Retour pour refermer. Grand menu retiré. Tests dédiés réussis. |
| Partage sécurisé des clés IA | ✅ | iPhone/Mac : clés personnelles du Trousseau ; Android : clé personnelle du fournisseur configuré. Champ ai_configs optionnel dans l’enveloppe chiffrée du foyer ; validation Rust, coffre Tizen par fournisseur et migration. Clé TV existante et consentement conservés. Aucun essai sur appareils. |
| Validation | ⏳ | Builds Apple et validation Android à terminer. |
| Builds Apple non signés | ⏳ | Premier build macOS refusé par les caches SwiftPM globaux ; relance autorisée hors bac à sable. macOS, iOS, tvOS, visionOS, sans signature ; DerivedData propre à cette session supprimé après usage. |
| Rust : Clippy puis tests workspace release | ❌ | Clippy réussi ; domaine 86/86. Premier workspace bloqué par sockets locales ; relance hors bac à sable : 317 réussis, 2 ignorés, 2 échecs de performance connus (test_recommendations_sla_50k_items, test_50k_streaming_m3u_ingestion_sla). Relance fonctionnelle prévue. |
| Tizen : TypeScript, tests et build | ✅ | TypeScript valide, 215/215 tests et build web réussi ; coffres séparés, migration, transfert chiffré et profils vérifiés. Première suite : un test sans IndexedDB échouait ; coffre indisponible désormais sans effet sur le transfert des sources. |
| Apple : swift test | ✅ | Après refus des caches globaux puis échecs des tests dans le bac à sable, relance avec caches du dépôt et accès aux services locaux : 551 XCTest exécutés, 2 ignorés, aucun échec ; 15 Swift Testing réussis. Deux tests sur l’export des seules clés personnelles. |
| Android : core:data tests et APK | ⏳ | Wrapper puis sockets refusés ; relance hors ligne avec caches du dépôt et cache dépendances existant en lecture seule. Une compilation des tests a croisé l’ajout du helper ; relance après stabilisation du code en cours. |
| Reconstruction Wasm MVP | ✅ | wasm-pack no-install et wasm-bindgen existant en cache, optimisation puis validation MVP. Aucun outil installé. |

## 2026-11-13 — Codex, écrans de gestion Tizen simplifiés

| Tâche | État | Détail |
| :--- | :--- | :--- |
| Sources, Appareils, Réglages et Quitter | ✅ | Grand menu retiré ; Sources : liste sobre sans hôte ni statut de connexion supposé, actions courtes et ordre du focus aligné sur l’écran. Réglages : Connexion, Assistant, Stockage/informations et Profils. Appareils : détails et départ du foyer repliés. Quitter : deux choix, Rester par défaut. Fonctions conservées ; 23/23 tests ciblés. |
| Validation | ✅ | TypeScript valide, 209/209 tests Tizen et build web réussi. Parcours menu/détail/Retour, options appareils repliées, absence du grand menu et focus Rester à la fermeture vérifiés. Non installé ni essayé à l’écran ou sur TV. |

## 2026-11-13 — Codex, retrait du menu latéral des catalogues Tizen

| Tâche | État | Détail |
| :--- | :--- | :--- |
| Retirer le menu principal dans les rubriques | ✅ | Menu principal et cibles de focus retirés de Live, Films, Séries et des fiches. Catégories propres à chaque rubrique conservées ; Retour retrouve l’accueil ou la liste précédente. Menu conservé dans les écrans de gestion et outils. |
| Validation Tizen | ✅ | TypeScript valide, 204/204 tests Tizen et build web réussi. Absence du menu et des cibles de focus vérifiée pour les trois rubriques ; retour accueil et menu des réglages vérifiés. Non installé ni essayé sur TV. |

## 2026-11-13 — Codex, réactivité télécommande Tizen

| Tâche | État | Détail |
| :--- | :--- | :--- |
| Alléger le traitement du focus | ✅ | Contour immédiat sans animation ni ombre floue sur l’accueil ; un seul travail DOM par image, accès direct à la sélection, focus accessible conservé et OK synchrone. Tests ciblés : 10/10. |
| Validation | ✅ | TypeScript valide, 204/204 tests Tizen et build web réussi. Régression appuis rapides : quatre déplacements avant une image produisent un seul travail DOM, OK reste immédiat ; changement d’écran et focus accessible vérifiés. Non installé ni essayé sur TV, aucun gain de latence mesuré sur appareil. |

## 2026-11-13 — Codex, diagnostic lenteur télécommande Tizen

| Tâche | État | Détail |
| :--- | :--- | :--- |
| Examiner le traitement des touches et l’accueil | ✅ | Aucun délai volontaire dans le dispatch des touches. Contour d’accueil animé sur 150 ms ; à chaque focus, une callback requestAnimationFrame fait scrollIntoView puis synchronise le focus DOM. Plusieurs callbacks peuvent être programmées en navigation rapide. Ouverture des rubriques : catégories, compteurs et listes chargés à l’entrée. Constats dans le code uniquement : aucune mesure sur TV, aucune cause unique confirmée. Aucun changement fonctionnel. |

## 2026-11-13 — Codex, heure sur l’accueil Tizen

| Tâche | État | Détail |
| :--- | :--- | :--- |
| Heure de l’accueil | ✅ | Heure locale de la TV en haut à droite, format 24 h, actualisation automatique et au retour de veille ; minuteur libéré à la fermeture de l’accueil. |
| Validation Tizen | ✅ | TypeScript valide, 201/201 tests réussis et build web de production réussi. Non installé ni essayé sur TV. |

## 2026-11-13 — Codex, télécommande accueil Tizen

| Tâche | État | Détail |
| :--- | :--- | :--- |
| Diagnostic et correction du focus accueil | ✅ | Deux règles de focus associaient .focused à :focus-visible, non supporté par Chromium 76 : le contour entier était ignoré. Remplacé par :focus compatible ; télécommande physique précisée par l’utilisateur. |
| Validation Tizen | ✅ | TypeScript valide, 201/201 tests, build web réussi. Nouveau test simulant le rejet des sélecteurs non supportés : contour visible, quatre directions et OK. Échec initial reproduit, correctif validé. Non installé ni essayé sur TV. |

## 2026-11-13 — Antigravity, alignement de l'écran Réglages Android sur macOS, ajout du test IA et mode verrouillage du lecteur

| Tâche | État | Détail |
| :--- | :--- | :--- |
| Modèles et contrats `:core:domain` + `:core:data` pour le test IA, `RuntimeSettings` et `DbStats` | ✅ | Exposition de `testAiProvider`, `getDbStats`, `getRuntimeConfig`, `updateRuntimeConfig`, `resetDismissedRecommendations` et persistance de `consent` et `autoSearch`. |
| Refonte de `SettingsViewModel` et `SettingsScreen` (parité macOS + bouton Tester l'IA) | ✅ | Libellés français des fournisseurs, test IA avec latence et modèle, afficher/masquer clé, consentement/serveur local, confidentialité (« Ce qui est envoyé »), réinitialisation des goûts « Pour vous » et « Pas intéressé », réglages téléchargements/réseau/OMDb/OpenSubtitles, contrôle parental et statistiques « À propos ». |
| Tests unitaires `:feature:settings` et validation Android | ✅ | `SettingsViewModelTest` (6/6), `:core:domain:test` (10/10), `:core:data:testDebugUnitTest` (16/16), `:feature:search:testDebugUnitTest` (1/1), `:app:testDebugUnitTest` (2/2), et `:app:assembleDebug` réussis. Non essayé sur appareil. |
| Mode verrouillage de l'écran du lecteur façon YouTube (`PlayerViewModel`, `PlayerScreen`) | ✅ | Bouton « Verrouiller l'écran » dans la barre du lecteur, la feuille Réglages et les raccourcis portrait ; blocage des clics/double-taps/retour accidentel et pilule « Écran verrouillé · Appuyer pour déverrouiller ». Tests `:feature:player:testDebugUnitTest` (9/9), `:app:testDebugUnitTest` (2/2) et `:app:assembleDebug` réussis. Non essayé sur appareil. |
| Correction de la saisie du modèle et de l'adresse IA dans `SettingsScreen` / `SettingsViewModel` | ✅ | Brouillon synchrone (`aiModelDraft`, `aiEndpointDraft`) avec écriture différée (300 ms) et flush sur `testAiProvider()`, + désactivation de l'autocorrection clavier sur les champs Modèle et Adresse serveur. Tests `:feature:settings:testDebugUnitTest` (7/7), `:app:testDebugUnitTest` (2/2) et `:app:assembleDebug` réussis. Non essayé sur appareil. |
| Recherche dans Direct/Films/Séries + popup avec choix Local/IA (`:app`, `:feature:live/movies/series/search`) | ✅ | Retrait de l'onglet Recherche de la barre de navigation ; ajout du bouton « Rechercher » dans Direct, Films et Séries ouvrant le popup modal pré-filtré avec sélecteur explicite Recherche locale / Assistant IA. Tests `:core:domain:test` (10/10), `:feature:search:testDebugUnitTest` (2/2), `:feature:live:testDebugUnitTest` (1/1), `:app:testDebugUnitTest` (2/2) et `:app:assembleDebug` réussis. Non essayé sur appareil. |
| Mise en page responsive de l'écran Détails film/série (`DetailsScreen`) | ✅ | `BoxWithConstraints` + `FlowRow` pour les boutons d'action, synopsis dépliable (« Voir plus / Voir moins »), affichage réalisation/casting et adaptation des lignes d'épisodes sur téléphone. Compilation `:feature:details:compileDebugKotlin`, `:app:testDebugUnitTest` et `:app:assembleDebug` réussis. Non essayé sur appareil. |

## 2026-11-13 — Codex, statut Hors service Apple et Android

| Tâche | État | Détail |
| :--- | :--- | :--- |
| Adapter erreurs et reprise des lecteurs natifs | ✅ | Apple partagé macOS/iOS/tvOS/visionOS et Android téléphone/TV ; erreurs/blocages marqués, retrait sur progression audio sans attendre de vidéo, reconnexion en attente annulée et listes actualisées. API Rust existante. |
| Validation Android | ✅ | 33/33 tests (core:data 16, core:player 6, feature:live 1, feature:player 8, app 2), APK debug construit. Reprise : tag, erreur et chargement retirés. Non essayé sur appareil. |
| Validation Apple | ✅ | swift test : 549 XCTest, 2 ignorés, 1 échec de temporisation AutoSearch hors sujet ; 15 Swift Testing réussis. Relances isolées : CndPlayerTests 21/21 et AutoSearchTests 11/11. |
| Build macOS | ✅ | BUILD SUCCEEDED. Sans signature, sans installation. |
| Build iOS | ✅ | BUILD SUCCEEDED. Sans signature, sans installation. |
| Build tvOS | ✅ | BUILD SUCCEEDED. Sans signature, sans installation. |
| Build visionOS | ✅ | BUILD SUCCEEDED. Sans signature, sans installation. |

Aucun essai sur appareil réel. Dossiers temporaires Xcode propres à cette session supprimés après chaque build. Des différences dans les copies générées android/core/domain/bin sont apparues pendant les builds ; conservées sans les inclure dans le correctif.

## 2026-11-13 — Codex, statut Hors service automatique Tizen

| Tâche | État | Détail |
| :--- | :--- | :--- |
| Marquage et guérison automatiques | ✅ | Échecs AVPlay et blocages détectés par le watchdog existant ; retrait sur progression du lecteur, sans exiger de piste vidéo. Tags réactifs dans liste, panneau et plein écran. Écritures ordonnées pour éviter un HS tardif après reprise. |
| Tests et build | ✅ | TypeScript valide, 194/194 tests Tizen et build de production réussis. Tests audio seul, blocage/reprise, événements d’ancienne chaîne ignorés, tag visible et écritures ordonnées. Non installé ni essayé sur TV. |

## 2026-11-13 — Codex, indicateur de connexion TV en direct

| Tâche | État | Détail |
| :--- | :--- | :--- |
| Correction du chargement restant visible | ✅ | Le temps de lecture qui avance termine le chargement même sans buffering-complete, efface l’erreur éventuelle et annule la reconnexion en attente. Un temps figé ne masque pas un vrai chargement. |
| Tests et build | ✅ | TypeScript valide, 189/189 tests Tizen et build de production réussis ; 4 régressions ajoutées (notification absente, reconnexion annulée, temps figé, blocage à zéro). Non installé ni essayé sur TV. |

## 2026-11-13 — Codex, modification locale des sources Tizen

| Tâche | État | Détail |
| :--- | :--- | :--- |
| Édition HOST / utilisateur / mot de passe | ✅ | Bouton Modifier, source du foyer conservée ; corrections chiffrées AES-GCM dans un coffre local distinct. Lectures et séries adaptées en Rust, identité du foyer conservée. |
| Tests Tizen, Wasm et build | ✅ | Wasm MVP reconstruit, TypeScript valide, 185/185 tests et build de production réussis. Tests ajustés au stockage partagé explicite et à la suppression asynchrone. Non installé ni essayé sur TV. |
| Clippy et domaine Rust | ✅ | Workspace Clippy sans avertissement ; cnd-domain release 84/84, dont validation et réécriture des coordonnées. |
| Suite Rust complète | ❌ | cnd-core : 318 réussis, 2 ignorés, seul échec test_50k_streaming_m3u_ingestion_sla (déjà observé avant ce chantier). Domaine et Clippy validés séparément. Aucun changement au test de performance. |

## 2026-11-13 — Codex, boutons Recevoir / Envoyer Tizen

| Tâche | État | Détail |
| :--- | :--- | :--- |
| Remplacer Synchroniser dans Appareils / Réglages | ✅ | Recevoir demande les données du foyer ; Envoyer transmet les comptes et favoris de la TV. Actions distinctes, erreurs visibles, doubles appuis bloqués. |
| Tests et build | ✅ | TypeScript valide, 177/177 tests Tizen et build de production réussis. Réception sans envoi, envoi sans demande, déconnexion et erreur/reprise testés. Propriété du test corrigée au premier contrôle. Non installé ni essayé sur TV. |

## 2026-11-13 — Codex, scanner Android et envoyer les données à la TV

| Tâche | État | Détail |
| :--- | :--- | :--- |
| Bouton Android et transfert | ✅ | Appareils : « Scanner un QR et envoyer mes données ». Foyer créé sur le téléphone si nécessaire ; clé scellée via Rust ; données envoyées à la TV après confirmation et présence authentifiée. |
| Validation Android | ✅ | core/platform : 24 tests, 0 échec, 0 erreur; feature/devices : 5 tests, 0 échec, 0 erreur; app : 2 tests, 0 échec, 0 erreur. APK debug construit. Première erreur de compilation corrigée. Non installé ni essayé sur appareil. |
| Instructions QR Tizen | ✅ | TypeScript valide, 173/173 tests et build web réussis. Non installé ni essayé sur TV. |

## 2026-11-13 — Codex, QR de salon à l’accueil Tizen sans compte

| Tâche | État | Détail |
| :--- | :--- | :--- |
| Remplacer le QR d’accueil | ✅ | L’accueil utilise le même parcours d’ajout de TV au salon que Sources ; saisie manuelle et exploration conservées. |
| Tests et build | ✅ | TypeScript valide, 173/173 tests Tizen et build de production réussis ; confirmation du salon, repli manuel et exploration testés. Non installé ni essayé sur TV. |

## 2026-11-13 — Codex, ajouter la TV au foyer uniquement par QR

| Tâche | État | Détail |
| :--- | :--- | :--- |
| Simplification de Sources et des réglages | ✅ | Boutons de création retirés. Sans foyer, Sources affiche le QR éphémère d’ajout de la TV ; confirmation à la télécommande. Parcours téléphone existant sur iPhone, pas encore sur Android. |
| Tests et build | ✅ | TypeScript valide, 170/170 tests Tizen et build de production réussis. Confirmation, refus, expiration et erreur testés. Non installé ni essayé sur TV. |

## 2026-11-13 — Codex, salons dans Sources Tizen

| Tâche | État | Détail |
| :--- | :--- | :--- |
| Création, adhésion et QR du salon dans Sources | ✅ | Invitation commune Apple/Android issue des règles Rust ; création avec nom et adhésion par invitation, synchronisation relancée. Import de comptes distinct. Non essayé sur appareils. |
| Reconstruction Wasm et tests Tizen | ✅ | wasm-bindgen existant en cache utilisé sans installation, Wasm MVP validé ; TypeScript et 169/169 tests réussis. |
| Clippy Rust | ✅ | Workspace et toutes les cibles, sans avertissement. |
| Build web | ✅ | Build Vite de production réussi. |
| Tests Rust du domaine | ✅ | Suite cnd-domain release : 81/81. |
| Tests Rust workspace (bac à sable) | ❌ | 251 réussis, 68 échecs, 2 ignorés ; serveurs HTTP locaux refusés (PermissionDenied). |
| Tests Rust workspace (relance) | ❌ | 317 réussis, 2 ignorés, 2 échecs de performance : test_50k_streaming_m3u_ingestion_sla et shelves_are_built_in_under_50_ms_on_a_big_catalog. Aucun fichier de ces fonctions modifié. |
| Tests Rust fonctionnels | ✅ | Workspace : 398 réussis, 2 ignorés, 2 tests de performance exclus. Aucun essai sur TV ou téléphone. |

## 2026-11-13 — Codex, suppression d’une source Tizen

| Tâche | État | Détail |
| :--- | :--- | :--- |
| Diagnostic et correction Tizen | ✅ | OK sur carte auparavant sans effet ; confirmation isolée avec openModal, focus conservé lors des annonces du foyer, erreurs visibles et doubles validations bloquées. Mes changements Android issus du malentendu ont été retirés. |
| Tests Tizen | ✅ | TypeScript valide, 165/165 tests dont parcours à la télécommande et échec/reprise de suppression. |
| Build Tizen | ✅ | Build web de production réussi avec Wasm existant ; aucune modification Rust. Non essayé sur la TV, aucune installation prévue. |

## 2026-11-13 — Codex, suppression Android : mauvaise plateforme

- 🚫 Chantier abandonné après clarification : la demande concerne Tizen. Seuls mes changements et tests Android ont été retirés ; aucun changement d’une autre session n’a été annulé.
- ✅ Vérifications effectuées avant clarification : 22 tests Android et assembleDebug réussis. APK non installé ; il ne correspond pas au correctif Tizen demandé.

## 2026-11-13 — Codex, lecture iPhone / Android vers Samsung Tizen

| Tâche | État | Détail |
| :--- | :--- | :--- |
| Diagnostic des transports et de la réception Tizen | ✅ | TV absente du sélecteur, confirmé par l’utilisateur. Démarrage sans foyer bloquant les démarrages suivants ; annonce avant confirmation MSF. |
| Correction et tests de non-régression | ✅ | TypeScript valide ; 163/163 tests Tizen, dont 3 nouveaux tests du transport. |
| Reconstruction complète Tizen | ❌ | Rust compile ; wasm-pack tente d’installer wasm-bindgen hors dépôt, refusé par le bac à sable. Aucun outil installé. |
| Build web de production | ✅ | Wasm existant validé MVP, domaine Rust inchangé. Premier build refusé par Babel sur spread + await ; expression adaptée dans la synchronisation, build réussi. |
| Paquet installable | ❌ | Le CLI Tizen demande le mot de passe auteur et ne produit pas de paquet signé dans cet environnement. Build web prêt dans tizen/dist ; aucune installation sur appareil. |
| Installation et lecture sur la TV | ⏸️ | L’utilisateur fera l’essai plus tard ; aucune installation demandée pour cette session. Correctif prêt, non essayé sur la TV. |

## 2026-11-12 — Claude, alignement de l'app Android sur l'app iPhone

Rien n'est commité. Rien n'est essayé sur un téléphone ni sur une Android TV.

| Tâche | État | Détail |
| :--- | :--- | :--- |
| Comparaison des apps iPhone et Android | ✅ | 10 écarts classés. La liste est dans les notes de la session. |
| Lot 1 « lecteur » : fin de lecture, épisode ou film suivant, compte à rebours, « Êtes-vous toujours là ? » | ✅ codé | Le choix du titre suivant est fait en Rust (`next_up`, `recommendations_for`). Les délais d'affichage (3 %, 4 min, 3 enchaînements) sont dans `NextUpTiming.kt`, recopiés d'Apple (`UpNextModel.swift`). À déplacer un jour dans `cnd-domain`. |
| Rangée « À suivre », favori, vitesse de lecture, réglages « À suivre » | ✅ testé | 8 tests du `PlayerViewModel`. |
| Logo Buntu de l'iPhone sur Android | ✅ codé | Icône adaptative, icône monochrome, bannière TV, logo dans les menus. Dessins vectoriels générés depuis `AppLogoView.swift`. |
| Rejoindre un foyer par QR code | ✅ codé | Format du lien en Rust (`cnd_domain::sync::invite`, 5 tests). Bibliothèque Android reconstruite. XCFramework Apple **non reconstruit** : Apple garde sa version Swift. |
| Champ de recherche responsive | ✅ codé | |
| Lecteur façon YouTube : portrait 16:9 avec la liste en dessous, plein écran en paysage et sur TV | ✅ compile | Non essayé à l'écran. |
| Sources et Appareils dans le menu | ✅ codé | Téléphone : rangée de raccourcis en haut (défilante), rail et tiroir ; TV : barre du haut. |
| Comptes du Mac non reçus sur Android | ✅ codé | 3 causes : mot de passe rangé sous `source_pwd_<uuid>` alors que le compte cherche `password_ref` ; catalogues des comptes reçus jamais téléchargés ; écran Sources pas rafraîchi. Corrigé dans `RustHouseholdSyncEngineBridge.kt`. **Non essayé sur le téléphone** : après installation, toucher « Synchroniser maintenant » sur Android. |
| Enquête « comptes absents sur le mobile » (12:05) | ⏸️ en attente de l'utilisateur | Le Mac **et** Android ont 0 compte et les mêmes 6 marques de suppression de compte (`sync_tombstones`, type `source`), dont 2 posées aujourd'hui à 11:20:18 et 11:20:49. Les comptes ont été supprimés puis la suppression s'est propagée : ce n'est pas un défaut de réception. Hypothèse non prouvée : depuis le dédoublonnage (`same_account_source`), un même compte garde un uuid différent sur chaque appareil ; supprimer le « doublon » sur l'un pose une marque sur un uuid qui est le compte principal de l'autre. L'iPhone (hors ligne) a peut-être encore les comptes. |
| Boutons « Envoyer mes données » et « Recevoir les données » à la place de « Synchroniser maintenant » (Android, Mac, iPhone) | ✅ codé | Additifs : rien n'est supprimé chez l'autre, un compte n'est jamais ajouté deux fois. Testé unitairement et compilé sur les 3 ; **non essayé sur les appareils**. |
| Règle Rust : une suppression de compte ne voyage plus (`cnd_domain::sync::deletion_propagates`) | ✅ testé | Plus envoyée, ignorée si reçue d'une ancienne app, et une marque locale ne bloque plus un compte reçu. `cnd-core` : 24/24 tests de synchro. |
| Reconstruction bibliothèque Android + XCFramework | ✅ | Les deux réussies. |
| Tests Apple (`swift test`) + builds macOS et iOS | ✅ | XCTest 547 tests (2 ignorés, 0 échec) + 15 tests Swift Testing ; `CndIPTV-macOS` et `CndIPTV-iOS` : BUILD SUCCEEDED. |
| Tests Android (`core:data`, `core:platform`, `feature:devices`, `app`) + APK | ✅ | 15/15, 19/19, 4/4, 2/2 ; APK debug construit. |
| Tests Rust (`clippy`, `cnd-domain`) | ✅ | 80/80. |
| Tests Android des modules touchés et APK | ✅ | `core:domain` 10/10, `core:data` 15/15, `feature:player` 8/8, `feature:live` 1/1, `feature:search` 1/1, `feature:devices` 4/4, `app` 2/2 (dont la règle des modules) ; APK debug construit. Avant ça : 2 lancements bloqués (arrêtés), 1 erreur de dépendance, 1 test en échec, 1 boucle sans fin dans les tests du lecteur, tous corrigés. |

## 2026-11-13 — Codex, accueil Tizen allégé

| Tâche | État | Détail |
| :--- | :--- | :--- |
| Accueil Live / Films / Séries et navigation | ⏳ | Accueil sans catalogue, rubriques montées uniquement à leur ouverture, retour à l’accueil et accès aux réglages. Modifications préexistantes conservées. |
| Validation Tizen | ⏳ | Tests de navigation, TypeScript, suite Tizen et build web à exécuter. Aucun déploiement TV. |

## 2026-11-13 — Claude, clé IA reçue par tous les appareils

| Tâche | État | Détail |
| :--- | :--- | :--- |
| Règle Rust exposée (`sync_missing_ai_credentials`) | ✅ | Import additif : une clé déjà enregistrée sur l'appareil n'est jamais remplacée. |
| Android : réception de la clé IA (Keystore + fournisseur) | ✅ | `core:data` 4/4 sur la clé IA ; `core:platform` et `app` verts. Non essayé sur appareil. |
| Mac / iPhone : réception de la clé IA (Trousseau) | ✅ | XCFramework reconstruit ; 4/4 tests `HouseholdAiCredentialsTests`. Builds macOS/iOS complets non relancés. |
| Tizen | ✅ déjà en place | Importe déjà `ai_configs` ; envoi depuis Android déjà fait (« Envoyer mes données »). |

| Build à faire par l'utilisateur (clé IA) | ⏳ | Builds macOS/iOS (`CndIPTV-macOS`, `CndIPTV-iOS`) et APK non lancés : l'utilisateur les fait. |

## 2026-11-13 — Claude, saisie à la télécommande (Sources, TV Tizen)

| Tâche | État | Détail |
| :--- | :--- | :--- |
| Bug : le focus revenait sur le 1er bouton à chaque flèche (`ManualSourceForm`) | ✅ | Cause : l'effet de la grille lisait le focus. Corrigé avec `untrack`. |
| Clavier à l'écran (`TvKeyboard`) pour « Saisie manuelle » et « Modifier » | ✅ | Touches, raccourcis `http://` `https://` `.com` `:8080` `/get.php`, chiffres de la télécommande, Afficher/Masquer le mot de passe, Retour = annuler. |
| Tests Tizen | ✅ ciblés / ⚠️ suite | `tsc` propre ; `TvKeyboard` 10/10 (4 échouent sans le correctif). Suite : 223/226, 3 échecs hors de ces fichiers (`AiKeyStore` migration, `HttpClient` délai). Non essayé sur la TV. |

## 2026-11-13 — Claude, écran Assistant (TV Tizen)

| Tâche | État | Détail |
| :--- | :--- | :--- |
| Bouton « Envoyer depuis le téléphone (QR code) » retiré | ✅ | Remplacé par une note : la clé se synchronise automatiquement avec le foyer. Le QR pour rejoindre un foyer reste. |
| Saisie de la clé, du modèle et de l'adresse au clavier à l'écran | ✅ | Enregistrement dès « Valider ». Boutons Afficher/Masquer supprimés (inutiles). |
| Tests | ✅ | `AssistantSettings` 3/3, `tsc` propre ; suite complète à relire ci-dessous. Non essayé sur la TV. |

## 2026-11-13 — Claude, icônes inutiles retirées (TV Tizen)

| Tâche | État | Détail |
| :--- | :--- | :--- |
| Icône « maison » (⌂) à côté de « Filtrer les catégories » + ✕ de recherche | ✅ | Retirés (affichage et focus) dans Live, Films, Séries ; ✕ aussi dans le Guide. « Toutes » reste dans la liste. |
| Tests | ✅ | `NoUselessIcons` 2/2, `tsc` propre, suite 229 tests dont 2 échecs hors sujet. Non essayé sur la TV. Les icônes ☰ ⊞ ◫ de la barre du haut ont aussi été retirées à la demande (affichage par défaut : catégories visibles, grille, aperçu actif). |

## 2026-11-13 — Claude, bouton jaune = favori (TV Tizen)

| Tâche | État | Détail |
| :--- | :--- | :--- |
| Jaune ajoute / retire des favoris la chaîne, le film ou la série sélectionné(e) | ✅ | Live, Films, Séries (cartes, étagères, panneau de droite). Ailleurs (catégories, barre du haut) le jaune ouvre toujours la recherche. Indice « Favori » avec point jaune dans la barre. |
| Tests | ✅ | `YellowFavorite` 5/5, `tsc` propre, suite 234/236 (2 échecs préexistants hors sujet). Non essayé sur la TV ; fiche détail et lecteur plein écran non traités. |

## 2026-11-13 — Claude, recherche Local / IA (TV Tizen)

| Tâche | État | Détail |
| :--- | :--- | :--- |
| Choix du mode de recherche Local / ✨ IA dans l'écran Recherche | ✅ | Deux boutons dans la ligne des filtres (accessibles à la télécommande), choix mémorisé. Mode IA : « Rechercher » affiche d'abord le local puis demande à l'assistant ; assistant non configuré → reste en local avec un message. Touche « ✨ ASSISTANT IA » du clavier supprimée. |
| Tests | ✅ | `SearchMode` 4/4, `tsc` propre ; suite complète relue dans le message. Non essayé sur la TV. |

## 2026-11-13 — Claude, mini lecteur : infos du film (TV Tizen)

| Tâche | État | Détail |
| :--- | :--- | :--- |
| Infos du film dans le panneau du mini lecteur (écran Films) | ✅ | Nouvelle requête `get_vod_info` (compte Xtream, mise en cache, jamais de flux ouvert) lancée quand le curseur s'arrête 0,35 s sur un film. Affiche synopsis, genre, pays, âge, note, année, durée, réalisateur, distribution, date de sortie. Un fait absent n'est pas affiché. Playlist M3U : rien de plus que ce qui existait. |
| Tests | ✅ | `MovieInfo` 3/3, `tsc` propre. Non essayé sur la TV. Séries et Live : non traités. |

## 2026-11-13 — Claude, clé OMDb du Mac vers la TV (même foyer)

| Tâche | État | Détail |
| :--- | :--- | :--- |
| Règle Rust `metadata_keys` (service connu, sans doublon, ajout seulement) + export wasm | ✅ | `cargo test -p cnd-domain` vert, `cargo check -p cnd-domain-wasm` ok. |
| Mac : envoi de la clé OMDb personnelle (jamais celle du build) avec « Envoyer mes données » | ✅ | Test Swift ajouté (`HouseholdAiCredentialsTests`). iPhone idem (même code). |
| TV : réception, coffre chiffré, envoi ; infos des films complétées par OMDb | ✅ code / ⏳ build | Tests Tizen verts. **À faire par l'utilisateur : `./scripts/build-tizen.sh`** (nouveau `.wasm`), sinon la clé reçue n'est pas enregistrée et le journal de la TV l'indique. Les règles de validation côté Mac/iPhone n'ont pas besoin du XCFramework. |

| Mac / iPhone : réception de la clé OMDb (Trousseau, ajout seulement) | ✅ (filtre Swift temporaire) | Rust `sync_missing_metadata_keys` ajouté à `cnd-core` (`cargo check` ok) + Swift + 2 tests écrits, **non compilés ni lancés** : l'API UniFFI a changé. **À faire par l'utilisateur : `./scripts/build-xcframework.sh`**, puis `cd apple && swift test --filter HouseholdAiCredentialsTests`. |

| Mac : erreur `syncMissingMetadataKeys` introuvable | ✅ | Appel UniFFI remplacé par un filtre Swift temporaire (`LocalSyncService.missingMetadataKeys`), 8/8 tests `HouseholdAiCredentialsTests`. **Après `./scripts/build-xcframework.sh`, revenir à la règle Rust** (`syncMissingMetadataKeys`). |

## 2026-11-13 — Claude, bouton « moteur de recherche » (TV Tizen)

| Tâche | État | Détail |
| :--- | :--- | :--- |
| Bouton après le champ de recherche (Live, Films, Séries) : « ⌕ Local » / « ✨ IA », OK pour changer | ✅ | Même choix partagé avec l'écran Recherche (`core/search/searchMode.ts`), mémorisé. Mode IA : les propositions de l'assistant passent devant les résultats locaux quand la frappe s'arrête (0,9 s, 3 lettres minimum). Assistant non configuré : reste en local avec un message. |
| Tests | ✅ | `SearchEngineButton` 6/6 + `SearchMode` 4/4, `tsc` propre, suite 253/255 (2 échecs préexistants hors sujet). Non essayé sur la TV. |

| Bouton moteur de recherche : passage en IA refusé alors que l'IA est configurée | ✅ | Cause : « configurée » = fournisseur choisi ; une clé reçue du foyer ne le choisit pas. Maintenant une clé enregistrée suffit et son fournisseur est sélectionné. Le consentement reste dans Réglages > Assistant (message si absent). `SearchEngineButton` 7/7. Non essayé sur la TV. |

## 2026-11-13 — Claude, ancien menu des catégories masqué (TV Tizen)

| Tâche | État | Détail |
| :--- | :--- | :--- |
| Volet « Filtrer les catégories / Récemment vus / Tous les films / Favoris » masqué par défaut (Live, Films, Séries) | ✅ (interprétation) | La capture montrait ce volet ; l'utilisateur a répondu « j'ai changé le home simplifié ». Le contenu prend toute la largeur ; GAUCHE depuis la première colonne rouvre la liste, choisir une catégorie ou RETOUR la referme. À défaire en remettant `showCats` à `true`. `CategoryPane` 2/2. Non essayé sur la TV. |

## 2026-11-13 — Claude, accueil simplifié conservé (Tizen) et créé sur Android TV

| Tâche | État | Détail |
| :--- | :--- | :--- |
| Tizen : accueil Live / Films / Séries + Sources, Appareils, Réglages, Quitter | ✅ conservé | Rien changé ; `HomeNavigation` 10/10. |
| Android TV : même accueil (`TvHomeScreen`, route `home`) | ✅ code + tests / ⏳ appareil | La TV démarre sur l'accueil ; Retour depuis une rubrique y revient, deuxième Retour sur l'accueil = quitter ; barre du haut masquée sur l'accueil. `:app:testDebugUnitTest` vert (dont `TvHomeModelTest` 3/3, règle des modules). Non essayé sur une Android TV. Téléphone inchangé (démarre sur Live). |

| Volet des catégories (Live, Films, Séries) | ✅ remis visible | Demande de l'utilisateur : le masquage est annulé (`showCats` à `true`, gestion GAUCHE/RETOUR supprimée, test `CategoryPane` supprimé). |

## 2026-11-13 — Claude, spinner au premier chargement (TV Tizen)

| Tâche | État | Détail |
| :--- | :--- | :--- |
| Films, Live, Séries : plus de « 0 » avant le chargement, un spinner à la place | ✅ | Les compteurs (catégories, « N films ») n'apparaissent qu'après le premier chargement ; spinner « Chargement des films… » ; Live n'affiche plus « Aucune chaîne disponible » pendant ce temps. Une erreur de chargement retire aussi le spinner. `FirstLoadSpinner` 4/4 (Films et Séries, rendus à l'écran en test). Live : même code, non testé à l'écran. Non essayé sur la TV. |

## 2026-11-13 — Claude, sons système de navigation (TV Tizen)

| Tâche | État | Détail |
| :--- | :--- | :--- |
| Sons système Samsung (`tizen.tvaudiocontrol.playSound`) sur OK, Retour et déplacements | ✅ code + tests / ⏳ TV | `core/audio/UiSounds.ts` : aucun fichier audio ; muet si l'API est absente, si désactivé, ou pendant la lecture plein écran ; 80 ms minimum entre deux sons. Réglage « Sons de navigation » dans Réglages > Stockage et informations (activé par défaut). Privilège `tv.audio` déjà déclaré. `UiSounds` 7/7, `tsc` propre. **Non essayé sur la TV** : l'API et son rendu à côté d'une vidéo sont à confirmer. Android TV : pas encore. |

## 2026-11-13 — Claude, sons système de navigation (Android TV)

| Tâche | État | Détail |
| :--- | :--- | :--- |
| Sons système Android (`View.playSoundEffect`) : OK = clic, flèches = effets de navigation | ✅ code + tests / ⏳ TV | `TvUiSounds` branché sur la TV (`TvShell`), jamais consommateur de touche, 80 ms minimum entre deux sons, rien dans le lecteur plein écran (autre branche), Retour silencieux. Le système ne les joue que si « Sons de navigation » est activé dans les réglages de la TV : pas de réglage propre à l'app. `TvUiSoundsTest` 4/4, `:app:testDebugUnitTest` vert. **Non essayé sur une Android TV.** |

## 2026-11-13 — Claude, carte « Reprendre » sur l'accueil (TV Tizen)

| Tâche | État | Détail |
| :--- | :--- | :--- |
| Carte « Reprendre » au-dessus des trois sections : dernier film, épisode, série ou chaîne vu(e) | ✅ code + tests / ⏳ TV | `getLastWatched()` (heure du dernier contenu enregistrée dans `recordRecent`) ; texte seul (type, titre, « Reprendre à 42:10 · 35 % »), barre de progression, aucune image ni réseau. Absente s'il n'y a rien ; focus sur elle quand elle existe. Film/épisode/chaîne : lecture directe (un film reprend à sa position) ; série : ouvre sa fiche. Non proposé : film fini à 95 %+, catégorie adulte pour un profil enfant. `HomeResume` 9/9, `tsc` propre. Limite : un épisode Xtream sans id en base n'est pas enregistré (donc non proposé). Non essayé sur la TV. |

## 2026-11-13 — Claude, reprise d'un film là où on s'est arrêté (TV Tizen)

| Tâche | État | Détail |
| :--- | :--- | :--- |
| Enregistrer la position pendant la lecture | ✅ code + tests / ⏳ TV | **Cause trouvée** : `updateWatchProgress` n'était jamais appelé en lecture locale et la position enregistrée n'était jamais relue. Maintenant : toutes les 10 s et à l'arrêt (`CndEngine.saveProgress`), films et épisodes seulement. |
| Reprendre à la position enregistrée | ✅ code + tests / ⏳ TV | `play()` déplace le flux avant de le lancer (aussi dans le mini lecteur) ; moins de 15 s ou 95 %+ : depuis le début ; la position envoyée par un autre appareil passe avant. Les listes (Films, récents, favoris, recherche) affichent « Reprendre à … » et l'accueil « Reprendre ». `ResumePlayback` 7/7, `tsc` propre, suite 282/283 (échec préexistant `AiKeyStore`). Non essayé sur la TV : le saut avant lecture (`seekTo` en état prêt) est à confirmer. Épisodes Xtream sans id en base : non enregistrés. |

| Liste des catégories (Live, Films, Séries) plus large et lisible | ✅ CSS + test / ⏳ TV | Largeur `clamp(260px, 25vw, 620px)` au lieu de `clamp(220px, 19vw, 480px)` (≈ 480 px au lieu de 365 px sur un écran 1920) ; un nom long passe sur 2 lignes au lieu d'être coupé par « … ». Non essayé sur la TV. |

## 2026-11-13 — Claude, mini lecteur des films : OK ne passe plus en plein écran (TV Tizen)

| Tâche | État | Détail |
| :--- | :--- | :--- |
| OK sur un film : lecture dans le mini lecteur + curseur déplacé vers lui (pour lire le texte) ; plus de plein écran automatique | ✅ code + tests / ⏳ TV | Option `focusPanelOnActivate` du contrôleur, activée pour Films : un second OK sur le même film ne passe pas non plus en plein écran. Plein écran = bouton « Plein écran » ou OK sur l'écran du mini lecteur. GAUCHE revient au film. Live inchangé (OK sur la chaîne en cours = plein écran). `MiniPlayer` 21/21, `MoviePanelFocus` 2/2, `tsc` propre. Non essayé sur la TV. |

| Mini lecteur : boutons Lecture / Favori / Plein écran / Fiche sur une seule ligne, plus compacts | ✅ CSS + navigation + tests / ⏳ TV | Une ligne (marges, pas de `gap`), boutons de taille égale, texte sur une ligne. Navigation : gauche/droite le long de la ligne, haut = écran du mini lecteur, bas = ligne, gauche depuis « Lecture » = retour au film. Films et Live (même panneau). `MoviePanelFocus` 4/4, `MiniPlayer` 22/22. Non essayé sur la TV : à vérifier que « Plein écran » tient sans être coupé sur votre résolution. |

## 2026-11-13 — Claude, « À suivre » : films similaires dans le lecteur (TV Tizen)

| Tâche | État | Détail |
| :--- | :--- | :--- |
| Films similaires proposés en bas du lecteur, à lire ensuite (comme sur macOS) | ✅ code + tests / ⏳ TV | `getSimilarMovies` : candidats de la même catégorie (puis du catalogue), notés par la règle partagée de `cnd-domain` (`wasm_score_recommendations`, déjà dans le `.wasm` : pas de reconstruction) avec les mêmes noms de critères que les autres plateformes (`group:`, `decade:`, `genre:`…). Rangée « À SUIVRE · FILMS SIMILAIRES » sous les boutons (bas depuis les boutons, OK lit le film) ; à 97 % du film elle apparaît seule avec le curseur sur la 1ʳᵉ proposition. Films finis (95 %+) exclus. `SimilarMovies` 7/7, `PlayerNextShelf` 3/3, `tsc` propre. **Pas encore** : lecture automatique avec compte à rebours, séries/épisodes suivants, sagas, vignettes. Non essayé sur la TV. |

| Fin de film : compte à rebours puis lecture automatique du premier film similaire | ✅ code + tests / ⏳ TV | À la fin (`onStreamCompleted`) : bandeau « Film suivant dans N s » (OK = tout de suite, Retour = annuler sans quitter), puis lecture du 1ᵉʳ film proposé. Après 3 films de suite sans touche : « Toujours là ? ». Réglages > Stockage et informations > « Film suivant » : lecture automatique (activée par défaut) et durée 5/10/15/30 s (10 par défaut). Sans suggestion, le lecteur se ferme comme avant. `UpNextCountdown` 9/9, suite 312/313 (échec préexistant `AiKeyStore`), `tsc` propre. Non essayé sur la TV. |

## 2026-11-13 — Claude, mini lecteur : plus de relance au retour du plein écran (TV Tizen)

| Tâche | État | Détail |
| :--- | :--- | :--- |
| Après plein écran puis Retour, le mini lecteur reste arrêté | ✅ code + tests / ⏳ TV | **Cause** : Live TV relançait automatiquement la dernière chaîne à chaque ouverture, y compris au retour du plein écran (l'arrêt était bien fait, puis la lecture repartait). Maintenant le retour du plein écran ne relance rien ; l'ouverture normale de Live reprend toujours la dernière chaîne. Films et Séries n'avaient pas ce comportement. `LiveReturnFromPlayer` 2/2, `tsc` propre. Non essayé sur la TV. |

## 2026-11-13 — Claude, recommandations dans Live TV (TV Tizen)

| Tâche | État | Détail |
| :--- | :--- | :--- |
| Étagère « ✨ Recommandé pour vous » dans Live TV (vue « Toutes les chaînes ») | ✅ code + tests / ⏳ TV | `getRecommendedChannels` : goût tiré des chaînes vues récemment (de moins en moins) et des favoris (plus fort) ; candidats = chaînes des catégories regardées ; notés par la règle partagée de `cnd-domain` (`wasm_score_recommendations`, déjà dans le `.wasm`) avec les critères `channel:` et `group:` des autres plateformes ; une seule version par chaîne (HD/SD), sans les chaînes déjà connues ni hors service. Calculée après l'affichage (l'écran n'attend pas) ; masquée tant qu'il n'y a ni récent ni favori ; cartes atteignables à la télécommande (jaune = favori aussi). `LiveRecommendations` 8/8, `tsc` propre. Pas encore : créneau horaire (« vos chaînes à cette heure-ci », demande un historique daté), raison affichée sur la carte. Non essayé sur la TV. |

## 2026-11-13 — Claude, Live TV : reconnexion automatique quand le serveur coupe (TV Tizen)

| Tâche | État | Détail |
| :--- | :--- | :--- |
| Reconnexion automatique d'une chaîne qui se fige en plein direct | ✅ code + tests / ⏳ TV | **Cause** : sur un figement de 8 s, le lecteur ne faisait que `pause()` puis `play()` sur le flux mort (rien ne rouvre la connexion) et l'écran restait noir sans message. Maintenant (direct uniquement) : bandeau « Connexion perdue… reconnexion (n/5) », réouverture par le moteur (ferme l'ancienne connexion d'abord) après 1, 2, 4, 8 puis 15 s, 10 s d'attente de reprise à chaque essai ; si le flux revient la lecture repart seule ; sinon « Le serveur ne répond plus. » avec Réessayer / Chaîne suivante / Quitter. Films : récupération inchangée. |
| « Hors service » plus prudent | ✅ | Une chaîne qui n'a jamais démarré est marquée tout de suite (comme avant) ; une chaîne qui jouait puis se tait n'est marquée qu'après 90 s sans reprise, et jamais par la coupure en cours de reconnexion. Test `ChannelHealth` adapté à cette règle. `LiveReconnect` 4/4, `LiveBrokenMarking` 5/5, `tsc` propre. Non essayé sur la TV. **Pas fait** : chaîne miroir automatique, détection par absence d'octets. |

## 2026-11-13 — Claude, films 4K : moins de pauses (TV Tizen)

| Tâche | État | Détail |
| :--- | :--- | :--- |
| Tampon vidéo plus grand pour les films | ✅ code + tests / ⏳ TV | `bufferPolicy` : direct 2 s / 3 s (inchangé), film 8 s avant lecture / 10 s à la reprise (c'était 4 / 6), film 4K (titre ou catégorie « 4K », « UHD », « 2160p ») 12 s / 18 s ; jamais plus de 20 s (mémoire de la TV). Le choix est transmis à AVPlay par `open(url, isLive, hint)` et conservé à la réouverture après veille. Coût : démarrage plus lent de quelques secondes. |
| Message clair à la première pause d'un film | ✅ | Une fois le film lancé, une pause de chargement (hors saut dans le film) affiche « Débit trop faible pour ce film 4K » + « Un câble Ethernet ou une version HD aident. » (autre film : « pour ce flux »). Jamais en direct. `MovieBuffering` 8/8, `tsc` propre, suite verte hors `AiKeyStore`. **Non essayé sur la TV** : l'effet réel sur les pauses est à mesurer. Pas fait : réglage Court/Normal/Long, mesure du débit. |
