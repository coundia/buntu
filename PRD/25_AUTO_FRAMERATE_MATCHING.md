# PRD 25 — Auto-Framerate Matching (AFR) & plage dynamique

- **ID :** `PRD-25`
- **Prérequis :** `PRD-21` (Apple TV : cible principale), `PRD-08` (Lecteur)
- **Couches impactées :** `Player/` (détection de cadence), intégration d'affichage par plateforme
- **Origine :** `PRD-14` §3.5 et §4.4
- **Objectif SLA :** cadence de l'écran alignée sur la vidéo (23,976 / 24 / 25 / 29,97 / 50 / 59,94 / 60 i/s) en **< 2 s** après le début de lecture, retour à la cadence d'origine à la sortie du lecteur, aucune saccade de type *judder* sur un film à 23,976 i/s.

---

## 1. Contexte & Objectif

Un film à 24 i/s affiché sur un écran à 60 Hz produit des saccades. Les lecteurs haut de gamme adaptent la fréquence de l'écran (et la plage dynamique SDR/HDR) au contenu.

---

## 2. Spécifications Techniques Détaillées

### 2.1. Détection de la cadence et de la plage dynamique

- `mpv` : propriétés `container-fps` puis `estimated-vf-fps` (plus fiable sur les flux TS) ; plage dynamique depuis `video-params/gamma` et `video-params/primaries` (`pq` → HDR10, `hlg` → HLG).
- `AVPlayer` : `AVAssetTrack.nominalFrameRate` pour les fichiers ; pour le HLS, attribut `FRAME-RATE` et `VIDEO-RANGE` de la variante (`AVPlayerItem` / `AVAssetVariant`).
- Arrondi aux cadences standard ; un flux entrelacé à 50 champs/s est traité comme 25 ou 50 selon le désentrelacement actif.

### 2.2. Application par plateforme

| Plateforme | Mécanisme | Comportement |
|---|---|---|
| **tvOS** (cible principale) | `AVDisplayManager.preferredDisplayCriteria = AVDisplayCriteria(refreshRate:videoDynamicRange:)` sur la fenêtre | Activé si le réglage système « Faire correspondre la fréquence d'images » l'autorise ; réinitialisé à `nil` à la sortie du lecteur. |
| **macOS** | `CGDisplayCopyAllDisplayModes` / `CGDisplaySetDisplayMode` vers un mode de même résolution et de fréquence multiple de la cadence | **Option désactivée par défaut** (changement de mode visible), uniquement en plein écran, mode d'origine restauré à la sortie et à la fermeture de l'app (y compris après un plantage, au lancement suivant). Écrans ProMotion : préférer une cadence d'affichage adaptée côté rendu plutôt qu'un changement de mode. |
| **iOS / iPadOS** | Pas d'API système de changement de mode | Hors périmètre ; ProMotion gère déjà les cadences variables. |

### 2.3. Interface

- Réglage « Adapter la fréquence de l'écran au contenu » (tvOS : activé ; macOS : désactivé) et indication dans le panneau d'infos du lecteur (« 23,976 i/s · SDR → écran 24 Hz »).

---

## 3. Contraintes Non-Négociables (Guardrails IA)

- Toujours restaurer le mode d'affichage d'origine (macOS), même en cas d'erreur de lecture ou de fermeture brutale.
- Aucun changement de mode pendant le zapping rapide en direct : délai de 2 s de stabilité avant d'appliquer.

## 4. Critères d'Acceptation & Commandes de Validation

1. Tests de l'arrondi des cadences et du choix du mode d'affichage (fonction pure, liste de modes simulée).
2. Tests du contrôleur : application après 2 s de stabilité, réinitialisation à la sortie.
3. Essai manuel sur Apple TV : un film 23,976 i/s puis une chaîne 50 i/s.
4. `task check` au vert.

---

## Statut d'Implémentation & Validation (audit)

**tvOS : réalisé ✅ (à vérifier sur Apple TV) ; macOS : non réalisé ; iOS : hors périmètre.**

- Une première version avait le calcul (`StandardFrameRate`, `DisplayRateMatcher`) mais **rien ne lui fournissait la cadence** de la vidéo : la fonction ne se déclenchait jamais. La branche macOS déclarait « adapté » sans changer de mode.
- **Détection** : `VideoBackend.currentVideoFormat()`. mpv lit `container-fps` puis `estimated-vf-fps`, `video-params/gamma` et `video-params/primaries` ; `AVPlayer` lit `nominalFrameRate` de la piste vidéo et la fonction de transfert (PQ, HLG) de son format. Le lecteur interroge le moteur après le début de la lecture (jusqu'à 10 s) puis transmet à `DisplayRateMatcher` ; la fermeture du lecteur réinitialise l'écran.
- **tvOS** : `AVDisplayCriteria` avec la cadence arrondie et la plage dynamique (HDR10 et HLG passent par les clés de couleur du format, codec HEVC), après 2 s de stabilité ; réglage « Adapter la fréquence de l'écran au contenu » dans Réglages (activé par défaut).
- **Hors réalisé** : changement de mode d'écran sur macOS (`CGDisplaySetDisplayMode`, option désactivée par défaut dans le PRD) ; Dolby Vision (traité comme HDR10) ; indication « → écran 24 Hz » dans le panneau d'infos (le format détecté s'affiche).
- **Validation** : tests de l'arrondi, de la plage dynamique et du branchement lecteur → matcher (4 tests), compilation tvOS. Aucun essai sur une Apple TV.
