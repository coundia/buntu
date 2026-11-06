# Changelog

## 1.1.0

Identité **Buntu** (`com.pcoundia.buntu`), bibliothèque locale, recherche par prompt et recommandations IA séparées par type.

### Nouveautés
- **Identité Buntu** : nouveau logo vectoriel généré sur macOS, iOS, iPadOS, tvOS et visionOS, identifiant `com.pcoundia.buntu`.
- **Recommandations « Pour vous » séparées par type (PRD 34)** :
  - Moteurs et profils de goûts indépendants pour **Films**, **Séries** (au niveau de la série avec prochain épisode) et **Live TV** (programmes en cours, à venir dans les 2 h, habitudes horaires).
  - Affinage IA optionnel par **Gemini**, **IA locale compatible OpenAI** (Ollama, LM Studio), **Claude** ou le **modèle d'Apple sur l'appareil** (`FoundationModels`, lot 34.5), avec triple verrou de séparation des types.
  - Affichage des recommandations TV directement **en bas du lecteur** pendant la lecture d'une chaîne en direct.
- **Recherche par prompt IA (PRD 33)** : recherche en langage naturel dans Films, Séries et Live TV sans mélange de types, sélecteur rapide de fournisseur IA dans la palette (`⌘K`).
- **Bibliothèque média locale (PRD 32)** : ajout et suppression de dossiers locaux (Vidéos, Audio avec mini-lecteur persistant, Images) avec accès sécurisé par Security-Scoped Bookmarks.
- **Interface & UX** :
  - Badge compact `⚠ HS` et boutons allégés pour le signalement de flux en panne sur les cartes, affiches et fiches détails.
  - Lecteur flottant toujours au premier plan (`⌥⌘T`) et mode compact 16:9 (PRD 29).
  - Conformité accessibilité VoiceOver, navigation clavier et Dynamic Type (PRD 30 & 31).

## 1.0.0

Première version publiée : lecteur IPTV natif pour macOS, iPhone et iPad.

### Fonctionnalités
- **Sources** : playlists M3U / M3U8 (URL ou fichier) et comptes Xtream Codes, mots de passe dans le Trousseau.
- **Live TV, Guide TV (EPG), Films, Séries** : catalogue de dizaines de milliers d'éléments, recherche plein texte dans toutes les catégories, favoris, reprise de lecture.
- **Lecteur** : `AVPlayer` et `libmpv` (macOS), reconnexion automatique, bascule vers un flux miroir, Multi-View, pause du direct, replay, plein écran, image dans l'image, AirPlay.
- **Assistant IA** (`⌘K`) : changer de chaîne en langage naturel, résolution locale d'abord, puis Gemini, OpenAI-compatible ou Claude avec votre propre clé.
- **Téléchargements, enregistrements (PVR), profils et contrôle parental, sous-titres.**
- **Partage de sources** : fichier `.cndshare`, lien ou QR code chiffrés (AES-GCM), et envoi direct vers un iPhone proche avec un code à 6 chiffres.

### iPhone et iPad
- Les chaînes en direct Xtream sont lues par leur adresse HLS (`.m3u8`) ; les films MP4 fonctionnent.
- Les films MKV, AVI et FLV ne sont pas lisibles dans l'app (pas de `libmpv` sur iOS) : ouverture dans VLC, Infuse ou Outplayer.
- iCloud est désactivé avec un compte développeur gratuit.

### Diagnostic
- Les échecs de lecture sont expliqués dans les logs (HTTP 429, 403, 404, DNS, délai dépassé) et la reconnexion s'arrête quand elle est inutile.

### Outils
- `task run`, `task run:iphone`, `task check` ; guide iPhone dans `docs/BUILD_IPHONE.md`.
