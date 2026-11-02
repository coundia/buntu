# PRD 21 — Application native Apple TV (tvOS, Siri Remote)

- **ID :** `PRD-21`
- **Prérequis :** `PRD-23` (projet Xcode signé), `PRD-08` (Lecteur), `PRD-09`/`PRD-10` (écrans), `PRD-12` (iCloud, pour recevoir les sources depuis l'iPhone)
- **Couches impactées :** `scripts/build-xcframework.sh`, `apple/Package.swift`, nouvelle cible tvOS, `SwiftUI (dossier Platforms/tvOS/)`
- **Origine :** `PRD-14` §4.6
- **Objectif SLA :** zapping haut/bas **< 1 s** jusqu'à l'image, navigation au focus fluide (aucune image perdue au défilement des grilles), démarrage à froid **< 2 s**.

---

## 1. Contexte & Objectif

L'IPTV se regarde surtout sur la télévision du salon. Le moteur Rust et la logique Swift (modèles, lecteur) sont réutilisables ; l'interface doit être repensée pour la télécommande (moteur de focus) et l'écran à 3 mètres.

---

## 2. Étapes techniques

### 2.1. Moteur Rust pour tvOS

- Cibles `aarch64-apple-tvos` et `aarch64-apple-tvos-sim` (présentes dans `rustup target list` sur cette machine ; vérifier leur niveau de support avant de commencer, et passer par `-Zbuild-std` sur nightly si la bibliothèque standard précompilée manque).
- Ajout des deux tranches à `scripts/build-xcframework.sh` (`TVOS_DEPLOYMENT_TARGET=17.0`) et à l'`XCFramework`.
- `Package.swift` : plateforme `.tvOS(.v17)`.

### 2.2. Lecture

- `AVPlayer` lit le HLS, mais **pas** le MPEG-TS progressif, très courant en IPTV : `libmpv` est indispensable. Utiliser une build tvOS de libmpv sous licence **LGPL** (ex. distributions communautaires type MPVKit compatibles tvOS), embarquée et signée dans `Frameworks/` (cf. `PRD-23`). Sans elle, l'application ne propose que les chaînes HLS et l'indique.
- Le chargement par `dlopen` du PRD 08 reste valable ; ajouter le chemin `Frameworks/` du bundle tvOS.

### 2.3. Interface « 10-foot »

- Navigation par `TabView` en haut : Live TV, Guide, Films, Séries, Réglages. Pas de Téléchargements ni de PVR (stockage tvOS non garanti : cache uniquement).
- **Live TV plein écran** : haut/bas sur la Siri Remote = chaîne précédente/suivante (`onMoveCommand`), clic = bandeau d'infos (programme en cours/suivant), menu = liste des chaînes en surimpression avec catégories.
- Grilles avec `focusable`, `focusSection`, effet de survol (`hoverEffect`) ; affiches et logos plus grands (cache d'images existant, `ThumbnailSize` dédiée).
- Guide EPG adapté au focus (déplacement par case).
- **Ajout de sources** : clavier tvOS, Continuity Keyboard depuis l'iPhone, et surtout **synchronisation iCloud** depuis l'app iPhone/Mac (mots de passe Xtream à ressaisir car le Trousseau ne se synchronise pas, ou Trousseau iCloud si `kSecAttrSynchronizable` est activé en PRD 23).
- Lecteur : `onPlayPauseCommand`, `onExitCommand`, glissement sur la surface tactile pour ±10 s en VOD, pistes audio/sous-titres dans le panneau d'infos.

### 2.4. Code partagé

- Déplacer la logique indépendante de la plateforme (modèles `@Observable`, `PlayableMedia`, `CndPlayerController`, `VodContext`…) dans la bibliothèque commune créée au PRD 23 ; les vues tvOS dans `Platforms/tvOS/`. Les `#if os(tvOS)` dans les vues existantes restent l'exception.

---

## 3. Contraintes Non-Négociables (Guardrails IA)

- Aucun écran inatteignable à la télécommande (vérifié au clavier du Simulateur Apple TV et au focus).
- libmpv LGPL en liaison dynamique uniquement (conformité App Store).
- Builds iOS et macOS inchangés et toujours verts.

## 4. Critères d'Acceptation & Commandes de Validation

1. `xcodebuild … -destination 'generic/platform=tvOS Simulator' build` réussit, et la suite existante (`task check`) reste verte.
2. Tests Swift des modèles partagés exécutés aussi pour tvOS (`xcodebuild test` sur un simulateur Apple TV).
3. Parcours manuel au Simulateur Apple TV : zapping, guide, film, réglages, sans souris.
