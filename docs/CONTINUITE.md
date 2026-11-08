# Continuité Multi-Appareils & Synchronisation du Foyer (PRD 41)

Buntu permet de synchroniser ses favoris, ses reprises de lecture et son historique entre tous les appareils du foyer (iPhone, Mac, Android, TV Samsung), **sans aucun serveur distant ni compte en ligne**, directement sur le Wi-Fi de la maison.

---

## 1. Comment ça marche

1. **Un foyer, une clé chiffrée** :
   - À la création du foyer sur un premier appareil (TV ou téléphone), une clé de 256 bits (`HouseholdKey`) est générée localement à partir d'entropie cryptographique.
   - Un identifiant déterministe est calculé : `buntu_hh_<blake3(key)[..16]>`.
   - La clé ne transite **jamais en clair** et est stockée dans le coffre sécurisé de l'appareil (Trousseau sous Apple, Keystore sous Android, IndexedDB chiffrée avec WebCrypto AES-GCM sous Tizen).

2. **Rejoindre le foyer (QR Code)** :
   - Pour ajouter un appareil, l'un des membres affiche un QR Code dans *Réglages > Continuité*.
   - Le nouvel appareil scanne le code et échange la clé de manière chiffrée de bout en bout (extension du protocole d'appairage sécurisé `PRD-39`).

3. **Échanges locaux scellés** :
   - Tout message échangé (delta de synchronisation, commande de reprise, navigation) est scellé dans une enveloppe chiffrée en **AES-256-GCM** avec un identifiant d'émetteur, un nonce aléatoire et un compteur de séquence strictement croissant empêchant toute attaque par rejeu.

---

## 2. Identité Déterministe Partagée

Pour garantir que deux appareils s'accordent sur le même élément sans partager d'identifiants internes :
- **Clé de source (`source_key`)** :
  - Xtream Codes : `blake3("xtream:<norm_server>:<norm_user>")`
  - M3U : `blake3("m3u:<norm_endpoint_url>")` (sans les paramètres de mot de passe)
- **Clé de contenu (`content_key`)** :
  - `blake3("<source_key>:<kind>:<provider_id>")` (par ex. `live:1001` ou `movie:5002`)

Cette règle est codée **une seule fois en Rust** dans `crates/cnd-domain/src/identity.rs`, et vérifiée par des vecteurs de test canoniques (`sync/vectors.json`).

---

## 3. Transports Selon les Appareils

| Appareil | Découverte | Transport |
| :--- | :--- | :--- |
| **Mac, iPhone, iPad** | Bonjour `_buntu-sync._tcp` | Serveur WebSocket local (port dynamique) |
| **Android (Phone & TV)** | `NsdManager` (`_buntu-sync._tcp`) | Client et serveur WebSocket local |
| **TV Samsung (Tizen)** | Bonjour `_samsungmsf._tcp` (annoncé par la TV) | Client du canal interne de la TV : `ws://<tv>:8001/api/v2/channels/buntu.sync.<household_id>` |

La TV Samsung ne pouvant pas ouvrir de socket d'écoute en tant qu'application web, tous les appareils de la maison et l'application Tizen elle-même se connectent comme **clients** au canal local hébergé par le système Tizen sur le port 8001.

---

## 4. Horloge Logique Hybride (HLC) et Conflits

- Pour ordonner les modifications sans dépendre d'une synchronisation d'horloge parfaite (NTP), Buntu utilise une **Horloge Logique Hybride (HLC)** combinant temps physique en millisecondes, compteur logique et identifiant de nœud.
- Format compact : `<physical_ms>.<counter>.<node_id>`.
- Les conflits sont résolus de manière déterministe par la règle du dernier écrivain (**Last-Write-Wins - LWW**).
- Les suppressions (favoris, historique) sont propagées sous forme de *tombstones* horodatés pour éviter qu'un appareil temporairement éteint ne réinjecte un élément supprimé.

---

## 5. Règle Stricte « 1 Seule Connexion Fournisseur »

Lorsqu'un utilisateur sélectionne **« Regarder sur la TV »** depuis son téléphone :
1. Le téléphone coupe immédiatement sa propre lecture vidéo AVANT d'envoyer l'ordre à la TV.
2. Le message chiffré `play_remote` (`content_key`, `position_ms`) est envoyé à la TV.
3. La TV retrouve le contenu via sa base locale et lance la lecture à la seconde exacte.
4. Aucun risque d'erreur 429 ou de bannissement pour connexion simultanée chez le fournisseur IPTV.

---

## 6. Dépannage Réseau

- **« La TV n'apparaît pas ou reste en attente de connexion »** :
  - Vérifiez que tous les appareils sont connectés sur le **même réseau Wi-Fi**.
  - Si votre box ou routeur active « l'isolation des clients » (AP Isolation ou réseau invité), les appareils ne peuvent pas communiquer entre eux : désactivez cette option dans l'interface de votre box.
- **« L'adresse IP de la TV a changé »** :
  - Les appareils Apple et Android découvrent la TV via le service Bonjour `_samsungmsf._tcp` sans dépendre d'une adresse IP fixe.
- **« Retirer un appareil ou renouveler la clé »** :
  - Dans *Paramètres > Appareils de la maison*, choisissez « Quitter le foyer ». La clé locale et les appareils enregistrés sont effacés de la mémoire sécurisée.

