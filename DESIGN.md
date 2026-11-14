# Buntu — Design System (`DESIGN.md`)

> **Principe directeur : sobriété matérielle (« anti-IA »).**
> Interface TV & multiplateforme lisible à 3 mètres, bâtie sur des **aplats francs**, des **bordures nettes** et des **boutons 100 % solides**. Aucun vernis décoratif superflu.

---

## 1. Philosophie visuelle (Anti-IA)

De nombreuses interfaces générées accumulent les mêmes tics visuels qui nuisent à la lisibilité sur téléviseur et alourdissent le rendu : dégradés multi-couleurs, panneaux translucides, flous d'arrière-plan (`backdrop-filter`) et halos lumineux diffus.

Buntu adopte l'approche inverse :

| À proscrire | Standard Buntu |
| :--- | :--- |
| Dégradés décoratifs (`linear-gradient`, `radial-gradient`) sur fonds, cartes, barres ou boutons | **Aplats hexadécimaux opaques**, hiérarchisés par contraste de luminance |
| Effets de verre (`backdrop-filter: blur`), cartes laiteuses | **Surfaces solides opaques** délimitées par une bordure nette (`1px` à `3px`) |
| Boutons fantômes semi-transparents (`rgba(255, 255, 255, 0.06)`) | **Boutons 100 % solides** (*solid buttons*) à l'état repos comme au focus |
| Ombres néon diffuses (`0 0 24px ...`) | **Anneau de focus net** sans flou (`box-shadow` à rayon nul + bordure franche) |

### Exception matérielle unique : le plan vidéo AVPlay (Samsung Tizen)

Sur Tizen (`tizen/`), le lecteur matériel AVPlay dessine la vidéo **sous la page web**. Seules les zones dédiées à l'affichage vidéo sous-jacent doivent rester strictement `transparent` :
- `html, body, #root`
- `.app-root.video-mode`, `.app-root.preview-mode`
- `.buntu-page.with-preview`
- `.buntu-inspector-pane.mini-panel` (zone du lecteur uniquement ; la zone d'informations `.buntu-insp-body` en dessous reste solide)
- `.buntu-inspector-viewport`, `.tv-live-preview-viewport`

Tout le reste de l'interface (barres d'outils, menus, cartes, modales, boutons, badges, OSD) utilise des couleurs **100 % solides** sans transparence.

---

## 2. Palette chromatique officielle (100 % opaque)

Alignée sur [`docs/BRANDING_BUNTU.md`](docs/BRANDING_BUNTU.md) et adaptée aux contrastes TV 10 pieds :

### 2.1 Fonds & surfaces

| Token CSS | Hexadécimal | Rôle |
| :--- | :--- | :--- |
| `--buntu-midnight` | `#0B0E14` | Fond principal des écrans, lecteur, accueil et écrans de gestion |
| `--buntu-main-bg` | `#0E121A` | Zone principale du catalogue (chaînes, films, séries) |
| `--buntu-cat-bg` | `#121722` | Colonne des catégories |
| `--buntu-sidebar-bg` | `#121722` | Barre latérale des réglages / menus |
| `--buntu-toolbar-bg` | `#141A26` | Barre d'outils supérieure |
| `--buntu-slate` | `#161B26` | Surface des cartes, panneaux, modales et clavier TV |
| `--buntu-card-bg` | `#161B26` | Fond des cartes de chaînes, films et séries |
| `--buntu-slate-light` | `#1F2736` | Surface imbriquée (blocs d'infos, vignettes, barres de recherche) |
| `--buntu-card-hover` | `#242D3E` | Carte survolée ou active |
| `--buntu-btn-bg` | `#242D3E` | Fond plein des boutons secondaires et outils |
| `--buntu-border` | `#2A344A` | Bordures structurelles et séparateurs |
| `--buntu-btn-border` | `#344058` | Bordure des boutons solides au repos |
| `--buntu-hairline` | `#242D3E` | Lignes de séparation fines entre zones |

### 2.2 Accents, sémantique & textes

| Token CSS | Hexadécimal | Usage | Contraste |
| :--- | :--- | :--- | :--- |
| `--buntu-gold` | `#FF9F0A` | **Teranga Gold** : CTA primaire, focus télécommande, sélection | Texte `#0B0E14` (**9,4:1** WCAG AA/AAA) |
| `--buntu-gold-hover` | `#FFB340` | État focus / actif du bouton primaire doré | Texte `#0B0E14` |
| `--buntu-accent` | `#1D6FE8` | Bleu d'action secondaire structurant (catégorie/carte sélectionnée, barre de progression) | Texte `#FFFFFF` |
| `--buntu-cyan` | `#00D2FF` | **Leer Cyan** : numéros de chaînes, indicateurs techniques, méta EPG | Sur `#0B0E14` (**10,7:1**) |
| `--buntu-star` | `#FFD60A` | Favoris (étoile) | Sur `#161B26` |
| `--buntu-uhd` | `#FF9F0A` | Badge `4K` / `UHD` | Texte `#0B0E14` |
| `--buntu-danger` | `#E03126` | Erreurs, suppression, bouton quitter, pastille `EN DIRECT` | Fond repos `#38171A`, texte repos `#FCA5A5` |
| `--buntu-text` | `#F5F7FA` | Texte principal (**Pure White**) | **18,0:1** sur `#0B0E14` |
| `--buntu-text-secondary` | `#C2CBD8` | Sous-titres et descriptions lisibles à distance | — |
| `--buntu-text-muted` | `#8E95A5` | Métadonnées secondaires (**Muted Silver**) | **6,4:1** sur `#0B0E14` |

> **Règle d'accessibilité obligatoire :** ne jamais poser de texte blanc (`#FFFFFF`) sur `--buntu-gold` (`#FF9F0A`, contraste 1,9:1 insuffisant). Tout bouton ou badge à fond doré porte du texte `#0B0E14`.

---

## 3. Boutons solides (*Solid Buttons*)

Chaque bouton interactif est plein, distinct du fond dès le repos et sans transparence.

### 3.1 Variantes

| Variante | Classes CSS concernées | Repos | Focus / Sélection TV |
| :--- | :--- | :--- | :--- |
| **Primaire** | `.buntu-action-primary`, `.tv-watch-pill` | Fond `#FF9F0A`, texte `#0B0E14`, bordure `#FF9F0A` | Fond `#FFB340`, texte `#0B0E14`, bordure `#FFFFFF`, anneau net `0 0 0 3px #FF9F0A` |
| **Secondaire / Outil** | `.tv-btn`, `.buntu-action-secondary`, `.buntu-tool-btn`, `.buntu-mode-btn`, `.buntu-toolbar-brand`, `.tv-mini-fs-btn`, `.buntu-cat-home-btn`, `.tv-miniguide-row` | Fond `#242D3E`, texte `#F5F7FA`, bordure `#344058` | Fond `#FF9F0A`, texte `#0B0E14`, bordure `#FFFFFF` |
| **Raccourci d'accueil** | `.buntu-home-shortcut` | Fond `#161B26`, texte `#C2CBD8`, bordure `#2A344A` | Fond `#242d3e`, texte `#FFFFFF`, bordure `#FF9F0A` |
| **Onglet / Pilule** | `.tv-category-pill`, `.tv-season-pill`, `.buntu-seg-btn` | Fond `#1F2736`, texte `#C2CBD8`, bordure `#2A344A` ; actif : `#1D6FE8` / `#FFFFFF` (ou `#FF9F0A` / `#0B0E14`) | Fond `#FF9F0A`, texte `#0B0E14`, bordure `#FFFFFF` |
| **Clavier TV** | `.buntu-kb-key` | Fond `#1F2736`, texte `#F5F7FA`, bordure `#344058` | Fond `#FF9F0A`, texte `#0B0E14`, bordure `#FFFFFF` |
| **Danger** | `.tv-btn-danger`, `.tv-nav-exit` | Fond `#38171A`, texte `#FCA5A5`, bordure `#7A272E` | Fond `#E03126`, texte `#FFFFFF`, bordure `#FFFFFF` |

### 3.2 Focus télécommande sur téléviseur

1. **Toujours immédiatement identifiable :** bordure franche + fort changement de fond plein ou anneau net sans flou (`blur-radius = 0`).
2. **Pas d'animation de focus sur l'accueil :** `.buntu-home-card` garde `transition: none;` pour une réactivité instantanée à la télécommande.
3. **Marge de défilement (`scroll-padding`) :** toutes les listes défilantes gardent un dégagement suffisant pour ne jamais rogner le cadre du focus.
4. **Compatibilité Samsung Chromium 56–76 :**
   - Ne jamais combiner `.focused` avec `:focus-visible` dans un même sélecteur (un sélecteur non reconnu invalide toute la règle CSS sur Chromium 56–76). Utiliser `.focused` et `:focus`.
   - Ne jamais compter uniquement sur `gap` en flexbox sans marges de repli (`margin-right`, `margin-left`, `> * + *`).
   - Ne jamais utiliser `inset: 0` (utiliser `top: 0; right: 0; bottom: 0; left: 0;`).
   - Pour les ratios 16:9 sans garantie de `aspect-ratio`, conserver le repli `height: 0; padding-top: 56.25%;`.

---

## 4. Cartes, champs de saisie et OSD lecteur

- **Cartes d'accueil (`.buntu-home-card`) :** fonds pleins distincts par univers sans dégradé — Live TV `#161F2E`, Films `#221C17`, Séries `#1C1929`, bordure `2px solid #2A344A` ; focus : `border-color: var(--buntu-gold)` + `box-shadow: 0 0 0 3px var(--buntu-gold)`.
- **Cartes de chaînes et affiches VOD (`.buntu-ch-card`, `.buntu-vod-card`) :** fond `#161B26`, bordure `#2A344A` ; focus : fond `#242D3E`, bordure `#FF9F0A`, anneau net `0 0 0 2px #FFFFFF`.
- **Champs de saisie (`.tv-input`, `.buntu-search-field`, `.buntu-cat-filter-input`, `.buntu-field-btn`) :** fond plein `#121722`, bordure `2px solid #2A344A`, texte `#F5F7FA` ; focus : bordure `#FF9F0A` (ou `#1D6FE8` dans la recherche) avec anneau net `0 0 0 3px #FF9F0A` sans opacité.
- **OSD lecteur plein écran (`.tv-osd`, `.tv-osd-top`) et HUD (`.tv-channel-hud`, `.tv-digit-hud`, `.tv-miniguide-drawer`, `.tv-mirrors-bar`) :** bandeaux et tiroirs opaques `#0B0E14` / `#161B26` bordés de `#2A344A` pour garantir une lisibilité constante quel que soit le contenu vidéo derrière.

---

## 5. Règles d'évolution

Toute nouvelle interface (Tizen, Apple, Android) qui implémente un bouton ou un panneau doit :
1. Réutiliser les tokens de cette palette (ou `BrandPalette` côté Swift / `Color.kt` côté Kotlin) plutôt que d'introduire des couleurs `rgba(...)` ponctuelles.
2. Utiliser des **boutons solides** conformes au § 3.
3. Proscrire tout dégradé ou `backdrop-filter` décoratif.
