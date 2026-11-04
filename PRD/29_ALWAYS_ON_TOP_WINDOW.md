# PRD 29 — Option « Toujours au premier plan » (fenêtre au-dessus de toutes les autres)

- **ID :** `PRD-29`
- **Prérequis :** `PRD-08` (lecteur), `PRD-09` (Live TV, lecteur intégré), `PRD-12` (Picture-in-Picture), `PRD-23` (projet Xcode, app macOS)
- **Couches impactées :** `SwiftUI / AppKit (macOS)` : `App/`, `Player/`, `Features/Settings/`, `KeyboardCommands`
- **Plateformes :** **macOS uniquement.** iOS, iPadOS, tvOS et visionOS ne permettent pas à une app de rester au-dessus des autres ; le Picture-in-Picture système (`PRD-12`) y joue déjà ce rôle.
- **Objectif SLA :** activation ou désactivation **immédiate** (< 100 ms, sans recréer la fenêtre ni couper la lecture).

---

## 1. Contexte & Objectif

On veut pouvoir regarder une chaîne ou un film **pendant qu'on travaille dans une autre application** (navigateur, éditeur de code, tableur) sans que la fenêtre de CND IPTV passe derrière dès qu'on clique ailleurs.

Le Picture-in-Picture existe déjà, mais il a des limites : petite taille, pas de liste de chaînes, pas de contrôles de l'app (zapping, EPG, sous-titres en ligne, favori), et il ne fonctionne qu'avec certains moteurs de lecture.

Ce PRD ajoute une option **« Toujours au premier plan »** : la fenêtre reste au-dessus des fenêtres des autres applications, y compris quand elle n'est pas active.

**Hors périmètre :** superposition au-dessus des apps en plein écran d'autres applications quand ce n'est pas demandé (§ 3.3), fenêtre transparente qui laisse passer les clics (lot facultatif 29.3), plateformes autres que macOS.

---

## 2. Modes proposés

| Mode | Comportement |
| :--- | :--- |
| **Jamais** *(défaut)* | Comportement actuel. |
| **Toujours** | La fenêtre principale reste au premier plan en permanence. |
| **Pendant la lecture** | La fenêtre passe au premier plan quand une lecture démarre et redevient normale quand la lecture est **arrêtée ou fermée**. Une pause ne compte pas comme un arrêt. |

Le mode est **mémorisé** entre les lancements (`UserDefaults`, clé `window.alwaysOnTop`). Il est propre à l'appareil et n'est pas synchronisé par iCloud.

---

## 3. Comportement de la fenêtre (macOS)

### 3.1. Niveau de fenêtre

- Fenêtre au premier plan : `NSWindow.level = .floating`. Ce niveau reste au-dessus des fenêtres normales des autres applications, mais sous les menus, le Dock, les alertes système et le Centre de notifications.
- Retour au niveau normal : `.normal`.
- Les **feuilles et fenêtres secondaires** de l'app (Réglages, journaux, partage, recherche de sous-titres, palette ⌘K) doivent s'afficher **au-dessus** de la fenêtre flottante, jamais derrière. Les feuilles SwiftUI attachées à la fenêtre suivent naturellement ; les fenêtres séparées (Réglages) reçoivent le même niveau tant que la fenêtre principale flotte.
- Les alertes système (mot de passe, autorisations, Trousseau) ne sont jamais masquées : niveau `.floating`, jamais `.screenSaver` ni `.statusBar`.

### 3.2. Espaces (bureaux)

- Option secondaire « **Afficher sur tous les bureaux** » (désactivée par défaut) : `collectionBehavior` ajoute `.canJoinAllSpaces`, pour que la fenêtre suive l'utilisateur quand il change de bureau (Mission Control). Désactivée, la fenêtre reste sur son bureau d'origine.

### 3.3. Plein écran

- **Quand CND IPTV passe en plein écran ou en mode Cinéma**, l'option est sans effet (la fenêtre occupe son propre espace). À la sortie du plein écran, le niveau choisi est rétabli.
- **Au-dessus d'une autre app en plein écran** : option « Afficher au-dessus des apps en plein écran » (désactivée par défaut), via `.fullScreenAuxiliary`. Elle n'a d'effet qu'avec « Afficher sur tous les bureaux ». Son fonctionnement dépend de la version de macOS : **à valider par un prototype** au début du lot 29.2. Si macOS ne le permet pas de façon fiable, l'option n'est pas proposée et le PRD le dit.

### 3.4. Fenêtres multiples

- L'option s'applique à la **fenêtre principale** qui contient le lecteur. Si plusieurs fenêtres de l'app sont ouvertes (`WindowGroup`), chacune garde son propre état, et la commande agit sur la fenêtre active.
- La mosaïque Multi-View (`PRD-16`) suit la fenêtre qui l'affiche.

---

## 4. Lecteur compact (lot 29.2)

Une fenêtre au premier plan n'est utile que si elle est petite. On ajoute donc un **mode compact**, actif seulement quand la fenêtre est au premier plan :

- Commande « **Lecteur compact** » : la fenêtre se réduit au lecteur seul, au format 16:9, sans barre latérale, liste ni barre d'outils. La taille par défaut est de 480 × 270 pt, sans descendre sous 320 × 180 pt. Elle se place dans le coin de l'écran choisi en dernier (en bas à droite par défaut).
- **Redimensionnement proportionnel** (`contentAspectRatio` 16:9) ; la taille et la position du mode compact sont mémorisées séparément de la taille normale.
- Contrôles au survol seulement : lecture/pause, chaîne précédente/suivante, volume, sortie du mode compact. La barre de titre est masquée (`titlebarAppearsTransparent`, fenêtre déplaçable en glissant l'image).
- Sortie du mode compact (double-clic, bouton ou raccourci) : la fenêtre retrouve **sa taille, sa position et sa disposition d'avant**.
- Le mode compact sans premier plan n'a pas d'intérêt : il active le premier plan s'il ne l'est pas, et le premier plan reste actif à la sortie du mode compact.

---

## 5. Points d'accès

- **Menu « Fenêtre »** : « Toujours au premier plan » (coche), sous-menu « Mode » (Jamais / Toujours / Pendant la lecture), « Afficher sur tous les bureaux », « Lecteur compact ».
- **Raccourcis** : ⌥⌘T pour basculer le premier plan ; ⌥⌘P pour le lecteur compact. Ils doivent être vérifiés contre les raccourcis existants de `KeyboardCommands` et ceux du système.
- **Barre du haut du lecteur** : bouton épingle (`pin` / `pin.fill`) qui bascule le premier plan ; info-bulle « Garder au premier plan » / « Ne plus garder au premier plan ».
- **Réglages > Lecture > Fenêtre** : le mode et les deux options secondaires.
- **Indicateur** : épingle pleine dans la barre du lecteur et coche dans le menu tant que la fenêtre flotte.
- Commande disponible depuis l'assistant ⌘K (`PRD-13`) : « garde la fenêtre au-dessus », « lecteur compact ».

---

## 6. Lots

| Lot | Contenu | Validation |
| :--- | :--- | :--- |
| **29.1** | Option premier plan (modes Jamais / Toujours / Pendant la lecture), menu, raccourci, bouton épingle, Réglages, mémorisation, comportement en plein écran et fenêtres secondaires au-dessus. | Tests du modèle d'état ; essai manuel avec un navigateur au premier plan. |
| **29.2** | Lecteur compact (§ 4), tous les bureaux, prototype « au-dessus des apps en plein écran ». | Essais manuels sur deux bureaux et avec une app en plein écran. |
| **29.3** *(facultatif)* | Opacité réglable (50 à 100 %) et option « laisser passer les clics » (`ignoresMouseEvents`) en mode compact, avec un raccourci pour en sortir. | Essai manuel ; le raccourci de sortie doit toujours fonctionner. |

---

## 7. Fichiers à Créer / Modifier

- `apple/Sources/CndIptvKit/App/WindowLevelController.swift` *(nouveau : accès à la `NSWindow` hôte, niveau, `collectionBehavior`, mémorisation)*
- `apple/Sources/CndIptvKit/App/CompactPlayerWindow.swift` *(nouveau, lot 29.2)*
- `apple/Sources/CndIptvKit/App/AppShellView.swift` *(mode « Pendant la lecture », retour après plein écran, mode compact)*
- `apple/Sources/CndIptvKit/App/KeyboardCommands.swift` *(menu Fenêtre, raccourcis)*
- `apple/Sources/CndIptvKit/Player/CndVideoPlayerView.swift` *(bouton épingle, macOS)*
- `apple/Sources/CndIptvKit/Features/Settings/SettingsView.swift`
- `apple/Sources/CndIptvKit/Features/Assistant/` *(deux nouvelles intentions)*
- `apple/Tests/CndIptvAppTests/WindowLevelTests.swift` *(nouveau)*
- `PRD/00_INDEX_ROADMAP.md`

---

## 8. Contraintes Non-Négociables (Guardrails IA)

- Aucun effet sur iOS, iPadOS, tvOS et visionOS : code limité à `#if os(macOS)`, et ces cibles restent vertes.
- Changer le niveau ne recrée pas la fenêtre et n'interrompt pas la lecture (même moteur, même position).
- Jamais de niveau supérieur à `.floating` : ni `.statusBar`, ni `.screenSaver`, ni `.popUpMenu`. Les alertes système et les demandes d'autorisation restent visibles.
- Les feuilles et fenêtres secondaires de l'app ne passent jamais derrière la fenêtre flottante.
- En mode « laisser passer les clics » (lot 29.3), un moyen de sortie (raccourci global de l'app et entrée de menu) reste toujours disponible.
- Pas de nouvelle dépendance.

---

## 9. Critères d'Acceptation & Commandes de Validation

1. **Tests Swift (modèle d'état, sans fenêtre réelle) :**
   - mode « Pendant la lecture » : premier plan au démarrage, maintenu en pause, retiré à l'arrêt et à la fermeture ;
   - retour au niveau choisi après la sortie du plein écran ;
   - mémorisation du mode ;
   - mode compact qui force le premier plan, puis restaure la taille et la disposition.
2. **Essais manuels (macOS) :**
   - option active, clic dans Safari : CND IPTV reste visible au-dessus ;
   - Réglages et palette ⌘K affichés au-dessus de la fenêtre flottante ;
   - plein écran puis sortie : premier plan rétabli ;
   - « Afficher sur tous les bureaux » : la fenêtre suit le changement de bureau ;
   - lecteur compact : taille 16:9, déplacement, retour à la disposition d'avant.
3. `cd apple && swift test`, builds des 4 schémas Xcode, `task check` au vert.

---

## 10. Questions ouvertes

- **Mode par défaut :** « Jamais » (retenu) ou « Pendant la lecture » ?
- **Raccourcis :** ⌥⌘T et ⌥⌘P sont des propositions, à confirmer après vérification des conflits.
- **iPad :** Stage Manager ne permet pas de fenêtre au premier plan ; faut-il proposer à la place le PiP automatique quand on quitte l'app (déjà possible avec AVPlayer) ?

---

## 11. Statut d'Implémentation & Validation

**Lots 29.1 et 29.2 (sans le prototype « au-dessus des apps en plein écran ») — réalisés ✅, à essayer à l'écran ; lot 29.3 non réalisé.**

- **Lot 29.1** (`App/WindowLevelController.swift`) : trois modes (Jamais, Toujours, Pendant la lecture) et leur règle `AlwaysOnTopPolicy` (testée sans fenêtre : pas de premier plan en plein écran ; « Pendant la lecture » suit la présence d'un média, une pause compte, une fermeture non). Niveau `.floating` au plus, appliqué sans recréer la fenêtre ; une nouvelle fenêtre principale reçoit le niveau courant ; le niveau est rétabli à la sortie du plein écran. Mode et « Afficher sur tous les bureaux » mémorisés dans `UserDefaults` (`window.alwaysOnTop`, `window.allSpaces`), par appareil. Accès : menu Fenêtre (« Toujours au premier plan » ⌥⌘T, « Mode du premier plan », « Afficher sur tous les bureaux »), bouton épingle de la barre du lecteur, Réglages > Fenêtre.
- **Lot 29.2** : « Lecteur compact » (menu Fenêtre, ⌥⌘O) : la fenêtre se réduit au lecteur 16:9 (480 × 270 par défaut, 320 × 180 au minimum, coin bas droit, taille et position mémorisées), sans barre latérale, barre d'outils ni titre, déplaçable en glissant l'image, avec une barre réduite (sortie, titre, épingle). Il active le premier plan s'il ne l'est pas et le laisse actif à la sortie ; la sortie (bouton, double-clic, menu, ou fin de lecture) rétablit la taille, la position et la disposition d'avant. ⌥⌘P, proposé au départ, sert déjà à l'Image dans l'image : ⌥⌘O est retenu.
- **Validation** : 14 tests (règle, modes, plein écran, bascule, mémorisation, niveau et comportement d'une vraie `NSWindow` sans dépasser `.floating`, conditions du mode compact) ; 345 tests Swift au vert ; builds macOS, iOS, tvOS et visionOS (simulateur) réussis, le code est limité à macOS.
- **Non vérifié / non fait** : aucun essai à l'écran (premier plan au-dessus d'un navigateur, deux bureaux, mode compact en lecture) ; « Afficher au-dessus des apps en plein écran » (`.fullScreenAuxiliary`, prototype prévu) non réalisé ; lot 29.3 (opacité, clics traversants) non réalisé ; commandes de l'assistant ⌘K (« garde la fenêtre au-dessus », « lecteur compact ») non ajoutées ; le mode compact n'a pas de barre de contrôles dédiée au survol : les contrôles du bas sont ceux du lecteur habituel ; avec plusieurs fenêtres, l'option agit sur la fenêtre principale.
