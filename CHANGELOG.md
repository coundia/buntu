# Changelog

## 1.2.0

Ouverture Open Source du dépôt (`MIT OR Apache-2.0`), préparation des releases multiplateformes unifiées (`1.2.0`, `build 3`), localisation bilingue **Français / English**, continuité du foyer chiffrée, « Commande TV » et refonte du lecteur Live TV (`PRD-46`).

> **Numérotation :** cette version prolonge la `1.1.0` déjà publiée (tag `v1.1.0`). Une `1.0.1` n'a jamais été publiée : le numéro de build passe de `2` à `3` pour rester supérieur à celui de la `1.1.0`.

### Open Source & Gouvernance
- **Double licence `MIT OR Apache-2.0`** : ajout de [`LICENSE`](LICENSE), [`LICENSE-MIT`](LICENSE-MIT) et [`LICENSE-APACHE`](LICENSE-APACHE) ainsi que des métadonnées `Cargo.toml`.
- **Guides et modèles communautaires** : ajout de [`CONTRIBUTING.md`](CONTRIBUTING.md), [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md), [`SECURITY.md`](SECURITY.md) et des modèles GitHub Issues / Pull Requests (`.github/ISSUE_TEMPLATE/`, `.github/pull_request_template.md`).
- **CI/CD GitHub Actions & hygiène** : workflows [`.github/workflows/ci.yml`](.github/workflows/ci.yml) (`secrets-and-keys`, `rust`, `tizen`, `android`) et [`.github/workflows/release.yml`](.github/workflows/release.yml) ; mises à jour hebdomadaires de dépendances ([`.github/dependabot.yml`](.github/dependabot.yml)) ; renforcement de [`scripts/check-secrets.sh`](scripts/check-secrets.sh) (fichiers neufs non encore suivis inclus) et assainissement des identifiants/chemins locaux dans la documentation et les scripts.
- **Version cohérente** : [`scripts/check-version.sh`](scripts/check-version.sh) refuse un arbre où une plateforme (Android, Apple, Tizen, Cargo) porte une autre version ou un autre numéro de build ; `prepare-releases.sh` et le workflow de release en dépendent, et un tag `vX.Y.Z` doit correspondre à `Cargo.toml`.
- **Licences tierces** : [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) (MPVKit LGPL-3.0 lié aux apps Apple, composant propriétaire Google Play services sur Android).

### Releases multiplateformes unifiées (`1.2.0`, build `3`)
- **Alignement des versions (`1.2.0` / `build 3`)** sur Rust (`Cargo.toml`), Apple (`AppBrand.swift`, `Info-macOS.plist`, `Info-iOS.plist`, `Info-tvOS.plist`, `Info-visionOS.plist`, `scripts/run-macos.sh`), Android (`android/app/build.gradle.kts`, `SettingsScreen.kt`) et Samsung Smart TV (`tizen/src/core/appInfo.ts`, `tizen/config.xml`, `tizen/package.json`).
- **Automatisation & documentation de release** : nouveau script [`scripts/prepare-releases.sh`](scripts/prepare-releases.sh) et tâches `Taskfile.yml` (`task release`, `task release:tizen`, `task release:macos`, `task release:android`, `task release:dry-run`) produisant `Buntu_1.2.0_Tizen.wgt`, `Buntu-1.2.0-macOS.zip` / `.dmg`, les APK Android par ABI et universel (`Buntu-1.2.0-android-*.apk`) et `SHA256SUMS.txt` dans `build/release/v1.2.0/`.
- **Guides de distribution** : ajout de [`docs/RELEASE.md`](docs/RELEASE.md) et mise à jour de [`docs/DEPLOY_TIZEN_STORE.md`](docs/DEPLOY_TIZEN_STORE.md) pour la soumission Samsung Apps TV Seller Office (`--prod` sans `devel.mode`, signatures `TIZEN_PROFILE`), la signature macOS (`DEVELOPMENT_TEAM`) et la signature Android (`BUNTU_KEYSTORE_*` avec repli `debug` en local).

### Nouveautés produit & multiplateforme
- **Localisation bilingue Français / English à chaud** sur **Tizen** (`tizen/src/core/i18n/`), **Apple** (`AppLanguage`, `AppStringsFR` / `AppStringsEN`) et **Android** (`AppLocalization`, `AppStringsFr` / `AppStringsEn`) avec persistance du choix sans redémarrage.
- **Continuité du foyer & « Lire sur un autre appareil » sans Cast (`PRD-41` à `PRD-45`)** : synchronisation chiffrée de bout en bout sur le réseau local (`AES-256-GCM`, identité déterministe en Rust `cnd-domain`), transfert de lecture mono-connexion avec arrêt préalable et `release_stream`, et réception sur Samsung Smart TV via le canal MSF.
- **Appairage par QR code & découverte locale (`PRD-39` & `PRD-43`)** : échange de clés éphémères `X25519` + `HKDF-SHA256` et confirmation à l'écran, avec QR code directement scannable sur TV Samsung pour rejoindre le foyer.
- **Écran « Commande TV »** : dictée vocale et saisie texte ciblée (`remote_text`) depuis l'application Apple ou Android vers un appareil précis du foyer ou l'ensemble du foyer.
- **Lecteur Live TV amélioré (`PRD-46`)** : zapping débouclé à **250 ms** anti-`429`, touche **Recall** (dernière chaîne), saisie numérique directe **`0–9`**, barre **EPG temps réel** et bouton **Start-Over** (« Revoir depuis le début »), sélecteur **Qualité / Miroirs** avec bascule automatique (max 2 par session), **Mini-Guide** latéral transparent, choix du **format vidéo** (`Ajuster / Remplir / Étirer`) et **minuteur de veille** (`15 / 30 / 60 / 90 min`).
- **Design System solide & ergonomie TV ([`DESIGN.md`](DESIGN.md))** : charte sombre opaque « anti-IA » sans dégradé ni flou de transparence, boutons 100 % solides WCAG AA/AAA, bouton accueil cliquable sur le logo Buntu, collage presse-papiers dans le clavier TV et les formulaires de sources, écran « À propos » unifié et préférences d'accessibilité/sous-titres.

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
