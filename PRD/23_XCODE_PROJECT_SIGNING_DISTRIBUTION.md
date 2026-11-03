# PRD 23 — Projet Xcode signé, Info.plist, entitlements & distribution

- **ID :** `PRD-23`
- **Prérequis :** aucun (fondation) ; requis par `PRD-21`, `PRD-22`, et pour activer réellement l'iCloud du `PRD-12`, l'app Fichiers du `PRD-11` et `libmpv` sur iOS (`PRD-08`)
- **Couches impactées :** `apple/Package.swift` (découpage en bibliothèque), nouveau projet Xcode généré, `assets/`, `scripts/`, `Taskfile.yml`
- **Origine :** limites connues listées dans `README.md` et `reprise.md` (non couvertes par `PRD-14`)
- **Objectif SLA :** un build `Release` signé de l'app macOS et iOS est produit par **une seule commande** ; l'app macOS sandboxée garde toutes ses fonctions.

---

## 1. Contexte & Objectif

L'app est aujourd'hui un **exécutable Swift Package**, empaqueté à la main par `scripts/run-macos.sh` (bundle signé « ad hoc », sans `Info.plist` complet ni entitlements). Conséquences déjà constatées :
- iCloud reste en « Mode local uniquement » (pas d'entitlement CloudKit ni de clé `CndCloudKitContainerIdentifier`) ;
- sur iOS : pas d'icône d'app, `Documents/Downloads` invisible dans l'app Fichiers, `libmpv` non embarqué (lecteur limité à `AVPlayer`) ;
- impossible d'ajouter une extension (Live Activities) ou une cible tvOS.

---

## 2. Spécifications Techniques Détaillées

### 2.1. Découpage du package

- `apple/Package.swift` : nouveau produit **bibliothèque** `CndIptvKit` contenant tout `Sources/CndIptvApp` **sauf** le point d'entrée `@main` ; l'exécutable `CndIptvApp` (gardé pour `swift run` et `task run`) ne contient plus que `CndIptvApp.swift`. Les tests ciblent `CndIptvKit`.

### 2.2. Projet Xcode généré

- Projet décrit en texte (`apple/project.yml`) et généré par **XcodeGen** (outil de développement, pas une dépendance de l'app) pour rester relisible et reproductible ; `apple/*.xcodeproj` ignoré par git ou régénéré par `task xcode:generate`.
- Cibles : `CND IPTV (macOS)`, `CND IPTV (iOS)` (iPhone + iPad) ; emplacements prévus pour `tvOS` (PRD 21), `visionOS` et l'extension Widget (PRD 22).
- Dépendance locale au package (`CndIptvKit`, `CndCoreBridge`).

### 2.3. Info.plist (par plateforme)

- Identité : `CFBundleIdentifier` (préfixe configurable, ex. `com.cnd.iptv`), version, `LSApplicationCategoryType = public.app-category.entertainment`.
- Réseau : `NSAppTransportSecurity` → `NSAllowsArbitraryLoads = YES` (les flux IPTV sont souvent en HTTP) avec justification App Review ; `NSLocalNetworkUsageDescription` (assistant IA local Ollama/LM Studio, `PRD-13`).
- iOS : `UIFileSharingEnabled` et `LSSupportsOpeningDocumentsInPlace` (téléchargements visibles dans Fichiers), `UIBackgroundModes = audio` (lecture en arrière-plan et PiP).
- iCloud : `CndCloudKitContainerIdentifier = iCloud.<identifiant>` (active `CloudKitSyncManager`).
- `NSSupportsLiveActivities` réservé au PRD 22.

### 2.4. Entitlements

- macOS **App Sandbox** : `network.client`, `files.user-selected.read-write`, `files.bookmarks.app-scope` (marque-pages du dossier de téléchargement, `PRD-11`), `files.downloads.read-write`.
- iCloud : service CloudKit, conteneur `iCloud.<identifiant>`.
- Trousseau : groupe d'accès partagé entre les cibles ; option `kSecAttrSynchronizable` (Trousseau iCloud) pour les mots de passe Xtream, **désactivée par défaut**, décision documentée.
- Hardened Runtime (macOS).

### 2.5. libmpv embarqué

- Build LGPL de `libmpv` (et dépendances FFmpeg) pour macOS et iOS, copiée dans `Frameworks/` et **signée** à la phase de build ; vérifier la licence (pas de composants GPL). Le chargement `dlopen` cherche déjà `Frameworks/`.

### 2.6. Ressources & signature

- Catalogue d'assets `AppIcon` généré depuis `assets/AppIcon-1024.png` (`task icon`).
- Signature automatique avec `DEVELOPMENT_TEAM` lu dans une variable d'environnement ; à défaut, « Sign to Run Locally » (l'app fonctionne alors en mode local, comme aujourd'hui).
- Tâches : `task xcode:generate`, `task app:macos` (archive Release), `task app:ios` (archive), `task app:testflight` (export, facultatif).

---

## 3. Contraintes Non-Négociables (Guardrails IA)

- `swift test`, `task run` et la suite `task check` existante restent fonctionnels.
- Aucun secret (identifiant d'équipe, profils) dans le dépôt : variables d'environnement uniquement.
- Le mode « Sign to Run Locally » ne doit jamais faire planter l'app (iCloud reste en mode local, comme garanti par le PRD 12).

## 4. Critères d'Acceptation & Commandes de Validation

1. `task xcode:generate` puis builds Release macOS et iOS signés (ou « to Run Locally » sans équipe).
2. L'app macOS sandboxée : choix d'un dossier de téléchargement, téléchargement, lecture mpv, journaux.
3. Avec une équipe Apple : la synchronisation iCloud fonctionne entre un Mac et un iPhone (essai manuel documenté), les téléchargements iOS apparaissent dans Fichiers, un flux `.ts` se lit sur iPhone via mpv.
4. `task check` au vert.

---

## Statut d'Implémentation & Validation (audit)

**Partiel.**

Réalisé : découpage en bibliothèque `CndIptvKit` (tout `Sources/CndIptvKit`, produit `.library` ; l'exécutable `CndIptvApp` ne contient que le point d'entrée `@main` et dépend de la bibliothèque ; les 31 fichiers de tests ciblent `CndIptvKit` ; les cibles Xcode compilent les deux dossiers dans un seul module), projet Xcode généré par XcodeGen (`apple/project.yml`, `task xcode:generate`, ignoré par git), cibles macOS, iOS, tvOS, visionOS et l'extension Live Activity, `Info.plist` par plateforme (identité, catégorie, ATS, réseau local, fichiers sur iOS, audio en arrière-plan, Bonjour), entitlements macOS (App Sandbox, fichiers, signets), Hardened Runtime sur macOS, option Trousseau iCloud pour les mots de passe (PRD 26 lot 26.1, désactivée par défaut), signature automatique avec `DEVELOPMENT_TEAM`, icône (`task icon`), lancement sur iPhone (`task run:iphone`), archives Release `task app:macos` et `task app:ios` dans `build/archives/` (signées si `DEVELOPMENT_TEAM` est défini, sinon non signées ; essayées sans signature).

Non réalisé :
- **`libmpv` embarqué** : aucune bibliothèque n'est copiée dans `Frameworks/`, ni sur macOS (le `.app` publié s'appuie sur `brew install mpv`) ni sur iOS/tvOS (pas de lecture MKV/AVI/FLV).
- **Entitlements iCloud sur iOS** : retirés (compte développeur personnel) ; l'app iPhone fonctionne en local, sans synchronisation iCloud ni groupe de Trousseau partagé.
- **`task app:testflight`** (export App Store Connect) : absent, il exige un compte développeur payant.
- Essais manuels demandés (iCloud entre un Mac et un iPhone, dossier Fichiers) : non faits.

### Évaluation de `libmpv` pour iOS, tvOS, visionOS et le `.app` macOS (non intégré)

Piste étudiée : **MPVKit** (`github.com/mpvkit/MPVKit`, paquet SwiftPM). Constats :
- Produit LGPL-3.0 (`MPVKit`) et variante GPL-3.0 (`MPVKit-GPL`, ajoute samba) ; mpv 0.41 et FFmpeg 9. Seule la variante **LGPL** est compatible avec ce projet (liaison dynamique, App Store).
- Plateformes annoncées : iOS, macOS, tvOS, visionOS (simulateurs compris).
- Le README précise que le dépôt est **« seulement adapté à l'apprentissage de libmpv »** et peu maintenu ; le rendu Metal n'est qu'un correctif non officiel. La taille des binaires n'est pas indiquée (plusieurs dizaines de Mo par plateforme à prévoir).

Pourquoi ce n'est pas fait ici : le lecteur actuel charge `libmpv` par `dlopen` et affiche par l'API de rendu OpenGL (macOS). Sur iOS il faudrait (1) lier la bibliothèque statiquement et remplacer le chargeur par des appels directs, (2) écrire un rendu Metal ou OpenGL ES propre à iOS/tvOS/visionOS, (3) gérer la mémoire et l'arrière-plan. Aucune de ces étapes ne peut être vérifiée sans voir la vidéo à l'écran d'un appareil ; écrire ce rendu à l'aveugle donnerait du code qui compile sans qu'on sache s'il affiche une image.

Marche à suivre proposée (à faire avec un appareil sous les yeux) :
1. Prototype isolé : une vue qui lit un flux `.ts` avec MPVKit (variante LGPL) sur l'iPhone ; valider l'image, le son, la pause et l'arrêt sans fuite.
2. Si le prototype tient, remplacer `MpvLibrary` (dlopen) par la liaison directe sur iOS/tvOS/visionOS et brancher `MpvVideoToolboxBackend` sur ce rendu ; garder `dlopen` sur macOS ou embarquer la bibliothèque dans `Frameworks/`.
3. Vérifier la licence (aucun composant GPL), la taille de l'app et la signature des frameworks.

Tant que ce n'est pas fait, l'app iPhone/iPad/Apple TV lit les chaînes par leur adresse HLS et signale les formats que seul `libmpv` sait lire (MKV, AVI, FLV).

