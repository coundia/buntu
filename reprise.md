# reprise.md — passation à un autre agent IA

> Écrit le 2026-11-07. L'utilisateur parle **français** : répondre en français. Ne pas coder quand il écrit « ne code pas » (PRD seuls).
> Ce fichier est un état des lieux honnête : ce qui est fait, vérifié, **non vérifié**, et ce qui reste.

## 1. Le projet

`cnd-iptv-native` (marque **Buntu**) : lecteur IPTV natif multiplateforme.

| Couche | Où | Rôle |
| :--- | :--- | :--- |
| Cœur Rust | `crates/cnd-core` (SQLite, réseau, IA, relais, téléchargements) | Règles métier avec entrées-sorties, exposé par **UniFFI** (Swift, Kotlin) |
| Domaine pur | `crates/cnd-domain` | Règles sans entrées-sorties (M3U, XMLTV, recherche, recommandations, **pairing**) |
| WebAssembly | `crates/cnd-domain-wasm` | Le domaine pour la TV Samsung (`wasm-bindgen`) |
| Apple | `apple/` (Swift, XcodeGen) | macOS, iPhone/iPad, Apple TV, Vision Pro |
| Android | `android/` (Kotlin, Compose, Hilt, Gradle multi-modules) | Téléphone + Android TV |
| Samsung | `tizen/` (TypeScript, SolidJS, Vite) | Smart TV Tizen 3.0+ (app web + AVPlay) |
| Spécifications | `PRD/00_INDEX_ROADMAP.md` + `PRD/NN_*.md` | PRD 1 à 39 ; l'index donne le statut |

Documents utiles : `docs/BUILD_IPHONE.md`, `docs/BUILD_ANDROID.md`, `docs/BUILD_TIZEN.md`, `docs/PAIRING.md`.

## 2. État git (IMPORTANT)

- Branche `main`, dernier commit `3c0c79c`.
- **~50 fichiers modifiés ou nouveaux, NON commités** (hors binaires du XCFramework, toujours laissés non commités : `apple/Packages/CndCoreBridge/cnd_coreFFI.xcframework/**`). Rien n'a été commité par la session qui écrit ce fichier : **ne rien commiter sans que l'utilisateur le demande**.
- Contenu non commité : tout le **PRD 39** (voir § 4), la **correction de la TV Samsung** (`config.xml`, worker, wasm), `scripts/build-tizen.sh`, plus les index/PRD.
- D'autres personnes/sessions ont modifié le dépôt en parallèle (dossiers `android/`, `tizen/`, PRD 35 à 38 apparus pendant la session). Avant de commiter, faire `git status` et ne stager que ce qui est à soi.

## 3. Commandes de validation (à relancer avant de conclure)

```bash
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace --release -- --skip test_50k --skip test_recommendations_sla   # 319 + 41 tests
cd apple && swift test                                                                 # 509 tests
cd tizen && npm test                                                                   # 21 tests (le .wasm doit être construit : ./scripts/build-tizen.sh)
cd android && ./gradlew --offline :core:platform:testDebugUnitTest :core:data:testDebugUnitTest :core:domain:test :app:testDebugUnitTest
```

Pièges connus :
- `test_recommendations_sla_50k_items` (PRD 27) échoue déjà (~70 ms au lieu de 50) **avant** ces travaux : ne pas le « réparer » en passant.
- `./gradlew testDebugUnitTest` complet peut durer plus de 10 min (module `feature:player`) ; lancer les modules touchés.
- Après tout changement d'API UniFFI : reconstruire le XCFramework (`./scripts/build-xcframework.sh`, ~6 min) **et** les liaisons Kotlin (`./scripts/build-android.sh --bindings-only`, ou sans option pour les `.so`, NDK présent).
- Disque presque plein sur le Mac : supprimer les dossiers `/private/tmp/claude-501/dd-*` après chaque `xcodebuild`.
- Pas de `timeout` ni de `sleep` long sur macOS dans cet environnement (utiliser des boucles `until`).
- Les 4 schémas Xcode : `CndIPTV-iOS`, `CndIPTV-tvOS`, `CndIPTV-macOS`, `CndIPTV-visionOS` (`xcodebuild -project apple/CndIPTV.xcodeproj -scheme … CODE_SIGNING_ALLOWED=NO build`). Après de nouveaux fichiers Swift : `DEVELOPMENT_TEAM=Q6V7UDW27J xcodegen generate` dans `apple/`.

## 4. Travaux de cette session

### 4.1 Recommandations par type (PRD 34) — terminé, validé, déjà dans le dépôt
Films / séries / TV séparés (`crates/cnd-core/src/recommend/{taste,movies,series,live,shelves,ai_rerank}.rs`), affinage IA validé, rangées « Pour vous » côté Swift. Reste : lot 34.5 (modèle Apple sur l'appareil), essai avec un vrai fournisseur IA.

### 4.2 Lecture des `.mkv` sur iPhone — corrigée, **essai réel partiel**
- libmpv (MPVKit) était retiré à l'édition de liens → `MpvLibrary.linkedSymbols()` (`MpvVideoToolboxBackend.swift`) référence les fonctions explicitement (iOS/tvOS/visionOS, pas macOS : conflit de symbole `rust_eh_personality` avec libdovi).
- Relais local **une seule connexion** : `crates/cnd-core/src/relay.rs` (garde l'adresse finale des redirections, ferme l'ancienne connexion avant la nouvelle, réessaie les 429 3 fois). `CndEngine.single_connection_url`, utilisé par `MpvVideoToolboxBackend.addressRewriter`.
- Tampon films, détection de débit insuffisant (`SlowSourceDetector`), bandeau « autre version / télécharger », rendu Metal (`gpu-next`) sur iOS.
- **Contrainte fournisseur de l'utilisateur** : abonnement à **1 connexion** ; un film 4K HEVC (~6 Mbit/s) dépasse le débit du serveur (~2,8 Mbit/s). Les 429/502 observés viennent du fournisseur. Chaque passage par l'adresse d'origine d'un film ouvre une nouvelle session.
- Non vérifié : lecture d'un film jusqu'au bout sur l'iPhone.

### 4.3 PRD 37 (Android) et 38 (Tizen) — PRD écrits ; code présent (autres sessions)
Le code Android/Tizen existait déjà dans le dépôt (commits `22cff68`, `389dad7`) : la session n'en a relu qu'une partie.

### 4.4 **PRD 39 — QR code : ajouter ses comptes sur la TV depuis un téléphone** (le gros du travail non commité)
Spécification : `PRD/39_QR_PAIRING_PHONE_TO_TV.md` (statut à jour en § 12). Guide : `docs/PAIRING.md`.

**Protocole unique, en Rust** : `crates/cnd-domain/src/pairing.rs` (X25519 + HKDF-SHA256 + AES-256-GCM, session à usage unique, expire en 300 s, 3 messages invalides la ferment, clé privée effacée après usage, réponse chiffrée). Pur : l'appelant fournit `entropy` et `now`. Vecteurs partagés : `crates/cnd-domain/src/pairing/vectors.json` (régénérer : `WRITE_PAIRING_VECTORS=1 cargo test -p cnd-domain --release pairing`, ce qui **casse la compatibilité** entre plateformes). Exports : UniFFI (`pairing_*` dans `cnd-core/src/lib.rs`), wasm (`wasm_pairing_*`, `wasm_qr_matrix` dans `cnd-domain-wasm`).

| Plateforme | Fichiers | Statut |
| :--- | :--- | :--- |
| **Samsung (réception)** | `tizen/src/core/pairing/{PairingService,MsfChannel,ShareImport}.ts`, `tizen/src/features/pairing/PairingQr.tsx`, `tizen/src/features/onboarding/{OnboardingView,ManualSourceForm}.tsx` | Code + 9 tests ; **installé sur la TV, QR NON confirmé à l'écran** (voir § 5) |
| **iPhone (envoi)** | `apple/Sources/CndIptvKit/Features/Sharing/{PairToTV,PairToTVSheet}.swift`, `Sources/SourcesListView.swift`, `AppShellView.swift` (`buntu://pair`) | Code + 8 tests, installé sur l'iPhone « icnd 14 » ; **aucun envoi réel essayé** |
| **Android TV (réception)** | `android/core/platform/.../tv/{QrPairingServer,TvPairingCoordinator,SharedSources}.kt`, onboarding + sources | Réécrit (plus de formulaire en clair) ; tests JVM OK |
| **Android téléphone (envoi)** | `android/core/platform/.../phone/PairingSender.kt` | Client seulement : **pas de scanner, pas d'écran, pas de filtre d'intent `buntu://pair`** |
| **Apple TV (réception)** | — | **Non fait** (le téléphone refuse un QR `tls` avec un message clair) |

Transport Samsung vérifié sur la vraie TV (Samsung UN43AU8000BXZA) : le canal `ws://<tv>:8001/api/v2/channels/buntu.pair.<session>` relaie les messages entre clients (60 Ko testés). Android TV : `POST /pair` sur un serveur local. L'app TV se connecte à son propre canal par `127.0.0.1` : **jamais observé à l'écran**.

## 5. Problème en cours (à reprendre en premier)

**Le QR code ne s'affiche pas sur la TV Samsung.** Erreurs successives rapportées par l'utilisateur :
1. « Web Worker not supported in this environment » → cause : worker de type module (Chromium 76 sur Tizen 6 ne sait pas). Corrigé : worker **iife** (`vite.config.ts` `worker.format: 'iife'`), `new Worker(new URL('./index.ts', import.meta.url))` sans `type`, + **repli sur le fil principal** (`tizen/src/worker/worker-bridge.ts`, handlers partagés dans `worker/handlers.ts`).
2. « failed to execute arrayBuffer on response body stream locked » → cause : `instantiateStreaming` de wasm-bindgen échoue sur la TV puis son repli relit une réponse déjà consommée. Corrigé : `handlers.ts` lit les octets lui-même (`fetch` puis XHR) et les passe à `init({ module_or_path })` ; `base: './'` dans Vite.

**Dernier état** : un paquet signé avec ces deux correctifs est installé et lancé sur la TV. L'utilisateur n'a pas encore dit si le QR s'affiche. Si une nouvelle erreur apparaît : demander son texte exact, puis déboguer à distance (`sdb forward` + Chrome DevTools, ou `task tizen:debug`). L'écran de la TV n'est pas visible par l'agent ; `sdb shell 0 debug <appid>` s'est bloqué sans sortie lors d'un essai.

Alternatives déjà ajoutées côté TV : bouton **« Saisir avec la télécommande »** (`ManualSourceForm`, clavier de la TV, Xtream ou M3U) et bouton **« Réessayer »** si le QR échoue. **Non testés à l'écran.**

## 6. Installer sur la TV Samsung (cette machine)

- TV : **UN43AU8000BXZA**, adresse **192.168.1.9** (elle a changé de `.15` à `.9` : la vérifier avec `sdb devices`). Mode développeur activé, « Host PC IP » = Mac (`192.168.1.13`).
- Tizen Studio (version ligne de commande) installé dans `~/tizen-studio` ; certificat Samsung : profil **Buntu** (auteur `~/tizen-studio-data/keystore/author/buntu_author.p12`, mot de passe dans `~/.buntu-tizen-author-password`, **ne jamais l'afficher**). Distributeur Samsung créé par l'utilisateur dans le Certificate Manager (DUID de la TV `41bd6199-12c9-46c6-9c77-f2e382e28cc2`).
- **Toujours** avoir l'outil dans le `PATH` avant de construire, sinon le paquet n'est **pas signé** et la TV répond `Check certificate error` (le script affiche maintenant un avertissement) :

```bash
export PATH="$PATH:$HOME/tizen-studio/tools:$HOME/tizen-studio/tools/ide/bin"
./scripts/build-tizen.sh                                   # wasm-pack + Vite + paquet signé → build/tizen/cnd-iptv-tizen.wgt
sdb connect 192.168.1.9
tizen install -n build/tizen/cnd-iptv-tizen.wgt -t UN43AU8000BXZA   # PAS « sdb install » (non signé)
tizen run -p cnd001iptv.CndIptv -t UN43AU8000BXZA
```

- `tizen/config.xml` : ne pas remettre les attributs `exec`, `entry`, `type`, `ambient-support`, `viewmodes` (causent `Parsing error -19` sur TV).
- Si `sdb connect` échoue : `sdb kill-server && sdb start-server`, vérifier le port 26101 (`nc -z 192.168.1.9 26101`) et redémarrer la TV complètement (débrancher 30 s).

## 7. Installer sur l'iPhone

```bash
./scripts/run-iphone.sh --device "icnd 14" [--no-launch] [--rebuild-core]
xcrun devicectl device process launch --device 00008120-00064CA63698201E --terminate-existing --console com.pcoundia.buntu   # console de l'app
```
Appareil verrouillé = erreur sans gravité à la fin du script. Les journaux de l'app (catégories `PLAYER`, `MPV`, `RECO`…) s'affichent dans la console.

## 8. Reste à faire (par ordre de valeur)

1. **Confirmer le QR sur la TV Samsung**, corriger ce qui bloque encore, puis **essai réel iPhone → TV** (Sources > « + » > « Envoyer vers une TV (QR code)… »). Vérifier ensuite l'import (Xtream passe par `get.php` converti en M3U : `CndEngine.syncXtreamSource`).
2. Android téléphone : déclarer `buntu://pair` dans le manifeste, écran « Envoyer vers une TV » (choix des comptes, mots de passe inclus), scanner (Google code scanner ou CameraX + ML Kit — non présents dans `libs.versions.toml`).
3. Apple TV : écran « Recevoir » tvOS (QR `CIQRCodeGenerator`, Bonjour + TLS-PSK du lot 26.3).
4. Alternatives au QR non faites : code à 6 chiffres (PRD 39 § 6), page web de secours chiffrée sur Android TV (nécessite X25519 + AES-GCM en JavaScript), relais Internet (lot 39.6).
5. Doublons Samsung : « Remplacer » non implémenté ; mots de passe stockés en clair dans IndexedDB (PRD 38 § 6 prévoit KeyManager).
6. Fichiers films : essai de lecture réel d'un `.mkv` sur iPhone ; comportement d'AVPlay lors d'un saut dans un MKV sur Samsung (PRD 38 § 14) ; PiP indisponible avec le rendu Metal d'iOS.
7. PRD 34 lot 34.5 ; tests Swift des rangées « Pour vous » ; builds Xcode après chaque changement.
8. **Commiter** (si l'utilisateur le demande) en deux ou trois commits thématiques : (a) protocole + exports + wasm, (b) Tizen, (c) Apple, (d) Android, (e) PRD/docs. Terminer les messages par la ligne `Co-Authored-By` indiquée par le rappel d'attribution de la session.

## 9. Règles de conduite héritées de la session

- Répondre en français, concis, honnête sur ce qui n'est pas vérifié ; dire explicitement « non essayé à l'écran » quand c'est le cas.
- Ne jamais saisir ni afficher d'identifiants, mots de passe, clés d'API ; l'utilisateur crée lui-même ses comptes (Samsung, etc.).
- Ne pas télécharger de gros fichiers sans l'annoncer (nom, source, taille) ; télécharger dans un dossier à part.
- Demander avant tout geste hors du dépôt (installer des outils, modifier les réglages d'un appareil) ; les installations sur ses appareils (iPhone, TV) ont été faites **à sa demande**.
- Ne pas supprimer le travail des autres : vérifier `git status` avant de toucher aux fichiers non reconnus.
