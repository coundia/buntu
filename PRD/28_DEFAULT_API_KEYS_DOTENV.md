# PRD 28 — Clés d'API par défaut depuis un fichier `.env`

- **ID :** `PRD-28`
- **Prérequis :** `PRD-01` (réglages, télémétrie et masquage des URL), `PRD-06` (OMDb), `PRD-13` (fournisseurs IA), `PRD-18` (OpenSubtitles), `PRD-23` (projet Xcode, scripts de build), `PRD-27` (TMDB, facultatif)
- **Couches impactées :** fichiers racine (`.env`, `.env.example`, `.gitignore`), `scripts/`, `Taskfile.yml`, `apple/project.yml`, `SwiftUI (CndIptvKit/Security/, Settings/, Assistant/, Subtitles/)`
- **Objectif :** l'app fonctionne **dès la première ouverture** (affiches et notes OMDb, sous-titres, assistant IA), sans que l'utilisateur ait à créer de compte ni à saisir de clé. Une clé saisie par l'utilisateur reste prioritaire.

---

## 1. Contexte & Objectif

Aujourd'hui, chaque service externe exige que l'utilisateur colle sa propre clé dans les Réglages :

| Service | Où la clé est rangée aujourd'hui | Usage |
| :--- | :--- | :--- |
| OMDb | Trousseau `cnd.omdb.apikey` | Fiches, affiches, notes des films et séries (`PRD-06`) |
| OpenSubtitles | Trousseau `cnd.opensubtitles.apikey` (+ compte utilisateur) | Recherche et téléchargement de sous-titres (`PRD-18`) |
| Gemini | Trousseau `cnd.ai.gemini.apikey` | Assistant IA (`PRD-13`), sagas (`PRD-27`) |
| Compatible OpenAI | Trousseau `cnd.ai.openAiCompatible.apikey` + adresse + modèle | Idem |
| Claude (Anthropic) | Trousseau `cnd.ai.anthropic.apikey` | Idem |
| TMDB *(si `PRD-27` lot 27.4)* | — | Collections de films |

Sans clé, ces fonctions sont désactivées et l'interface demande une configuration que la plupart des utilisateurs ne feront pas.

Ce PRD permet au développeur de renseigner des **clés par défaut** dans un fichier `.env` à la racine du dépôt. Au build, elles sont intégrées à l'app et utilisées **quand l'utilisateur n'a pas saisi sa propre clé**.

---

## 2. Le fichier `.env`

### 2.1. Emplacement et versionnage

- `.env` à la racine du dépôt, **ignoré par git** (ajout à `.gitignore`, avec `.env.*` sauf `.env.example`).
- `.env.example` **versionné**, avec toutes les variables, des valeurs vides et un commentaire par variable (où obtenir la clé, quotas gratuits, si elle est intégrée aux builds Release).
- Les **variables d'environnement** du shell ou de la CI ont priorité sur le fichier : un build de CI n'a pas besoin de fichier.

### 2.2. Variables

```dotenv
# Métadonnées
CND_OMDB_API_KEY=
CND_TMDB_API_KEY=

# Sous-titres (clé d'application OpenSubtitles, pas un compte utilisateur)
CND_OPENSUBTITLES_API_KEY=

# Assistant IA : fournisseur proposé par défaut (gemini | openai | anthropic | none)
CND_DEFAULT_AI_PROVIDER=none
CND_GEMINI_API_KEY=
CND_OPENAI_API_KEY=
CND_OPENAI_BASE_URL=https://api.openai.com/v1
CND_OPENAI_MODEL=
CND_ANTHROPIC_API_KEY=

# Intégration aux builds Release (les builds Debug intègrent toujours les clés présentes)
CND_EMBED_METADATA_KEYS_IN_RELEASE=1
CND_EMBED_AI_KEYS_IN_RELEASE=0
```

- **Uniquement des clés d'API** de services. **Jamais** de mot de passe ou d'identifiant personnel : ni compte OpenSubtitles, ni identifiants Xtream, ni URL de source. Le générateur refuse toute variable inconnue et le dit.
- Format : `NOM=valeur`, commentaires `#`, valeurs entre guillemets acceptées, espaces autour de la valeur retirés. Une ligne invalide arrête la génération avec le numéro de ligne, **sans afficher la valeur**.

---

## 3. Intégration au build

### 3.1. Génération

- Script `scripts/gen-default-keys.sh` (appelé aussi par `task keys`) : lit l'environnement puis `.env`, et écrit `apple/Sources/CndIptvKit/Generated/DefaultApiKeys.generated.swift` (**ignoré par git**).
- Le fichier généré expose un type interne `DefaultApiKeys` avec une propriété optionnelle par clé. Les valeurs ne sont pas écrites en clair : elles sont **masquées** (XOR avec un sel aléatoire régénéré à chaque build), pour qu'elles n'apparaissent pas telles quelles dans `strings` du binaire. Ce masquage **n'est pas une protection** (§ 6) ; il évite seulement l'extraction triviale et les scanners automatiques.
- Sans `.env` ni variables, le fichier est généré **avec des valeurs vides** : le build réussit, l'app se comporte comme aujourd'hui.
- Configuration Release : les clés IA ne sont intégrées que si `CND_EMBED_AI_KEYS_IN_RELEASE=1`, et les clés de métadonnées et de sous-titres que si `CND_EMBED_METADATA_KEYS_IN_RELEASE=1`. Le script affiche **quelles clés** sont intégrées (noms seulement, jamais les valeurs).

### 3.2. Points d'appel

- `apple/project.yml` : script de pré-build (`preBuildScripts`) sur les cibles macOS, iOS, tvOS et visionOS, qui reçoit la configuration (`Debug` / `Release`).
- `scripts/run-macos.sh`, `scripts/run-iphone.sh`, `scripts/install-macos.sh` : appel avant le build.
- `Taskfile.yml` : tâche `keys`, dépendance des tâches `build`, `run`, `run:iphone`, `install`, `swift:test`, `app:*`.
- SwiftPM (`swift build`, `swift test`) ne lance pas de script : un fichier généré vide est nécessaire. La tâche `task keys` le crée ; si le fichier manque, la compilation échoue avec un message qui dit de lancer `task keys` (vérifié par une assertion de compilation dans un fichier versionné).
- La couche Rust **ne lit jamais** `.env` : les clés passent toujours par les appels UniFFI existants, qui prennent déjà une clé en paramètre (`api_key`). Aucun `env!()` ni `build.rs` côté Rust.

---

## 4. Résolution des clés dans l'app

### 4.1. Ordre de priorité

Pour chaque service, un résolveur unique (`ApiKeyResolver`, `CndIptvKit/Security/`) renvoie la clé à utiliser :

1. **La clé de l'utilisateur** dans le Trousseau, si elle existe.
2. Sinon, **la clé par défaut** de `DefaultApiKeys`, si elle est présente et que la fonction l'autorise (§ 4.3).
3. Sinon, aucune clé : la fonction reste désactivée, comme aujourd'hui.

Tous les endroits qui lisent aujourd'hui une clé dans le Trousseau (`SettingsModel`, `AiProviderSettings`, `SubtitleSearchModel`, enrichissement VOD) passent par ce résolveur.

### 4.2. Ce que voit l'utilisateur (Réglages)

- Le champ de chaque clé reste vide quand la clé par défaut est utilisée. En dessous : « Clé intégrée à l'application utilisée. Saisissez la vôtre pour ne plus partager le quota. »
- La clé par défaut n'est **jamais affichée, copiée, exportée ni écrite** dans le Trousseau, SQLite, `UserDefaults`, iCloud, un partage de sources (`PRD-26`) ou un journal.
- Effacer sa propre clé rebascule sur la clé par défaut, et l'interface le dit.
- En cas d'erreur de quota ou de clé refusée avec la clé par défaut (HTTP 401, 403 ou 429), le message propose de saisir sa propre clé, au lieu d'un message d'erreur technique.

### 4.3. Règles par type de clé

- **Métadonnées (OMDb, TMDB) et sous-titres (OpenSubtitles)** : utilisées automatiquement. Ce sont des clés gratuites et limitées, prévues pour ce genre d'usage. Le compte OpenSubtitles (nom et mot de passe) reste celui de l'utilisateur.
- **Fournisseurs IA** : la clé par défaut **ne remplace pas le consentement** du `PRD-13`. L'assistant est proposé avec le fournisseur `CND_DEFAULT_AI_PROVIDER` déjà réglé, mais le premier envoi demande toujours l'accord de l'utilisateur. Limites locales, avec la clé par défaut seulement :
  - au plus **50 requêtes par jour** et par appareil ;
  - au plus **2 000 jetons en sortie** par requête ;
  - aucune utilisation en mode Enfants.
  Au-delà, l'app propose d'utiliser sa propre clé.
- Un **modèle local** (Ollama, LM Studio) n'a pas besoin de clé : rien ne change.

---

## 5. Journaux et diagnostics

- La télémétrie (`PRD-01`, `redact_url` / `redact_text`) masque déjà les paramètres sensibles. On vérifie et on complète la liste pour `apikey` (OMDb passe la clé dans l'URL), `api_key`, `key` (Gemini), et les en-têtes `Authorization`, `x-api-key`, `Api-Key` (OpenSubtitles).
- La console réseau et l'export des journaux affichent « clé par défaut » ou « clé utilisateur » pour chaque appel, jamais la valeur.
- Réglages > À propos : liste des services qui ont une clé par défaut dans ce build (oui/non), utile au support.

---

## 6. Sécurité : ce qu'il faut savoir

- **Toute clé intégrée dans une application distribuée peut être extraite** par quelqu'un qui analyse le binaire. Le masquage du § 3.1 ne sert qu'à éviter l'extraction triviale. Conséquences :
  - n'intégrer dans les builds distribués que des clés **gratuites, à quota limité et révocables** (OMDb, TMDB, clé d'application OpenSubtitles) ;
  - **ne pas intégrer de clé IA payante** dans un build distribué (`CND_EMBED_AI_KEYS_IN_RELEASE=0` par défaut). Pour un usage personnel, utiliser une clé dédiée avec un **plafond de dépenses** chez le fournisseur ;
  - prévoir la **rotation** : changer une clé dans `.env` puis refaire un build suffit ; les builds déjà installés gardent l'ancienne jusqu'à leur mise à jour.
- Une vraie protection d'une clé IA partagée demanderait un **serveur relais** qui garde la clé côté serveur. C'est hors périmètre, l'app n'a volontairement aucun serveur (`PRD-26`).
- Le dépôt ne doit jamais contenir de clé : un contrôle `task check` refuse un commit si `.env` est suivi par git ou si une chaîne ressemblant à une clé connue (préfixes `sk-`, `sk-ant-`, `AIza`) apparaît dans les fichiers versionnés.

---

## 7. Fichiers à Créer / Modifier

- `.env.example` *(nouveau, versionné)*, `.gitignore` *(`.env`, `.env.*`, `!.env.example`, `apple/Sources/CndIptvKit/Generated/`)*
- `scripts/gen-default-keys.sh` *(nouveau)* ; `scripts/run-macos.sh`, `run-iphone.sh`, `install-macos.sh`
- `Taskfile.yml` *(tâche `keys`, dépendances, contrôle des secrets dans `check`)*
- `apple/project.yml` *(script de pré-build sur les 4 cibles)*
- `apple/Sources/CndIptvKit/Generated/DefaultApiKeys.generated.swift` *(généré, ignoré)* ; `apple/Sources/CndIptvKit/Security/DefaultApiKeys.swift` *(contrat versionné, assertion « lancer `task keys` »)*
- `apple/Sources/CndIptvKit/Security/ApiKeyResolver.swift` *(nouveau)*
- `SettingsModel.swift`, `SettingsView.swift`, `AiProviderSettings.swift`, `SubtitleSearchModel.swift`, `VodContext.swift` *(lecture via le résolveur, textes « clé intégrée »)*
- `crates/cnd-core/src/telemetry/mod.rs` *(compléments de masquage, si nécessaire)*
- `README.md`, `docs/` *(section « Clés d'API par défaut »)*, `PRD/00_INDEX_ROADMAP.md`

---

## 8. Contraintes Non-Négociables (Guardrails IA)

- `.env` n'est **jamais** versionné, copié dans le bundle, ni lu à l'exécution : il ne sert qu'au build.
- Aucune valeur de clé dans la sortie des scripts, les journaux de build, les journaux de l'app, les captures de la console réseau ni les messages d'erreur.
- La clé de l'utilisateur est **toujours prioritaire** ; la clé par défaut ne remplace jamais le consentement IA du `PRD-13`.
- Pas de mot de passe, d'identifiant personnel ni d'URL de source dans `.env`.
- Les builds sans `.env` restent verts et se comportent comme aujourd'hui.
- Les cibles macOS, iOS, tvOS et visionOS restent vertes.

---

## 9. Critères d'Acceptation & Commandes de Validation

1. **Générateur (tests shell ou Swift) :** lecture de `.env` (commentaires, guillemets, espaces), priorité de l'environnement, variable inconnue refusée, ligne invalide signalée sans sa valeur, fichier vide sans `.env`, règles Release (`CND_EMBED_*`), masquage réversible, aucune valeur en clair dans le fichier généré.
2. **Tests Swift :** `ApiKeyResolver` (utilisateur > défaut > aucune), clé par défaut jamais écrite dans le Trousseau ni exportée, retour à la clé par défaut après effacement, limites IA (50 requêtes par jour, mode Enfants), message en cas de 401/403/429.
3. **Tests Rust :** masquage de `apikey`, `api_key`, `key`, `Authorization`, `x-api-key`, `Api-Key` dans la télémétrie.
4. **Vérifications manuelles :**
   - build Release puis `strings` sur le binaire : aucune clé en clair ;
   - premier lancement sans clé saisie : affiches OMDb et recherche de sous-titres fonctionnelles ;
   - clé utilisateur saisie : utilisée à la place (visible dans la console réseau, « clé utilisateur ») ;
   - `.env` absent : build vert, fonctions désactivées comme avant.
5. `task check` (dont le contrôle des secrets), `cargo test --workspace --release`, `cd apple && swift test`, builds des 4 schémas Xcode au vert.

---

## 10. Questions ouvertes

- **Clés IA dans les builds Release :** ce PRD les exclut par défaut. Si l'app ne sert qu'à toi et à tes appareils, tu peux les activer (`CND_EMBED_AI_KEYS_IN_RELEASE=1`) avec une clé plafonnée.
- **Limite IA quotidienne :** 50 requêtes par jour et par appareil est une proposition ; elle peut devenir une variable du `.env`.
- **Apple TV :** l'app tvOS utilise les mêmes clés ; faut-il une variable distincte pour séparer les quotas par plateforme ?

---

## 11. Statut d'Implémentation & Validation

**Implémenté ✅ (à vérifier avec de vraies clés).**

- **Générateur** (`scripts/gen-default-keys.sh`) : lit l'environnement puis `.env`, refuse les variables inconnues et les lignes invalides (numéro de ligne, jamais la valeur), applique les règles Debug / Release (`CND_EMBED_*_IN_RELEASE`, `CONFIGURATION` d'Xcode), écrit `Generated/DefaultApiKeys.generated.swift` (ignoré par git) avec les valeurs masquées par XOR. Le sel ne change que si le contenu change, pour ne pas recompiler à chaque build. Il liste les clés intégrées, par nom seulement.
- **Appels** : `task keys`, dépendance de `swift:test` et `xcode:generate` ; appelé par `run-macos.sh` et `run-iphone.sh` ; script de pré-build des 4 cibles dans `apple/project.yml`. La couche Rust ne lit jamais `.env`.
- **App** : `DefaultApiKeys` (clés démasquées à la demande) et `ApiKeyResolver` (clé de l'utilisateur, sinon clé par défaut, sinon rien) pour OMDb, OpenSubtitles et les fournisseurs IA. Le champ des Réglages n'affiche jamais la clé par défaut ; il dit « Clé intégrée à l'application utilisée ». Section À propos : liste des services qui ont une clé par défaut. Chaque service écrit une ligne `KEYS` dans la console (« clé par défaut » ou « clé utilisateur »).
- **IA** : le fournisseur de `CND_DEFAULT_AI_PROVIDER` est proposé tant que l'utilisateur n'a pas choisi, mais le consentement du PRD 13 reste exigé avant tout envoi ; adresse et modèle OpenAI préremplis depuis `.env` ; 50 requêtes par jour et par appareil avec la clé par défaut seulement (au-delà : résolution locale et message), pas de limite avec la clé de l'utilisateur ; une clé refusée ou un quota atteint renvoie vers la clé personnelle. Le plafond de sortie existait déjà côté Rust (1 024 jetons Gemini, 512 Claude, sous les 2 000 du PRD) ; la limite en jetons n'est pas imposée aux serveurs compatibles OpenAI. Le mode Enfants n'a pas d'assistant (`KidsModePolicy`).
- **Contrôles** : `task secrets:check` (`.env` suivi, formes `sk-`, `sk-ant-`, `AIza`), inclus dans `task check` avec `task keys:test` (16 tests du générateur). 18 tests Swift (priorité, clé jamais écrite dans le Trousseau, quota, consentement, retour à la clé par défaut) et 1 test Rust (masquage `apikey`, `api_key`, `api-key`, `key`).
- **Validation** : 331 tests Swift, tests de télémétrie Rust, builds macOS, iOS, tvOS et visionOS (simulateur) réussis.
- **Non vérifié / non fait** : aucune vraie clé n'a été essayée contre OMDb, OpenSubtitles ou un fournisseur IA ; la commande `strings` sur un binaire Release n'a pas été passée (le fichier généré a été vérifié, pas le binaire) ; le message « clé refusée » avec la clé par défaut s'appuie sur le texte des erreurs du moteur ; la console réseau n'a pas de colonne par appel : seule la ligne `KEYS` par service et par lancement indique la provenance ; TMDB est résolu mais aucune fonction ne l'appelle encore (PRD 27, lot 27.4) ; la limite quotidienne n'est pas réglable depuis `.env`. Sur un clone neuf, `task keys` est nécessaire avant `swift build`.
