# Assistant IA sur Samsung Smart TV (Tizen)

Ce document décrit l'architecture, la configuration des fournisseurs, le stockage sécurisé des clés API, les garde-fous de confidentialité et les procédures de test de l'assistant IA de CND IPTV sur Samsung Tizen (PRD 40).

---

## 1. Vue d'Ensemble & Architecture

L'assistant IA sur Tizen repose sur une architecture partagée et sécurisée :
- **Logique pure en Rust (`cnd-domain::ai`)** : construction des requêtes HTTP, lecture des réponses, validation des actions, explication des codes d'erreur et résolution locale ultra-rapide (< 50 ms).
- **WebAssembly 1.0 MVP (`cnd-domain-wasm`)** : exécuté soit dans un Web Worker Tizen, soit directement sur le fil principal de l'application via `WorkerBridge` pour compatibilité totale Tizen 3.0 à 8.0+.
- **Couche Core Tizen (`tizen/src/core/ai/`)** :
  - `AiClient.ts` : communication HTTP native (`fetch` avec repli `XMLHttpRequest`), délai maximal de 8 s, réessais automatiques sur `429` et repli mode allégé sur rejet de schéma.
  - `AiKeyStore.ts` : coffre-fort chiffré WebCrypto AES-GCM 256 bits dans IndexedDB (`cnd_ai_vault`).
  - `AiSettings.ts` : configuration des fournisseurs, modèles, adresses personnalisées et gestion du consentement.
  - `AiUsage.ts` : suivi du quota journalier (plafond par défaut de 30 appels distants par jour).
  - `candidates.ts` : extracteur de candidats (chaînes récentes, favoris, EPG en cours).

---

## 2. Fournisseurs Supportés

| Fournisseur | Identifiant | Modèle par défaut | URL de base | Authentification |
| :--- | :--- | :--- | :--- | :--- |
| **Local uniquement** | `local_only` | *(aucun)* | *(aucune)* | Aucune clé requise. Zéro appel réseau. |
| **Google Gemini** | `gemini` | `gemini-3.5-flash-lite` | `https://generativelanguage.googleapis.com/v1beta` | En-tête `x-goog-api-key` |
| **OpenAI Compatible** | `openai_compatible` | `gpt-4o-mini` | `https://api.openai.com/v1` | En-tête `Authorization: Bearer <clé>` |
| **Anthropic Claude** | `anthropic` | `claude-haiku-5-5` | `https://api.anthropic.com` | En-têtes `x-api-key` et `anthropic-dangerous-direct-browser-access: true` |

> [!TIP]
> **Modèles locaux sur réseau local (Ollama, LM Studio) :**
> En configurant le fournisseur `openai_compatible` avec une URL LAN (ex. `http://192.168.1.50:11434/v1`), l'application détecte automatiquement le réseau local : aucune clé n'est exigée et le quota journalier est automatiquement désactivé.

---

## 3. Coffre-fort & Chiffrement des Clés (`AiKeyStore`)

Afin de garantir la sécurité sur un téléviseur partagé :
1. **Chiffrement AES-GCM 256 bits** : chaque clé API est chiffrée avec un vecteur d'initialisation aléatoire (IV de 12 octets) via `crypto.subtle`.
2. **Clé maîtresse non exportable** : générée avec `extractable: false` et stockée directement dans la base isolée IndexedDB `cnd_ai_vault`.
3. **Réception sécurisée par QR Code (PRD 39 / PRD 40 § 4.2)** :
   - L'utilisateur scanne le QR code affiché dans les Réglages ou la modale Assistant avec son smartphone.
   - La clé API est envoyée scellée de bout en bout via le protocole d'appairage chiffré (`ai-config` sous ChaCha20-Poly1305 / X25519).
   - La clé est immédiatement écrite dans le coffre-fort chiffré de la TV sans jamais être affichée en clair.
4. **Masquage à l'écran** : seuls les 4 derniers caractères sont affichés (`••••••••1234`).
5. **Zéro fuite** : la clé n'apparaît jamais dans les logs de la console, ni dans l'inspecteur WebInspector, ni dans `localStorage`.

---

## 4. Garde-fous Non-Négociables (Guardrails)

1. **Mode Enfants (Kids Profile)** :
   - Tout appel distant est **strictement bloqué** (`isLocalFallback: true`).
   - Seul le moteur de résolution locale (< 50 ms) s'exécute sur le catalogue autorisé.
2. **Consentement explicite** :
   - Aucun paquet réseau n'est émis sans consentement utilisateur préalable dans `Réglages > Assistant IA`.
3. **Plafond d'usage quotidien** :
   - Plafond par défaut : 30 appels distants par jour pour les recommandations / affinage de recherche.
   - Les commandes résolues localement (« Mets France 2 », « suivante ») ne consomment aucun crédit.
4. **Pas d'action hors catalogue** :
   - L'IA ne peut jamais déclencher une lecture d'un flux inventé. Seuls les `id` et `stable_hash` des candidats réels transmis et validés sont exécutables.
5. **Délai maximal & non-blocage** :
   - Timeout strict à 8 secondes avec `AbortController`.
   - Pendant l'attente du résultat distant, les résultats locaux sont déjà affichés et navigables.

---

## 5. Intégration dans l'Interface TV

- **Modale Assistant (`AssistantModal.tsx`)** :
  - Accessible via la touche micro de la télécommande, la touche menu rapide ou le bouton ✨ de l'OSD du lecteur.
  - Commandes rapides prédéfinies (« Mets France 2 », « Matchs de foot en direct », « Film avec DiCaprio »).
  - QR code d'appairage instantané permettant de taper du texte au smartphone ou d'injecter une clé API.
- **Recherche Universelle (`SearchView.tsx`)** :
  - Recherche locale instantanée (< 150 ms) avec proposition « Demander à l'assistant IA ».
  - Affichage progressif des résultats et explication concise de l'intention comprise.
- **Lecteur Vidéo (`PlayerView.tsx`)** :
  - Bouton `✨ Assistant` intégré à la barre de contrôle OSD pour zapper intelligemment sans quitter la vidéo.
- **Recommandations (`RecommendationsView.tsx`)** :
  - Bouton « ✨ Affiner avec l'IA » pour réordonner les étagères de films et séries selon les goûts du profil actif avec mise en cache.
- **Réglages (`SettingsView.tsx`)** :
  - Sélection du fournisseur et du modèle.
  - Bouton « Tester la connexion » mesurant la latence réelle aller-retour en millisecondes.
  - Bascule du consentement et QR code pour appairer une clé depuis un téléphone.

---

## 6. Procédures de Test & Validation

### Tests automatisés

```bash
# 1. Tests unitaires et d'intégration TypeScript (Tizen)
cd tizen
npm test
npm run typecheck

# 2. Compilation de production du paquet Tizen
npm run build

# 3. Tests unitaires Rust de la logique IA (cnd-domain)
cargo test -p cnd-domain --lib ai

# 4. Tests d'intégration Core et Sagas LLM
cargo test -p cnd-core --lib ai

# 5. Vérification du linter
cargo clippy --workspace --all-targets -- -D warnings
```

### Essai manuel avec une vraie clé API (hors CI)

1. Ouvrir l'application sur la TV ou dans le simulateur Tizen.
2. Naviguer vers **Réglages → Assistant IA**.
3. Sélectionner le fournisseur souhaité (ex. *Google Gemini*).
4. Scanner le QR code avec l'application mobile CND IPTV pour transférer la clé API, ou la coller dans l'environnement de test.
5. Cliquer sur **Tester la connexion** : la pastille verte indique le succès avec la latence mesurée (ex. `Connexion réussie (412 ms)`).
6. Ouvrir la recherche universelle, taper une phrase naturelle (ex. *« films d'action spatiale »*) et valider l'affichage progressif des résultats.

