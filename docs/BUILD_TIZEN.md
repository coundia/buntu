# Guide de Build & Déploiement Samsung Smart TV (Tizen 3.0+)

Ce document décrit comment compiler, tester, empaqueter et installer l'application native **Buntu** (`cnd001iptv`) pour les téléviseurs **Samsung Smart TV (Tizen 3.0 à Tizen 8.0+, modèles 2017 à 2025+)**, conformément au [`PRD-38`](../PRD/38_TIZEN_SAMSUNG_TV_APP.md).

---

## 1. Prérequis & Outillage

1. **Node.js 20+** et **npm** :
   ```bash
   node -v && npm -v
   ```
2. **Rust & cible WebAssembly** :
   ```bash
   rustup target add wasm32-unknown-unknown
   ```
3. **wasm-pack & binaryen (`wasm-opt`)** :
   ```bash
   # Sur macOS via Homebrew :
   brew install wasm-pack binaryen
   ```
4. **Samsung Tizen Studio & CLI (Optionnel pour le build, requis pour déploiement direct)** :
   - Télécharger [Tizen Studio avec IDE](https://developer.samsung.com/smarttv/develop/development-tools/tizen-studio/download.html).
   - Installer l'extension **Samsung Certificate Extension** et **TV Extensions** via le *Package Manager* de Tizen Studio.
   - Ajouter `tizen` et `sdb` (Smart Development Bridge) à votre `PATH` :
     ```bash
     export PATH="$PATH:$HOME/tizen-studio/tools:$HOME/tizen-studio/tools/ide/bin"
     ```

---

## 2. Architecture de l'Application Tizen (`tizen/`)

L'application repose sur une architecture sans framework lourd (zéro React/Angular), optimisée pour les processeurs ARM TV à faible TDP :

| Composant | Technologie | Rôle & Responsabilité (SRP) |
| :--- | :--- | :--- |
| **Interface Salon (10-foot)** | **SolidJS + TypeScript** | Réactivité à grain fin sans Virtual DOM, mises à jour DOM chirurgicales, zéro ré-exécution de composant. |
| **Rétrocompatibilité** | `@vitejs/plugin-legacy` | Support natif des moteurs Chromium 56+ (Tizen 3.0 / 2017) avec injection automatique des polyfills ES2015. |
| **Règles métier & IA** | **`cnd-domain-wasm`** | Cœur Rust compilé en Wasm (1.5 Mo brut, 578 Ko gzip) exécuté dans un **Web Worker** dédié : analyse M3U/XMLTV, ranking de recherche, recommandations de sagas. |
| **Persistance locale** | **IndexedDB** | Base de données locale persistante (sources, items, favoris, historique, profils) avec recherche rapide indexée. |
| **Lecteur Vidéo Matériel** | **Samsung AVPlay (`webapis.avplay`)** | Décodage matériel 4K HDR10/HLG, gestion des pistes audio et sous-titres avec décalage de synchronisation, gestionnaire de veille TV (`suspend` / `restore`). |
| **Gestion Réseau Mono-Connexion** | `HttpClient.ts` | File d'attente séquentielle, résolution transparente des redirections CDN via `Range: bytes=0-0`, et temporisation adaptative sur erreur HTTP `429 Too Many Requests`. |
| **Navigation Spatiale Télécommande** | `RemoteKeyHandler.ts` + `SpatialNav.ts` | Capture des touches Tizen (`tizen.tvinputdevice.registerKey`), gestion du focus D-Pad, touches Ch+/Ch-, pavé numérique, raccourcis couleur et marges d'overscan 5%. |

---

## 3. Déployer sur une TV Samsung

Pour une première installation, configurez le mode développeur et le profil de signature Samsung en suivant la section 4. Depuis la racine du dépôt, remplacez l’adresse dans cet exemple par l’IP affichée sur votre téléviseur.

```bash
task tizen:install TV_IP="192.168.1.50"
```

Cette commande compile le WebAssembly et le bundle web, signe le paquet avec le profil Tizen actif (ou celui indiqué par `TIZEN_PROFILE`), puis installe et lance Buntu. Le paquet est généré dans `build/tizen/cnd-iptv-tizen.wgt`.

Pour réinstaller un paquet de test déjà signé pour cette TV, vérifiez que le fichier existe, puis lancez la commande suivante. Si le paquet manque, le script relance la compilation.

```bash
task tizen:install TV_IP="192.168.1.50" NO_BUILD=1
```

Ajoutez `NO_LAUNCH=1` pour installer sans lancer Buntu. Au premier lancement, vérifiez la navigation à la télécommande et l’image et le son en lecture.

Autres commandes depuis la racine du dépôt :

- `task tizen:test` lance les tests unitaires Tizen.
- `task tizen:build` génère le paquet de test. Si la CLI `tizen` est absente, le paquet est une archive non signée destinée à l’inspection.

Pour publier Buntu sur la boutique Samsung, suivez le [guide de soumission au Samsung Apps TV Store](DEPLOY_TIZEN_STORE.md). Le build de publication écrit au même emplacement que le build de test. Conservez une copie du paquet de publication avant de relancer un build local.

---

## 4. Configuration du Téléviseur Samsung (Mode Développeur)

Pour installer et tester l'application sur un téléviseur physique Samsung :

### Étape 1 : Activer le Developer Mode sur la TV
1. Allumer le téléviseur et appuyer sur le bouton **Home / Smart Hub**.
2. Naviguer vers le panneau **Apps**.
3. Sur la télécommande physique Samsung, taper la séquence numérique suivante :  
   `1` `2` `3` `4` `5`
4. Une fenêtre modale **Developer Mode Configuration** apparaît :
   - Basculer **Developer Mode** sur **On**.
   - Dans le champ **Host PC IP**, saisir l'adresse IP locale de votre ordinateur de développement (ex. `192.168.1.20`).
5. Cliquer sur **OK**.
6. **Redémarrer complètement la TV** : maintenir la touche Power de la télécommande enfoncée jusqu'à ce que le logo Samsung apparaisse, ou débrancher/rebrancher la prise secteur.

### Étape 2 : Connecter `sdb` au téléviseur
Vérifier l'adresse IP du téléviseur dans le menu *Réseau > État du réseau* de la TV, puis exécuter :
```bash
sdb connect 192.168.1.50:26101
sdb devices
```
Remplacez l’adresse de l’exemple par l’IP de la TV. Dans `sdb devices`, vérifiez que cette adresse apparaît avec l’état `device`. Relevez le DUID dans le gestionnaire de certificats Samsung lors de la création du certificat de distribution.

### Étape 3 : Créer et enregistrer les Certificats Samsung
1. Ouvrir le **Certificate Manager** de Tizen Studio :
   - Créer un **Author Certificate** (compte Samsung).
   - Créer un **Distributor Certificate** (sélectionner le privilège *Partner* ou *Public* et ajouter le DUID de votre téléviseur).
2. Définir ce profil de certificat comme profil actif.

---

## 5. Débogage & Profilage à Distance

Pour inspecter la console JavaScript, le DOM SolidJS et surveiller les métriques réseau en direct sur le téléviseur :

1. Lancer l'inspection distante :
   ```bash
   task tizen:debug
   ```
2. Ouvrir Google Chrome sur votre Mac / PC et accéder à :
   ```text
   chrome://inspect
   ```
   ou directement à `http://localhost:9222`.
3. Cliquer sur **Inspect** sous la cible Buntu IPTV pour ouvrir les Chrome DevTools.

---

## 6. Vérifications & Critères de Validation

Avant toute soumission ou mise en production, valider la checklist suivante :

- [x] **Compilation Rust & WebAssembly** : `cargo test -p cnd-domain` passe à 100%, et `wasm-opt -Oz` produit un binaire Wasm compressé < 600 Ko.
- [x] **Build & Polyfills Legacy** : `@vitejs/plugin-legacy` génère correctement les bundles ES2015 pour Chromium 56+.
- [x] **Navigation 100% Télécommande** : Navigation D-Pad fluide, touche Return gérée sans quitter inopinément l'application, raccourcis Ch+/Ch- fonctionnels.
- [x] **Respect du Fournisseur Mono-Connexion** : `HttpClient` résout l'URL finale via `bytes=0-0` avant de la transmettre à AVPlay, empêchant l'ouverture de connexions concurrentes.
- [x] **Cycle de Veille TV** : Mise en veille du téléviseur en cours de lecture et réveil gérés gracieusement par les écouteurs `appcommon.AppCommonScreenSaverState` et `document.addEventListener("visibilitychange")`.


## Voir aussi

- [TIZEN_CONTROLE_A_DISTANCE.md](TIZEN_CONTROLE_A_DISTANCE.md) : installer, lancer, inspecter et piloter l'application sur la TV depuis le Mac (sdb, mode débogage, Chrome DevTools Protocol).
