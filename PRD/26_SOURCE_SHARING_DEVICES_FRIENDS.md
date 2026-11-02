# PRD 26 — Partage des sources IPTV entre mes appareils et avec des proches

- **ID :** `PRD-26`
- **Prérequis :** `PRD-03` (Xtream & Trousseau), `PRD-09` (gestion des sources), `PRD-12` (synchronisation iCloud) ; `PRD-23` (projet Xcode signé) pour les lots qui ont besoin d'entitlements, d'un type de fichier ou d'un schéma d'URL
- **Couches impactées :** `Rust (crates/cnd-core/src/sharing/)`, `UniFFI`, `Swift (Features/Sharing/, Security/KeychainStore.swift, Sync/)`
- **Objectif SLA :** une source partagée est importée et prête à être synchronisée en **moins de 30 secondes** de manipulation, sans serveur tiers ; **aucun mot de passe en clair** ne quitte l'appareil hors d'une enveloppe chiffrée de bout en bout.

---

## 1. Contexte & Objectif

L'utilisateur veut retrouver ses sources IPTV sur tous ses appareils (Mac, iPhone, iPad, Apple TV) et pouvoir en donner une à un proche, sans tout ressaisir.

État actuel :
- La synchronisation iCloud (`PRD-12`, `sync_repo.rs`) transporte déjà les **définitions** des sources (nom, type, URL, serveur, utilisateur, `password_ref`, URL EPG), mais **pas les mots de passe** Xtream : ils restent dans le Trousseau local. Une source Xtream arrivée par iCloud demande donc de ressaisir le mot de passe.
- Les sources `file://` (playlists importées) ne sont pas synchronisées.
- iCloud ne fonctionne réellement qu'avec un build signé (`PRD-23`) ; sans lui, l'app reste en « Mode local uniquement ».
- Rien ne permet de partager une source avec une autre personne.

Le partage passe par **quatre lots indépendants**, du plus simple au plus avancé, validés un par un.

---

## 2. Principes communs

### 2.1. Ce qu'est une « source partagée »

Un document versionné, produit par le moteur Rust à partir de SQLite :

```json
{
  "format": "cnd-source-share",
  "version": 1,
  "created_at": 1767225600,
  "expires_at": 1767830400,
  "from": "Le Mac de Papa",
  "sources": [
    {
      "name": "Premium",
      "type": "xtream",
      "server": "http://srv.example:8080",
      "username": "alice",
      "password": "••• (présent seulement si l'expéditeur l'a choisi)",
      "url": null,
      "epg_url": null,
      "playlist": null
    }
  ]
}
```

- `playlist` : contenu compressé d'une playlist **locale** (`file://`) quand l'expéditeur la joint, plafonné à 20 Mo.
- Jamais inclus : catalogue (`iptv_items`), guide (`epg_programs`), favoris, historique, téléchargements, clés OMDb / IA.

### 2.2. Avec ou sans identifiants

L'expéditeur choisit, source par source :
- **Sans identifiants** (par défaut pour un ami) : le mot de passe Xtream n'est pas inclus et le destinataire le saisit. Le moteur **détecte les identifiants cachés dans les URL** et les retire : `get.php?username=…&password=…`, chemins Xtream `/live/{user}/{pass}/…`, `user:pass@hôte`. Si l'URL devient inutilisable sans eux, l'interface le signale avant l'envoi.
- **Avec identifiants** : le mot de passe (lu dans le Trousseau) est inclus **dans l'enveloppe chiffrée uniquement**.

Avertissement affiché avant tout partage avec identifiants : « Partager votre abonnement peut enfreindre les conditions de votre fournisseur, et chaque appareil qui l'utilise compte dans la limite de connexions simultanées (ici : N). » (`N` = `max_connections` connu.)

### 2.3. Enveloppe chiffrée

- Chiffrement **AES-GCM 256** (`CryptoKit`) d'un document compressé ; clé dérivée par **HKDF-SHA256** d'un **code de partage aléatoire de 128 bits** généré par l'app (jamais d'un mot de passe choisi par l'utilisateur, ce qui évite d'avoir à étirer une clé faible).
- Code présenté en **26 caractères base32** groupés (« K7QF-…-3M ») ou dans un QR code.
- En-tête en clair minimal : format, version, `expires_at`, nombre de sources (pour l'aperçu) ; **aucun nom de serveur ni identifiant en clair**.
- Toute altération est détectée (tag GCM) ; enveloppe expirée refusée.
- Le moteur Rust produit et lit le **document en clair** (sérialisation, validation, détection d'identifiants) ; le chiffrement est fait côté Swift avec `CryptoKit`, sans nouvelle crate Rust.

### 2.4. Import (commun à tous les lots)

1. Aperçu : sources contenues, expéditeur, date d'expiration, avec ou sans identifiants.
2. **Doublons** : une source est « déjà présente » si même serveur + utilisateur (Xtream) ou même URL normalisée (M3U) ; choix entre ignorer, remplacer, ou importer en double.
3. Création des sources, mot de passe éventuel **écrit dans le Trousseau** (`cnd.xtream.<uuid>`), puis synchronisation automatique (comme un ajout manuel).
4. Rien n'est importé sans confirmation explicite.

---

## 3. Lots

### Lot 26.1 — Mes appareils avec iCloud (mots de passe compris)

- Option **« Synchroniser aussi les mots de passe via le Trousseau iCloud »** (désactivée par défaut) : les mots de passe Xtream sont enregistrés avec `kSecAttrSynchronizable = true` dans le groupe d'accès de l'app. Une source arrivée par iCloud retrouve alors son mot de passe sans ressaisie.
- Désactiver l'option rapatrie les secrets en local (non synchronisés) et les supprime du Trousseau iCloud.
- Les sources `file://` peuvent être synchronisées en joignant la playlist (CloudKit `CKAsset`, 20 Mo maximum par source) : option par source.
- **Dépend du `PRD-23`** (entitlements iCloud et groupe de Trousseau). Sans lui, le lot n'est pas activable et l'interface renvoie vers les lots 26.2 et 26.3.

### Lot 26.2 — Partage chiffré par fichier, lien ou QR code (amis, appareils sans iCloud)

- Menu d'une source (ou sélection multiple) : **« Partager… »** → choix avec / sans identifiants, durée de validité (1 h, 24 h, 7 jours) → génération de l'enveloppe et du code.
- Trois façons d'envoyer :
  - **fichier `.cndshare`** via la feuille de partage système (AirDrop, Messages, Mail…) ; le code est donné à part (affiché, copiable, à dicter) ;
  - **lien `cndiptv://import#<enveloppe>.<code>`** pour un envoi en un geste à une personne de confiance (le lien contient tout : l'interface le dit) ;
  - **QR code** contenant le lien, si l'enveloppe tient dans un QR (≈ 2,9 Ko) ; sinon, l'app propose le fichier.
- Import : ouverture du fichier ou du lien (type de document `.cndshare` et schéma d'URL déclarés dans l'`Info.plist` du `PRD-23`) ; sans ces déclarations, import par **« Sources > Importer un partage… »** (sélecteur de fichier) puis saisie ou collage du code.

### Lot 26.3 — Transfert direct à proximité (dont vers l'Apple TV)

- Entre deux appareils sur le **même réseau local** : l'appareil qui reçoit affiche « Recevoir des sources » avec un **code à 6 chiffres** et un QR ; l'appareil qui envoie le découvre par **Bonjour** (`Network.framework`, service `_cndiptv._tcp`) ou le scanne.
- Canal chiffré : TLS avec clé pré-partagée dérivée du code (ou `MultipeerConnectivity` avec `encryptionPreference = .required`, à trancher par un prototype), puis envoi de la même enveloppe que le lot 26.2.
- Cas principal : configurer une **Apple TV** (`PRD-21`) depuis l'iPhone sans taper d'identifiants à la télécommande.
- Le récepteur n'écoute que pendant que l'écran « Recevoir » est ouvert (5 min maximum), puis ferme le port.
- `NSLocalNetworkUsageDescription` et `NSBonjourServices` dans l'`Info.plist` (`PRD-23`).

### Lot 26.4 — Partage « vivant » via iCloud (facultatif)

- Partager une source avec un proche via **`CKShare`** (base partagée CloudKit) : les changements faits par le propriétaire (nouveau serveur, nouvelle URL EPG) se propagent chez le participant ; **arrêter le partage** retire la source chez lui.
- Le mot de passe n'est jamais placé dans CloudKit : le participant le reçoit une fois par le lot 26.2 ou le saisit.
- Révocation honnête : arrêter le partage retire la configuration, mais **ne peut pas** empêcher l'usage d'un mot de passe déjà transmis. Pour cela, l'utilisateur doit le changer chez son fournisseur, et l'interface le dit.
- **Dépend du `PRD-23`** et de comptes iCloud des deux côtés.

---

## 4. Fichiers à Créer / Modifier

- `crates/cnd-core/src/sharing/mod.rs` *(document de partage : export depuis SQLite, validation, import avec détection des doublons)*
- `crates/cnd-core/src/sharing/credentials.rs` *(détection et retrait des identifiants dans les URL)*
- `crates/cnd-core/src/lib.rs` *(exports `export_share_document(source_ids, include_credentials_for)`, `preview_share_document(json)`, `import_share_document(json, decisions)`)*
- `apple/Sources/CndIptvApp/Features/Sharing/ShareEnvelope.swift` *(CryptoKit : code de partage, HKDF, AES-GCM, base32, en-tête, expiration)*
- `apple/Sources/CndIptvApp/Features/Sharing/ShareSourcesSheet.swift` *(choix, avertissements, code, QR, feuille de partage)*
- `apple/Sources/CndIptvApp/Features/Sharing/ImportShareSheet.swift` *(aperçu, doublons, confirmation)*
- `apple/Sources/CndIptvApp/Features/Sharing/NearbyTransfer.swift` *(lot 26.3 : Bonjour, canal chiffré)*
- `apple/Sources/CndIptvApp/Security/KeychainStore.swift` *(lot 26.1 : option `synchronizable`, migration des secrets)*
- `apple/Sources/CndIptvApp/Sync/` *(lot 26.1 : `CKAsset` des playlists locales ; lot 26.4 : `CKShare`)*
- `apple/Sources/CndIptvApp/Features/Sources/SourcesListView.swift` *(menus « Partager… », « Importer un partage… », « Recevoir depuis un appareil proche »)*

---

## 5. Contraintes Non-Négociables (Guardrails IA)

- **Aucun serveur tiers** : le partage passe uniquement par iCloud de l'utilisateur, la feuille de partage système ou le réseau local.
- Mots de passe : jamais en clair hors du Trousseau et de l'enveloppe chiffrée ; jamais dans SQLite, les journaux, `UserDefaults`, les en-têtes en clair ni l'aperçu.
- Les journaux (`AI`, `DB`…) ne contiennent ni le document, ni l'enveloppe, ni le code.
- Le code de partage est généré par `SecRandomCopyBytes` / `SystemRandomNumberGenerator`, jamais par l'utilisateur.
- Pas de nouvelle crate Rust ; cryptographie uniquement via `CryptoKit` et `Security` d'Apple.
- Import toujours précédé d'un aperçu et d'une confirmation ; une enveloppe expirée ou altérée est refusée avec un message clair.

---

## 6. Critères d'Acceptation & Commandes de Validation

1. **Tests Rust :** document de partage (export d'une source M3U, Xtream, `file://` avec playlist jointe), détection et retrait des identifiants (`get.php`, chemins `/live/u/p/`, `user:pass@`), URL rendue inutilisable signalée, import dans un moteur en mémoire, doublons (même serveur + utilisateur, même URL normalisée), version inconnue refusée.
2. **Tests Swift :** enveloppe (aller-retour, mauvais code refusé, octet modifié détecté, expiration, en-tête sans donnée sensible), code base32 (aléa, format, saisie tolérante aux espaces et à la casse), taille limite du QR, import qui écrit le mot de passe dans un Trousseau de test isolé, option Trousseau iCloud (lot 26.1) avec un faux magasin.
3. **Lot 26.3 :** test d'intégration local (deux points de terminaison sur `127.0.0.1`), refus d'un mauvais code, fermeture du port après 5 min.
4. **Essais manuels :** Mac → iPhone par AirDrop (sans identifiants puis avec), iPhone → Apple TV par le lot 26.3, synchronisation des mots de passe entre deux appareils avec iCloud (lot 26.1, build signé).
5. `task check` au vert.

---

## 7. Statut d'Implémentation & Validation

**Lot 26.2 — terminé ✅ ; lots 26.1, 26.3 et 26.4 — en attente du PRD 23 (projet Xcode signé, entitlements, `Info.plist`) et de prototypes.**

- **Rust (`crates/cnd-core/src/sharing/`)** : document de partage JSON (`format`, `version`, expiration, sources), retrait des identifiants cachés dans les URL (`user:pass@`, paramètres `username`/`password`/`token`…, chemins Xtream `/live/u/p/`), détection des doublons (serveur + utilisateur, URL M3U normalisée), aperçu sans secret, import avec décision par source (ignorer / importer / remplacer). Exports UniFFI : `export_share_document`, `preview_share_document`, `import_share_document`. 19 tests.
- **Swift (`Features/Sharing/`)** : `ShareEnvelope` (CryptoKit : HKDF-SHA256 depuis un code aléatoire de 128 bits, AES-GCM avec l'en-tête en données authentifiées, compression zlib), codes base32 tolérants, lien `cndiptv://import#…`, QR limité à ≈ 2,9 Ko ; `ShareSourcesModel` / `ShareImportModel` ; feuilles « Partager des sources » et « Importer un partage » ; mot de passe importé écrit dans le Trousseau (`cnd.xtream.<uuid>`), seule sa référence est stockée en base ; synchronisation automatique des sources prêtes.
- **Intégration** : menu d'une source et bouton « Ajouter », menu Fichier, `onOpenURL` (liens et fichiers), dépôt d'un `.cndshare` sur la fenêtre, schéma d'URL et type de document déclarés dans l'`Info.plist` généré par `scripts/run-macos.sh`.
- **Choix** : le nom d'utilisateur Xtream est toujours transmis (c'est un identifiant, il sert aussi aux doublons) ; seul le mot de passe est optionnel. Le lien et le QR contiennent le code (l'interface le dit) ; le fichier se partage avec un code donné à part.
- **Validation** : 122 tests Rust (le test de débit `test_50k_streaming_m3u_ingestion_sla` peut échouer quand la machine est chargée ; il passe seul), 211 tests Swift, 5 tests du pont, `xcodebuild` Release macOS et simulateur iOS réussis, clippy sans avertissement.
- **Reste à faire** : 26.1 (mots de passe via Trousseau iCloud, opt-in), 26.3 (transfert à proximité Bonjour, Apple TV), 26.4 (`CKShare`). Les déclarations d'URL/type de document de l'app iOS devront être reprises dans l'`Info.plist` du PRD 23. Essais manuels AirDrop Mac → iPhone non réalisés.
