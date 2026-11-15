# Guide de contribution à Buntu

Merci de votre intérêt pour **Buntu** (`cnd-iptv-native`). Buntu est un lecteur média et IPTV neutre multiplateforme (Apple, Android / Android TV et Samsung Smart TV Tizen) propulsé par un cœur métier unique en Rust.

> **Rappel important :** Buntu ne fournit aucun contenu, aucune chaîne et aucune playlist. Merci de ne jamais publier d'URL de flux privées, d'identifiants, de mots de passe ou de clés d'API dans les issues, captures d'écran, fixtures de test ou pull requests.

---

## 1. Initialisation de l'environnement (`task init`)

Après avoir cloné le dépôt, exécutez la commande d'initialisation pour vérifier les outils, préparer `.env` (non suivi par git), générer les clés par défaut factices/locales, compiler le XCFramework Apple (`cnd_coreFFI.xcframework`), générer `apple/CndIPTV.xcodeproj` et installer les dépendances Node de `tizen/` :

```bash
task init
```

Commandes complémentaires utiles :

- `task doctor` : vérifie la présence de `cargo`, `rustc`, `swift`, `xcodebuild`, `codesign` et des cibles Rust requises.
- `task init SKIP_CORE=1` : ignore la recompilation longue du XCFramework Apple si vous travaillez uniquement sur Rust, Android ou Tizen.
- `task init FORCE=1` : force la reconstruction du XCFramework et la réinstallation des dépendances.

Consultez également les guides dédiés selon la plateforme ciblée :

- Apple : [`docs/BUILD_IPHONE.md`](docs/BUILD_IPHONE.md)
- Android & Android TV : [`docs/BUILD_ANDROID.md`](docs/BUILD_ANDROID.md)
- Samsung Smart TV (Tizen) : [`docs/BUILD_TIZEN.md`](docs/BUILD_TIZEN.md)

---

## 2. Règles d'architecture non négociables

1. **Source unique de vérité dans `crates/cnd-domain` (Rust sans I/O) :**
   - Toute logique de décision ou de validation (normalisation, identité des contenus, recherche, recommandations, protocole d'appairage QR, prompts et validation IA, horloge et fusion de synchronisation) doit être écrite **une seule fois** dans `crates/cnd-domain`, sans aucune entrée-sortie (ni réseau, ni disque, ni horloge système, ni générateur aléatoire : ces dépendances sont passées en paramètres).
   - Ne réécrivez jamais de règle métier en Swift, Kotlin ou TypeScript. Utilisez les liaisons UniFFI (`crates/cnd-core`) ou WebAssembly (`crates/cnd-domain-wasm`) et vérifiez les vecteurs partagés (`*/vectors.json`) sur chaque plateforme.
2. **Anti-saturation mémoire (Streaming) :**
   - Ne chargez jamais une playlist M3U, un guide XMLTV ou un gros fichier JSON entièrement en mémoire. Lisez en flux continu et insérez en base par lots (2 000 à 5 000 lignes).
3. **Fil principal toujours libre :**
   - Aucune opération disque, réseau ou appel lourd au moteur ne doit s'exécuter sur le fil principal (`@MainActor` sur Apple, thread principal Android sans coroutine dédiée, thread UI Tizen au lieu du Web Worker).
4. **Mono-connexion fournisseur :**
   - Beaucoup d'abonnements n'autorisent qu'un seul flux actif. Coupez toujours la lecture en cours avant d'ouvrir un nouveau flux et n'ouvrez jamais deux connexions simultanées pour le même contenu.
5. **Architecture modulaire SRP sur Android :**
   - Les modules `feature/*` ne doivent **jamais** dépendre directement de `:core:engine` (contrôlé par `android/app/src/test/kotlin/com/pcoundia/buntu/ModuleArchitectureTest.kt`). Les interfaces de contrat résident dans `:core:domain` et les implémentations Rust dans `:core:data`.
6. **Compatibilité Samsung Smart TV (`tizen/`) — Chromium 56 à 76 :**
   - La TV de référence Tizen 6.0 embarque Chromium 76 (les modèles plus anciens utilisent Chromium 56 à 69).
   - **CSS :** évitez `aspect-ratio`, `inset` et `gap` dans flexbox ; utilisez des marges, `padding-top: 56.25%` pour le 16:9 et `top`/`right`/`bottom`/`left`. Les expressions `clamp()` s'appuient sur le plugin PostCSS `tizen/build-plugins/clampFallback.cjs`.
   - **JavaScript :** le bundle est transpilé via `@vitejs/plugin-legacy`, mais n'utilisez ni `?.` ni `??` dans du code évalué à distance et évitez `AbortController` sans repli avant Chromium 66.
   - **WebAssembly :** le binaire `cnd-domain-wasm` doit rester strictement compatible **WebAssembly 1.0 MVP** (vérifié par `wasm-opt --mvp-features` dans `./scripts/build-tizen.sh`).
   - **Worker & AVPlay :** le Web Worker utilise le format classique `iife` avec repli sur le fil principal ; la zone vidéo AVPlay doit rester transparente (la vidéo est rendue derrière la page web).

---

## 3. Commandes de test par plateforme

Exécutez les vérifications correspondant aux couches modifiées avant d'ouvrir une Pull Request :

### Rust (`crates/`)

```bash
cargo clippy --workspace --all-targets -- -D warnings
cargo test -p cnd-domain -p cnd-core
# Ou en mode release complet :
cargo test --workspace --release
```

*(Note : le benchmark `test_recommendations_sla_50k_items` peut être sensible à la charge machine ; privilégiez une machine dédiée ou `--skip test_recommendations_sla` lors de tests locaux rapides si besoin.)*

### Apple (`apple/`)

```bash
cd apple && swift test
# Vérification des schémas Xcode sans signature :
xcodebuild -project apple/CndIPTV.xcodeproj -scheme CndIPTV-macOS CODE_SIGNING_ALLOWED=NO build
xcodebuild -project apple/CndIPTV.xcodeproj -scheme CndIPTV-iOS CODE_SIGNING_ALLOWED=NO build
xcodebuild -project apple/CndIPTV.xcodeproj -scheme CndIPTV-tvOS CODE_SIGNING_ALLOWED=NO build
xcodebuild -project apple/CndIPTV.xcodeproj -scheme CndIPTV-visionOS CODE_SIGNING_ALLOWED=NO build
```

- Si vous ajoutez ou supprimez des fichiers Swift : régénérez le projet via `cd apple && xcodegen generate`.
- Si vous modifiez une API UniFFI (`#[uniffi::export]`, `Record`, `Enum`, `Error`) : reconstruisez le XCFramework via `./scripts/build-xcframework.sh`.

### Android (`android/`)

```bash
cd android && ./gradlew :core:data:testDebugUnitTest :core:domain:test :app:testDebugUnitTest
# Suite complète + lint :
task android:test
```

- Si vous modifiez une API UniFFI : régénérez les liaisons Kotlin via `./scripts/build-android.sh --bindings-only` (ou `./scripts/build-android.sh` pour les bibliothèques `.so`).

### Samsung TV Tizen (`tizen/`)

```bash
cd tizen && npx tsc --noEmit && npm test
```

- Si `crates/cnd-domain` ou `crates/cnd-domain-wasm` a été modifié, reconstruisez le `.wasm` avant de lancer les tests Tizen : `./scripts/build-tizen.sh`.

---

## 4. Hygiène sécurité et vérification des secrets

Avant chaque commit ou Pull Request, exécutez impérativement :

```bash
./scripts/check-secrets.sh
./scripts/test-gen-default-keys.sh
```

Assurez-vous également qu'aucun fichier `.env`, certificat (`.p12`, `.mobileprovision`), keystore (`.keystore`, `.jks`), fichier swap (`.swp`) ou chemin local personnel (`/Users/...`) n'a été ajouté.

---

## 5. Format des commits et Pull Requests

Les messages de commit suivent le standard **Conventional Commits** en anglais, avec un sujet clair et ciblé :

- `feat(tizen): add EPG start-over confirmation dialog`
- `fix(core): prevent duplicate connection on fast channel zap`
- `docs: update Tizen store checklist`
- `perf(apple): avoid redundant SQLite writes on progress tick`
- `test(android): verify household sync parity vectors`

---

## 6. Licence des contributions

Buntu est distribué sous double licence **MIT OR Apache-2.0** (`LICENSE`, `LICENSE-MIT`, `LICENSE-APACHE`). En soumettant une contribution, vous acceptez qu'elle soit diffusée sous ces mêmes conditions.
