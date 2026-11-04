# PRD 31 — Accessibilité : VoiceOver, clavier, Contrôle vocal, sous-titres, audiodescription et réglages visuels

- **ID :** `PRD-31`
- **Prérequis :** `PRD-08` (lecteur), `PRD-09` à `PRD-11` (écrans SwiftUI), `PRD-18` (sous-titres), `PRD-21` (Apple TV), `PRD-30` (interface responsive, Dynamic Type, contraste : **ce PRD le complète**, il ne le répète pas)
- **Couches impactées :** `SwiftUI / AppKit / UIKit (apple/Sources/CndIptvKit/**)`, `Player/` (pistes accessibles), un peu de `Rust (cnd-core)` pour les métadonnées de pistes
- **Plateformes :** macOS, iPhone, iPad, Apple TV, Vision Pro
- **Objectif :** que toutes les fonctions principales soient faisables **sans voir l'écran** (VoiceOver), **sans souris ni écran tactile** (clavier, Contrôle vocal, Switch Control, Siri Remote) et **sans entendre** (sous-titres). Ces fonctions sont : ajouter une source, trouver et lancer une chaîne ou un film, utiliser le lecteur, gérer ses favoris, enregistrer, régler.

---

## 1. Contexte & état des lieux

Un relevé du code (`apple/Sources/CndIptvKit`) montre une base partielle :

| Élément | Occurrences | Constat |
| :--- | :---: | :--- |
| `Image(systemName:)` | 72 | Beaucoup de boutons ne sont **que des icônes**. |
| `accessibilityLabel` | 35 | Moins d'un libellé pour deux icônes. |
| `onTapGesture` | 15 | Gestes non annoncés comme boutons, inaccessibles au clavier et à VoiceOver. Seule la carte de chaîne a reçu le trait « bouton ». |
| `accessibilityHint`, `accessibilityAction`, `accessibilityRotor`, `accessibilityFocused`, annonces | 0 | Aucune action personnalisée : favori, menu ou mosaïque demandent un menu contextuel, difficile à atteindre. Aucune annonce de changement d'état (chargement, erreur, reconnexion, chaîne changée). |
| `accessibilityValue` | 1 | Progression, volume, position de lecture et programme EPG ne sont pas annoncés. |
| Réduire les animations | 0 | Les animations (HUD, transitions, flèches de défilement) ne respectent pas le réglage système. |
| Pistes d'audiodescription et de sous-titres pour sourds et malentendants | 0 | Elles ne sont pas signalées et ne peuvent pas être choisies automatiquement. |

L'interface responsive, Dynamic Type, la taille minimale du texte, le contraste des badges et les cibles tactiles relèvent du `PRD-30`. Ce PRD se limite à ce que le `PRD-30` ne couvre pas.

---

## 2. Principes

1. **Tout élément interactif est un vrai contrôle** : `Button`, `Toggle` ou `Picker`, jamais un `onTapGesture` seul. Si un geste est indispensable (double-clic plein écran, glissements du lecteur), il existe aussi un équivalent accessible : un bouton, une action VoiceOver ou un raccourci.
2. **Chaque contrôle a un libellé parlé**, court et en français, qui dit **ce qu'il fait** (« Ajouter aux favoris ») et pas ce qu'il montre (« étoile »). Son état est donné par la valeur ou le trait (« Favori, sélectionné »).
3. **Les éléments composés se lisent en une fois** : une carte de chaîne se lit « TF1, chaîne 1, en direct : Journal de 20 h, jusqu'à 20 h 45, favori ». Les actions secondaires sont des **actions personnalisées**, pas des boutons cachés dans la carte.
4. **Les changements importants sont annoncés** : chargement, erreur de lecture, reconnexion, bascule de miroir, changement de chaîne, enregistrement démarré.
5. **Les réglages du système sont respectés** : Réduire les animations, Réduire la transparence, Augmenter le contraste, Différencier sans couleur, Sous-titres et SDH, Audiodescription, Lecture automatique des aperçus vidéo.

---

## 3. VoiceOver

### 3.1. Libellés, valeurs et traits

- Inventaire de toutes les icônes seules (72 aujourd'hui) : chacune reçoit un libellé, ou `accessibilityHidden(true)` si elle est décorative (icône à côté d'un texte qui dit la même chose).
- **Valeurs annoncées** :
  - position et durée (« 12 minutes sur 1 h 48 ») ;
  - volume (en pourcentage) ;
  - vitesse de lecture ;
  - progression d'un téléchargement et vitesse ;
  - temps restant d'un enregistrement ;
  - note IMDb ;
  - progression de reprise d'une affiche (« vu à 40 % »).
- **Curseurs** (progression, volume) : `accessibilityAdjustableAction`, avec des pas de 10 s pour la position et de 10 % pour le volume.
- **États** : favori, en panne, en cours de lecture, sélectionné, désactivé, en direct ou replay.

### 3.2. Actions personnalisées

Sur les cartes de chaînes, d'affiches, d'épisodes, d'enregistrements et de téléchargements, et sur les cartes « À suivre » (`PRD-27`), les entrées du menu contextuel deviennent aussi des **actions VoiceOver** (balayage vers le haut ou le bas) :
- **chaîne :** « Lire », « Ajouter aux favoris » ou « Retirer », « Voir le programme », « Revoir depuis le début », « Ajouter à la mosaïque », « Miroirs » ;
- **film :** « Lire », « Reprendre », « Télécharger », « Voir la fiche », « Pas intéressé ».

### 3.3. Navigation rapide (rotors)

- **Live TV :** rotor « Catégories » pour sauter d'une catégorie à l'autre, rotor « Favoris ».
- **Guide TV :** rotors « Chaînes » et « Programmes en cours » ; chaque case se lit « TF1, 20 h – 20 h 45, Journal, en cours ».
- **Fiche de série :** rotor « Saisons ».
- **Longues listes :** l'ordre de lecture suit l'ordre visuel (`accessibilitySortPriority` lorsque la mise en page le casse, par exemple avec la colonne de droite du lecteur).

### 3.4. Annonces

Annonces VoiceOver (`AccessibilityNotification.Announcement`), avec une priorité adaptée :

| Événement | Exemple d'annonce | Priorité |
| :--- | :--- | :--- |
| Lecture démarrée | « TF1, en direct » | Normale |
| Chargement long (plus de 2 s) | « Chargement… » | Basse |
| Erreur de lecture | Message d'erreur avec l'action proposée | Haute |
| Reconnexion | « Reconnexion au flux… » | Normale |
| Bascule de miroir (`PRD-17`) | « Bascule sur un autre serveur » | Normale |
| Zapping | Nom de la nouvelle chaîne | Normale |
| Enregistrement (démarrage ou fin) | « Enregistrement démarré » | Normale |
| Synchronisation d'une source terminée | « 12 345 chaînes importées » | Basse |
| Toasts de l'app | Leur texte | Selon le cas |

- Le **focus VoiceOver** est placé au bon endroit : sur le lecteur à son ouverture, sur le premier champ d'une feuille, et sur le bouton d'action d'une erreur.
- Le HUD du lecteur **ne se masque pas** tant que VoiceOver est actif et que le focus est sur un de ses contrôles (aujourd'hui, il se masque après 3 s).

### 3.5. Lecteur

- Tous les boutons du lecteur sont accessibles sans faire apparaître le HUD d'abord.
- Le geste magique (double tap à deux doigts) bascule lecture et pause, et l'action « Échap » (zigzag à deux doigts) ferme le lecteur ou sort du plein écran.
- Les gestes du lecteur sur iPhone (`PlayerGestures` : luminosité, volume, avance) ont tous un équivalent par bouton ou par action VoiceOver.

---

## 4. Clavier, Contrôle vocal et Switch Control

### 4.1. Clavier (macOS, iPad avec clavier)

- **Accès complet au clavier** : Tab et les flèches parcourent la barre latérale, les catégories, les grilles et le lecteur ; Entrée lance ; Espace bascule lecture et pause ; Échap ferme une feuille ou le lecteur.
- **Grilles** (chaînes, affiches) : déplacement aux flèches entre les cartes, avec un focus visible.
- **Anneau de focus visible** sur tous les contrôles personnalisés : cartes, puces, flèches de défilement, boutons du HUD.
- **Raccourcis documentés** : le menu « Aide > Raccourcis clavier » affiche la liste (lecture, zapping, plein écran, mode Cinéma, recherche, ⌘K, favoris). Aucun raccourci ne repose sur une seule touche sans modificateur, en dehors du lecteur actif.

### 4.2. Contrôle vocal

- Les libellés visibles et les libellés parlés coïncident : on dit « Toucher Ajouter aux favoris ».
- `accessibilityInputLabels` donne des noms alternatifs courts pour les commandes fréquentes : « Lecture », « Pause », « Plein écran », « Suivante », « Précédente », « Favori ».

### 4.3. Switch Control et Accès guidé

- Les groupes d'éléments composés (§ 2.3) évitent de parcourir chaque sous-élément d'une carte.
- Aucun délai d'action trop court : HUD non masqué pendant l'utilisation (§ 3.4), compte à rebours de la carte « Film suivant » (`PRD-27`) mis en pause quand un contrôle d'accessibilité est actif.

### 4.4. Apple TV

- Ordre de focus logique par sections (`focusSection`) : barre d'onglets, catégories, contenu, rangées horizontales.
- VoiceOver sur tvOS lit les cartes comme au § 3.1. Les rangées horizontales annoncent leur titre (« Favoris, 12 éléments »).

---

## 5. Sous-titres et audio

- **Sous-titres pour sourds et malentendants (SDH)** : les pistes SDH (`public.accessibility.describes-music-and-sound` dans HLS, `forced` et `hearing_impaired` dans mpv et OpenSubtitles) sont signalées dans le menu (« Français (SDH) »).
- **Sélection automatique** selon les réglages du système :
  - si « Sous-titres codés + SDH » est activé (`MACaptionAppearance`), l'app choisit la piste SDH dans la langue préférée ;
  - si l'audiodescription est activée, l'app choisit la piste audio qui décrit la vidéo (`public.accessibility.describes-video`).
- **Apparence des sous-titres** : la surcouche de l'app (`SubtitleOverlay`, sous-titres OpenSubtitles) suit les styles définis dans Réglages Système > Accessibilité > Sous-titres. Cela concerne la police, la taille, la couleur, le fond et l'opacité, via `MACaptionAppearance`, au lieu de la police fixe actuelle de 20 pt. La taille relative à la vidéo est définie par le `PRD-30`.
- **Audio mono et balance** : rien à faire côté app, mais le Dialogue Boost (`PRD-18`) doit rester compatible.
- **Transcription en direct** (Live Captions macOS et iOS) : aucun blocage par l'app ; vérification que l'audio de mpv est bien capté.

---

## 6. Réglages visuels du système

- **Réduire les animations** (`accessibilityReduceMotion`) : transitions remplacées par un fondu court ou supprimées pour le HUD, les rangées, l'agrandissement du lecteur, les flèches de défilement et les toasts ; pas de défilement animé automatique.
- **Réduire la transparence** : fonds `.ultraThinMaterial` du HUD et des barres remplacés par un fond opaque.
- **Augmenter le contraste** : bordures visibles autour des cartes et des puces, couleurs d'état (en panne, en direct, replay) renforcées.
- **Différencier sans couleur** : les états signalés par une couleur (pastille rouge de panne, état de santé du flux, badge « REPLAY ») reçoivent aussi une **forme ou un texte**.
- **Lecture automatique des aperçus vidéo désactivée** : pas de lecture automatique dans « À suivre » (`PRD-27`), ni d'enchaînement automatique sans confirmation.
- **Clignotements** : aucun élément de l'app ne clignote plus de 3 fois par seconde. L'option « Diminuer les lumières clignotantes » (`Dim Flashing Lights`) est prise en compte par AVPlayer.

---

## 7. Textes et langue

- Tous les libellés d'accessibilité sont en **français**, cohérents avec l'interface, sans abréviation lue lettre par lettre : « i/s » est lu « images par seconde », « VOSTFR » est lu « version originale sous-titrée ».
- Dates et durées lues en langage naturel (« dans 15 minutes », « 1 heure 48 »), via les formateurs du système.
- Les noms de chaînes et de films restent tels quels. Les noms en majuscules (« TF1 HD FHD ») sont lus tels que fournis : aucun nettoyage hasardeux.
- Préparation à la localisation : les libellés passent par des chaînes localisables (`String(localized:)`) pour permettre plus tard l'anglais.

---

## 8. Lots

| Lot | Contenu | Validation |
| :--- | :--- | :--- |
| **31.1** | Inventaire et correction des icônes seules et des `onTapGesture` ; libellés, valeurs et traits (§ 3.1) ; anneau de focus et accès clavier complet (§ 4.1). | Audit VoiceOver macOS et iPhone ; parcours complet au clavier. |
| **31.2** | Actions personnalisées (§ 3.2), rotors (§ 3.3), annonces et focus (§ 3.4), lecteur accessible (§ 3.5), Contrôle vocal (§ 4.2). | Parcours VoiceOver « ajouter une source → lancer une chaîne → mettre en favori → changer de chaîne ». |
| **31.3** | Sous-titres SDH, audiodescription, style système des sous-titres (§ 5). | Flux HLS de test avec pistes SDH et audiodescription. |
| **31.4** | Réglages visuels du système (§ 6), Apple TV (§ 4.4), textes et langue (§ 7), page des raccourcis. | Essais avec chaque réglage système activé ; VoiceOver sur Apple TV. |

---

## 9. Fichiers à Créer / Modifier

- `apple/Sources/CndIptvKit/Shared/Accessibility/` *(nouveau)* :
  - `AccessibilityAnnouncer.swift` : annonces avec priorité et limitation des répétitions ;
  - `A11yLabels.swift` : libellés partagés ;
  - `SystemAccessibilitySettings.swift` : lecture des réglages du système, observables.
- Toutes les vues contenant des icônes seules ou des `onTapGesture`, en priorité :
  - `Player/CndVideoPlayerView.swift`, `Player/PlayerGestures.swift`, `Player/SubtitleOverlay.swift` ;
  - `Features/LiveTV/ChannelCardView.swift`, `Features/Movies/MoviePosterCard.swift`, `Features/EPG/EpgGuideView.swift` ;
  - `Shared/CategoryNavigation.swift`, `Shared/HorizontalShelf.swift` ;
  - `Features/Recommendations/*`, `Features/Downloads/*`, `Features/Recordings/*`, `Features/MultiView/*`, `App/AppShellView.swift`.
- `Player/AVPlayerBackend.swift`, `Player/MpvVideoToolboxBackend.swift` : caractéristiques SDH et audiodescription des pistes.
- `crates/cnd-core/src/subtitles/` : indicateur `hearing_impaired` d'OpenSubtitles, si absent.
- `App/KeyboardCommands.swift` : menu « Aide > Raccourcis clavier ».
- `apple/Tests/CndIptvAppTests/AccessibilityTests.swift`, `apple/UITests/` *(nouveau, audits automatiques)*
- `scripts/lint-ui.sh` *(du `PRD-30`)* : règle supplémentaire signalant `onTapGesture` sans équivalent et `Image(systemName:)` dans un `Button` sans libellé.
- `PRD/00_INDEX_ROADMAP.md`

---

## 10. Contraintes Non-Négociables (Guardrails IA)

- Aucune fonction accessible uniquement par un geste, un survol ou un menu contextuel.
- Aucun libellé d'accessibilité ne contient de donnée sensible : ni URL de flux, ni nom de serveur, ni identifiant.
- Les annonces ne se répètent pas en boucle : une reconnexion qui échoue plusieurs fois est annoncée une fois, puis à son résultat.
- Les réglages d'accessibilité du système priment sur les choix de l'app, sauf sur un réglage que l'utilisateur a explicitement changé dans l'app.
- Aucune régression visuelle pour les utilisateurs qui n'utilisent pas ces fonctions.
- Pas de nouvelle dépendance. Les cibles macOS, iOS, tvOS et visionOS restent vertes.

---

## 11. Critères d'Acceptation & Commandes de Validation

1. **Audits automatiques** :
   - `XCUIApplication().performAccessibilityAudit()` (iOS 17+ / macOS 14+) sur les écrans principaux : Live TV, Films, fiche, lecteur, Guide TV, Sources, Réglages ;
   - aucun problème de type « élément sans libellé », « cible trop petite », « contraste » ou « texte coupé » ;
   - tests intégrés à `task check`, ou dans une tâche `task test:a11y` s'ils sont trop lents.
2. **Tests Swift** :
   - libellés et valeurs des cartes (chaîne, affiche, épisode) ;
   - choix automatique des pistes SDH et d'audiodescription selon les réglages simulés ;
   - limitation des répétitions d'annonces ;
   - HUD maintenu avec VoiceOver actif.
3. **Parcours manuels** (yeux fermés pour VoiceOver), chacun mené jusqu'au bout sans aide :
   - **VoiceOver (macOS, iPhone, Apple TV) :** ajouter une source, chercher un film, le lancer, mettre la lecture en pause, l'ajouter aux favoris, changer de chaîne ;
   - **Clavier seul (macOS) :** même parcours, sans souris ;
   - **Contrôle vocal (iPhone) :** lancer une chaîne et passer en plein écran.
4. **Réglages système** : chaque réglage du § 6 activé tour à tour, l'effet attendu est constaté.
5. `cd apple && swift test`, builds des 4 schémas Xcode, `task check` au vert.

---

## 12. Questions ouvertes

- **Langue des libellés** : français seulement pour l'instant (retenu), ou localisation anglaise dès ce PRD ?
- **Audits automatiques bloquants** dans `task check`, ou seulement en avertissement tant que les tests d'interface sont lents ?
- **Assistant ⌘K à la voix** (`PRD-13`) : faut-il un mode « dicter une commande » dédié, utile aux personnes malvoyantes, ou la dictée du système suffit-elle ?

---

## 13. Statut d'Implémentation & Validation

**Lots 31.1 à 31.4 réalisés en partie ✅. Aucun essai avec VoiceOver, le Contrôle vocal ou le clavier seul.**

- **Socle** (`Shared/Accessibility/`) : `A11yText` (phrases lues en français : durées naturelles, position « 12 minutes sur 1 heure et 48 minutes », pourcentages, notes, vitesse, abréviations, phrase d'une chaîne sans adresse ni serveur), `AccessibilityAnnouncer` (annonces avec priorité, même texte non répété dans les 30 s), `accessibleTap` (un geste qui est aussi un vrai bouton : trait « bouton », action par défaut de VoiceOver, focus et Entrée / Espace au clavier sur Mac), `StatusDot`, `ScreenReader.isRunning`, `systemAccessibilityPreferences()`.
- **Libellés et gestes (31.1)** : les 10 boutons-icônes sans libellé relevés ont un libellé (favoris des séries et des films, œil et corbeille des bouquets, corbeille des profils, boutons de la mosaïque, menu « … » d'un épisode) ; 11 `onTapGesture` sont devenus `accessibleTap` (cartes de chaînes, fiches, lignes du guide TV et leurs programmes, épisodes, avatars, mini-lecteur, mosaïque). Il reste 4 gestes nus, justifiés et marqués (poignée de la colonne, gestes sur la vidéo : leurs équivalents sont des boutons du lecteur).
- **VoiceOver (31.2)** : la carte d'une chaîne se lit « TF1, chaîne 1, en cours de lecture, favori. En ce moment : Journal, 20:00 – 20:45 » avec les actions du menu contextuel en actions VoiceOver (favori, programme, panne, revoir depuis le début, mosaïque, miroirs) ; curseur de position (pas de 10 s) et de volume (pas de 10 %) avec valeur parlée, vitesse, bouton Muet à l'état annoncé ; annonces du démarrage de la lecture, d'une erreur (priorité haute), du chargement, de la reconnexion, de la bascule de miroir et des toasts ; la barre du lecteur ne se masque plus tant que VoiceOver est actif.
- **Pistes (31.3)** : pistes pour sourds et malentendants et d'audiodescription détectées (AVPlayer par ses caractéristiques, mpv par `hearing-impaired` et `visual-impaired`) et signalées « (SDH) » / « (audiodescription) » dans les menus ; avec mpv, la piste correspondante est choisie une fois par média selon les réglages du système et la langue préférée, sans écraser un choix déjà fait (AVPlayer applique déjà ces réglages seul).
- **Réglages visuels et clavier (31.4)** : « Réduire les animations » appliqué à toute l'interface ; « Différencier sans couleur » : les pastilles d'état de santé deviennent des symboles distincts ; page « Aide > Raccourcis clavier » ; `focusSection` sur la colonne des catégories (Apple TV) ; règle `task lint:ui` qui signale les `onTapGesture` nus.
- **Validation** : 18 tests (phrases parlées, annonces et non-répétition, priorités, toasts, choix des pistes par langue et réglages, titres de pistes) ; 376 tests Swift au vert ; builds macOS, iOS, tvOS et visionOS (simulateur) réussis.
- **Non fait / non vérifié** : aucun essai avec VoiceOver (parcours « ajouter une source → lancer une chaîne → favori »), le Contrôle vocal, le clavier seul ou l'Apple TV ; les audits automatiques `performAccessibilityAudit` (il n'y a pas de cible de tests d'interface dans le projet) ; les rotors (catégories, favoris, chaînes, saisons) ; `accessibilityInputLabels` pour le Contrôle vocal ; les gestes de luminosité et de volume de l'iPhone n'ont pas d'équivalent dédié ; le style des sous-titres de l'app ne suit pas encore les réglages du système (`MACaptionAppearance`) ; pas de pause du compte à rebours « Film suivant » avec un contrôle d'accessibilité ; la localisation anglaise ; les libellés des écrans non listés (réglages, téléchargements, sources) n'ont pas été audités un à un ; « Réduire la transparence » repose sur le comportement automatique des matériaux du système.
