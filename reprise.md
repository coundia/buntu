# Reprise du Projet `cnd-iptv-native` (Passation vers Claude Code)

Date : 2 novembre 2026

---

## 1. État Global du Projet

Le projet est dans un état **100 % sain, compilant et testé** :
- **Workspace Rust (`cargo test --workspace`)** : **103 tests passés**, 0 échec.
- **Linter Rust (`cargo clippy --workspace -- -D warnings`)** : **0 avertissement, 0 erreur**.
- **XCFramework Universel (`scripts/build-xcframework.sh`)** : compilé et synchronisé avec les headers C et bindings Swift UniFFI.
- **Suite de tests Swift (`swift test`)** : **191 tests passés**, 0 échec.

---

## 2. Statut des PRD

| PRD | Titre | Statut |
| :---: | :--- | :---: |
| **PRD-01 à 13** | Socle v1 (M3U, Xtream, EPG, Player hybride, Téléchargements, VOD, Assistant IA) | **Terminé `[x]`** |
| **PRD-14** | État des lieux & Roadmap d'Innovation | **Terminé `[x]`** |
| **PRD-15** | Catch-up TV Replay & Start-Over (timeshift Xtream & Flussonic, rétention EPG) | **Terminé `[x]`** |
| **PRD-16** | Multi-View Mosaïque (2 à 4 flux, audio exclusif, raccourcis, IA "TF1 et M6 côte à côte") | **Terminé `[x]`** |
| **PRD-17** | Health-Check & Auto-Failover Miroir (sonde MPEG-TS/HLS, bascule < 3 s, table `stream_health`) | **Terminé `[x]`** |
| **PRD-18** | Dialogue Boost & Sous-titres OpenSubtitles | **En cours (fichier `AudioEnhancement.swift` créé)** |
| **PRD-19 à 25** | PVR, Bouquets/Parental, tvOS, Live Activities, Xcode Signé, Pause Direct, Framerate | **À faire `[ ]`** |

---

## 3. Ce qui vient d'être livré (Sessions récentes)

### PRD-15 — Replay & Catch-up EPG
- Algorithme de calcul de dates Howard Hinnant (`civil_from_days`, UTC sans allocations).
- Résolution universelle d'URLs de replay (Xtream Codes `/timeshift/...`, Flussonic `/timeshift_abs-...`, modes append/shift).
- Grille EPG rétrospective (jusqu'à 14 jours) et boutons « Revoir (Replay) » / « Reprendre depuis le début ».

### PRD-16 — Multi-View Mosaïque
- Calcul des grilles dans `MultiViewLayout.swift` (`sideBySide`, `grid2x2`, `onePlusThree`).
- Contrôleur multi-lecteurs `MultiViewController.swift` avec audio exclusif et respect strict de `maxConnections`.
- Interface `MultiViewScreen.swift` avec tuiles interactives et mini-HUD.
- Détection IA en langage naturel (`AiAction::MultiView { item_ids }`) pour « TF1 et M6 côte à côte ».

### PRD-17 — Health-Check & Auto-Failover Miroir
- **Rust Core (`crates/cnd-core/src/health/`)** :
  - `mirrors.rs` : détection d'équivalence par `tvg_id` ou tokens normalisés (`channel_name_tokens`), scoring de qualité (4K > FHD > HD > SD), tri par santé connue.
  - `probe.rs` : sonde légère HTTP/TS (3 octets `0x47` espacés de 188 octets) et HLS (playlist maître/variante + segment probe), timeout 5 s.
  - `mod.rs` : worker périodique (favoris + récents), table `stream_health`, auto-signalement en panne après 3 échecs consécutifs (`origin = 'auto'`), respect strict de `max_connections`.
- **Swift Layer** :
  - `CndPlayerController.swift` : bascule miroir automatique après échec des reconnexions ou 2 décrochages rapides (< 60 s), plafonné à 2 bascules par session, bandeau visuel non bloquant.
  - `ChannelCardView.swift` & `LiveTvView.swift` : pastilles de santé (vert, orange, rouge), menu contextuel « Alternatives (Miroirs) » avec feuille `MirrorSheetView`.
  - `SettingsView.swift` : réglages « Bascule automatique » et « Vérification périodique ».

---

## 4. Prochaine Étape pour Claude Code

Reprendre au **PRD-18 : Dialogue Boost & Sous-titres OpenSubtitles** (`PRD/18_DIALOGUE_BOOST_OPENSUBTITLES.md`) :
1. **Lot 18.1 (Dialogue Boost & Mode nuit)** :
   - Le fichier `apple/Sources/CndIptvApp/Player/AudioEnhancement.swift` est déjà créé (génère la chaîne de filtres mpv `af`).
   - Brancher `setAudioEnhancement` sur `VideoBackendProtocol` et `MpvVideoToolboxBackend.swift` (`mpv_set_property_string(handle, "af", filterString)`).
   - Ajouter le menu Dialogue Boost (Off / Low +3dB / Med +6dB / High +9dB) et Mode nuit dans `CndVideoPlayerView.swift`.
   - Proposer la bascule vers mpv si l'utilisateur active Dialogue Boost pendant un flux HLS sur `AVPlayer`.
2. **Lot 18.2 (OpenSubtitles)** :
   - Rust core `crates/cnd-core/src/subtitles/{hash, srt, mod}.rs`.
   - Calcul `moviehash` 64 bits et parseur SRT en streaming.
   - Surcouche de sous-titres `SubtitleOverlay.swift` avec réglage de décalage (±0,25 s).

---

## 5. Déploiement Physique iOS (iPhone 14 Pro)

L'application a été compilée, signée et déployée avec succès sur le téléphone physique connecté :
- **Appareil cible** : `icnd 14` — iPhone 14 Pro (`iPhone15,2`), iOS 27.0.1 (arm64/arm64e), UDID: `00008120-00064CA63698201E`.
- **Mode Développeur** : Activé (`Developer Mode Status: Enabled (1)`).
- **Profil de provisionnement & Signature** :
  - Identité : `Apple Development: papa.coundia@unchk.edu.sn (X6427LV6MG)`
  - Profil : `e86c8551-2442-429f-9b95-4d9914b64f7d.mobileprovision` (Bundle ID : `com.saytu.agent.ios`, Team : `Q6V7UDW27J`).
- **Correction apportée** :
  - `HealthService::start` s'exécutant sur le thread synchrone de l'app sans contexte Tokio réactif, le worker a été adapté pour démarrer son propre runtime local sur un thread dédié (`std::thread::Builder::new().name("cnd-health-worker")`) lorsqu'aucun runtime Tokio ambiant n'est détecté.
- **Statut d'exécution** :
  - Bundle `.app` assemblé, signé avec entitlements DER et installé via `xcrun devicectl device install app`.
  - Processus lancé et en cours d'exécution au premier plan sur l'iPhone.
  - La console réseau intégrée affiche les logs Rust en direct : `CndEngine initialized (SQLite WAL + FTS5 + HttpClientPool)`.

