# PRD 30 — Interface responsive : icônes, barre latérale, catégories, cartes et lecteur à l'échelle

- **ID :** `PRD-30`
- **Prérequis :** `PRD-09`, `PRD-10`, `PRD-11` (écrans SwiftUI), `PRD-21` (Apple TV), `PRD-22` (visionOS), `PRD-27` (« À suivre »), `PRD-29` (lecteur compact)
- **Couches impactées :** `SwiftUI (apple/Sources/CndIptvKit/**)` uniquement, avec un nouveau module `Shared/Design/`
- **Plateformes :** macOS, iPhone, iPad, Apple TV, Vision Pro
- **Objectif SLA :** aucune régression de fluidité (défilement des grilles à 120 i/s sur ProMotion, comme au `PRD-10`) ; changement de taille appliqué **immédiatement**, sans relancer l'app.

---

## 1. Contexte & Objectif

L'interface utilise aujourd'hui des **tailles fixes**. Un relevé du code montre :

- **68 cadres de taille fixe** :
  - logos de chaînes en 44 × 44 ;
  - affiches de 44 × 66 à 150 × 225 ;
  - cartes de chaînes en 280 de large ;
  - affiches de rangées en 150 ;
  - flèches de défilement en 22 × 28 et 24 × 40 ;
  - colonne des catégories en 190 ou 250.
- **8 polices en taille absolue**, dont des badges en **8 et 9 points**, illisibles sur un grand écran comme sur un iPhone.
- **Grilles à largeur minimale fixe** : 240 pour les chaînes, 155 pour les films, 420 pour les téléchargements.
- **Barre latérale macOS** de 180 à 280 de large, avec des icônes système à la taille par défaut.
- **Peu d'adaptation à la taille du texte** : seuls 4 fichiers utilisent `dynamicTypeSize`, `@ScaledMetric`, les classes de taille ou `ViewThatFits`.

Résultat :
- sur un grand écran (iMac 27", Apple TV), les icônes de favoris, de la barre latérale et des catégories paraissent minuscules ;
- sur une petite fenêtre ou un iPhone SE, des éléments débordent ou sont coupés ;
- le réglage « Taille du texte » du système n'a presque aucun effet.

Ce PRD rend **toute l'interface proportionnelle** : icônes, textes, cartes, affiches, logos, boutons du lecteur, barre latérale, catégories, badges. Elle suit la taille de l'écran, la taille de la fenêtre et la taille de texte choisie par l'utilisateur.

---

## 2. Principes

1. **Une seule source de tailles** : un module de jetons de design (`Shared/Design/`) définit les tailles d'icônes, d'espacements, de cartes, d'affiches, de logos, de rayons et de cibles tactiles. **Aucune valeur numérique de taille** n'est écrite directement dans une vue (seules les exceptions documentées sont permises, § 8).
2. **Trois facteurs combinés** :
   - la **taille de texte** du système (Dynamic Type, iOS / iPadOS / tvOS / visionOS) ;
   - un **réglage de l'app « Taille de l'interface »**, surtout utile sur macOS, où Dynamic Type n'existe pas pour les apps ;
   - la **place disponible** (largeur de fenêtre ou d'écran, classes de taille).
3. **Les icônes suivent le texte qu'elles accompagnent** : icônes SF Symbols dimensionnées par le style de texte (`.font(.body)`, `.imageScale`) ou par `@ScaledMetric`, jamais par une taille de police absolue.
4. **Les mises en page s'adaptent au lieu de rétrécir** : passage d'une rangée à une colonne, de l'icône + texte à l'icône seule, d'une grille à une liste, avec `ViewThatFits` et des seuils de largeur.
5. **Cibles tactiles minimales** : 44 × 44 pt sur iPhone et iPad, 28 × 28 pt sur macOS, focus agrandi sur Apple TV, 60 pt sur Vision Pro (regard + pincement).

---

## 3. Jetons de design (`Shared/Design/`)

### 3.1. Échelle

`UIScale` combine les facteurs du § 2.2 en un **coefficient unique** exposé dans l'environnement SwiftUI (`@Environment(\.uiScale)`), borné entre **0,85 et 1,6**.

| Réglage « Taille de l'interface » | macOS | Autres plateformes |
| :--- | :--- | :--- |
| Petite | 0,9 | Dynamic Type `.small` |
| Standard *(défaut)* | 1,0 | Taille de texte du système |
| Grande | 1,15 | `.xLarge` |
| Très grande | 1,3 | `.xxxLarge` |

Sur iOS, iPadOS, tvOS et visionOS, le réglage de l'app **s'ajoute** au réglage système : il impose une taille minimale (`dynamicTypeSize(...)`), sans jamais réduire ce que l'utilisateur a choisi dans le système. Les tailles d'accessibilité (`.accessibility1` à `.accessibility5`) sont prises en charge (§ 6).

### 3.2. Familles de jetons

- **Icônes :**
  - `iconXS` : badges, pastilles d'état ;
  - `iconS` : favoris dans une liste, indicateurs ;
  - `iconM` : barre latérale, catégories, boutons de la barre d'outils ;
  - `iconL` : boutons du lecteur ;
  - `iconXL` : états vides, lecture au centre.
- **Logos et affiches :**
  - `channelLogo` : 44 pt de base ;
  - `posterThumb` : 44 × 66 ;
  - `posterCard` : largeur de base de 150, au format 2:3 ;
  - `posterDetail` : 150 × 225 ;
  - `posterCompact` : 96 × 144.
- **Cartes et grilles :**
  - `channelCardMinWidth` : 240 ;
  - `posterGridMinWidth` : 155 ;
  - `shelfCardWidth` ;
  - `downloadCardMinWidth` : 420 ;
  - espacements `spacingXS` à `spacingXL`.
- **Colonnes :**
  - `sidebarWidth` (min / idéal / max) ;
  - `categoryColumnWidth` (compacte / normale) ;
  - `sidePanelWidth` (lecteur de droite, `PRD` « colonne du lecteur »).
- **Texte :** uniquement des **styles de texte** (`.caption2` à `.largeTitle`). Les badges en 8 ou 9 points deviennent `.caption2` avec une taille minimale lisible de **11 pt** à l'échelle 1,0.
- **Cibles :** `minHitTarget` par plateforme (§ 2.5).

Chaque jeton a une **valeur de base** et se calcule `base × uiScale`, arrondi au point entier. Les valeurs qui dépendent de la plateforme (Apple TV notamment) sont définies dans le même fichier, avec `#if os(...)`.

---

## 4. Écrans concernés

| Zone | Aujourd'hui | Attendu |
| :--- | :--- | :--- |
| **Barre latérale (macOS, iPad)** | Icônes à la taille par défaut, largeur 180 à 280, logo de marque fixe. | Icônes `iconM` à l'échelle, largeur `sidebarWidth`. Sous une largeur donnée : icônes seules, avec infobulle. Badges lisibles. |
| **Catégories** (colonne, puces, feuille) | Colonne 190/250, flèches 22 × 28, puces en `.subheadline`. | Largeur proportionnelle, icônes `iconM` (Accueil, « Toutes »). Puces et flèches à l'échelle, cibles minimales respectées. Noms longs sur 2 lignes en grande taille. |
| **Favoris** (étoile des cartes, du lecteur, des fiches) | Étoile à la taille du texte voisin, souvent petite. | Jeton `iconS` (listes) ou `iconM` (fiches, lecteur), zone cliquable `minHitTarget` même si l'icône est petite. |
| **Cartes de chaînes** | 280 de large dans les rangées, logo 44, hauteur minimale 92. | Largeur, logo et hauteur proportionnels. Le titre et le programme en cours passent sur plusieurs lignes en grande taille. Grille adaptative à partir de `channelCardMinWidth`. |
| **Affiches (films, séries, « À suivre »)** | 150 dans les rangées, grille minimale 155, cartes « À suivre » 130, carte de fin 330. | Jetons `posterCard` / `shelfCardWidth`. Nombre de colonnes calculé selon la largeur. Badges de note et de reprise à l'échelle. |
| **Lecteur** (barre du haut, contrôles, pastilles) | Boutons `hudButton` à la taille du texte, pastilles en `.caption2.monospaced`, bouton 24 × 24. | Boutons `iconL`, pastilles lisibles, curseur de progression épaissi en grande taille. En lecteur réduit ou compact (`PRD-29`), boutons secondaires regroupés dans un menu « … » plutôt que coupés. |
| **Guide TV (EPG)** | Logos 32/48, colonne d'heures 56, badge en 8 pt. | Logos, colonne d'heures et hauteur de ligne proportionnels. Largeur par heure qui suit l'échelle. Badge lisible. |
| **Téléchargements, sources, réglages, profils, Multi-View** | Cartes minimales 420, icônes 32/36, fixes. | Jetons correspondants. Formulaires qui passent sur une colonne en petite largeur. |
| **Sous-titres** | Police 20 pt fixe. | Taille liée à la hauteur de la vidéo et à un réglage « Taille des sous-titres » (petite à très grande), indépendante de l'échelle de l'interface. |
| **États vides, chargement, erreurs** | Icônes 40 à 56 pt fixes. | `iconXL` à l'échelle. |

---

## 5. Adaptation à la place disponible

- **Seuils de largeur communs** (jetons `Breakpoints`), à la place des seuils écrits dans chaque vue (900 et 520 dans `CategoryNavigation`, 900 dans `DownloadsDashboardView`). Les seuils sont **multipliés par `uiScale`** : en « Très grande », la colonne des catégories bascule plus tôt en puces.
- **Classes de taille** sur iPhone et iPad (`horizontalSizeClass`) pour choisir entre colonne et puces, grille et liste, panneau de droite et feuille.
- **`ViewThatFits`** pour les barres d'outils et la barre du lecteur : icône + texte, puis icône seule, puis menu « … ».
- **Rotation et multitâche iPad** (Split View, Slide Over, Stage Manager) : aucune coupure de 320 pt de large jusqu'au plein écran 13".
- **macOS** : fenêtre de 800 × 500 pt minimum (inchangé) jusqu'à un écran 6K. En « Très grande », la largeur minimale de fenêtre augmente en proportion pour éviter les chevauchements.

---

## 6. Accessibilité

- Prise en charge des tailles d'accessibilité Dynamic Type : à partir de `.accessibility1`, les cartes de chaînes passent en liste, les grilles d'affiches en 2 colonnes au plus sur iPhone, et les libellés ne sont plus tronqués (retour à la ligne).
- **Contraste et lisibilité** : aucun texte informatif sous 11 pt à l'échelle 1,0 ; pastilles et badges avec un fond qui garantit le contraste WCAG AA sur les affiches.
- **Libellés d'accessibilité** conservés quand l'interface passe en « icône seule ».
- Respect de « Réduire les animations » pour les transitions de mise en page.

---

## 7. Apple TV et Vision Pro

- **Apple TV (10-foot UI)** : jetons dédiés, avec des logos et des affiches **environ 2× plus grands** et des espacements plus larges. Le focus agrandit la carte (`.buttonStyle(.card)`) sans chevauchement. Le texte reste lisible à 3 m : 29 pt minimum pour le corps.
- **Vision Pro** : cibles de 60 pt, marges de fenêtre conformes au système. Les ornements (barre du lecteur) suivent les mêmes jetons.

---

## 8. Règle de code et contrôle automatique

- Toute taille passe par un jeton. Exceptions permises, commentées sur place :
  - les pastilles d'état de 8 pt (forme décorative, non textuelle) ;
  - les rapports d'aspect (16:9, 2:3) ;
  - la police monospace de la console réseau.
- Contrôle `task lint:ui` (ajouté à `task check`) qui signale dans `apple/Sources/` :
  - les `frame(width:` et `height:` à valeur littérale hors de `Shared/Design/` ;
  - les `.font(.system(size:` ;
  - les `GridItem(.adaptive(minimum:` à valeur littérale.

  Une liste d'exceptions versionnée accompagne ce contrôle. Il démarre en **avertissement** au lot 30.1 et devient **bloquant** à la fin du lot 30.3.

---

## 9. Réglages

Réglages > Apparence :
- **Taille de l'interface** : Petite / Standard / Grande / Très grande. Aperçu en direct avec une carte de chaîne, une affiche et la barre du lecteur.
- **Taille des sous-titres** : Petite / Moyenne / Grande / Très grande.
- **Barre latérale compacte** (icônes seules), macOS et iPad.

Réglages mémorisés par appareil (`UserDefaults`), non synchronisés : un Mac et un iPhone n'ont pas les mêmes besoins.

Raccourcis macOS : ⌘+ et ⌘- changent la taille de l'interface et ⌘0 revient à « Standard », comme dans un navigateur. Ils doivent être vérifiés contre les raccourcis existants.

---

## 10. Lots

| Lot | Contenu | Validation |
| :--- | :--- | :--- |
| **30.1** | Module `Shared/Design/` (jetons, `UIScale`, seuils), réglage « Taille de l'interface » et raccourcis, contrôle `lint:ui` en avertissement. | Tests des jetons et de l'échelle. |
| **30.2** | Barre latérale, catégories (colonne, puces, feuille, Accueil), favoris, cartes de chaînes, Live TV, rangées horizontales. | Captures aux 4 tailles, sur macOS et iPhone. |
| **30.3** | Films, séries, fiches, « À suivre » et carte de fin (`PRD-27`), lecteur et sa barre, EPG, téléchargements, sources, réglages, profils, Multi-View, états vides. `lint:ui` bloquant. | Captures aux 4 tailles, sur macOS, iPhone et iPad. |
| **30.4** | Accessibilité (tailles `.accessibility*`, contraste), Apple TV (jetons 10-foot), Vision Pro, taille des sous-titres. | Essai sur Apple TV ; simulateur iPhone en `.accessibility3`. |

---

## 11. Fichiers à Créer / Modifier

- `apple/Sources/CndIptvKit/Shared/Design/DesignTokens.swift`, `UIScale.swift`, `Breakpoints.swift`, `ScaledFrame.swift` *(nouveaux : modificateurs `.tokenFrame(...)`, `.minHitTarget()`)*
- Toutes les vues listées au § 4, notamment :
  - `App/AppShellView.swift`, `Shared/CategoryNavigation.swift`, `Shared/HorizontalShelf.swift` ;
  - `Features/LiveTV/*`, `Features/Movies/*`, `Features/Series/*`, `Features/VOD/*`, `Features/Recommendations/*`, `Features/EPG/*` ;
  - `Features/Downloads/*`, `Features/Sources/*`, `Features/Settings/*`, `Features/Profiles/*`, `Features/MultiView/*`, `Features/Sharing/*` ;
  - `Player/CndVideoPlayerView.swift`, `Player/SubtitleOverlay.swift`, `Player/PlayerGestures.swift`.
- `scripts/lint-ui.sh` *(nouveau)*, `Taskfile.yml` *(`lint:ui`, ajout à `check`)*
- `apple/Tests/CndIptvAppTests/DesignTokensTests.swift` *(nouveau)*
- `PRD/00_INDEX_ROADMAP.md`

---

## 12. Contraintes Non-Négociables (Guardrails IA)

- Aucune régression fonctionnelle : mêmes actions, mêmes raccourcis, mêmes libellés d'accessibilité.
- Défilement fluide conservé : les jetons sont calculés une fois par changement d'échelle, jamais par cellule à chaque image. Les miniatures restent décodées à la taille affichée, multipliée par l'échelle de l'écran (`PRD-10`), et sont recalculées quand l'échelle change.
- À l'échelle « Standard », l'apparence reste **proche de l'actuelle** : ce PRD ne refait pas le design graphique.
- Pas de nouvelle dépendance.
- Les cibles macOS, iOS, tvOS et visionOS restent vertes.

---

## 13. Critères d'Acceptation & Commandes de Validation

1. **Tests Swift :**
   - calcul de `UIScale` (réglage app × Dynamic Type, bornes 0,85 et 1,6) ;
   - jetons arrondis au point entier ;
   - seuils multipliés par l'échelle ;
   - cibles minimales par plateforme ;
   - mémorisation du réglage.
2. **Captures de contrôle** (manuelles ou automatisées par tests d'interface), aux 4 tailles, sans texte coupé, chevauchement ni défilement horizontal de page :
   - macOS à 800 × 500 et en plein écran 27" ;
   - iPhone SE et iPhone Pro Max, en portrait et en paysage ;
   - iPad en plein écran et en Split View 1/3 ;
   - Apple TV.
3. **Accessibilité :** simulateur iPhone en `.accessibility3` ; Inspecteur d'accessibilité sur macOS (contraste, libellés des boutons « icône seule »).
4. `task lint:ui` sans erreur (fin du lot 30.3), `cd apple && swift test`, builds des 4 schémas Xcode, `task check` au vert.

---

## 14. Questions ouvertes

- **Échelle automatique selon l'écran sur macOS** (par exemple « Grande » par défaut sur un écran de plus de 27") : utile ou déroutant ? Ce PRD retient un réglage manuel, « Standard » par défaut.
- **Barre latérale compacte automatique** sous une certaine largeur de fenêtre, ou seulement sur demande ?
- **Sous-titres** : taille relative à la vidéo (retenue) ou à l'écran ?

---

## 15. Statut d'Implémentation & Validation

**Lot 30.1 — réalisé ✅ ; lots 30.2 et 30.3 — réalisés en partie ; lot 30.4 — non réalisé. Non essayé à l'écran.**

- **Lot 30.1** (`Shared/Design/`) : `UIScaleSetting` (Petite, Standard, Grande, Très grande), `UIScale` (coefficient borné à 0,85–1,6 : sur macOS le facteur du réglage, sur les autres plateformes le plus grand de la taille de texte du système et du minimum du réglage, jamais moins que le choix du système), `UIScaleStore` (mémorisé par appareil, `⌘+` `⌘-` `⌘0` sur macOS), `UIMetrics` (jetons : icônes, logos, affiches 2:3, cartes, grilles, colonnes, espacements, cible minimale 28 / 44 / 66 / 60 pt selon la plateforme, `font(_:)` à l'échelle sur macOS), `Breakpoints` (seuils qui suivent l'échelle). Injecté à la racine par `uiScaleRoot()` ; Réglages > Apparence > « Taille de l'interface ». À l'échelle Standard les tailles sont celles d'avant (testé).
- **Lot 30.2** : barre latérale macOS (largeurs, icônes, logo, texte, bouton Journaux), catégories (colonne, seuils, Accueil, puces, flèches), flèches de défilement des rangées, cartes de chaînes (logo, hauteur, textes, étoile avec zone cliquable minimale), grille et rangées de Live TV.
- **Lot 30.3, en partie** : grille et rangées des films et séries, affiches des listes et des fiches (films et séries), logos et colonne d'heures du guide TV, badge du guide (8 pt remplacé par un style lisible), grille des téléchargements, police de la barre du haut du lecteur.
- **Contrôle** : `scripts/lint-ui.sh` (`task lint:ui`, avertissement seulement ; `STRICT=1` pour échouer) signale encore **62** tailles fixes (74 au départ) : fenêtres et feuilles (`minWidth` de formulaires), Multi-View, partage, profils, mode Enfants, console, `UpNextShelf` et `NextUpCard` (PRD 27), badges, curseur du lecteur. Le contrôle n'est pas bloquant et n'est pas dans `task check`.
- **Validation** : 13 tests (échelle, bornes, arrondis, tailles inchangées à l'échelle 1, cibles minimales, seuils, mémorisation) ; 358 tests Swift au vert ; builds macOS, iOS, tvOS et visionOS (simulateur) réussis.
- **Non vérifié / non fait** : aucune capture aux 4 tailles ni sur les écrans listés au § 13 (le rendu réel des icônes et du texte à l'échelle, notamment dans la barre latérale macOS, n'a pas été vu) ; sur macOS, seuls les textes passés par `ui.font(…)` suivent l'échelle (le reste du texte garde la taille système, SwiftUI n'ayant pas de Dynamic Type sur Mac) ; les 62 tailles restantes ; `ViewThatFits` (icône seule, menu « … » pour la barre du lecteur) ; classes de taille de l'iPad ; la taille minimale de fenêtre qui augmente avec l'échelle ; le lot 30.4 (tailles d'accessibilité, jetons Apple TV et Vision Pro dédiés, taille des sous-titres) ; la barre latérale compacte (icônes seules).
