# PRD 08 — Moteur Vidéo Hybride "Zero-Lag" (`AVPlayer` + `libmpv` VideoToolbox) & Lecteurs Externes

- **ID :** `PRD-08`
- **Prérequis :** `PRD-01`
- **Couches impactées :** `Swift / C++ (apple/Sources/CndIptvApp/Player/)`, `apple/Package.swift`
- **Référence Flutter migrée :** `lib/ui/widgets/cnd_video_player.dart`, `lib/ui/pages/playlist_player_page.dart`, `lib/ui/pages/episodePlay.dart`, `lib/services/open_external.dart`
- **Objectif SLA :** Zapping Live TV **< 400 ms**, utilisation CPU **< 8 %** en lecture 1080p/4K HEVC (`VideoToolbox`), Stall Watchdog réactif sous 4 s avec reconnexion réseau native via `NWPathMonitor`.

---

## 1. Contexte & Objectif

Un lecteur IPTV natif sur Apple doit relever un double défi :
1. **`AVPlayer` natif** est imbattable en consommation énergétique (`< 3 % CPU`), en démarrage HLS (`.m3u8`), en AirPlay 2 matériel et en Picture-in-Picture, **mais** il refuse les flux MPEG-TS bruts (`.ts`), les conteneurs `.mkv`/`.avi` et les pistes audio `AC3`/`DTS` non packagées Apple.
2. **`libmpv` / `FFmpeg` (LGPLv2.1+)** via `VideoToolbox` décode absolument tous les formats IPTV mondiaux (`.ts`, `.mkv`, `HEVC`, `AC3`, `EAC3`, `DTS`, sous-titres `ASS`/`SRT`/`PGS`).

Ce PRD met en place un **Dual-Engine Video Controller (`CndPlayerController`)** unifié derrière une même vue SwiftUI `CndVideoPlayerView`, accompagné du gestionnaire de playlist multi-épisodes et du lanceur de lecteurs externes (**IINA, VLC, Infuse, Outplayer** + générateur `ffmpeg`/`curl`).

---

## 2. Fichiers à Créer / Modifier

- `apple/Package.swift` *(ajout dépendance SPM `MPVKit` LGPL ou target wrapper `libmpv` si disponible, avec fallback propre)*
- `apple/Sources/CndIptvApp/Player/PlayableMedia.swift` *(modèle unifié flux Live / Film / Playlist d'épisodes + headers HTTP)*
- `apple/Sources/CndIptvApp/Player/VideoBackendProtocol.swift` *(contrat commun `AVPlayerBackend` & `MpvBackend`)*
- `apple/Sources/CndIptvApp/Player/AVPlayerBackend.swift` *(`AVURLAsset` avec `AVURLAssetHTTPHeaderFieldsKey`, observateurs timecode/buffer)*
- `apple/Sources/CndIptvApp/Player/MpvVideoToolboxBackend.swift` *(`libmpv` avec `hwdec=videotoolbox`, rendu Metal / `AVSampleBufferDisplayLayer`, sélection pistes audio/sous-titres)*
- `apple/Sources/CndIptvApp/Player/CndPlayerController.swift` *(`@Observable` : routing automatique AVPlayer ↔ MPV, Stall Watchdog, `NWPathMonitor`, Playlist Saison, sauvegarde progression)*
- `apple/Sources/CndIptvApp/Player/CndVideoPlayerView.swift` *(surface vidéo `NSViewRepresentable` / `UIViewRepresentable` + HUD contrôles auto-masqués)*
- `apple/Sources/CndIptvApp/Player/ExternalPlayerLauncher.swift` *(IINA, VLC, Infuse + presse-papier commande `ffmpeg` / `curl`)*

---

## 3. Spécifications Techniques Détaillées

### 3.1. Routage Automatique Dual-Engine (`CndPlayerController`)
Lors de l'ouverture d'un `PlayableMedia(title, url, headers, kind, startPositionMs)` :
1. **Sélection initiale :**
   - Choisir `AVPlayerBackend` si l'extension/URL est `.m3u8` ou `.mp4`/`.mov` standard.
   - Choisir directement `MpvVideoToolboxBackend` si l'URL est un flux brut `.ts`, `.mkv`, `.avi`, `.flv`, ou si l'utilisateur a forcé le moteur MPV dans ses préférences.
2. **Fallback Transparent Instantané (`< 200 ms`) :**
   - Si `AVPlayerBackend` émet une erreur de décodage/format (`AVPlayerItem.Status.failed`), basculer automatiquement et sans action utilisateur sur `MpvVideoToolboxBackend` en conservant `headers` et `startPositionMs` !

### 3.2. Configuration Stricte `VideoToolbox` & Zapping Rapide
Pour `MpvVideoToolboxBackend` :
- Options obligatoires à l'initialisation :
  - `hwdec = "videotoolbox"` (décodage matériel GPU Apple Silicon obligatoire).
  - `vo = "gpu-next"` / `gpu-context = "macvk"` ou render API sur `CAMetalLayer` / `AVSampleBufferDisplayLayer`.
  - `demuxer-max-bytes = "64MiB"`, `cache = "yes"`.
  - Pour `kind == "live"` : profil basse latence (`cache-secs = 3`, reconnexion HTTP activée `stream-lavf-o = "reconnect=1,reconnect_streamed=1,reconnect_delay_max=2"`).
  - Propagation exacte de `user-agent`, `referrer` et `http-header-fields` (issus de `#EXTVLCOPT` / `#KODIPROP` / `RuntimeSettings`).

### 3.3. Stall Watchdog & Reconnexion Réseau (`NWPathMonitor`)
Remplacement natif et fiable de la logique `_startStallWatch` / `_scheduleRetry` de `cnd_video_player.dart` :
- Un tâche asynchrone vérifie chaque seconde que `currentPosition` avance lorsque `state == .playing`.
- Si le flux est figé depuis `>= 4 secondes` (hors pause et hors fin de VOD) ou en erreur :
  - Utiliser `Network.NWPathMonitor` d'Apple (zéro dépendance tierce) pour vérifier la connectivité réelle.
  - Lancer jusqu'à `3 tentatives` de reconnexion avec backoff (`1s`, `2s`, `4s`), en reprenant exactement au dernier `currentPosition` connu pour un Film/Épisode VOD, et afficher un bandeau discret non bloquant dans le HUD (`Reconnexion 1/3…`).

### 3.4. Contrôles HUD, Pistes Audio/Sous-Titres & Playlist Multi-Épisodes
- **Contrôles HUD SwiftUI (auto-hide après 3 s d'inactivité souris/tactile) :**
  - Lecture/Pause, recul/avance `-10s` / `+10s`, barre de scrubbing fluide VOD ou badge rouge `LIVE`, volume + mute, vitesse (`0.5x`, `1.0x`, `1.25x`, `1.5x`, `2.0x`), sélecteur de piste **Audio** et **Sous-titres**, plein écran.
- **Mode Playlist (`PlaylistQueue`) :**
  - Permet de charger toute une saison ou série (`[PlayableMedia]`, `currentIndex`), avec boutons *Épisode précédent / suivant* et enchaînement automatique à la fin d'un épisode.
  - Sauvegarde périodique (toutes les 5 s et à la fermeture) de la progression via `engine.recordWatchProgress(...)` (`PRD-05`).

### 3.5. Lecteurs Externes & Générateur CLI (`ExternalPlayerLauncher.swift`)
- **macOS :** Détecter et proposer l'ouverture directe dans **IINA** (`iina://weblink?url=...`), **VLC** (`vlc://...` ou ouverture via `NSWorkspace` vers `/Applications/VLC.app` / `/Applications/IINA.app`).
- **iOS :** Support des URL schemes `vlc-x-callback://x-callback-url/stream?url=...`, `infuse://x-callback-url/play?url=...`, `outplayer://...`.
- **Outils Power-User (parité `MovieDetailsPage` / `SeriesDetailsPage`) :**
  - `copyStreamUrl()`
  - `copyFfmpegCommand()` : génère `ffmpeg -headers $'User-Agent: ...\r\nReferer: ...\r\n' -i "<url>" -c copy "<safe_title>.mp4"` prêt à coller dans un terminal !
  - `copyCurlCommand()` : génère `curl -L -H "User-Agent: ..." "<url>" -o "<safe_title>.mp4"`.

---

## 4. Contraintes Non-Négociables (Guardrails IA)
- **Zéro fuite mémoire / Thread zombie :** À la fermeture de `CndVideoPlayerView` (`onDisappear` / `deinit`), détruire proprement l'instance `AVPlayer` / `mpv_handle`, annuler le `NWPathMonitor` et les `Task` du Watchdog.
- **Licence App Store :** Utiliser uniquement un build `MPVKit` / `FFmpeg` **LGPLv2.1+** (sans code GPL).

---

## 5. Critères d'Acceptation & Commandes de Validation
1. Tests unitaires Swift sur :
   - La logique de sélection automatique `AVPlayer` vs `MPV` selon l'URL et les headers.
   - La génération exacte et échappée des commandes `ffmpeg` et `curl` avec headers HTTP personnalisés.
   - La navigation `next()` / `previous()` de `PlaylistQueue`.
2. Compilation propre macOS & iOS Simulator :
   ```bash
   cd cnd-iptv-native/apple
   xcodebuild -scheme CndIptvNative -destination 'generic/platform=macOS' build
   xcodebuild -scheme CndIptvNative -destination 'generic/platform=iOS Simulator' build
   ```

