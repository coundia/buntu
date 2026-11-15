# Guide de Release Multiplateforme — Buntu

Ce guide décrit la procédure complète pour vérifier, compiler, signer et publier une release unifiée de **Buntu** (`1.2.0`, build `3`) pour **Samsung Smart TV (Tizen)**, **macOS** et **Android / Android TV** sur [`https://github.com/coundia/buntu`](https://github.com/coundia/buntu).

> [!IMPORTANT]
> Les builds d'application complets et la génération des paquets de release sont déclenchés manuellement par le mainteneur (ou via le workflow GitHub Actions dédié). Vérifiez systématiquement les secrets et les tests unitaires avant de générer les binaires finaux.

---

## 1. Vérifications pré-release

Avant de produire les paquets dans `build/release/v1.2.0/`, exécutez les contrôles suivants depuis la racine du dépôt :

### 1.1 Contrôle des secrets et fichiers sensibles

```bash
./scripts/check-secrets.sh
./scripts/test-gen-default-keys.sh
```

- `check-secrets.sh` vérifie que `.env` n'est pas suivi par Git, qu'aucune clé d'API, aucun chemin personnel local absolu ni aucun fichier sensible (`.p12`, `.keystore`, `.jks`, `.mobileprovision`, `.swp`) n'est présent dans les fichiers versionnés. La sortie attendue est `secrets check: clean`.

### 1.2 Tests unitaires et analyse statique

```bash
# 1. Cœur Rust (clippy strict + tests métier purs)
cargo clippy --workspace --all-targets -- -D warnings
cargo test -p cnd-domain
cargo test --workspace --release

# 2. Apple (SwiftPM)
(cd apple && swift test)

# 3. Android & Android TV (JVM + architecture SRP + lint)
(cd android && ./gradlew testDebugUnitTest :core:domain:test lintDebug)

# 4. Samsung Smart TV (TypeScript + Vitest)
(cd tizen && npx tsc --noEmit && npm test)
```

> [!NOTE]
> Sur macOS, `task check` exécute également la validation complète Rust + XCFramework + Swift + `xcodebuild` Release (`CndIPTV-macOS` et `CndIPTV-iOS`). Consultez [`Taskfile.yml`](../Taskfile.yml) pour le détail.

### 1.3 Simulation à blanc (`--dry-run`)

Vérifiez les étapes, commandes et chemins de sortie sans lancer aucune compilation :

```bash
./scripts/prepare-releases.sh --dry-run
# ou via go-task :
task release:dry-run
```

---

## 2. Script unifié & tâches `Taskfile.yml`

La préparation des artefacts est centralisée dans [`scripts/prepare-releases.sh`](../scripts/prepare-releases.sh) et exposée via [`Taskfile.yml`](../Taskfile.yml) :

| Commande `task` | Équivalent script | Cibles générées |
| :--- | :--- | :--- |
| `task release` | `./scripts/prepare-releases.sh --all` | Tizen + macOS + Android + `SHA256SUMS.txt` |
| `task release:tizen` | `./scripts/prepare-releases.sh --tizen` | Paquets `.wgt` Tizen + `SHA256SUMS.txt` |
| `task release:macos` | `./scripts/prepare-releases.sh --macos` | `.zip` et `.dmg` macOS + `SHA256SUMS.txt` |
| `task release:android` | `./scripts/prepare-releases.sh --android` | APK Android par ABI + universel + `SHA256SUMS.txt` |
| `task release:dry-run` | `./scripts/prepare-releases.sh --all --dry-run` | Affichage du plan sans compilation |

Options prises en charge par [`scripts/prepare-releases.sh`](../scripts/prepare-releases.sh) :
- `--all` : prépare toutes les plateformes (comportement par défaut).
- `--tizen` : prépare uniquement les paquets Samsung Tizen.
- `--macos` : prépare uniquement les paquets macOS (`.zip` et `.dmg`).
- `--android` : prépare uniquement les APK Android / Android TV.
- `--skip-core` : réutilise l'XCFramework Apple ou les bibliothèques JNI Android déjà compilées sans relancer `build-xcframework.sh` / `build-android.sh`.
- `--dry-run` : affiche toutes les commandes et chemins cibles sans exécuter les builds.
- `-h`, `--help` : affiche l'aide du script.

Tous les artefacts sont regroupés dans `build/release/v1.2.0/`.

---

## 3. Release Samsung Smart TV (`Buntu_1.2.0_Tizen.wgt`)

### Prérequis
- **Tizen Studio** installé avec **TV Extensions** et **Samsung Certificate Extension** (`tizen` dans le `PATH`, par exemple `$HOME/tizen-studio/tools/ide/bin`).
- Outils de build : `node`, `npm`, `wasm-pack`, `wasm-opt` (`binaryen`), `zip`.
- Un profil de certificat **Samsung Public / Distributor** configuré dans le **Certificate Manager** de Tizen Studio (le profil *Developer* sert uniquement aux tests locaux sur votre propre téléviseur).

### Génération et signature

```bash
export PATH="$PATH:$HOME/tizen-studio/tools:$HOME/tizen-studio/tools/ide/bin"
TIZEN_PROFILE="<NOM_DU_PROFIL_SAMSUNG>" task release:tizen
```

Vous pouvez aussi invoquer directement :

```bash
TIZEN_PROFILE="<NOM_DU_PROFIL_SAMSUNG>" ./scripts/prepare-releases.sh --tizen
# ou le script Tizen seul :
TIZEN_PROFILE="<NOM_DU_PROFIL_SAMSUNG>" ./scripts/build-tizen.sh --prod
```

Le mode `--prod` compile `crates/cnd-domain-wasm` en **WebAssembly 1.0 MVP strict** (`wasm-opt --mvp-features`), assemble le bundle Vite compatible Chromium 56+, supprime la métadonnée `devel.mode` du `config.xml` empaqueté et signe le paquet via `tizen package -t wgt`.

`prepare-releases.sh` copie le résultat dans `build/release/v1.2.0/` sous deux noms :
- `Buntu_1.2.0_Tizen.wgt` (format attendu par le pré-test du Samsung Apps TV Seller Office) ;
- `Buntu-1.2.0-tizen.wgt` (nommage homogène pour GitHub Releases).

### Contrôle obligatoire de l'archive `.wgt`

Vérifiez impérativement l'absence de `devel.mode` et la présence des fichiers de signature dans l'archive générée :

```bash
unzip -p build/release/v1.2.0/Buntu_1.2.0_Tizen.wgt config.xml | grep -i "devel.mode" || echo "OK: devel.mode absent"
unzip -l build/release/v1.2.0/Buntu_1.2.0_Tizen.wgt | grep -E "author-signature.xml|signature1.xml|config.xml"
```

Les deux fichiers `author-signature.xml` et `signature1.xml` doivent apparaître dans la sortie, et `devel.mode` ne doit renvoyer aucune correspondance. Pour le détail complet de la soumission sur le Seller Office, consultez [`docs/DEPLOY_TIZEN_STORE.md`](DEPLOY_TIZEN_STORE.md).

---

## 4. Release macOS (`Buntu-1.2.0-macOS.dmg` et `.zip`)

### Génération standard (signature locale ad-hoc)

```bash
task release:macos
# ou, si cnd_coreFFI.xcframework est déjà à jour :
./scripts/prepare-releases.sh --macos --skip-core
```

Ce pipeline effectue les opérations suivantes :
1. Exécute `./scripts/run-macos.sh --release --build-only` (avec `--rebuild-core` sauf si `--skip-core` est passé) pour assembler `build/CndIPTV.app` (`CFBundleShortVersionString = 1.2.0`, `CFBundleVersion = 2`).
2. Copie et renomme le bundle en `Buntu.app` dans un dossier de staging temporaire.
3. Crée `build/release/v1.2.0/Buntu-1.2.0-macOS.zip` via `ditto -c -k --sequesterRsrc --keepParent`.
4. Crée `build/release/v1.2.0/Buntu-1.2.0-macOS.dmg` via `hdiutil create -volname "Buntu" -srcfolder ... -ov -format UDZO`.

### Signature Developer ID & archives Apple (`DEVELOPMENT_TEAM`)

- Par défaut, [`scripts/run-macos.sh`](../scripts/run-macos.sh) applique une signature locale ad-hoc (`codesign --force --sign -`) adaptée à une exécution sur la machine de développement.
- Pour une distribution signée avec votre compte Apple Developer (macOS et iOS), utilisez la variable `DEVELOPMENT_TEAM` :

```bash
# Archive Xcode macOS signée (build/archives/CndIPTV-macOS.xcarchive)
task app:macos DEVELOPMENT_TEAM="<YOUR_APPLE_TEAM_ID>"

# Archive Xcode iOS signée (build/archives/CndIPTV-iOS.xcarchive)
task app:ios DEVELOPMENT_TEAM="<YOUR_APPLE_TEAM_ID>"
```

- Pour diffuser publiquement un `.dmg` / `.zip` macOS en dehors du Mac App Store sans avertissement Gatekeeper sur d'autres Mac, signez `Buntu.app` avec un certificat **Developer ID Application** puis soumettez le paquet à la notarisation Apple (`xcrun notarytool submit` / `xcrun stapler staple`) avant d'assembler les archives finales.
- Les versions `1.2.0` (`build 3`) sont également alignées dans [`apple/Resources/Info-macOS.plist`](../apple/Resources/Info-macOS.plist), [`Info-iOS.plist`](../apple/Resources/Info-iOS.plist), [`Info-tvOS.plist`](../apple/Resources/Info-tvOS.plist), [`Info-visionOS.plist`](../apple/Resources/Info-visionOS.plist) et [`AppBrand.swift`](../apple/Sources/CndIptvKit/Shared/Design/AppBrand.swift).

---

## 5. Release Android & Android TV (`Buntu-1.2.0-android-*.apk`)

### Variables de signature (optionnelles en local)

[`android/app/build.gradle.kts`](../android/app/build.gradle.kts) lit automatiquement les 4 variables suivantes (via variables d'environnement ou propriétés Gradle) pour signer le build `release` (`versionCode = 3`, `versionName = "1.2.0"`) :

| Variable | Rôle |
| :--- | :--- |
| `BUNTU_KEYSTORE_FILE` | Chemin vers le fichier `.keystore` ou `.jks` |
| `BUNTU_KEYSTORE_PASSWORD` | Mot de passe du keystore |
| `BUNTU_KEY_ALIAS` | Alias de la clé de signature |
| `BUNTU_KEY_PASSWORD` | Mot de passe de la clé |

> [!TIP]
> **Repli debug automatique :** si `BUNTU_KEYSTORE_FILE` n'est pas défini, Gradle bascule automatiquement sur la configuration `debug` locale afin de permettre la génération d'APK release minifiés (R8) sans bloquer les tests locaux. Pour toute publication publique ou sur Google Play, fournissez un keystore de release dédié (jamais versionné).

### Génération des APK

```bash
export BUNTU_KEYSTORE_FILE="/chemin/vers/buntu-release.keystore"
export BUNTU_KEYSTORE_PASSWORD="<mot_de_passe>"
export BUNTU_KEY_ALIAS="<alias>"
export BUNTU_KEY_PASSWORD="<mot_de_passe_cle>"

task release:android
# ou sans recompiler les bibliothèques Rust .so déjà présentes :
./scripts/prepare-releases.sh --android --skip-core
```

Le script exécute `./scripts/build-android.sh` (sauf `--skip-core`), lance `(cd android && ./gradlew assembleRelease)` et copie les 4 APK générés dans `build/release/v1.2.0/` :
- `Buntu-1.2.0-android-arm64-v8a.apk` (smartphones, tablettes et Android TV 64 bits modernes)
- `Buntu-1.2.0-android-armeabi-v7a.apk` (appareils et boîtiers Android 32 bits)
- `Buntu-1.2.0-android-x86_64.apk` (émulateurs, ChromeOS, PC x86_64)
- `Buntu-1.2.0-android-universal.apk` (APK universel multi-ABI)

---

## 6. Vérification des empreintes & publication sur GitHub Releases

### 6.1 Empreintes SHA-256 (`SHA256SUMS.txt`)

À la fin de l'exécution, `scripts/prepare-releases.sh` génère `build/release/v1.2.0/SHA256SUMS.txt` via `shasum -a 256` et affiche un récapitulatif des artefacts produits :

```text
build/release/v1.2.0/
├── Buntu_1.2.0_Tizen.wgt
├── Buntu-1.2.0-tizen.wgt
├── Buntu-1.2.0-macOS.zip
├── Buntu-1.2.0-macOS.dmg
├── Buntu-1.2.0-android-arm64-v8a.apk
├── Buntu-1.2.0-android-armeabi-v7a.apk
├── Buntu-1.2.0-android-x86_64.apk
├── Buntu-1.2.0-android-universal.apk
└── SHA256SUMS.txt
```

Vérifiez l'intégrité des fichiers avant téléversement :

```bash
(cd build/release/v1.2.0 && shasum -a 256 -c SHA256SUMS.txt)
```

### 6.2 Publication automatisée via GitHub Actions

Le dépôt inclut le workflow [`.github/workflows/release.yml`](../.github/workflows/release.yml) qui prépare et publie les artefacts de release sur `https://github.com/coundia/buntu/releases` dans deux cas :

1. **Poussée d'un tag de version (`v*`)** :
   ```bash
   git tag -a v1.2.0 -m "Release v1.2.0"
   git push origin v1.2.0
   ```
2. **Déclenchement manuel (`workflow_dispatch`)** depuis l'onglet **Actions** de GitHub.

### 6.3 Publication ou complément manuel (`gh release`)

Si vous signez les paquets localement (notamment `Buntu_1.2.0_Tizen.wgt` avec votre profil Samsung privé, ou des binaires macOS/Android signés avec vos certificats locaux), vous pouvez créer ou compléter la release avec GitHub CLI :

```bash
gh release create v1.2.0 build/release/v1.2.0/* \
  --title "Buntu v1.2.0" \
  --notes-file CHANGELOG.md
```

---

## 7. Avant de rendre le dépôt public et de publier la première release

Ces étapes se font sur GitHub, hors du dépôt : elles ne sont pas automatisées.

### 7.1 Contrôles locaux (déjà couverts par le CI)

```bash
./scripts/check-version.sh        # même version et même numéro de build sur Cargo, Android, Apple et Tizen
./scripts/check-secrets.sh        # aucun secret, keystore ou chemin local, fichiers neufs compris
./scripts/prepare-releases.sh --all --dry-run
```

Pour une nouvelle version : modifier **tous** les emplacements que `check-version.sh` lit (`Cargo.toml`,
`android/app/build.gradle.kts`, `SettingsScreen.kt` (Android, page « À propos »), les quatre `apple/Resources/Info-*.plist`,
`AppBrand.swift`, `scripts/run-macos.sh`, `tizen/config.xml`, `tizen/package.json` et `package-lock.json`,
`tizen/src/core/appInfo.ts`) ; les tests qui citent la version suivent (`AppBrandTests`, `SettingsViewModelTest`,
`TizenNiceToHave.test.ts`), puis relancer le script jusqu'à `version check: … on every platform`.

### 7.2 Historique Git

L'historique (171 commits) a été **scanné** avec des motifs de secrets (clés OpenAI, Anthropic, Google, AWS, jetons GitHub,
clés privées) et par nom de fichier (`.env`, `.p12`, `.jks`, `.keystore`, `.mobileprovision`, `.pem`) :
aucun secret réel n'y figure. Le seul fichier sensible par son nom, `docs/.DEPLOY_TIZEN_STORE.md.swp` (fichier d'échange
d'éditeur, 16 Ko), y reste ; son texte n'évoque que le script de contrôle des secrets. Il peut être purgé avec
`git filter-repo` pour un historique sans lui. Ce scan ne remplace pas un outil dédié (gitleaks, GitHub secret scanning).
Les adresses e-mail d'auteur des commits restent visibles dans l'historique.

### 7.3 Réglages du dépôt GitHub

- **Settings → Security** : activer *Private vulnerability reporting*, *Dependabot alerts* et *Secret scanning* avec
  *Push protection*.
- **Settings → Branches** : protéger `main` (CI `Secrets & Default Keys`, `Rust`, `Samsung TV Tizen` et `Android`
  obligatoires avant fusion).
- **Settings → Actions → General** : limiter les workflows aux actions de GitHub et aux actions déjà utilisées ici,
  et demander une approbation pour les PR de contributeurs externes.
- **Settings → Secrets and variables → Actions** : ajouter, **si** vous voulez des APK signés avec votre clé :
  `BUNTU_KEYSTORE_BASE64`, `BUNTU_KEYSTORE_PASSWORD`, `BUNTU_KEY_ALIAS`, `BUNTU_KEY_PASSWORD`. Sans eux, les APK sont
  signés avec la clé de debug (le workflow l'indique dans les notes de version).

### 7.4 Limites connues des artefacts produits par GitHub Actions

| Plateforme | Ce que produit le workflow | À faire en local pour une vraie distribution |
| :--- | :--- | :--- |
| Android | APK signés avec la clé de debug si aucun keystore n'est configuré | Fournir le keystore de release (7.3) |
| macOS | `.app` signée en ad-hoc, non notariée (avertissement Gatekeeper) | Certificat Developer ID et notarisation (section 4) |
| Samsung TV | `.wgt` **non signé** (`-unsigned`), refusé par une TV | `TIZEN_PROFILE=… task release:tizen` avec votre certificat Samsung (section 3) |
| iOS, tvOS, visionOS | Aucun : non produits par le workflow | `task app:ios` avec `DEVELOPMENT_TEAM` |

Ces workflows n'ont **pas été exécutés sur GitHub** depuis leur mise à jour (le YAML est valide, mais rien ne l'a joué) :
surveiller le premier passage de `CI` (le job `android` est le moins éprouvé), puis lancer `Release` en
`workflow_dispatch` avec `draft` coché avant de pousser un tag.

### 7.5 Licences tierces

Lire [`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md) avant la première publication, en particulier le point 1 :
MPVKit (LGPL-3.0) est lié statiquement aux apps Apple, ce qui demande une décision sur l'App Store.

### 7.6 Publier

```bash
git tag -a v1.2.0 -m "Release v1.2.0"
git push origin v1.2.0      # déclenche .github/workflows/release.yml (échoue si le tag ≠ Cargo.toml)
```
