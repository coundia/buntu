# PRD 39 — Ajouter ses comptes sur la TV en scannant un QR code avec son téléphone (iPhone ou Android)

- **ID :** `PRD-39`
- **Prérequis :**
  - `PRD-26` (partage des sources), dont le document `cnd-source-share` (export, aperçu, détection des doublons, import), qui reste le contenu transporté ;
  - les apps TV : `PRD-21` (Apple TV), `PRD-37` (Android TV), `PRD-38` (Samsung Tizen) ;
  - les apps téléphone : iPhone (Apple) et Android (`PRD-37`).
- **Couches impactées :**
  - `Rust` : module **`pairing`** dans `cnd-domain`, sans entrées-sorties, compilé pour UniFFI (Swift, Kotlin) et WebAssembly (Tizen). Il porte la charge utile du QR, l'échange de clés, le chiffrement et la validation ;
  - `apple/` : scanner et envoi sur iPhone, écran « Recevoir » sur Apple TV ;
  - `android/` : scanner et envoi sur téléphone, réception sur Android TV (remplace l'actuel `QrPairingServer`) ;
  - `tizen/` : QR réel, réception par le canal Samsung, confirmation à la télécommande (remplace le QR simulé de l'onboarding).
- **Objectifs SLA :**
  - **< 30 s** entre l'affichage du QR sur la TV et le début de la synchronisation de la source, téléphone et TV sur le même Wi-Fi ;
  - QR lisible **à 3 m** par l'appareil photo d'un téléphone (charge utile < 300 octets, correction d'erreur M) ;
  - **0 secret en clair** sur le réseau : vérifié par une capture réseau pendant les tests ;
  - **0 import sans confirmation** à la télécommande.

---

## 1. Contexte & Objectif

Saisir un serveur Xtream, un nom d'utilisateur et un mot de passe avec la télécommande d'une TV est long et source d'erreurs. L'utilisateur a déjà ses comptes dans l'app de son téléphone, ou les a sous la main.

**Objectif :**
1. La TV affiche un **QR code**, sur l'écran d'accueil au premier lancement ou dans Sources > « Ajouter depuis le téléphone ».
2. L'utilisateur le **scanne avec son iPhone ou son téléphone Android**.
3. Il choisit sur le téléphone les **comptes (sources)** à envoyer, mots de passe compris.
4. La TV montre ce qu'elle a reçu, l'utilisateur **confirme à la télécommande**, et les sources se synchronisent.

Cela doit marcher sur **Samsung (Tizen)**, **Android TV / Google TV** et **Apple TV**, depuis **iPhone** comme depuis **Android**.

**Ce que fait déjà le code :**
- **Rust (`sharing/`) :** il sait produire, prévisualiser et importer un document de partage. Pas de changement de format.
- **Android TV (`QrPairingServer.kt`) :** il sert un formulaire web et reçoit les mots de passe **en clair** sur le réseau local, sans confirmation sur la TV. Ce PRD le remplace.
- **Tizen (`OnboardingView.tsx`) :** il affiche un **QR simulé** (« [ QR CODE ] »). Ce PRD le rend réel.
- **Apple :** l'envoi Mac → iPhone/iPad par réseau local existe (`PRD-26`, lot 26.3), mais l'Apple TV n'a **pas d'écran « Recevoir »**.

**Hors périmètre :**
- envoi de favoris, d'historique ou de profils (seulement les sources et leurs réglages : EPG, User-Agent, en-têtes) ;
- envoi de **clés d'IA** et de texte : traité par le `PRD-40` (§ 4.2), qui ajoute deux types de message scellé à ce protocole ;
- playlists locales (`file://`), trop lourdes pour ce canal : elles passent par le fichier `.cndshare` du `PRD-26` ;
- appareils sur des réseaux différents (voir le relais facultatif, § 9).

---

## 2. Parcours

### 2.1. Sur la TV

1. **Écran « Ajouter depuis le téléphone » :**
   - un grand QR code, avec « Scannez avec l'appareil photo de votre téléphone » ;
   - le nom de la TV et, en secours, l'**adresse de la TV** et un **code à 6 chiffres** (§ 6) ;
   - un compte à rebours : la session dure **5 minutes**, puis le QR se renouvelle d'une touche.
2. **À la réception**, une fenêtre de confirmation, avec le focus sur « Ajouter » :
   - « **iPhone de Papa** veut ajouter 2 comptes » ;
   - pour chaque compte : son nom, son type (Xtream / M3U), l'**hôte du serveur seulement** et « avec mot de passe » ;
   - les doublons (`PRD-26` § 2.4) : « déjà présent », avec les choix Ignorer / Remplacer ;
   - les boutons **Ajouter** et **Refuser**.
3. **Après l'ajout :** « 2 comptes ajoutés », puis la synchronisation démarre comme pour un ajout manuel. Le téléphone est prévenu du résultat.

### 2.2. Sur le téléphone

- **Avec l'app Buntu installée (iPhone ou Android) :**
  1. On scanne le QR avec l'appareil photo du système, et le lien ouvre l'app sur « Envoyer vers la TV ». On peut aussi passer par l'app : Sources > « Envoyer vers une TV », qui ouvre le scanner intégré.
  2. On voit la liste des comptes du téléphone, tous cochés, avec l'option « Inclure les mots de passe » activée. Il s'agit de vos appareils, donc l'avertissement du `PRD-26` sur la limite de connexions est affiché.
  3. On appuie sur **Envoyer**. Le téléphone affiche « En attente de confirmation sur la TV… », puis « Ajouté sur Salon TV » ou « Refusé ».
- **Sans l'app :**
  - **Android TV :** le QR peut ouvrir une **page web servie par la TV**. On y saisit un compte, chiffré dans la page avant l'envoi (§ 5.2).
  - **Samsung et Apple TV :** l'app sur le téléphone est nécessaire, car ces TV ne peuvent pas servir de page web (§ 3). Le lien du QR mène alors l'utilisateur vers l'App Store ou le Play Store.
- **Si le scan échoue :** dans l'app, « Saisir le code » permet de taper l'adresse de la TV et le code à 6 chiffres affichés à l'écran.

---

## 3. Transport, selon la TV

Le contenu, son chiffrement et la confirmation sont **identiques** partout (§ 4). Seul le chemin réseau change :

| TV | Comment la TV reçoit | Pourquoi |
| :--- | :--- | :--- |
| **Samsung (Tizen)** | **Canal Samsung Multiscreen (MSF)** : l'app TV ouvre un canal nommé (`msf.local()` puis `service.channel("buntu.pair.<session>")`). Le téléphone s'y connecte par WebSocket (`ws://<tv>:8001/api/v2/channels/buntu.pair.<session>`, ou `wss://<tv>:8002/…` sur les modèles qui l'exigent). | Une app web Tizen **ne peut pas ouvrir de port d'écoute**. Le canal MSF est le moyen prévu par Samsung pour qu'un téléphone parle à une app TV du même réseau. |
| **Android TV / Google TV** | **Petit serveur HTTP local** sur la TV (port aléatoire), qui n'accepte que des messages chiffrés, sauf la page web de secours du § 5.2. | Android peut écouter sur le réseau local. |
| **Apple TV** | **Bonjour (`_cndiptv._tcp`) + canal TLS-PSK** du lot 26.3, avec une clé dérivée de l'échange du § 4. | Le canal existe déjà entre Mac et iPhone : il reste à créer l'écran « Recevoir » sur tvOS. |

**Réseau :**
- même Wi-Fi requis. Un réseau « invité » qui isole les appareils empêche la connexion, et l'app le dit avec ce message : « Votre téléphone ne voit pas la TV : vérifiez qu'ils sont sur le même Wi-Fi (pas un réseau invité) » ;
- sur iPhone, l'autorisation « Réseau local » est demandée au premier envoi (`NSLocalNetworkUsageDescription`, déjà prévue au `PRD-26`).

---

## 4. Protocole (un seul, dans `cnd-domain::pairing`)

### 4.1. Contenu du QR

Lien court, moins de 300 octets :

```
buntu://pair?v=1&s=<session>&n=<nom de la TV>&t=<msf|http|tls>&h=<ip>&p=<port>&k=<clé publique>&e=<expiration>
```

- `s` : identifiant de session aléatoire (64 bits, base32) ;
- `k` : **clé publique X25519 éphémère de la TV** (32 octets, base64url), créée pour cette seule session ;
- `t`, `h`, `p` : le transport et l'adresse pour joindre la TV ;
- `e` : l'expiration (5 minutes).

Sur Android TV, le QR utilise `http://<ip>:<port>/pair#<mêmes paramètres>` pour que la page de secours s'ouvre aussi sans l'app. L'app Android intercepte ce lien quand elle est installée.

### 4.2. Envoi chiffré de bout en bout

1. Le téléphone crée sa propre paire X25519 éphémère, calcule le secret partagé avec `k`, puis dérive la clé par **HKDF-SHA256** (`info = "buntu-pair-v1" || s`).
2. Il chiffre en **AES-256-GCM** le document `cnd-source-share` du `PRD-26`, compressé, avec les mots de passe s'ils sont inclus. Les données authentifiées sont `v || s || nom du téléphone`.
3. Il envoie : `{ "v": 1, "s": …, "from": "iPhone de Papa", "epk": …, "nonce": …, "ct": … }`. La taille maximale est de 64 Ko, et les playlists locales sont exclues.
4. La TV déchiffre, appelle `preview_share_document` et affiche la confirmation (§ 2.1). Rien n'est écrit avant « Ajouter ».
5. La TV répond `{ "s": …, "result": "added" | "refused" | "error", "count": n }`, chiffré avec la même clé.

**Pourquoi c'est sûr :** la clé de la TV n'arrive que par le **QR affiché à l'écran**, c'est-à-dire par la vue. Un appareil du réseau qui intercepte le trafic ne peut ni lire le contenu, ni se faire passer pour la TV.

### 4.3. Garde-fous de session

- **Session :** à usage unique, 5 minutes au plus. La clé privée de la TV est effacée à la fin, après un succès, un refus ou l'expiration.
- **Échecs :** au-delà de **3 messages invalides** (déchiffrement raté, mauvaise session, format faux), la session est fermée et un nouveau QR est demandé.
- **Expiration :** toute charge expirée ou rejouée est refusée.
- **Écoute :** la TV n'écoute (serveur HTTP, canal MSF, Bonjour) **que pendant que l'écran est ouvert**.
- **Confirmation obligatoire** à la télécommande, même avec une session valide.

### 4.4. Mise en commun du code

`cnd-domain::pairing` (Rust pur, `x25519-dalek`, `hkdf`, `aes-gcm`, `sha2` de RustCrypto) fournit :
- `pairing_offer(tv_name, transport, host, port)`, qui renvoie le lien du QR et une session ;
- `pairing_seal(offer_link, share_json, phone_name)`, qui renvoie le message ;
- `pairing_open(session, message)`, qui renvoie le document en clair ;
- `pairing_seal_reply` / `pairing_open_reply`.

Ces fonctions sont exposées par **UniFFI** (Swift, Kotlin) et **wasm-bindgen** (Tizen). Les **mêmes vecteurs de test** sont vérifiés sur les trois plateformes.

> Le `PRD-26` faisait le chiffrement en Swift (CryptoKit). Ici, trois plateformes doivent se comprendre : une seule implémentation, en Rust, évite les incompatibilités. Le format `.cndshare` du `PRD-26` ne change pas.

---

## 5. Par plateforme

### 5.1. Samsung (Tizen)

- **QR réel**, généré dans le Worker (bibliothèque QR en TypeScript ou Rust/WebAssembly) et dessiné en `canvas`. Il remplace le QR simulé de `OnboardingView.tsx`.
- **Réception :**
  - par la bibliothèque `msf` de Samsung, chargée avec l'app ;
  - chaque message du canal passe par `pairing_open` dans le Worker ;
  - la fenêtre de confirmation se pilote à la télécommande.
- **Secrets :** les mots de passe reçus sont stockés comme au `PRD-38` § 6 (KeyManager ou chiffrement lié à l'appareil).
- **À vérifier au lot 39.2 :**
  - connexion du téléphone au canal sur le port 8001, ou 8002 sécurisé sur les modèles récents ;
  - fenêtre « Autoriser cet appareil » affichée par la TV à la première connexion.

  Si la TV demande d'autoriser le téléphone, l'écran l'explique : « Choisissez Autoriser sur la TV ».

### 5.2. Android TV / Google TV

- Le **serveur local est réécrit** (`QrPairingServer`) :
  - il n'accepte que les messages chiffrés du § 4.2, et la fenêtre de confirmation s'affiche avant tout import ;
  - il ferme le port en quittant l'écran ;
  - il limite la taille des requêtes et les essais.
- **Page web de secours pour un téléphone sans l'app :**
  - un formulaire (Xtream ou M3U) dont la page **chiffre elle-même** le compte avant l'envoi ;
  - le chiffrement se fait par une petite bibliothèque JavaScript intégrée (X25519 et AES-GCM), car une page `http://` en réseau local n'a pas accès à WebCrypto ;
  - aucun mot de passe ne circule en clair, et la confirmation sur la TV reste obligatoire.
- **QR** affiché par Compose for TV (bibliothèque ZXing, déjà présente).

### 5.3. Apple TV

- Nouvel écran tvOS **« Recevoir depuis le téléphone »** (Sources, et premier lancement), avec un QR (Core Image `CIQRCodeGenerator`), le nom et le code.
- **Réception :** Bonjour avec le canal TLS-PSK du lot 26.3. La clé pré-partagée est dérivée de l'échange X25519 du § 4.2, à la place du code à 6 chiffres, qui reste le secours.
- **Secrets :** les mots de passe sont écrits dans le Trousseau de l'Apple TV (`cnd.xtream.<uuid>`).

### 5.4. iPhone (envoi)

- **Lien `buntu://pair`** déclaré dans `Info-iOS.plist` (`CFBundleURLTypes`, qui manque encore d'après le `PRD-26`).
- **Scanner intégré :** `DataScannerViewController` (VisionKit, iOS 16+), ou `AVCaptureMetadataOutput` en repli. La permission caméra n'est demandée qu'au premier scan.
- **Envoi** selon `t` : WebSocket vers le canal Samsung, HTTP vers Android TV, ou TLS-PSK vers Apple TV.

### 5.5. Android (envoi)

- **Lien** `buntu://pair` et `http://…/pair` (filtre d'intent).
- **Scanner :** le **Google code scanner** (Play services, sans permission caméra), ou CameraX avec ML Kit sur les appareils sans Play services.
- **Envoi** par le même client (OkHttp WebSocket ou HTTP, TLS-PSK pour l'Apple TV si utile).

---

## 6. Secours sans scan

- **Code à 6 chiffres :** dans l'app téléphone, « Saisir le code » demande l'**adresse de la TV** et le **code** affichés à l'écran. La clé est alors dérivée du code (comme au lot 26.3, avec un seul essai par connexion et la fermeture après 3 erreurs). C'est moins fort que le QR, d'où la session courte.
- **Code de partage du `PRD-26` :** il reste possible de taper un code `.cndshare` sur la TV, ce qui est long.
- **Relais par Internet, facultatif (lot 39.6) :** quand le téléphone et la TV ne sont pas sur le même réseau, un service de rendez-vous qui ne voit que des messages chiffrés de bout en bout. Il demande un serveur : à décider (§ 11).

---

## 7. Lots

| Lot | Contenu | Validation principale |
| :--- | :--- | :--- |
| **39.1** | `cnd-domain::pairing` : lien du QR, X25519, HKDF, AES-GCM, session, réponse ; exports UniFFI et WebAssembly ; vecteurs de test communs. | Tests Rust : aller-retour, mauvaise clé, rejeu, expiration, 3 échecs, charge trop grosse ; mêmes vecteurs vérifiés en Swift, Kotlin et TypeScript. |
| **39.2** | Samsung : QR réel, canal MSF, confirmation à la télécommande, stockage des secrets, synchronisation. | Ajout depuis un iPhone et un Android sur une TV Samsung réelle (AU8000, Tizen 6). |
| **39.3** | Téléphones : lien `buntu://pair`, scanner, choix des comptes, envoi (MSF, HTTP, TLS-PSK), résultat affiché. | Envoi réussi vers chaque type de TV ; la capture réseau ne montre aucun secret. |
| **39.4** | Android TV : serveur réécrit (chiffré, confirmation, port fermé à la sortie), page web de secours chiffrée. | Ajout depuis un téléphone **sans l'app** ; l'ancien envoi en clair n'est plus accepté. |
| **39.5** | Apple TV : écran « Recevoir », QR, Bonjour + TLS-PSK dérivé de l'échange. | Ajout depuis un iPhone et un téléphone Android. |
| **39.6** | Facultatif : relais Internet chiffré de bout en bout, pour des réseaux différents. | À décider (§ 11). |

Ordre conseillé : 39.1 → 39.2 (votre TV Samsung) → 39.3 → 39.4 → 39.5 → 39.6.

---

## 8. Fichiers à Créer / Modifier

- `crates/cnd-domain/src/pairing/` *(nouveau)* : `offer.rs`, `seal.rs`, `session.rs`, `tests.rs`, `vectors.json` ;
- `crates/cnd-core/src/lib.rs` *(exports UniFFI)* et `crates/cnd-domain-wasm/` *(exports WebAssembly)* ;
- `tizen/src/features/pairing/` *(nouveau : écran, QR, canal MSF)*, `tizen/src/features/onboarding/OnboardingView.tsx` *(QR réel)*, `tizen/config.xml` *(privilèges du canal si nécessaires)* ;
- `android/core/platform/.../tv/QrPairingServer.kt` *(réécrit)*, `android/feature/sources/` *(scanner, envoi)*, `AndroidManifest.xml` *(liens)* ;
- `apple/Sources/CndIptvKit/Features/Sharing/` : `PairingScanner.swift`, `PairingSender.swift`, `TvReceiveView.swift` *(nouveaux)* ;
- `apple/Resources/Info-iOS.plist` *(`buntu://`, caméra)*, `Info-tvOS.plist` *(Bonjour)* ;
- `docs/PAIRING.md` *(nouveau : fonctionnement, dépannage réseau)* ;
- `PRD/00_INDEX_ROADMAP.md`.

---

## 9. Contraintes Non-Négociables (Guardrails IA)

- **Aucun mot de passe ni identifiant en clair sur le réseau,** y compris depuis la page web de secours. L'ancien formulaire en clair d'Android TV est supprimé.
- **Aucun import sans confirmation à la télécommande** sur la TV.
- **La clé de la TV ne vient que du QR** ou du code affiché. Elle n'est jamais annoncée sur le réseau (pas dans Bonjour, pas dans le canal).
- **Sessions courtes et à usage unique ;** écoute fermée hors de l'écran ; 3 erreurs ferment la session.
- **Un seul protocole,** implémenté en Rust (`cnd-domain::pairing`) et utilisé par toutes les apps.
- **Les journaux** ne contiennent ni le contenu, ni la clé, ni l'adresse complète des serveurs IPTV.
- **Les cibles existantes restent vertes :** `cargo test`, `swift test`, les 4 schémas Xcode, les tests Android et Tizen.

---

## 10. Critères d'Acceptation & Commandes de Validation

1. **Rust :**
   - `cargo clippy --workspace --all-targets -- -D warnings` ;
   - `cargo test --workspace --release`, dont les cas : aller-retour, clé fausse, message altéré, rejeu, expiration, 3 échecs, 64 Ko dépassés ;
   - `cargo build -p cnd-domain-wasm --target wasm32-unknown-unknown --release`.
2. **Interopérabilité :** les vecteurs de `vectors.json` passent en Swift (`swift test`), en Kotlin (`./gradlew testDebugUnitTest`) et en TypeScript (`cd tizen && npm test`).
3. **Essais réels :**
   - iPhone → Samsung, Android → Samsung, iPhone → Android TV, Android → Apple TV ;
   - téléphone sans l'app → Android TV (page de secours) ;
   - temps du scan à la synchronisation < 30 s ;
   - QR lu à 3 m.
4. **Sécurité :**
   - capture réseau (`tcpdump` ou Wireshark) sans aucun identifiant lisible ;
   - un second téléphone qui renvoie un message capturé est refusé ;
   - un faux message sans le QR est refusé.
5. **Réseau invité :** le message d'erreur explicite s'affiche sur le téléphone.

---

## 11. Questions ouvertes

- **Canal Samsung sur les modèles récents :** le port 8001 suffit-il, ou faut-il le 8002 sécurisé avec un certificat auto-signé et l'autorisation sur la TV ? À mesurer sur votre AU8000 au lot 39.2.
- **Téléphone sans l'app vers Samsung ou Apple TV :** sans relais Internet, l'app est nécessaire. Faut-il le relais (lot 39.6), qui demande d'héberger un petit service ?
- **Inclure par défaut les mots de passe :** ce PRD les inclut par défaut (vos propres appareils), avec l'avertissement sur la limite de connexions du fournisseur. Faut-il plutôt les exclure par défaut, comme pour un ami au `PRD-26` ?
- **Envoyer aussi les favoris et la progression** des comptes : utile, mais ce sont des données personnelles. À traiter dans un PRD de synchronisation séparé.

---

## 12. Statut d'Implémentation & Validation

**Partiel : lots 39.1 à 39.4 réalisés ; 39.5 (Apple TV) et 39.6 (relais Internet) non faits.** Voir aussi [`docs/PAIRING.md`](../docs/PAIRING.md).

- **39.1 (protocole)** : `crates/cnd-domain/src/pairing.rs` (X25519, HKDF-SHA256, AES-256-GCM, session à usage unique, 3 échecs, expiration, réponse chiffrée), 14 tests, vecteurs partagés `pairing/vectors.json`. Exports UniFFI (`pairing_*`) et WebAssembly (`wasm_pairing_*`, `wasm_qr_matrix`).
- **39.2 (Samsung)** : QR réel dessiné par l'app (matrice calculée en Rust), canal Samsung de la TV (`MsfChannel`), confirmation à la télécommande (`OnboardingView`), import des comptes Xtream et M3U, binaire WebAssembly compilé et vérifié en **WebAssembly 1.0 MVP strict** (`wasm-opt --mvp-features`, sans retours multiples ni `externref`) pour les moteurs V8 des TV Tizen 5.0+ (Chromium 56..84). 22 tests Tizen, dont les vecteurs reproduits **octet pour octet en WebAssembly**, le parcours complet téléphone → TV avec confirmation et un test de non-régression sur les signatures MVP du `.wasm`.
- **39.3 (téléphones)** :
  - **iPhone** : feuille « Envoyer vers une TV (QR code) » dans Sources, scanner VisionKit, lien `buntu://pair` déclaré, choix des comptes, mots de passe inclus par défaut. 8 tests Swift (TV simulée qui exécute le vrai protocole Rust).
  - **Android** : feuille « Envoyer vers une TV (QR) » dans `SourcesScreen`, scanner `PhoneQrScanner` (Google Play Services code scanner sans permission caméra + repli saisie de lien), lien `buntu://pair` déclaré dans `AndroidManifest.xml`, export chiffré des comptes via `RustSourcesRepository.exportShareJson`, client `PairingSender` (HTTP Android TV et WebSocket Samsung MSF avec gestion `Ping`/`Pong`), tests unitaires `PairingSenderTest`.
- **39.4 (Android TV)** : serveur réécrit (`QrPairingServer` : uniquement des messages scellés, confirmation obligatoire, un message par session, port fermé à la sortie, sélection prioritaire de l'interface LAN Wi-Fi/Ethernet, plus aucun formulaire), `TvPairingCoordinator` exécuté hors Main Thread (`Dispatchers.IO`) et partagé par l'accueil et Sources, cartes de confirmation. Contrat `PairingRepository` dans `core:domain`, implémentation Rust dans `core:data` ; `RustPairingRepositoryTest` reproduit les vecteurs partagés en Kotlin par la vraie bibliothèque Rust.
- **Vérifié** : `cargo test --workspace` et clippy, `swift test` (509 tests), `npm test` (22 tests), tests Android (`./gradlew testDebugUnitTest lintDebug`), les 4 schémas Xcode.
- **Écarts avec le texte du PRD** :
  - le message n'est pas compressé (inutile sous 64 Ko : les playlists locales sont exclues) ;
  - pas de code à 6 chiffres de secours (§ 6) : la clé vient du QR seulement ;
  - pas de page web de secours chiffrée sur Android TV (elle demandait X25519 et AES-GCM en JavaScript sur une page http) : le navigateur est renvoyé vers l'app ;
  - doublons : ignorés (pas de choix « Remplacer ») sur Samsung ;
  - les mots de passe reçus sont stockés comme ceux de l'app Tizen existante (base IndexedDB), sans KeyManager.
- **Non fait / non vérifié** :
  - **39.5** : écran « Recevoir » sur Apple TV (le téléphone refuse un QR de type `tls` avec un message clair) ;
  - **39.6** : relais Internet ;
  - **essai réel d'un téléphone vers la TV** : à valider sur les appareils physiques après réinstallation du `.wgt` Tizen MVP et de l'APK Android mis à jour.
