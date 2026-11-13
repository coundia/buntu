# Ajouter ses comptes sur la TV en scannant un QR code (PRD 39)

La TV affiche un QR code. Le téléphone (iPhone ou Android) le scanne, envoie les comptes **chiffrés de bout en bout**, et l'utilisateur confirme **à la télécommande**.

## Comment ça marche

À **l’accueil Samsung Tizen sans compte**, ainsi que dans **Sources** pour une TV sans foyer, l’application affiche directement un QR
**Ajouter cette TV à votre foyer**. La TV ne crée plus de foyer et ne demande plus de lien à saisir.
Depuis **Android**, ouvrir **Buntu → Appareils → Scanner un QR et envoyer mes données**.
Depuis un **iPhone déjà membre du foyer**, ouvrir **Buntu → Appareils → Ajouter une TV Samsung**.
Scanner le QR puis confirmer sur la TV. Android transmet ensuite les comptes, favoris et reprises
après avoir reçu la présence chiffrée de la TV sur le canal du foyer. La clé du foyer est transmise dans la session chiffrée
et n’est pas incluse dans le QR. Le QR expire après cinq minutes et se renouvelle.

Pour transférer uniquement des comptes, utiliser **Importer des comptes (QR)** : ce bouton
conserve le parcours d’appairage décrit ci-dessous. La saisie manuelle d’une source reste disponible.

1. La TV crée une **session** de 5 minutes : une clé X25519 jetable, dont seule la partie publique va dans le QR code (`buntu://pair?v=1&s=…&t=msf&h=<ip>&p=8001&k=<clé>&e=<expiration>`).
2. Le téléphone scanne, crée sa propre clé jetable, en déduit une clé de chiffrement (HKDF-SHA256) et chiffre le document de partage en AES-256-GCM.
3. Il l'envoie à la TV. Un appareil qui écoute le réseau ne peut ni lire le contenu, ni se faire passer pour la TV : la clé de la TV ne voyage que par l'écran.
4. La TV déchiffre, **affiche ce qu'elle a reçu** (nom, type, hôte du serveur, « avec mot de passe »), et n'ajoute rien avant « Ajouter ».
5. Elle répond au téléphone (`added`, `refused`, `error`), chiffré aussi.

Une session sert **un seul message**, se ferme après **3 messages invalides** ou à l'expiration, et la clé privée de la TV est effacée après usage.

## Un seul protocole

Il est écrit **une fois**, en Rust : `crates/cnd-domain/src/pairing.rs`. Swift et Kotlin l'appellent par UniFFI, la TV Samsung par WebAssembly (`wasm_pairing_*`). Les mêmes entrées doivent donner les mêmes octets : `crates/cnd-domain/src/pairing/vectors.json`, vérifié en Rust, en TypeScript (`cd tizen && npm test`), en Kotlin (`RustPairingRepositoryTest`) et, par l'aller-retour des tests, en Swift.

Pour régénérer les vecteurs (après un changement volontaire du protocole, qui casse la compatibilité) :

```bash
WRITE_PAIRING_VECTORS=1 cargo test -p cnd-domain --release pairing
```

## Selon la TV

| TV | Transport | Comment la TV reçoit |
| :--- | :--- | :--- |
| Samsung (Tizen) | `msf` | Le canal de la TV : `ws://<tv>:8001/api/v2/channels/buntu.pair.<session>`. L'app web y est cliente, le téléphone aussi, la TV relaie les messages. Une app Tizen ne peut pas ouvrir de port. |
| Android TV | `http` | Un petit serveur local, `POST /pair`, qui n'accepte que des messages scellés. Un navigateur qui ouvre l'adresse reçoit une page qui renvoie vers l'app (jamais un formulaire). |
| Apple TV | `tls` | Pas encore réalisé : l'Apple TV n'a pas d'écran « Recevoir ». |

## Dépannage

- **« Votre téléphone ne voit pas la TV »** : même Wi-Fi requis ; un réseau « invité » qui isole les appareils empêche la connexion.
- **« La TV n'écoute plus »** : l'écran « Ajouter depuis le téléphone » de la TV n'est plus ouvert (ou la session a expiré). Rouvrez-le et scannez le nouveau code.
- **Samsung** : le mode développeur n'est pas nécessaire pour recevoir, mais l'app doit être au premier plan sur l'écran d'ajout.

## Modifier une source sur la TV uniquement

Dans **Sources → Modifier**, les coordonnées HOST, utilisateur et mot de passe d’un compte Xtream
peuvent être corrigées, même pour un compte reçu du foyer. Ces corrections sont chiffrées dans
un coffre propre à la TV. Les lectures et les séries utilisent les nouvelles coordonnées, sans
modifier l’identité du compte dans le foyer. Un flux déjà ouvert sur ce compte est arrêté à l’enregistrement.

**Envoyer mes données** transmet les coordonnées d’origine du compte ; **Recevoir les données**
ne remplace pas les corrections locales. Pour une playlist M3U, modifier son adresse recharge
la playlist sur cette TV. Aucun de ces changements n’est envoyé aux autres appareils.
