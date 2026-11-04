# PRD 32 — « Mes fichiers » : bibliothèque locale Vidéo, Audio et Images (comme VLC)

- **ID :** `PRD-32`
- **Prérequis :**
  - `PRD-07` (téléchargements, dossier de destination) ;
  - `PRD-08` (lecteur AVPlayer + mpv) ;
  - `PRD-11` (Réglages, dossier de téléchargement par signet de sécurité) ;
  - `PRD-12` (Now Playing, touches multimédia) ;
  - `PRD-18` (sous-titres) ;
  - `PRD-30` (jetons de design) et `PRD-31` (accessibilité).
- **Couches impactées :**
  - `Rust (crates/cnd-core/src/library/, db/)` ;
  - `UniFFI` ;
  - `SwiftUI (App/AppShellView, Features/Library/, Player/, Settings/)` ;
  - entitlements et `Info.plist`.
- **Plateformes :** macOS, iPhone, iPad, Vision Pro. **Pas Apple TV** : tvOS n'a pas de dossiers de l'utilisateur ; les partages réseau sont hors périmètre (§ 11).
- **Objectifs SLA :**
  - **Parcours des dossiers :** 10 000 fichiers parcourus et indexés en **< 10 s**, sans les métadonnées.
  - **Affichage :** liste d'une bibliothèque de 50 000 éléments en **< 50 ms** ; défilement des grilles fluide (miniatures réduites à la taille affichée, comme au `PRD-10`).
  - **Métadonnées :** extraites en arrière-plan, sans jamais bloquer l'interface.

---

## 1. Contexte & Objectif

L'app ne lit aujourd'hui que des flux IPTV et ses propres téléchargements. Beaucoup d'utilisateurs ont aussi des films, de la musique et des photos sur leur disque, un disque externe ou dans iCloud Drive. Ils les ouvrent avec VLC.

Ce PRD ajoute à la barre latérale une section **« Mes fichiers »**, avec trois entrées, comme la médiathèque de VLC :

- **Vidéo** : films et vidéos des dossiers autorisés, avec miniature, durée et reprise.
- **Audio** : musique par titres, albums, artistes, genres et dossiers, avec un lecteur audio.
- **Images** : grille de photos et visionneuse plein écran.

**L'utilisateur choisit les dossiers que l'app peut parcourir.** Rien n'est lu en dehors d'eux, et il peut retirer une autorisation à tout moment.

---

## 2. Autorisation des dossiers

### 2.1. Ajouter un dossier

- **Où :** bouton « Ajouter un dossier… » dans « Mes fichiers » (état vide et barre d'outils), dans Réglages > Mes fichiers et, sur macOS, dans le menu Fichier.
- **macOS :** panneau d'ouverture système limité aux dossiers (`fileImporter` ou `NSOpenPanel`, `canChooseDirectories`). L'app garde un **signet de sécurité** (`bookmarkData(options: .withSecurityScope)`, droit `com.apple.security.files.bookmarks.app-scope`, déjà présent) pour retrouver l'accès au prochain lancement.
- **iPhone, iPad, Vision Pro :** sélecteur de dossier de l'app Fichiers (`UIDocumentPickerViewController` en mode dossier). Il couvre « Sur mon iPhone », iCloud Drive, les fournisseurs tiers et les disques externes. L'app garde un signet (`bookmarkData()`) ; l'accès se reprend par `startAccessingSecurityScopedResource()`.
- **Ajouté automatiquement :** le dossier de téléchargement de l'app (`PRD-07` / `PRD-11`). Les films téléchargés apparaissent donc dans « Vidéo » sans rien faire. On peut le masquer, pas le supprimer.
- **Options par dossier :**
  - inclure les sous-dossiers (oui par défaut) ;
  - types à indexer (vidéo, audio et images par défaut) ;
  - nom affiché.

### 2.2. Garder, perdre et retirer l'accès

- **Au démarrage,** chaque signet est résolu :
  - **signet périmé** (`isStale`) : renouvelé sans rien demander ;
  - **dossier introuvable** (disque débranché, dossier déplacé) : marqué « indisponible » et conservé, ses éléments restent affichés grisés ;
  - **accès refusé :** l'app propose « Autoriser à nouveau… », qui rouvre le sélecteur sur ce dossier.
- **Retirer un dossier** supprime son signet et ses éléments de l'index, mais **jamais les fichiers**.
- **Durée de l'accès :** l'accès de sécurité n'est ouvert que le temps d'un parcours, d'une lecture ou d'une extraction de métadonnées, puis refermé (`stopAccessingSecurityScopedResource`). Il n'est jamais gardé ouvert sans raison.
- **Aucun accès large :** l'app ne demande pas l'accès complet au disque et ne parcourt aucun dossier non autorisé, même un parent. Pas de lecture de la Photothèque dans ce PRD (§ 11).

### 2.3. Gestion

- **Réglages > Mes fichiers :** liste des dossiers autorisés avec leur chemin, leur état (disponible, indisponible, à réautoriser) et leur nombre d'éléments. Actions : « Actualiser », « Options », « Retirer ».
- **Synchronisation :** les signets sont **propres à l'appareil** et ne sont pas synchronisés par iCloud (un chemin de Mac ne sert à rien sur un iPhone). Seuls les **positions de reprise** et les **favoris** des fichiers peuvent l'être plus tard, par l'empreinte du fichier (§ 4.3).

---

## 3. Navigation (barre latérale)

### 3.1. macOS et iPad

Nouvelle section **« Mes fichiers »** dans la barre latérale, sous les entrées IPTV, comme dans VLC :

| Entrée | Icône (SF Symbols) | Contenu |
| :--- | :--- | :--- |
| Vidéo | `film.stack` | Toutes les vidéos ; vues Tout, Récents, Dossiers. |
| Audio | `music.note` | Titres, Albums, Artistes, Genres, Dossiers, Listes de lecture. |
| Images | `photo.on.rectangle` | Grille par date ou par dossier. |
| Dossiers | `folder` | Parcours des dossiers autorisés tels qu'ils sont sur le disque. |

- Le badge de chaque entrée donne le nombre d'éléments.
- Un indicateur discret signale un parcours en cours.

### 3.2. iPhone

- Un onglet **« Fichiers »** (`folder`) ouvre une page avec les quatre entrées. La barre d'onglets reste à 5 entrées au plus : l'onglet remplace une entrée moins utilisée sous « Plus ».
- La recherche et le tri sont dans la barre de navigation.

### 3.3. Vision Pro

Même structure que l'iPad, en fenêtres.

---

## 4. Index de la bibliothèque (Rust, `cnd-core/src/library/`)

### 4.1. Parcours

- **Appel :** Swift ouvre l'accès de sécurité, appelle `library_scan(folder_id, root_path)`, puis le referme. Le moteur Rust lit les fichiers par leur chemin pendant que l'accès est ouvert : il est dans le même processus.
- **Parcours :**
  - streaming, sans tout charger en mémoire ;
  - fichiers cachés, paquets (`.app`, `.photoslibrary`, `.fcpbundle`) et liens symboliques sortant du dossier ignorés ;
  - profondeur maximale de 32 niveaux et plafond de 200 000 fichiers par dossier, signalé à l'utilisateur ;
  - annulable.
- **Type de média** par extension, puis vérifié par les premiers octets en cas de doute :
  - **Vidéo :** `mp4`, `m4v`, `mov`, `mkv`, `webm`, `avi`, `ts`, `m2ts`, `mts`, `mpg`, `mpeg`, `wmv`, `flv`, `3gp`, `ogv`.
  - **Audio :** `mp3`, `m4a`, `aac`, `flac`, `alac`, `wav`, `aiff`, `aif`, `ogg`, `oga`, `opus`, `wma`, `ape`, `wv`.
  - **Images :** `jpg`, `jpeg`, `png`, `heic`, `heif`, `gif`, `webp`, `tif`, `tiff`, `bmp`, `avif` ; formats RAW (`dng`, `cr2`, `nef`, `arw`) en option.
  - **Fichiers associés :** sous-titres `srt`, `ass`, `vtt` et pochettes `cover.jpg`, `folder.jpg`, rattachés au média voisin et jamais listés seuls.
- **Incrémental :** un fichier dont la taille et la date de modification n'ont pas changé n'est pas relu. Disparu, il est retiré de l'index ; renommé ou déplacé dans le même dossier, il est retrouvé par son empreinte (§ 4.3) pour garder sa position de reprise.

### 4.2. Données (SQLite)

- **`library_folders` :** `id`, `display_name`, `path` (pour l'affichage seulement), `bookmark` (BLOB), `include_subfolders`, `kinds`, `state` (`ok` | `missing` | `denied`), `item_count`, `last_scan_at`.
- **`library_items` :**
  - **identification :** `id`, `folder_id`, `rel_path`, `kind` (`video` | `audio` | `image`), `size`, `mtime`, `fingerprint` ;
  - **métadonnées :** `title`, `duration_ms`, `width`, `height`, `codec`, `artist`, `album`, `album_artist`, `track_no`, `disc_no`, `genre`, `year`, `taken_at` (date EXIF), `thumbnail_path` ;
  - **suivi :** `metadata_state` (`pending` | `done` | `failed`), `added_at`.
- **`library_progress` :** `profile_id`, `fingerprint`, `position_ms`, `duration_ms`, `completed`, `last_played_at`. Elle suit le même modèle que `watch_history` (`PRD-05`) et respecte les profils (`PRD-20`).
- **`library_playlists` / `library_playlist_items` :** listes de lecture audio et vidéo de l'utilisateur.
- **Recherche :** index FTS5 sur titre, artiste, album et nom de fichier, comme le catalogue IPTV.

### 4.3. Empreinte d'un fichier

Une empreinte rapide sert à retrouver un fichier déplacé et à garder sa reprise : taille + BLAKE3 des 64 premiers Ko et des 64 derniers Ko. Elle n'est **jamais** un hachage complet du fichier, trop lent pour un film de 20 Go.

### 4.4. API UniFFI (extrait)

- `library_add_folder(display_name, path, bookmark, options) -> FolderRecord`, `library_remove_folder(id)`, `library_list_folders()`.
- `library_scan(folder_id, root_path) -> ScanReport` (ajoutés, mis à jour, retirés, ignorés, durée) et `library_cancel_scan(folder_id)`.
- `library_list(kind, filter, sort, offset, limit)`, `library_albums()`, `library_artists()`, `library_genres()`, `library_browse(folder_id, rel_dir)`.
- `library_pending_metadata(limit)`, `library_store_metadata(item_id, metadata)` : Swift extrait, Rust enregistre.
- `library_record_progress(fingerprint, position_ms, duration_ms)`, `library_recent(kind, limit)`.

---

## 5. Métadonnées et miniatures (Swift, en arrière-plan)

- **Vidéo :**
  - **durée, dimensions, codec :** `AVURLAsset`, et pour les formats qu'AVFoundation ne lit pas (MKV, AVI, WMV), l'outil de sonde de mpv ou FFmpeg déjà présent ;
  - **miniature :** image à 10 % de la durée (`AVAssetImageGenerator`, ou une capture mpv en secours).
- **Audio :**
  - **étiquettes :** ID3, iTunes, Vorbis et FLAC par `AVAsset` (`commonMetadata`, puis les formats spécifiques) ;
  - **pochette :** intégrée au fichier, sinon `cover.jpg` ou `folder.jpg` du dossier ;
  - **sans étiquette :** titre déduit du nom de fichier.
- **Images :** dimensions, date de prise de vue et orientation par ImageIO (EXIF) ; miniature réduite par ImageIO (`kCGImageSourceCreateThumbnailFromImageAlways`), jamais l'image entière en mémoire.
- **Cache :** miniatures dans `Caches/CndLibraryThumbnails/`, effaçable dans Réglages (comme le cache d'images actuel).
- **Cadence :**
  - file de priorité basse, au plus 2 extractions en parallèle ;
  - mise en pause pendant une lecture IPTV pour ne pas gêner le flux ;
  - fichiers visibles à l'écran traités en premier.
- **Rien n'est envoyé sur Internet.** L'enrichissement des vidéos par OMDb (affiche, résumé) est une **option désactivée par défaut**. Activée, elle n'envoie que le titre nettoyé et l'année déduits du nom de fichier, avec la clé du `PRD-28`.

---

## 6. Écrans

### 6.1. Vidéo

- **Grille :**
  - miniatures 16:9 avec durée, barre de reprise et pastille de qualité (720p, 1080p, 4K, déduite des dimensions) ;
  - vue liste au choix ;
  - tri par nom, date d'ajout, date du fichier, durée ou taille ;
  - filtres « Non vus » et « En cours ».
- **Rangées « Reprendre » et « Ajoutés récemment »** en haut, avec le composant `HorizontalShelf` existant.
- **Lecture :**
  - **lecteur :** le lecteur de l'app (AVPlayer pour les formats natifs, mpv pour MKV, AVI, TS), avec reprise à la dernière position ;
  - **sous-titres :** le fichier `.srt` ou `.ass` de même nom est chargé automatiquement, et la recherche OpenSubtitles (`PRD-18`) reste disponible ;
  - **à la fin :** la vidéo suivante du même dossier est proposée, comme un épisode suivant.
- **Menu contextuel :**
  - lire et reprendre ;
  - ajouter à une liste de lecture ;
  - afficher dans le Finder (macOS) ou partager ;
  - informations (codec, débit, taille, chemin) ;
  - « Mettre à la corbeille », avec confirmation, seulement si le dossier est autorisé en écriture.

### 6.2. Audio

- **Vues :** Titres, Albums (grille de pochettes), Artistes, Genres, Dossiers, Listes de lecture.
- **Lecteur audio :**
  - **barre :** barre compacte en bas de la fenêtre (pochette, titre, artiste, lecture/pause, suivant) et vue « En cours de lecture » agrandie (pochette, progression, volume, aléatoire, répétition, file d'attente) ;
  - **lecture continue :** sur iPhone et iPad, la lecture continue quand l'app est en arrière-plan ou l'écran verrouillé (mode d'arrière-plan `audio`), avec Now Playing et les commandes de l'écran verrouillé et des écouteurs (`PRD-12`) ;
  - **sur Mac :** touches multimédia et centre de contrôle.
- **Coexistence avec l'IPTV :** lancer une chaîne met la musique en pause, et inversement. Un seul flux sonore à la fois.
- **Formats :** AVPlayer pour MP3, AAC, ALAC, WAV, AIFF et FLAC ; mpv sur macOS pour OGG, OPUS, WMA, APE et WV. Sur iPhone sans mpv, ces formats sont indiqués comme non pris en charge.

### 6.3. Images

- **Grille :** par mois de prise de vue ou par dossier, avec un zoom de grille (3 à 8 colonnes, pincement ou ⌘+ / ⌘-).
- **Visionneuse plein écran :**
  - navigation par glissement ou flèches ← → ;
  - zoom par pincement et double-tap ;
  - rotation selon EXIF ;
  - panneau d'informations (date, dimensions, appareil photo).
- **Diaporama :** durée réglable (3 à 10 s), avec fondu (respecte « Réduire les animations », `PRD-31`).
- **Partage :** feuille de partage du système. **Pas de retouche.**

### 6.4. Dossiers

- Parcours de l'arborescence des dossiers autorisés tels qu'ils sont sur le disque : sous-dossiers puis fichiers, avec leur icône de type.
- Un fichier non pris en charge est affiché grisé avec « Ouvrir avec… » (macOS).

### 6.5. Commun

- **Recherche** dans toute la bibliothèque (titre, artiste, album, nom de fichier), et depuis l'assistant ⌘K : « mets l'album Thriller », « ouvre mes vidéos de vacances ».
- **État vide :** « Ajoutez un dossier pour retrouver ici vos vidéos, votre musique et vos photos », avec le bouton « Ajouter un dossier… ».
- **Glisser-déposer** (macOS) d'un dossier sur la fenêtre : propose de l'autoriser.

---

## 7. Mises à jour de l'index

- **macOS :** surveillance des dossiers autorisés par FSEvents, avec un regroupement de 5 s, puis parcours incrémental du sous-dossier modifié.
- **iPhone, iPad :** parcours incrémental au retour au premier plan, au plus toutes les 10 minutes, et avec « Tirer pour actualiser ».
- **Téléchargement terminé (`PRD-07`) :** il est ajouté immédiatement, sans attendre un parcours.
- **Disque externe rebranché :** le dossier repasse « disponible » et un parcours incrémental est lancé.

---

## 8. Lots

| Lot | Contenu | Validation principale |
| :--- | :--- | :--- |
| **32.1** | Autorisation des dossiers et signets (macOS, iOS), dossier de téléchargement ajouté d'office, parcours incrémental Rust, tables SQLite, section « Mes fichiers » dans la barre latérale et **Vidéo** (grille, lecture, reprise, sous-titres voisins). | Tests Rust du parcours et de la classification ; signet conservé après relance (macOS signé et iPhone). |
| **32.2** | Métadonnées vidéo et audio, miniatures, **Audio** (vues, lecteur audio, arrière-plan, Now Playing, listes de lecture). | Tests des étiquettes sur des fichiers de test ; lecture en arrière-plan sur iPhone. |
| **32.3** | **Images** (grille, visionneuse, diaporama, EXIF). | Tests ImageIO ; essai sur 5 000 photos. |
| **32.4** | **Dossiers** (parcours), surveillance FSEvents, recherche FTS5 et commandes ⌘K, glisser-déposer, Réglages > Mes fichiers, corbeille. | Tests de la surveillance et de la recherche. |

Chaque lot est livrable et validable seul.

---

## 9. Fichiers à Créer / Modifier

- **Rust :**
  - `crates/cnd-core/src/library/` *(nouveau)* : `mod.rs`, `scanner.rs`, `classify.rs`, `fingerprint.rs` ;
  - `db/schema.rs`, `db/library_repo.rs` *(nouveau)* ;
  - `lib.rs` *(exports UniFFI)*, puis `scripts/build-xcframework.sh`.
- **Swift :**
  - `apple/Sources/CndIptvKit/Features/Library/` *(nouveau)* : `LibraryModel.swift`, `FolderAccess.swift` (signets, accès de sécurité), `MetadataExtractor.swift`, `LibraryVideoView.swift`, `LibraryAudioView.swift`, `AudioPlayerBar.swift`, `NowPlayingAudioView.swift`, `LibraryImagesView.swift`, `ImageViewer.swift`, `LibraryFoldersView.swift` ;
  - `App/AppShellView.swift` *(section « Mes fichiers », onglet iPhone)* ;
  - `Player/CndPlayerController.swift` *(fichiers locaux, sous-titres voisins, mode audio)* ;
  - `Features/Settings/SettingsView.swift` *(Réglages > Mes fichiers)*.
- **Configuration :**
  - `apple/Resources/Info-iOS.plist` *(`UIBackgroundModes` : `audio`, si absent ; `LSSupportsOpeningDocumentsInPlace`)* ;
  - entitlements macOS : déjà suffisants (`files.user-selected.read-write`, `files.bookmarks.app-scope`).
- **Tests :** `apple/Tests/CndIptvAppTests/Library*Tests.swift`.
- **Index :** `PRD/00_INDEX_ROADMAP.md`.

---

## 10. Contraintes Non-Négociables (Guardrails IA)

- **Uniquement les dossiers autorisés par l'utilisateur.** Aucun parcours d'un dossier parent, du dossier personnel ou du disque entier. Aucune demande d'« Accès complet au disque ».
- **L'app ne modifie, ne déplace et ne supprime aucun fichier,** sauf « Mettre à la corbeille » demandé explicitement et confirmé. Jamais de suppression définitive.
- **Rien ne quitte l'appareil :**
  - **noms et chemins :** pas de nom de fichier, de chemin ou de métadonnée envoyé sur Internet, sauf l'option OMDb activée (titre et année seulement) ;
  - **journaux :** ils ne contiennent pas les chemins complets (dossier autorisé + nom du fichier seulement, comme le masquage des URL du `PRD-01`).
- **Accès de sécurité :** ouvert seulement pendant l'opération et toujours refermé, même en cas d'erreur (`defer`).
- **Aucun blocage :**
  - aucun fichier lu en entier pour l'indexation (empreinte partielle, métadonnées par AVFoundation et ImageIO) ;
  - le parcours et l'extraction ne bloquent jamais l'interface ;
  - une lecture IPTV en cours garde la priorité.
- **Sécurité des données :** pas de nouvelle crate Rust lourde (le parcours utilise la bibliothèque standard, BLAKE3 est déjà présent). Les cibles macOS, iOS, tvOS et visionOS restent vertes, et tvOS n'affiche pas la section.

---

## 11. Hors périmètre (PRD ultérieurs possibles)

- **Partages réseau** (SMB, NFS, UPnP/DLNA, WebDAV, FTP), comme l'onglet « Réseau » de VLC. C'est ce qui rendrait la bibliothèque utile sur Apple TV.
- **Photothèque Apple** (`PhotoKit`) : elle demande une autorisation distincte et a sa propre app.
- **Édition des étiquettes audio,** conversion, extraction de CD.
- **Synchronisation iCloud** des positions de reprise des fichiers locaux, par empreinte (§ 4.3).

---

## 12. Critères d'Acceptation & Commandes de Validation

1. **Tests Rust :**
   - classification par extension et par signature ;
   - fichiers cachés, paquets et liens symboliques ignorés ;
   - parcours incrémental (ajout, modification, suppression, renommage retrouvé par l'empreinte) ;
   - plafond et annulation ;
   - sous-titres et pochettes rattachés ;
   - FTS5 ;
   - SLA : 10 000 fichiers en moins de 10 s (`--release`) et une liste de 50 000 éléments en moins de 50 ms.
2. **Tests Swift :**
   - signets (création, résolution, signet périmé renouvelé, dossier introuvable, accès refusé) ;
   - accès de sécurité toujours refermé ;
   - extraction des métadonnées sur des fichiers de test (MP4, MKV, MP3 étiqueté, FLAC, JPEG avec EXIF, HEIC) ;
   - reprise par profil ;
   - sous-titre voisin chargé ;
   - musique mise en pause au lancement d'une chaîne.
3. **Essais manuels :**
   - **Mac :** autoriser `~/Movies` et un disque externe, relancer l'app (signet conservé), débrancher le disque (« indisponible »), le rebrancher ;
   - **iPhone :** autoriser un dossier d'iCloud Drive, lire un album écran verrouillé avec les commandes de l'écran verrouillé ;
   - **téléchargement :** un téléchargement terminé apparaît dans « Vidéo » ;
   - **retrait :** retirer un dossier, les fichiers restent intacts sur le disque.
4. `cargo clippy --workspace --all-targets -- -D warnings`, `cargo test --workspace --release`, `cd apple && swift test`, builds des 4 schémas Xcode, `task check` au vert.

---

## 13. Questions ouvertes

- **Place dans la barre latérale :** « Mes fichiers » sous les entrées IPTV (retenu), ou au-dessus pour ceux qui l'utilisent surtout comme lecteur local ?
- **iPhone :** quel onglet passe sous « Plus » pour laisser la place à « Fichiers » (Enregistrements, Guide TV) ?
- **Corbeille :** proposer « Mettre à la corbeille » dès le lot 32.1, ou garder la bibliothèque en lecture seule au début ?
- **Apple TV :** faut-il commencer par les partages réseau (§ 11) pour que la bibliothèque y existe aussi ?

---

## 14. Statut d'Implémentation & Validation

**Terminé et validé.**

- **Rust Core (`crates/cnd-core`) :**
  - Traversal streaming, réconciliation incrémentale, détection des renommages par empreinte BLAKE3 (64KB début/fin), ignore cachés/paquets/liens symboliques sortants (`crates/cnd-core/src/library/`).
  - Classification par extension et vérification par signature / magic bytes (`crates/cnd-core/src/library/classify.rs`).
  - Détection automatique des sous-titres voisins (`.srt`, `.ass`) et des pochettes (`cover.jpg`, `folder.jpg`).
  - Modèle SQLite complet avec FTS5 (`library_folders`, `library_items`, `library_items_fts`, `library_progress`, `library_playlists`, `library_playlist_items`).
  - SLA validés par tests : 10 000 fichiers scannés en < 10 s, requête de 50 000 éléments en < 50 ms.
- **Universal XCFramework (`scripts/build-xcframework.sh`) :**
  - Compilé avec succès pour les 7 cibles (macOS, iOS device & simulator, tvOS device & simulator, visionOS device & simulator).
  - Bindings UniFFI Swift générés dans `apple/Packages/CndCoreBridge/`.
- **Couche Swift (`CndIptvKit`) :**
  - `FolderAccess` : gestion des signets de sécurité persistants (`security-scoped bookmarks`) et wrappers d'accès.
  - `MetadataExtractor` : extraction arrière-plan AVFoundation (durée, dimensions, codec, ID3), ImageIO (EXIF, miniatures downsamplées), cache disque.
  - `LibraryModel` : coordinateur `@Observable` réactif pour dossiers, scans, filtres, tris, FTS5 et moteur audio AVPlayer.
  - Écrans complets : `LibraryVideoView`, `LibraryAudioView`, `AudioPlayerBar`, `NowPlayingAudioView`, `LibraryImagesView`, `ImageViewer`, `LibraryFoldersView`, `LibrarySettingsView`.
  - Intégration `AppShellView` : section « Mes fichiers » dans la barre latérale macOS avec indicateur de scan et badges, onglets, coexistence audio/vidéo exclusive, drag-and-drop de dossiers.
  - Exclusion automatique tvOS (`#if !os(tvOS)`).
- **Tests :**
  - Tests unitaires Rust complets (210 tests passés, 0 échec).
  - Tests unitaires Swift `LibraryModelTests` (signets, sécurité, indexation, filtres, audio, recherche FTS5, corbeille, reprise).
