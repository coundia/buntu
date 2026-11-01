# PRD 11 — UI SwiftUI : Gestionnaire de Téléchargements, Paramètres & Console Réseau

- **ID :** `PRD-11`
- **Prérequis :** `PRD-01` (Settings & Telemetry), `PRD-07` (Download Engine), `PRD-09` (AppShell)
- **Couches impactées :** `SwiftUI (apple/Sources/CndIptvApp/Features/Downloads/, Settings/, Console/)`
- **Référence Flutter migrée :** `lib/ui/pages/download_page.dart`, `lib/ui/widgets/download_tile.dart`, `lib/ui/pages/logs_sheet.dart`, `lib/ui/pages/settings_page.dart`, `lib/ui/widgets/global_console.dart`, `lib/ui/pages/about_page.dart`
- **Objectif SLA :** Rafraîchissement fluide à **4 Hz** des barres de progression multi-segments avec **< 1 % CPU UI**, persistance Security-Scoped Bookmark fiable entre redémarrages sur macOS.

---

## 1. Contexte & Objectif

Ce PRD livre l'interface complète du gestionnaire de téléchargement multi-segments ("FastDown"), l'écran des Réglages (avec gestion native du sandboxing macOS et des dossiers iOS) ainsi que le panneau pliable de Console Réseau temps réel (`GlobalConsole`).

---

## 2. Fichiers à Créer / Modifier

- `apple/Sources/CndIptvApp/Security/DownloadDirectoryManager.swift` *(Security-Scoped Bookmarks macOS + dossier Documents/Downloads visible dans l'app Fichiers sur iOS)*
- `apple/Sources/CndIptvApp/Features/Downloads/DownloadsDashboardView.swift` *(recherche/filtre par état, ajout batch d'URLs, vue Grille `>= 900pt` & Liste `< 900pt`, barre de stats globale en bas)*
- `apple/Sources/CndIptvApp/Features/Downloads/DownloadTaskCard.swift` *(barre globale + visualisation segmentée des `parts` parallèles, débit Mo/s, ETA, actions Démarrer/Pause/Relancer/Révéler dans le Finder/Lire/Supprimer)*
- `apple/Sources/CndIptvApp/Features/Downloads/AddUrlsSheet.swift` *(ajout multi-lignes d'URLs HTTP/HTTPS, choix headers optionnels et dossier cible)*
- `apple/Sources/CndIptvApp/Features/Downloads/TaskLogsSheet.swift` *(journaux détaillés par tâche `getDownloadLogs` avec copie presse-papier)*
- `apple/Sources/CndIptvApp/Features/Settings/SettingsView.swift` *(Segments/fichier, taille part Mo, max fichiers actifs, dossier par défaut, User-Agent, Referer, clé OMDb dans Keychain, toggle Console Réseau, À propos)*
- `apple/Sources/CndIptvApp/Features/Console/NetworkConsoleDrawer.swift` *(tiroir inférieur redimensionnable/pliable affichant `getLogsSince` en direct avec filtres par niveau/catégorie)*

---

## 3. Spécifications Techniques Détaillées

### 3.1. Sandboxing & Dossier de Téléchargement (`DownloadDirectoryManager.swift`)
- **macOS :** Lorsqu'un utilisateur choisit un dossier via `NSOpenPanel` (ex: `~/Downloads/CND` ou un SSD externe), enregistrer un **Security-Scoped Bookmark** (`url.bookmarkData(options: .withSecurityScope)`) dans `UserDefaults`, et appeler `startAccessingSecurityScopedResource()` au démarrage de l'application pour que le moteur Rust `cnd-core` ait le droit POSIX d'écrire les fichiers `.part` et finaux sans erreur `Operation not permitted` !
- **iOS / iPadOS :** Utiliser par défaut `FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("Downloads")`, accessible nativement dans l'application **Fichiers** d'iOS, et proposer `ShareLink` / lecture directe dans le lecteur interne une fois le téléchargement `completed`.

### 3.2. Tableau de Bord des Téléchargements (`DownloadsDashboardView`)
1. **Polling Throttlé Intelligent :**
   - Tant qu'au moins une tâche est `running` ou `queued`, rafraîchir `listDownloads` toutes les **250 ms (4 Hz)** hors du Main Thread ; dès que tout est au repos (`completed` / `paused` / vide), suspendre le timer pour consommer **0 % CPU** !
2. **Visualisation Multi-Segments Exclusive :**
   - Sur chaque `DownloadTaskCard`, afficher non seulement le pourcentage global, mais aussi une barre segmentée montrant en temps réel le remplissage de chacun des $N$ segments parallèles (`parts`) — signature visuelle forte d'un vrai gestionnaire multi-segments haute performance.
3. **Actions Individuelles & Globales :**
   - Par tâche : *Démarrer / Pause*, *Réessayer*, *Lire la vidéo* (ouvre directement le fichier local dans `CndVideoPlayerView` !), *Afficher dans le Finder* (`NSWorkspace.shared.activateFileViewerSelecting` sur macOS), *Voir les logs* (`TaskLogsSheet`), *Supprimer (avec ou sans suppression du fichier sur disque)*.
   - Barre inférieure de statistiques (`BottomStatsBar`) : `Total • En cours • En file • Erreurs • Débit cumulé Mo/s` + boutons *Tout démarrer*, *Tout mettre en pause*, *Relancer les erreurs*.

### 3.3. Paramètres & Console Réseau (`SettingsView` & `NetworkConsoleDrawer`)
- **Paramètres :** Formulaire clair divisé en sections (*Téléchargements*, *Réseau & Headers HTTP*, *Métadonnées OMDb*, *Diagnostic*, *À propos / Version Moteur Rust*). La clé API OMDb est lue/écrite via `KeychainStore` avec bouton afficher/masquer.
- **Console Réseau Pliable :** Lorsqu'elle est activée dans les réglages (`show_network_console`), afficher en bas de `AppShellView` un bandeau pliable récupérant incrémentalement `engine.getLogsSince(lastSeqId, limit: 200)` avec coloration par statut HTTP (`2xx` vert, `3xx` bleu, `4xx/5xx` rouge), filtre par catégorie (`HTTP`, `M3U`, `XTREAM`, `EPG`, `DOWNLOAD`), bouton *Vider* et *Copier les logs*.

---

## 4. Contraintes Non-Négociables (Guardrails IA)
- **Zéro Timer actif au repos :** Vérifier qu'aucun timer de polling de téléchargement ou de console ne tourne lorsque l'onglet/console est inactif et qu'aucun téléchargement n'est en cours.
- Gérer proprement `stopAccessingSecurityScopedResource()` lors du changement de dossier de téléchargement sur macOS.

---

## 5. Critères d'Acceptation & Commandes de Validation
1. Vérifier l'ajout d'un lot de liens, le suivi visuel par segment, la pause/reprise, l'ouverture dans le Finder (macOS) et l'affichage des logs par tâche.
2. Vérifier la compilation sans warning sur macOS et iOS Simulator :
   ```bash
   cd cnd-iptv-native/apple
   xcodebuild -scheme CndIptvNative -destination 'generic/platform=macOS' build
   xcodebuild -scheme CndIptvNative -destination 'generic/platform=iOS Simulator' build
   ```

