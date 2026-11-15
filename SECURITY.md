# Politique de sécurité (`SECURITY.md`)

## Versions prises en charge

| Version | Prise en charge |
| :--- | :--- |
| `1.0.x` (`main`) | ✅ Correctifs de sécurité actifs |
| `< 1.0.0` | ❌ Non prise en charge |

---

## Signaler une vulnérabilité

**N'ouvrez pas d'issue GitHub publique pour signaler une faille de sécurité.**

Envoyez un message privé à : **papacoundia@gmail.com** avec l'objet `[SECURITY] Buntu - <résumé court>`.

Merci d'inclure autant d'informations que possible :

- La plateforme et le module concernés (`crates/cnd-domain`, `crates/cnd-core`, `apple/`, `android/`, `tizen/`).
- La version ou le hash de commit concerné.
- Les étapes précises pour reproduire le problème et son impact potentiel (fuite d'identifiants, injection, contournement de chiffrement, etc.).
- Toute piste de correction si vous en avez identifié une.

Un accusé de réception est envoyé sous **72 heures** et un correctif coordonné est préparé avant toute divulgation publique.

---

## Modèle de sécurité et confidentialité de Buntu

### 1. Lecteur média neutre, sans serveur tiers

- **Buntu est un lecteur média neutre :** l'application ne fournit aucun flux, aucune playlist et aucun contenu préchargé. L'utilisateur ajoute uniquement ses propres sources et fichiers.
- **Zéro serveur central Buntu :** aucune donnée utilisateur (sources, identifiants, historique de lecture, favoris, guides EPG ou clés d'API tierces) n'est transmise à un serveur opéré par les mainteneurs du projet.

### 2. Stockage chiffré des secrets par plateforme

Les identifiants, clés de foyer et clés d'API saisies par l'utilisateur ne sont jamais stockés en clair dans SQLite, les journaux applicatifs ou les exports non chiffrés :

| Plateforme | Stockage sécurisé utilisé |
| :--- | :--- |
| **Apple** (macOS, iOS, iPadOS, tvOS, visionOS) | **Trousseau Apple** (Keychain Services) |
| **Android & Android TV** | **Android Keystore** (`AES/GCM/NoPadding` matériel lorsque disponible) |
| **Samsung Smart TV (Tizen)** | **WebCrypto** et stockage local chiffré sur l'appareil |

### 3. Chiffrement de bout en bout (Appairage & Continuité du foyer)

- L'appairage par QR code (`crates/cnd-domain/src/pairing.rs`) utilise un échange de clés éphémère **X25519 + HKDF-SHA256 + AES-256-GCM** avec expiration stricte et effacement de la clé privée après usage.
- La continuité entre appareils du foyer (`crates/cnd-domain/src/sync/`) s'effectue uniquement sur le réseau local, chiffrée en **AES-256-GCM** avec authentification AAD et protection anti-rejeu.
- Lors des partages de sources (`.cndshare` / `cndiptv://` / `buntu://`), les mots de passe sont masqués par défaut et ne sont inclus que sur consentement explicite.

### 4. Contrôles automatisés dans le dépôt

- `./scripts/check-secrets.sh` empêche la mise en suivi git de `.env`, de clés ou certificats (`.p12`, `.keystore`, `.jks`, `.mobileprovision`), de fichiers temporaires `.swp`, de motifs de clés d'API ou de chemins locaux développeur (`/Users/...`).
- `./scripts/test-gen-default-keys.sh` vérifie qu'aucune valeur de clé par défaut n'est imprimée en clair dans les journaux ou fichiers générés.
