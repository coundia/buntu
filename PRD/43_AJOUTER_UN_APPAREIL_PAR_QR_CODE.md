# PRD 43 — Ajouter un appareil au foyer : QR code et découverte automatique à proximité (Bonjour / réseau local)

- **ID :** `PRD-43`
- **Prérequis :**
  - `PRD-39` (appairage par QR code : X25519, HKDF, AES-256-GCM, session à usage unique, confirmation) ;
  - `PRD-41` (foyer : clé de foyer, messages chiffrés, § 5 « Le foyer : confiance et clés ») ;
  - `PRD-20` (profils, mode Enfants).
- **Couches impactées :**
  - `Rust` : module `pairing` de `cnd-domain` (demande d'adhésion, réponse qui porte la clé, calcul de code SAS à 6 chiffres), exposé par UniFFI et WebAssembly ;
  - `apple/` : écran Appareils (QR à afficher/scanner, découverte Bonjour `_buntu-pair._tcp` sans caméra, fiches d'invitation/adhésion), transport local ;
  - `android/` : écran Appareils (inexistant aujourd'hui), scanner, QR, découverte NSD `_buntu-pair._tcp` ;
  - `tizen/` : QR d'invitation, réception avec confirmation à la télécommande.
- **Objectifs mesurables :**
  - **< 20 s** entre « Ajouter un appareil » et le nouvel appareil visible dans la liste, sur le même Wi-Fi ;
  - **0 clé de foyer saisie manuellement** (remplacement de la saisie des 64 caractères hexadécimaux par QR code ou découverte Bonjour avec code court SAS) ;
  - **0 clé de foyer lisible** dans un QR code, dans une capture d'écran, sur le réseau ou dans les journaux ;
  - **0 appareil ajouté sans confirmation** sur un appareil qui est déjà dans le foyer ou sur le nouvel appareil (§ 4.3) ;
  - un QR code photographié puis scanné plus tard, ou une deuxième fois, est **refusé**.

---

## 1. Contexte & Objectif

**La question de départ :** comment ajouter un appareil au foyer facilement et en toute sécurité, particulièrement sur les appareils dépourvus de caméra (Mac, Apple TV, box) et sans forcer l'utilisateur à recopier une clé de 64 caractères hexadécimaux ?

**Trois modes sont supportés, tous protégés par chiffrement de bout en bout et confirmation humaine :**

| Sens | Mode | Qui initie | Qui confirme | Idéal pour |
| :--- | :--- | :--- | :--- | :--- |
| **A. « Inviter par QR »** | QR code | un appareil **déjà dans le foyer** affiche le QR | le **nouvel** appareil scanne avec sa caméra | iPhone invitant un autre téléphone ou tablette. |
| **B. « Rejoindre par QR »** | QR code | le **nouvel** appareil affiche le QR | un appareil **déjà dans le foyer** scanne le QR | TV Samsung ou Apple TV rejoignant le foyer via un iPhone. |
| **C. « Découverte locale »** | Bonjour / Wi-Fi local | l'appareil invitant **ou** le nouvel appareil | **Validation mutuelle** (code court à 6 chiffres SAS + bouton « Autoriser ») | **Mac, ordinateurs, Apple TV**, ou tout utilisateur refusant de scanner un QR ou de saisir une clé. |

Le sens B est l'adaptation du `PRD-39` (le téléphone scanne la TV). Le sens A est naturel entre téléphones. Le mode C (style AirDrop / Apple TV) élimine complètement la nécessité d'une caméra et toute saisie manuelle de clé.

**Objectif :** un seul protocole sûr, multi-modes, sur toutes les plateformes, qui remplace les essais actuels (§ 1.2).

### 1.1. Pourquoi ne pas mettre la clé dans le QR

La clé du foyer donne accès aux favoris, aux profils et **aux comptes IPTV avec leurs mots de passe** (`PRD-41` § 4). Si elle est écrite dans le QR :
- une **photo ou une capture d'écran** du QR suffit à entrer dans le foyer, pour toujours ;
- le QR affiché sur une TV de salon est lisible par toute personne dans la pièce ;
- il n'y a **aucune expiration, aucun usage unique, aucune confirmation**.

Le `PRD-41` (§ 5) demande le contraire : la clé n'est « jamais affichée », et l'ajout d'un appareil passe par le QR chiffré du `PRD-39` avec confirmation. Ce PRD applique cette règle aux deux sens.

### 1.2. Ce qui existe déjà (constaté dans le code, 8 novembre 2026)

| Brique | Où | État et écart |
| :--- | :--- | :--- |
| Message scellé **`HouseholdJoin`** (id, clé, nom du foyer, nom et id de l'appareil expéditeur) | `crates/cnd-domain/src/pairing.rs` | Existe, testé en Rust (`pairing/tests.rs`). C'est le sens B. Pas de message de **demande** (sens A). |
| **Réception** du message par la TV | `tizen/src/core/pairing/PairingService.ts`, `SettingsView.tsx` (`onHouseholdJoinRequest`) | **Défaut :** la TV appelle `req.accept()` tout de suite, **sans confirmation à la télécommande**. Contraire aux `PRD-39` et `PRD-41`. |
| **Envoi** de `HouseholdJoin` par un téléphone | Apple, Android | **N'existe pas.** `PairToTV.swift` et `PairingSender.kt` n'envoient que des comptes. Le sens B ne marche donc de bout en bout nulle part. |
| QR « inviter un appareil » sur la TV | `SettingsView.tsx` (`showInviteDeviceQr`) | Lien `buntu://household-join?id=…&key=<clé en clair>&name=…&from=…`. **Clé lisible dans le QR** (§ 1.1). |
| QR « Afficher le QR code » et scanner sur Apple | `Features/Household/HouseholdInvite.swift`, `HouseholdQRSheets.swift` (**prototype, non commité**) | Lien `buntu://household?key=<clé en clair>`. Même défaut, et **format différent de celui de la TV** : l'iPhone ne sait pas lire le QR de la TV. |
| Écran « Appareils » (liste, QR, scanner) | Apple (sidebar Appareils) ; Tizen (Réglages) | Android : **aucun écran** ; seules les couches `HouseholdStore` et `LocalSyncService` existent. |
| `joinHousehold(keyHex:)` | `HouseholdStore.swift` | Vérifie seulement la longueur (64), pas que ce soit de l'hexadécimal. |

**Conclusion :** le sens A et le sens B existent à moitié, de deux façons incompatibles, et le QR contient la clé. Ce PRD les remplace par un protocole unique.

### 1.3. Hors périmètre

- **Retirer un appareil** avec changement de clé (`PRD-41`, lot 41.3) : traité là-bas. Le présent protocole le rend plus facile à vivre : un QR ancien ne donne plus rien.
- **Relais Internet** : réseau local seulement (choix du `PRD-41`).
- **Client du canal Samsung sur Apple et Android** (pour que la TV apparaisse dans la liste) : `PRD-41`, lot 41.4. Ici, la TV n'est jointe que pendant l'ajout, par le canal d'appairage de la TV (`PRD-39` § 3).

---

## 2. Parcours

### 2.1. Sens A — « Inviter » (le nouvel appareil scanne)

**Sur l'appareil du foyer** (Appareils > « Ajouter un appareil ») :
1. Un QR code, un compte à rebours de **2 minutes**, le nom de l'appareil et, en secours, un **code à 6 chiffres** (§ 6).
2. Quand le nouvel appareil scanne, une fenêtre s'ouvre : « **Téléphone de Léa** (Android) veut rejoindre le foyer. Autoriser ? ». Boutons **Autoriser** et **Refuser**, focus sur **Refuser**.
3. Après « Autoriser » : « Téléphone de Léa a rejoint le foyer », et il apparaît dans la liste.

**Sur le nouvel appareil** (Appareils > « Scanner un QR code », ou l'écran d'accueil au premier lancement) :
1. Il scanne le QR (ou ouvre le lien avec l'appareil photo du système).
2. « En attente d'autorisation sur *iPhone de Papa*… ».
3. « Foyer rejoint. » ou « Refusé ».

### 2.2. Sens B — « Rejoindre » (l'appareil du foyer scanne)

**Sur le nouvel appareil** (TV Samsung, Apple TV, Android TV, ou tout appareil sans caméra) : Appareils > « Rejoindre un foyer » affiche le QR du `PRD-39` (session de 5 minutes, clé publique éphémère).

**Sur l'appareil du foyer** : Appareils > « Scanner un QR code ». L'écran montre : « Ajouter **Salon TV** au foyer ? » avec **Ajouter** et **Annuler**. Après « Ajouter », la clé part scellée.

**Sur le nouvel appareil**, **confirmation obligatoire** : « **iPhone de Papa** vous invite dans le foyer *Maison*. Rejoindre ? » (à la télécommande sur une TV). Aucune clé n'est enregistrée avant « Rejoindre ».

### 2.3. Mode C — « Découverte locale » (sans scan, sans saisie de clé)

Ce mode résout le cas des **Mac, PC ou Apple TV** (sans caméra dorsale) ou des utilisateurs trouvant la saisie de clé pénible.

**Sur l'appareil invitant (ex. Mac du foyer)** : Appareils > « Ajouter un appareil à proximité ».
1. Il active une écoute locale temporaire Bonjour (`_buntu-pair._tcp`) pendant 2 minutes.
2. Il affiche : « En attente d'appareils à proximité sur ce Wi-Fi… ».
3. Dès qu'un nouvel appareil demande à se connecter :
   - Un accord de clé éphémère X25519 calcule un **code court de confirmation à 6 chiffres (SAS)**.
   - Une fenêtre s'affiche : « **iPhone de Léa** veut rejoindre le foyer. Vérifiez le code : **482 193** ».
   - Boutons **[Refuser]** (focus par défaut) et **[Autoriser]**.
4. Clic sur **Autoriser** : la clé du foyer est chiffrée avec la clé de session et envoyée. L'écoute se ferme aussitôt.

**Sur le nouvel appareil (ex. iPhone, autre Mac, Apple TV)** : Appareils > « Rejoindre un foyer à proximité ».
1. Il parcourt le réseau local via Bonjour (`_buntu-pair._tcp`).
2. Il voit apparaître la liste des foyers proposant une adhésion : « *Foyer Maison (MacBook Pro de Papa)* ».
3. Il clique dessus : « En attente d'autorisation sur *MacBook Pro de Papa*… Code : **482 193** ».
4. Dès l'autorisation accordée, la clé est enregistrée dans le Keychain/Keystore et la synchronisation démarre.
5. **Résultat : Zéro caméra, zéro saisie de clé de 64 caractères, 100 % sécurisé par confirmation humaine et SAS.**

### 2.4. Règles communes

- **Profil Enfants :** l'écran Appareils est caché (déjà fait sur Apple) ; aucune demande d'adhésion n'est acceptée tant qu'un profil Enfants est actif sur l'appareil qui autorise.
- **Un seul foyer par appareil :** un appareil déjà dans un autre foyer demande « Quitter *Maison* et rejoindre *Chez Léa* ? » avant d'accepter.
- **Messages d'erreur clairs :** réseau « invité », QR expiré (« Demandez-en un nouveau »), QR déjà utilisé, mauvaise version.

---

## 3. Le QR code ne contient aucun secret

Lien court, même famille que le `PRD-39` :

```
buntu://household-invite?v=1&s=<session>&n=<nom de l'appareil>&r=<invite|join>&t=<tcp|msf>&h=<ip>&p=<port>&k=<clé publique éphémère>&e=<expiration>
```

- `r` : `invite` (sens A, le QR vient d'un membre) ou `join` (sens B, le QR vient du nouvel appareil) ;
- `k` : clé publique X25519 **éphémère**, créée pour cette session seulement ;
- `t`, `h`, `p` : comment joindre l'afficheur (`tcp` = petite écoute locale temporaire sur Apple, Android, Android TV ; `msf` = canal Samsung pour la TV) ;
- `e` : expiration (2 minutes en sens A, 5 minutes en sens B).

Le `PRD-39` garde son lien `buntu://pair` pour les comptes ; `household-invite` est un autre type de session, pour qu'un QR de comptes ne puisse pas servir à entrer dans le foyer, et l'inverse.

**Formats historiques :** `buntu://household-join?…&key=…` (TV) et `buntu://household?key=…` (prototype Apple) ne sont **plus produits**. Un appareil qui en scanne un affiche : « Ce code est ancien et peu sûr : mettez à jour Buntu sur l'autre appareil. » Il ne lit pas la clé.

---

## 4. Protocole (dans `cnd-domain::pairing`, un seul code pour toutes les plateformes)

### 4.1. Sens B (déjà prévu : à compléter)

1. Le nouvel appareil affiche l'offre (`create_offer`, `r=join`).
2. L'appareil du foyer scanne, appelle `seal` avec `HouseholdJoin { household_id, household_key, … }` et l'envoie.
3. Le nouvel appareil appelle `open`, **affiche la confirmation** (§ 2.2), puis seulement alors enregistre la clé dans son coffre, et répond `added` ou `refused` avec `seal_reply`.
4. La session est à usage unique ; trois messages invalides la ferment.

### 4.2. Sens A (nouveau) : la réponse porte la clé

Le sens A est le sens B à l'envers : celui qui affiche le QR est celui qui **détient** la clé.

1. L'appareil du foyer crée l'offre (`r=invite`) et garde la clé privée éphémère.
2. Le nouvel appareil scanne et envoie, scellé (`seal`), un message **`HouseholdJoinRequest { device_name, device_id, device_type }`**. Il ne contient aucun secret.
3. L'appareil du foyer ouvre le message et **affiche la demande** (§ 2.1). Rien ne part avant « Autoriser ».
4. Après « Autoriser », il répond avec `seal_reply`, dont le corps est **étendu** : `ReplyBody` porte aujourd'hui seulement `result` et `count` ; il gagne un champ facultatif `payload` (le `HouseholdJoin` avec la clé), chiffré avec la **même clé de session**.
5. Le nouvel appareil ouvre la réponse (`open_reply`), enregistre la clé et prévient : « Foyer rejoint ».

La clé du foyer ne circule donc jamais en clair, et ne passe jamais par un QR : elle est chiffrée avec un secret que seuls les deux appareils (celui qui a scanné et celui qui a affiché) ont calculé.

### 4.3. Garde-fous

- **Session** : usage unique ; la clé privée éphémère est effacée après un succès, un refus ou l'expiration.
- **Échecs** : au-delà de **3 messages invalides**, la session est fermée et un nouveau QR est demandé.
- **Confirmation** : toujours sur un appareil **humain** (clic ou télécommande), jamais automatique. Le focus est sur « Refuser » en sens A. *(C'est le défaut constaté sur la TV : § 1.2.)*
- **Écoute** : la petite écoute locale n'existe que pendant que l'écran est ouvert ; fermée à la sortie.
- **Rate limit** : une seule demande en attente à la fois ; une deuxième est refusée avec « Une demande est déjà en cours ».
- **Journaux** : jamais la clé, jamais le lien du QR complet, jamais une adresse de serveur IPTV.
- **Nom d'appareil affiché** : texte seul, limité à 40 caractères, sans balisage. Il vient du nouvel appareil et n'est pas vérifié : la fenêtre le dit (« Nom donné par l'appareil »).

### 4.4. Mise en commun du code

`cnd-domain::pairing` expose en plus : `HouseholdJoinRequest` dans `SealedPayload`, `seal_reply_with_payload` et `open_reply` étendu. Exports UniFFI (Swift, Kotlin) et WebAssembly (Tizen). Mêmes vecteurs de test (`pairing/vectors.json`) vérifiés sur chaque plateforme. **Aucune règle réécrite en Swift, Kotlin ou TypeScript** (`AGENTS.md` § 3).

---

## 5. Par plateforme

| Plateforme | Afficher un QR (sens A et B) | Scanner (sens A et B) | Mode C (Découverte Bonjour) | Écoute locale |
| :--- | :--- | :--- | :--- | :--- |
| **iPhone / iPad** | Core Image (`CIQRCodeGenerator`) | VisionKit `DataScannerViewController` | **Oui** (Inviter et Rejoindre) | `NWListener` temporaire |
| **Mac** | oui | **pas de caméra** : remplacé par le Mode C | **Oui** (Inviter et Rejoindre, 100 % sans scan) | `NWListener` temporaire |
| **Apple TV** | **sens B seulement** (nouvel appareil) | non | **Oui** (Rejoindre le foyer facilement) | `NWListener` temporaire |
| **Android** | ZXing, déjà présent | Google code scanner / CameraX | **Oui** (NSD `_buntu-pair._tcp`) | `ServerSocket` temporaire |
| **Android TV** | sens B ; sens A possible | non | **Oui** (NSD `_buntu-pair._tcp`) | `ServerSocket` temporaire |
| **Samsung (Tizen)** | sens B ; sens A retiré (§ 6) | non | non (canal MSF pour l'appairage TV) | canal MSF |

- **Service Bonjour / NSD :** `_buntu-pair._tcp` actif uniquement pendant l'affichage des fiches d'appairage. Déclaré dans `NSBonjourServices` (`Info-*.plist`) et `AndroidManifest.xml`.
- **Lien profond :** `buntu://household-invite` déclaré dans `Info-iOS.plist` (le schéma `buntu` existe déjà) et dans `AndroidManifest.xml`.
- **Transport `tcp` :** un petit protocole de longueur préfixée, comme dans `LocalSyncService`, mais **sans** la clé du foyer (le nouvel appareil ne l'a pas encore) : seuls les messages scellés de la session sont acceptés.
- **Autorisation caméra iOS :** le texte de `NSCameraUsageDescription` couvre déjà le foyer (prototype non commité).
- **Android :** l'écran Appareils est à créer (liste, ajouter, scanner, quitter) en respectant l'architecture : contrat dans `core:domain`, implémentation dans `core:data`, et aucune dépendance `feature/* → :core:engine` (`AGENTS.md` § 3).

---

## 6. Secours sans scan

- **Code à 6 chiffres** (sens A seulement) : l'appareil du foyer l'affiche avec son adresse ; le nouvel appareil les saisit. La clé de session est dérivée du code ; **un seul essai par connexion, session fermée après 3 erreurs**. Moins fort que le QR, d'où la durée courte (2 minutes) et la même confirmation.
- **Coller la clé** (existant sur Apple : « Rejoindre avec la clé… ») : **gardé comme dernier recours**, avec un avertissement (« la clé donne accès à vos comptes »). Hors QR, pas de nouveau risque : l'utilisateur la copie volontairement. Elle doit être validée comme hexadécimale de 64 caractères.
- **La TV ne montre plus la clé** en QR : le bouton « Inviter un appareil » de la TV est retiré. Pour ajouter un nouveau téléphone, on part d'un téléphone ou d'un Mac du foyer (sens A). Pour ajouter une TV, c'est la TV qui montre son QR (sens B).

---

## 7. Lots

| Lot | Contenu | Validation principale |
| :--- | :--- | :--- |
| **43.1** | **Protocole Rust** : `HouseholdJoinRequest`, réponse avec `payload`, lien `household-invite`, vecteurs, exports UniFFI et WebAssembly. | Tests Rust : aller-retour A et B, mauvaise clé, rejeu, expiration, 3 échecs, QR utilisé deux fois, nom trop long ; vecteurs vérifiés en Swift, Kotlin, TypeScript. |
| **43.2** | **Corrections de sécurité de l'existant** : confirmation à la télécommande dans `onHouseholdJoinRequest` ; retrait du QR avec clé en clair sur la TV ; validation hexadécimale dans `joinHousehold` ; le prototype Apple passe au nouveau protocole. | Test : `req.accept()` n'est jamais appelé sans action de l'utilisateur ; aucun QR ne contient `key=`. |
| **43.3** | **Apple** : sens A (afficher, autoriser) et sens B (scanner, envoyer `HouseholdJoin`), écoute temporaire, écran Appareils mis à jour. | Deux appareils Apple réels : A et B, QR expiré refusé. |
| **43.4** | **Tizen** : sens B complet (QR de la TV, réception avec confirmation) ; envoi de `HouseholdJoin` par un téléphone (lot 43.3 côté Apple). | iPhone → TV réelle (AU8000) : confirmation à la télécommande, clé enregistrée, TV en synchronisation. |
| **43.5** | **Android** : écran Appareils, QR, scanner, sens A et B. | Android ↔ iPhone, Android → TV. |
| **43.6** | **Secours** : code à 6 chiffres, nettoyage des anciens formats. | Mauvais code ×3 ferme la session. |

Ordre conseillé : 43.1 → 43.2 (corrige les défauts actuels sans attendre) → 43.3 → 43.4 → 43.5 → 43.6.

---

## 8. Fichiers à Créer / Modifier

- `crates/cnd-domain/src/pairing.rs`, `pairing/tests.rs`, `pairing/vectors.json` ; `crates/cnd-core/src/lib.rs` *(exports UniFFI)* ; `crates/cnd-domain-wasm/src/lib.rs` ;
- `apple/Sources/CndIptvKit/Features/Household/` : `HouseholdInvite.swift` *(réécrit)*, `HouseholdQRSheets.swift`, `HouseholdView.swift` ; `Sync/HouseholdStore.swift` *(validation)* ; nouveau `Sync/HouseholdPairing.swift` *(écoute temporaire, session)* ; `Resources/Info-iOS.plist` ;
- `android/feature/devices/` *(nouveau)*, `core/domain`, `core/data`, `core/platform/.../sync/`, `AndroidManifest.xml` ;
- `tizen/src/core/pairing/PairingService.ts`, `tizen/src/features/settings/SettingsView.tsx` ;
- `docs/PAIRING.md` *(section « Ajouter un appareil au foyer »)*, `PRD/41_…md` *(§ 5, renvoi vers ce PRD)*, `PRD/00_INDEX_ROADMAP.md`, `AGENTS.md` *(§ 7)*.

---

## 9. Contraintes Non-Négociables (Guardrails IA)

- **La clé du foyer n'est jamais écrite dans un QR code,** ni dans un lien, ni dans une capture d'écran, ni dans les journaux.
- **Confirmation humaine** avant tout ajout, sur l'appareil qui autorise (sens A) et sur celui qui reçoit (sens B). Jamais d'`accept()` automatique.
- **Sessions à usage unique, courtes ;** écoute fermée hors de l'écran ; 3 erreurs ferment la session.
- **Un seul protocole,** en Rust (`cnd-domain::pairing`). Pas de règle réécrite par plateforme.
- **Profil Enfants** : aucune demande d'adhésion acceptée, écran caché.
- **Pas de foyer par défaut :** un appareil ne rejoint un autre foyer qu'après avoir quitté le sien (avec confirmation).
- **Les cibles existantes restent vertes :** `cargo test`, `swift test`, les 4 schémas Xcode, les tests Android et Tizen.

---

## 10. Critères d'Acceptation & Commandes de Validation

1. **Rust :** `cargo clippy --workspace --all-targets -- -D warnings` ; `cargo test --workspace --release` (cas du lot 43.1) ; `cargo build -p cnd-domain-wasm --target wasm32-unknown-unknown --release` et contrôle WebAssembly 1.0 MVP.
2. **Interopérabilité :** vecteurs communs en Swift (`swift test`), Kotlin (`./gradlew :core:data:testDebugUnitTest`), TypeScript (`cd tizen && npm test`).
3. **Essais réels (même Wi-Fi) :**
   - sens A : iPhone → iPhone, iPhone → Android ;
   - sens B : TV Samsung → iPhone du foyer ; l'iPhone scanne, la TV demande la confirmation à la télécommande ;
   - QR photographié puis scanné 3 minutes plus tard : refusé ;
   - même QR scanné deux fois : la deuxième est refusée ;
   - temps total < 20 s.
4. **Sécurité :**
   - capture réseau (`tcpdump` ou Wireshark) sans clé lisible ;
   - un QR et un lien scannés ne contiennent pas `key=` ;
   - un message rejoué par un autre appareil est refusé ;
   - un profil Enfants actif empêche d'autoriser.

---

## 11. Questions ouvertes

1. **Code PIN parental :** si un PIN est défini, faut-il le demander avant d'autoriser un nouvel appareil (il reçoit les mots de passe) ?
2. **Durée du QR :** 2 minutes en sens A et 5 minutes en sens B conviennent-elles ?
3. **Mac sans caméra :** accepter l'import d'une image (capture d'écran du QR) pour scanner ? Cela remet une photo en jeu, mais la session reste à usage unique et courte.
4. **TV qui invite :** autoriser un jour le sens A sur la TV (avec la même confirmation à la télécommande), ou le garder réservé aux téléphones ?
5. **Écoute temporaire sur iPhone :** l'autorisation « Réseau local » est-elle toujours déjà accordée à ce moment-là (elle l'est pour le foyer) ? À mesurer.

---

## 12. Statut d'Implémentation & Validation

**Non commencé : étude seulement (aucun lot réalisé).** Rédigé le 8 novembre 2026 après lecture du code.

- **Constaté dans le code** (§ 1.2) : message `HouseholdJoin` en Rust, réception sur la TV **sans confirmation**, QR d'invitation de la TV qui contient la **clé en clair**, aucun envoi de `HouseholdJoin` depuis Apple ou Android, aucun écran Appareils sur Android.
- **Prototype Apple non commité** (branche `feat/apple-household-qr`) : QR et scanner qui transportent la **clé en clair** dans un format différent de celui de la TV. À remplacer par le lot 43.3, ou à retirer avant tout commit si l'on veut éviter d'installer un mauvais usage.
- **Non mesuré :** aucune mesure de temps, aucun essai sur appareil réel.
