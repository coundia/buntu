# PRD 45 — TV Samsung : recevoir une lecture lancée depuis un autre appareil du foyer (réception seule)

- **ID :** `PRD-45`
- **Prérequis :**
  - `PRD-38` (app Samsung Tizen) ;
  - `PRD-39` (canal Samsung MSF, déjà utilisé pour l'appairage par QR) ;
  - `PRD-41` (foyer, enveloppe chiffrée, canal `buntu.sync.<identifiant du foyer>`) ;
  - `PRD-42` (protocole `play_request` / `play_ready` / `play_go`, réception Tizen codée) ;
  - `PRD-43` (la TV rejoint le foyer).
- **Couches impactées :**
  - `apple/Sources/CndIptvKit/Sync/` : **nouveau** lien vers la TV par le canal Samsung ;
  - `android/core/platform/.../sync/` : même lien (après le `PRD-44`, lot 44.2) ;
  - `tizen/src/core/sync/LocalSyncService.ts`, `tizen/src/core/remote/RemotePlayback.ts` : format du canal, présence, remplacement sans confirmation ;
  - `crates/cnd-domain/src/remote/` : règle « remplacer sans confirmation dans le foyer » (partagée avec `PRD-44`, lot 44.1).
- **Objectifs (à mesurer sur la TV de référence UN43AU8000, Tizen 6.0) :**
  - la TV apparaît **« Disponible »** sur le Mac et l'iPhone en **< 10 s** après l'ouverture de Buntu sur la TV ;
  - **< 5 s** entre le choix de la TV et l'image ;
  - la TV **arrête son flux en cours** et lit le nouveau, **sans question** ;
  - **100 %** des transferts sans deux flux du même compte chez le fournisseur ;
  - **0 URL de flux, 0 mot de passe** dans les messages, les journaux et les écrans.

---

## 1. Contexte & Objectif

Le Mac et l'iPhone se lancent des lectures dans les deux sens depuis le 9 novembre 2026. L'utilisateur veut que **la TV Samsung puisse recevoir** une lecture lancée depuis n'importe quel appareil du foyer (Mac, iPhone, iPad, et Android après le `PRD-44`).

### 1.1. Décisions de l'utilisateur (9 novembre 2026)

- **Réception seule pour l'instant** : la TV **reçoit** des lectures ; elle **ne propose pas** « Lire sur un autre appareil » (aucun menu d'envoi sur la TV dans ce PRD).
- **Pas de confirmation dans le foyer** : la TV **arrête toujours le flux en cours** et lit le nouveau, sans écran « Lire ici ? ».

### 1.2. Pourquoi la TV n'apparaît pas aujourd'hui

Une app web Tizen **ne peut pas ouvrir de port** (`PRD-39`, choix du canal Samsung) : la TV ne peut pas utiliser le transport Bonjour + TCP des autres appareils (`_buntu-sync._tcp`). Elle passe par le **canal Samsung** : un relais WebSocket fourni par la TV (`ws://<tv>:8001/api/v2/channels/<nom>`) auquel l'app de la TV **et** les autres appareils se connectent comme clients (`PRD-41 § 6.2`). Les apps Apple et Android **ne se connectent jamais à ce canal** pour le foyer ; l'écran Appareils du Mac le dit : « La TV Samsung n'apparaît pas encore ici ».

### 1.3. Ce qui existe (vérifié dans le code, 9 novembre 2026)

| Brique | Où | État |
| :--- | :--- | :--- |
| Connexion de la TV à son propre canal `buntu.sync.<foyer>` | `tizen/src/core/sync/LocalSyncService.ts` (`connectWs`, hôte de la page sinon `127.0.0.1`, port 8001) | Codé ; reconnexion toutes les 5 s |
| Envoi sur le canal | `sendMessage` : `ws.send(JSON.stringify({ event: 'buntu-sync-envelope', data: envelope }))` | **À vérifier** : le canal d'appairage envoie `{ method: 'ms.channel.emit', params: { event, to: 'broadcast', data } }` (`tizen/src/core/pairing/MsfChannel.ts`). Sans `ms.channel.emit`, le relais ne transmet probablement rien. **Jamais mesuré.** |
| Présentation de la TV | `broadcastDeviceAnnounce` | Envoyée **une seule fois**, à l'ouverture du canal ; pas de présence régulière, pas de réponse à la présentation des autres |
| Réception d'une lecture | `tizen/src/core/remote/RemotePlayback.ts`, branché dans `tizen/src/app/App.tsx` (`onPlayItem` → lecteur plein écran) | Codé et testé : contenu retrouvé, profil Enfants, un seul flux par compte (`release_stream`), état toutes les secondes, limite de débit |
| Lecture en cours sur la TV | `RemotePlayback.ts` : `playingHere` → `onPrompt`, sinon refus `busy` | **`onPrompt` n'est branché nulle part** : une TV qui lit **refuse toujours** (`busy`). Contraire à la décision § 1.1 |
| Données du foyer | `LocalSyncService.ts` : `sync_delta` (format à horloge HLC) | Apple envoie `household_data_delta` (format de l'export `cnd-core`) : **les deux formats ne se comprennent pas**. Hors périmètre ici (§ 1.4), mais à signaler |
| Client du canal Samsung côté Apple | `apple/Sources/CndIptvKit/Features/Sharing/PairToTV.swift` (`URLSessionWebSocketTask`, attend `ms.channel.connect`, envoie `ms.channel.emit`) | Existe **pour l'appairage seulement** ; réutilisable |
| Client du canal côté Android | `android/core/platform/.../phone/PairingSender.kt` (`ms.channel.emit`, `Ping`/`Pong`) | Existe **pour l'appairage seulement** |
| Trouver la TV sans connaître son adresse | La TV s'annonce en `_samsungmsf._tcp` (mesuré, `PRD-41 § 9`) | **Non déclaré** dans `NSBonjourServices` d'Apple (`apple/Resources/Info-*.plist` : `_cndiptv._tcp`, `_buntu-sync._tcp`, `_buntu-pair._tcp`) : iOS refusera de le chercher tant qu'il n'y est pas |

### 1.4. Hors périmètre

- **Envoyer depuis la TV** (« Lire sur un autre appareil » sur la TV) : plus tard.
- **Synchroniser les données** (comptes, favoris, reprises) entre la TV et les autres appareils : le format diffère (§ 1.3) ; à traiter dans un PRD à part.
- **Télécommande de lecture** depuis le téléphone (pause, saut, chaîne +/−) : déjà prévue au `PRD-42` ; non exigée ici, mais ne doit pas casser.
- **Allumer Buntu sur la TV à distance** (`POST /api/v2/applications/…`) : jamais essayé (`PRD-42 § 7`), hors périmètre.

---

## 2. Expérience utilisateur

- **Sur le Mac, l'iPhone, l'iPad (puis Android) :** quand Buntu est ouvert sur la TV, la TV apparaît dans l'écran Appareils (« Salon TV · Disponible ») et dans le menu **« Lire sur un autre appareil »** (films, épisodes, chaînes), comme les autres appareils.
- **Sur la TV :** la lecture en cours s'arrête et le contenu reçu s'ouvre en plein écran. Si la TV ne peut pas le lire, l'appareil d'origine affiche la raison : contenu introuvable, compte absent, profil Enfants, app en démarrage.
- **Buntu fermé sur la TV :** la TV passe « Hors ligne · vu il y a … » ; le menu ne la propose pas.

---

## 3. Spécifications

### 3.1. Le canal Samsung, une seule fois vérifié

1. **Mesurer d'abord** sur la TV de référence ce que le relais transmet : format `ms.channel.emit` (`event`, `to`, `data`), taille maximale (60 Ko vérifiés au `PRD-41`), `ms.channel.clientConnect` / `clientDisconnect`, port 8001 ou 8002 sécurisé.
2. Corriger `LocalSyncService.ts` si le format d'envoi de la TV n'est pas relayé (§ 1.3).
3. **Un seul format** d'enveloppe dans les deux transports : le JSON de l'enveloppe (`household_id`, `sender_device_id`, `sequence`, `nonce_hex`, `ciphertext_hex`) est le `data` d'un `ms.channel.emit` sur le canal Samsung et le contenu préfixé de sa longueur sur TCP.

### 3.2. Apple (puis Android) : un deuxième transport pour la TV

- Chercher la TV par `_samsungmsf._tcp` (à ajouter dans `NSBonjourServices` de chaque `Info-*.plist`, et dans le manifeste Android).
- Se connecter comme client à `ws://<tv>:8001/api/v2/channels/buntu.sync.<identifiant du foyer>` quand le foyer est rejoint ; reconnexion automatique ; connexion seulement pendant que l'app est au premier plan sur iOS.
- Ce transport alimente **la même liste d'appareils** et **la même table appareil → route** que Bonjour : `sendToPeer` envoie à la TV par le canal Samsung, `activePeers` contient la TV. Le coordinateur de lecture (`RemotePlaybackCoordinator.swift`) et le menu (`PlayOnAnotherDeviceMenu.swift`) **ne changent pas**.
- **Messages adressés seulement** : le relais diffuse à tous les clients du canal ; chaque message porte déjà `target_device_id`, et l'enveloppe chiffrée empêche un appareil hors foyer de le lire. Ne jamais envoyer sur le canal un message destiné à un appareil Bonjour.
- Supprimer la phrase « La TV Samsung n'apparaît pas encore ici… » de l'écran Appareils quand c'est fait.

### 3.3. TV : présence et réception

- **Présence** : présentation à l'ouverture du canal, **réponse** à toute présentation reçue d'un appareil qu'elle ne connaît pas encore sur cette connexion, puis **toutes les 30 s** (les autres affichent « Hors ligne » après 120 s sans nouvelles). Champ `can_play: true`, `device_type: 'tv'`.
- **Remplacement sans confirmation** : une demande reçue pendant une lecture **est acceptée** (`play_ready`), puis à `play_go` la TV arrête son flux (`AVPlay` stop) et lit le nouveau. Plus de refus `busy` pour une lecture en cours ; `busy` reste seulement pour **une autre demande déjà en attente** (réservation de 10 s).
- **Règle Rust :** la décision est écrite dans `cnd-domain::remote` (lot partagé avec `PRD-44`, lot 44.1) ; `RemotePlayback.ts` la suit et `remote/vectors.json` la vérifie. Aujourd'hui Swift et TypeScript répètent la règle (contraire à `AGENTS.md § 3.1`) : si l'export WebAssembly de la machine d'états est fait dans ce PRD, la copie TypeScript disparaît.
- **Vidéo AVPlay** : la lecture reçue passe par le chemin normal de l'app (`onPlayItem` → lecteur plein écran) ; zone vidéo transparente (`AGENTS.md § 4`).
- **Pas d'envoi** depuis la TV (décision § 1.1) : aucun menu d'envoi, la TV n'émet jamais `play_request`.

### 3.4. Un seul flux par compte

La TV envoie `release_stream { source_key }` à **tous** les appareils (canal Samsung **et**, par les appareils Apple/Android qui le relaient, Bonjour) avant d'ouvrir son flux. **À décider au lot 45.2 :** un appareil Apple connecté aux deux transports retransmet-il le `release_stream` de la TV vers ses pairs Bonjour, ou chaque appareil se connecte-t-il au canal de la TV ? Le second est plus simple ; il est retenu par défaut.

---

## 4. Lots

| Lot | Contenu | Vérification |
| :--- | :--- | :--- |
| **45.1** | Mesures sur la TV : format relayé, taille, port, comportement à la fermeture de l'app. Correction du format d'envoi Tizen si besoin. | Message envoyé par la TV reçu sur le Mac (client de test du canal) ; rapport de mesure dans ce PRD. |
| **45.2** | Apple : découverte `_samsungmsf._tcp`, client du canal `buntu.sync.<foyer>`, TV dans la liste et dans le menu. | TV « Disponible » sur le Mac et l'iPhone ; `swift test`, 4 schémas Xcode. |
| **45.3** | TV : présence (réponse + 30 s) et remplacement sans confirmation (avec la règle Rust du lot 44.1, `./scripts/build-tizen.sh` si le `.wasm` change). | `cd tizen && npx tsc --noEmit && npm test` ; Mac → TV pendant qu'une chaîne joue : la chaîne s'arrête, le film démarre. |
| **45.4** | Android : même client du canal (après `PRD-44`, lot 44.2). | Android → TV. |

---

## 5. Fichiers à créer / modifier

- `apple/Sources/CndIptvKit/Sync/SamsungChannelTransport.swift` *(nouveau)*, `apple/Sources/CndIptvKit/Sync/LocalSyncService.swift` *(deuxième route vers un appareil)*, `apple/Sources/CndIptvKit/Features/Household/HouseholdView.swift` *(phrase retirée)*, `apple/Resources/Info-*.plist` *(`_samsungmsf._tcp`)* ; `xcodegen generate` après l'ajout du fichier ;
- `tizen/src/core/sync/LocalSyncService.ts` *(format du canal, présence)*, `tizen/src/core/remote/RemotePlayback.ts` *(remplacement sans confirmation)* et leurs tests ;
- `crates/cnd-domain/src/remote/` *(règle partagée, lot 44.1)* ;
- `android/core/platform/.../sync/` *(lot 45.4)*.

---

## 6. Contraintes non négociables

- **Aucune URL de flux, aucun mot de passe, aucune clé** en clair sur le canal, dans les journaux ou les rapports ; tout passe dans l'enveloppe chiffrée.
- **Un seul flux par compte** (`AGENTS.md § 3.5`).
- **TypeScript compatible Chromium 56 à 76** (pas de `?.` ni `??` dans le code évalué à distance, `AbortController` absent avant Chromium 66) ; **WebAssembly 1.0 MVP strict**.
- **Pas d'installation sur une adresse de TV non confirmée** par l'utilisateur (`CLAUDE.md`, `AGENTS.md § 2`).
- L'image vidéo n'est pas visible à distance : **la faire confirmer par l'utilisateur**.
- Le lecteur Apple n'est pas modifié ; le lecteur de la TV seulement par son chemin normal.

---

## 7. Critères d'acceptation & commandes de validation

- `cargo test -p cnd-domain` ; `cd apple && swift test` + schémas `CndIPTV-iOS`, `CndIPTV-macOS`, `CndIPTV-tvOS`, `CndIPTV-visionOS` ; `cd tizen && npx tsc --noEmit && npm test` ; `./scripts/build-tizen.sh` si `cnd-domain` change.
- Sur la TV de référence, même Wi-Fi, Buntu ouvert sur la TV :
  1. la TV apparaît « Disponible » sur le Mac et l'iPhone en < 10 s, et le reste 30 minutes ;
  2. Mac → TV et iPhone → TV : image sur la TV (confirmée par l'utilisateur), flux de l'origine arrêté ;
  3. la TV joue une chaîne, l'iPhone lui envoie un film : la chaîne s'arrête, le film démarre, **aucune question à l'écran** ;
  4. Buntu fermé sur la TV : la TV passe « Hors ligne » et n'est plus proposée ;
  5. aucune URL de flux ni mot de passe dans le journal ou la capture réseau.

---

## 8. Questions ouvertes

1. **Port 8001 ou 8002 sécurisé** sur la TV de référence pour un client qui n'est pas l'app de la TV ? La TV demande-t-elle une autorisation à l'écran au premier client (`TokenAuthSupport: true`) ?
2. **Relais `release_stream`** (§ 3.4) : chaque appareil se connecte au canal de la TV (retenu par défaut) ou un appareil sert de pont ?
3. **Plusieurs TV Samsung** dans le foyer : un canal par TV, donc un client par TV sur chaque appareil : acceptable ?
4. **iPhone en arrière-plan** : la connexion au canal se ferme ; la TV le voit « Hors ligne » : conforme au comportement Bonjour actuel ?

---

## 9. Statut d'implémentation & validation

**Statut : `[~]` partiel** : codé et testé par tests unitaires, **rien essayé avec la TV** (revue du 10 novembre 2026).

| Lot | État | Détail |
| :--- | :--- | :--- |
| **45.1** | **Non fait** | Aucune mesure sur la TV. `LocalSyncService.ts` envoie désormais `ms.channel.emit` (`to: broadcast`) comme le canal d'appairage, mais le relais, la taille maximale, le port et l'autorisation à l'écran (`TokenAuthSupport`) restent à mesurer. |
| **45.2** | Codé | Apple : `_samsungmsf._tcp` dans les 4 `Info-*.plist` ; `Sync/SamsungChannelTransport.swift` (résolution IPv4, client du canal `buntu.sync.<foyer>`, reconnexion, nouvelle recherche si la TV change d'adresse) ; la TV est reconnue **après déchiffrement** de sa présentation (`device_type: tv`), et non d'après l'expéditeur en clair ; une seule réponse de présentation par appareil et par connexion (sinon deux téléphones se répondaient sans fin par le relais) ; pas d'envoi des données du foyer à la TV (format non lu, § 1.4). Phrase « La TV Samsung n'apparaît pas encore ici » retirée. |
| **45.3** | Codé | TV : présentation à l'ouverture, réponse une fois par appareil, présence toutes les 30 s (`can_play`, `device_type: 'tv'`) ; une demande reçue pendant une lecture est acceptée, la TV arrête son flux à `play_go` (`stopHere`) puis lit le nouveau ; `busy` seulement pour une autre demande réservée. La règle reste recopiée en TypeScript (pas d'export WebAssembly). |
| **45.4** | Codé | Android : `core/platform/.../sync/SamsungChannelTransport.kt` (le fichier livré n'était appelé nulle part) branché dans `LocalSyncService.kt` : découverte NSD `_samsungmsf._tcp`, même règles qu'Apple ; corrigés : base64 compatible Android 7 (`java.util.Base64` exige l'API 26), `sequence` envoyée en nombre (elle partait en texte, refusée par Apple), messages fragmentés. |

- **Vérifié :** `cargo test -p cnd-domain` ; `cd tizen && npx tsc --noEmit && npm test` (147/147) ; `cd apple && swift test` (dont `SamsungChannelTransportTests`) ; tests Android de `core:platform` (dont `SamsungChannelTransportTest`).
- **Non vérifié :** schémas Xcode des 4 plateformes après la revue ; aucun essai avec la TV (Mac → TV, iPhone → TV, Android → TV), image non confirmée ; question ouverte n° 1 (port, autorisation) sans réponse.
