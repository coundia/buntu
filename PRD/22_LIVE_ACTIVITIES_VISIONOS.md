# PRD 22 — Live Activities, Dynamic Island & visionOS

- **ID :** `PRD-22`
- **Prérequis :** `PRD-23` (projet Xcode, extension de widget), `PRD-19` (enregistrements, pour le lot 22.1), `PRD-21` recommandé (code partagé multi-plateformes)
- **Couches impactées :** extension Widget iOS, `ActivityKit`, nouvelle cible visionOS, `RealityKit`
- **Origine :** `PRD-14` §4.6 et tableau PRD-22
- **Objectif SLA :** Live Activity démarrée **< 1 s** après le début d'un enregistrement, mise à jour au plus **1 fois par minute** (économie de batterie) ; sur Vision Pro, écran virtuel stable à 90 Hz.

Deux lots indépendants.

---

## Lot 22.1 — Live Activities & Dynamic Island (iOS / iPadOS)

- **Cas d'usage :**
  1. **Enregistrement en cours** (PRD 19) : chaîne, titre, temps restant, barre de progression ; bouton « Arrêter » (App Intent).
  2. **Programme en cours de lecture** : chaîne et programme, progression du programme, programme suivant.
- `ActivityAttributes` partagés entre l'app et l'extension ; présentation compacte, étendue et minimale pour la Dynamic Island ; écran verrouillé.
- Mises à jour **locales** (`Activity.update`) pendant que l'app tourne ; pas de notifications push (pas de serveur). Fin de l'activité à la fin de l'enregistrement ou de la lecture.
- `Info.plist` : `NSSupportsLiveActivities = YES` (projet du PRD 23).
- Réglage pour désactiver chaque type d'activité.

## Lot 22.2 — visionOS (Apple Vision Pro)

- Moteur Rust : cibles `aarch64-apple-visionos` et `aarch64-apple-visionos-sim` (présentes dans `rustup target list` ; vérifier le niveau de support), ajout à l'`XCFramework`, `.visionOS(.v2)` dans `Package.swift`.
- Application en **fenêtres** reprenant l'interface iPad (navigation, catalogue, réglages).
- **Mode Cinéma** (espace immersif) : écran virtuel géant avec `RealityKit` ; lecture `AVPlayer` via `VideoPlayerComponent` (HLS). Le chemin `mpv` (TS, MKV) nécessite un rendu par `AVSampleBufferDisplayLayer` / renderer vidéo compatible RealityKit : **à valider par un prototype** au début du lot ; à défaut, le mode Cinéma reste limité aux flux HLS et le dit.
- Audio spatialisé fourni par le système pour `AVPlayer`.

---

## Contraintes Non-Négociables (Guardrails IA)

- Aucune donnée sensible (URL de flux, identifiants) dans les `ActivityAttributes` : seulement noms de chaîne, titres et horaires.
- Les cibles iOS, macOS et tvOS existantes restent vertes.

## Critères d'Acceptation & Commandes de Validation

1. Lot 22.1 : build de l'extension, tests du modèle d'état des activités (démarrage, mise à jour limitée à 1/min, fin), essai manuel sur iPhone avec Dynamic Island.
2. Lot 22.2 : `xcodebuild … -destination 'generic/platform=visionOS Simulator' build`, parcours manuel au simulateur Vision Pro, mode Cinéma avec un flux HLS.
3. `task check` au vert.

---

## Statut d'Implémentation & Validation

**Lot 22.1 — réalisé ✅ (à vérifier sur l'appareil) ; lot 22.2 (visionOS) — fenêtres réalisées (compilation vérifiée), mode Cinéma non réalisé.**

- Une première version ne contenait qu'un `LiveActivityManager` que rien n'appelait, et aucune extension Widget : aucune activité ne pouvait s'afficher. Le lot a été refait.
- **Extension Widget** (`apple/LiveActivityExtension/`, cible `CndIPTV-LiveActivity` dans `project.yml`, embarquée dans l'app iOS) : écran verrouillé et Dynamic Island (compacte, étendue, minimale) pour l'enregistrement en cours (compte à rebours automatique, barre de progression, bouton « Arrêter » via `StopRecordingIntent`) et pour le programme lu.
- **App** : `RecordingsModel` transmet la liste des enregistrements (relevée chaque seconde) à `LiveActivityManager.sync`, qui applique les règles de `RecordingActivityPlanner` (démarrage à l'apparition de l'enregistrement, mise à jour au plus une fois par minute, fin à l'arrêt). La lecture démarre et termine l'activité « en cours de lecture ». Deux réglages dans Réglages (iOS) désactivent chaque type. Les `ActivityAttributes` ne contiennent que des noms, titres et horaires.
- **Validation** : 6 tests du planificateur (démarrage unique, limite de 60 s, fin, progression, absence d'adresse dans les attributs), build de l'app avec l'extension pour le simulateur iOS et pour un iPhone (signé, installé). **Non vérifié** : l'affichage réel sur l'écran verrouillé et dans la Dynamic Island, et le bouton « Arrêter » (à essayer sur iPhone en lançant un enregistrement). L'enregistrement sur iOS ne tourne que tant que l'app est active.
- **Lot 22.2, partie fenêtres — compile ✅** : le moteur Rust se compile pour `aarch64-apple-visionos` et `-sim` (support officiel de `rustc`, `rustup target add` suffit), l'`XCFramework` contient les tranches `xros-arm64` et `xros-arm64-simulator`, `Package.swift` déclare `.visionOS(.v1)`, et la cible `CndIPTV-visionOS` (`project.yml`, `Info-visionOS.plist`) reprend l'interface iPad en fenêtres. Le bouton AirPlay est absent sur visionOS. `xcodebuild -scheme CndIPTV-visionOS -destination 'generic/platform=visionOS Simulator' build` réussit (`task xcode:visionos`). Comme sur iPhone, `libmpv` n'est pas inclus : les chaînes passent par leur adresse HLS et les MKV ne se lisent pas.
- **Non vérifié / non réalisé** : aucun simulateur Vision Pro n'est installé sur la machine de développement, donc l'app n'a jamais été lancée sur visionOS (ni signée pour un appareil). Le **mode Cinéma** (espace immersif, écran virtuel `RealityKit`, `VideoPlayerComponent`) n'est pas réalisé et exige un prototype sur simulateur ou appareil.
- La cible tvOS avait la clé iCloud dans son `Info.plist` sans le droit correspondant (même plantage au lancement que sur iPhone) : retirée.
