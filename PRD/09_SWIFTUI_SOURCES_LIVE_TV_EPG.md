# PRD 09 — UI SwiftUI : Gestion des Sources, Live TV & Guide EPG Temps Réel

- **ID :** `PRD-09`
- **Prérequis :** `PRD-04` (EPG), `PRD-05` (Catalogue/Favoris/Récents), `PRD-08` (Lecteur Vidéo)
- **Couches impactées :** `SwiftUI (apple/Sources/CndIptvApp/)`
- **Référence Flutter migrée :** `lib/ui/pages/shell_page.dart`, `lib/ui/sources/sources_page.dart`, `lib/ui/sources/source_form_page.dart`, `lib/ui/pages/tv_page.dart`, `lib/ui/pages/widgets/search_filter_bar.dart`, `lib/ui/pages/widgets/categories_sidebar.dart`
- **Objectif SLA :** Défilement constant à **120 fps (ProMotion)** sur 100 000 chaînes, filtrage/recherche instantané `< 16 ms` (1 frame), zéro double barre de titre.

---

## 1. Contexte & Objectif

Ce PRD remplace le squelette SwiftUI initial de Phase 1 par la véritable architecture de navigation multiplateforme Apple et livre **100 % des écrans Sources IPTV, Live TV et Guide EPG**, tout en corrigeant les défauts ergonomiques identifiés sur l'app Flutter (double `AppBar`, absence de sidebar catégories sur grand écran, impossibilité d'éditer une source existante).

---

## 2. Fichiers à Créer / Modifier

- `apple/Sources/CndIptvApp/App/AppShellView.swift` *(navigation adaptative macOS `NavigationSplitView` 3 colonnes vs iOS `TabView` + Mini-Player persistant)*
- `apple/Sources/CndIptvApp/Shared/ImageThumbnailCache.swift` *(acteur Swift de cache disque/mémoire avec downsampling `CGImageSourceCreateThumbnailAtIndex`)*
- `apple/Sources/CndIptvApp/Shared/SearchFilterToolbar.swift` *(recherche debounced 120ms, filtre Groupe, filtre Host, tri + ordre)*
- `apple/Sources/CndIptvApp/Features/Sources/SourcesListView.swift` *(liste, recherche, filtre M3U/Xtream, sync unitaire/global, édition, suppression, Drag & Drop `.m3u`)*
- `apple/Sources/CndIptvApp/Features/Sources/SourceFormSheet.swift` *(création & **édition** M3U ou Xtream avec test de connexion `verifyXtreamAccount` + sauvegarde Keychain)*
- `apple/Sources/CndIptvApp/Features/LiveTV/LiveTvView.swift` *(Sidebar catégories avec compteurs, sections Récents / Favoris / Toutes, vue Grille adaptative & Liste, pagination infinie)*
- `apple/Sources/CndIptvApp/Features/LiveTV/ChannelCardView.swift` *(logo downsamplé, badge HD/4K, programme EPG *Now* + barre de progression, étoile favori, menu contextuel)*
- `apple/Sources/CndIptvApp/Features/EPG/EpgGuideView.swift` *(grille horaire EPG dédiée + détails programme)*

---

## 3. Spécifications Techniques Détaillées

### 3.1. Pipeline de Logos & Posters Haute Vitesse (`ImageThumbnailCache.swift`)
- Ne **jamais** utiliser `AsyncImage` standard de SwiftUI sur une grille de milliers d'éléments (pas de cache disque persistant ni de downsampling, ce qui sature la RAM).
- Implémenter un `actor ImageThumbnailCache` utilisant `NSCache` (limité ex: `150 Mo`) + cache disque dans `Caches/CndThumbnails/` + décodage hors Main Thread via `CGImageSourceCreateThumbnailAtIndex` avec `kCGImageSourceThumbnailMaxPixelSize` calé sur la taille réelle à l'écran (`120px` pour un logo TV, `360px` pour un poster VOD).

### 3.2. Gestion Complète des Sources (`SourcesListView` & `SourceFormSheet`)
- **Ajout & Édition complète :** Onglets `M3U` (Nom, URL M3U, URL EPG optionnelle) et `Xtream Codes` (Nom, Serveur, Username, Password stocké via `KeychainStore`, bouton *"Tester le compte"* affichant le statut et la date d'expiration via `verifyXtreamAccount`).
- **Drag & Drop macOS & Import Fichier iOS :** Déposer un fichier `.m3u` / `.m3u8` sur la fenêtre macOS (ou via `fileImporter` sur iOS/macOS) déclenche immédiatement `engine.importLocalM3u(...)`.
- **Indicateur de synchronisation non bloquant :** Affichage du résumé (`SyncSummary` : nombre de chaînes, films, séries et temps en ms) à la fin du rafraîchissement.

### 3.3. Expérience Live TV "Zero-Lag" (`LiveTvView`)
1. **Navigation Catégories Adaptative :**
   - **macOS & iPad paysage (`>= 900 pt`) :** Liste des catégories (`getGroups("live")`) avec compteurs d'éléments visible en permanence en colonne latérale.
   - **iPhone / Compact :** Sélecteur rapide par chips horizontaux + feuille/tiroir de catégories filtrable.
2. **Sections Intelligentes & Pagination :**
   - Lorsqu'aucune recherche/catégorie spécifique n'est active, afficher en tête les sections **Récemment consultés** (`listRecentItems("live")`) et **Favoris** (`listFavoriteItems("live")`), suivies de **Toutes les chaînes** chargées par lots de 60 via `LazyVGrid` / `LazyVStack` au scroll.
   - Bascule instantanée **Mode Grille** (colonnes adaptatives `GridItem(.adaptive(minimum: 240, maximum: 340))`) ↔ **Mode Liste**, mémorisée dans `@AppStorage("live.viewMode")`.
3. **EPG Temps Réel Intégré aux Cartes :**
   - Charger par lot (`getEpgNowNext`) les programmes des chaînes visibles à l'écran pour afficher sous le nom de chaque chaîne le titre de l'émission en cours et une fine jauge de progression temporelle.
4. **Zapping Instantané & Mini-Player Ancré :**
   - Cliquer sur une chaîne lance immédiatement la lecture dans le lecteur intégré (en panneau latéral / Mini-Player ancré permettant de continuer à parcourir la liste des chaînes sans couper le direct, ou en plein écran en un clic !).
   - Menu contextuel natif (clic droit macOS / appui long iOS) : *Lire*, *Ajouter/Retirer des favoris*, *Ouvrir dans IINA / VLC*, *Voir le programme TV complet*, *Copier l'URL du flux*.

---

## 4. Contraintes Non-Négociables (Guardrails IA)
- **Zéro double barre d'outils :** Utiliser une seule hiérarchie `NavigationSplitView` / `NavigationStack` propre avec `.toolbar` natif.
- Persister le dernier onglet sélectionné (`@AppStorage("shell.selectedTab")`).

---

## 5. Critères d'Acceptation & Commandes de Validation
1. Vérifier la compilation sans warning sur les deux plateformes :
   ```bash
   cd cnd-iptv-native/apple
   xcodebuild -scheme CndIptvNative -destination 'generic/platform=macOS' build
   xcodebuild -scheme CndIptvNative -destination 'generic/platform=iOS Simulator' build
   ```
2. Vérifier que l'ajout, la **modification**, le rafraîchissement et la suppression d'une source M3U et Xtream fonctionnent de bout en bout avec mise à jour automatique des compteurs de la sidebar.

