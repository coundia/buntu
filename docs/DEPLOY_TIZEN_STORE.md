# Déploiement de Buntu (Tizen) sur Samsung Apps TV Store

Guide étape par étape pour préparer, signer et soumettre le package `.wgt` de **Buntu** sur le **Samsung Smart TV Seller Office**.

Pour le build et l'installation locale sur votre propre TV en mode développeur, voir [`docs/BUILD_TIZEN.md`](BUILD_TIZEN.md) et [`docs/TIZEN_CONTROLE_A_DISTANCE.md`](TIZEN_CONTROLE_A_DISTANCE.md).

---

## 1. Prérequis

1. **Compte développeur [Samsung Apps TV Seller Office](https://seller.samsungapps.com/tv)** validé pour les applications Smart TV (voir la [documentation Samsung Smart TV](https://developer.samsung.com/smarttv)).
2. **[Tizen Studio](https://developer.tizen.org)** installé avec l'extension **TV Extensions** et **Samsung Certificate Extension** (via le Package Manager de Tizen Studio, CLI `tizen` dans le `PATH`, par défaut `~/tizen-studio/tools/ide/bin`).
3. **Certificat de distribution Samsung (Public / Store)** configuré dans **Tizen Studio Certificate Manager** :
   - Le certificat *Developer* sert uniquement au test local sur votre TV.
   - Pour le store Samsung, créez un profil de certificat **Samsung / Public** (sans DUID limité à une seule TV).
   - Notez le nom exact de ce profil pour la variable `TIZEN_PROFILE`.
4. **Outils de build locaux** : `node`, `npm`, `wasm-pack`, `wasm-opt` (`binaryen`), `zip`.

---

## 2. Vérifications avant le build

1. **Synchroniser la version et le build** (actuellement `1.0.0` / `1`) :
   - [`tizen/src/core/appInfo.ts`](../tizen/src/core/appInfo.ts) (`APP_VERSION`, `APP_BUILD`)
   - [`tizen/config.xml`](../tizen/config.xml) (`<widget ... version="1.0.0">`)
   - [`tizen/package.json`](../tizen/package.json) (`"version": "1.0.0"`)
2. **Lancer la vérification TypeScript et les tests** :
   ```bash
   (cd tizen && npx tsc --noEmit && npm test)
   ```
   Tous les tests doivent passer (aucun échec).
3. **Vérifier l'absence de secrets** depuis la racine du dépôt :
   ```bash
   ./scripts/check-secrets.sh
   ```

---

## 3. Générer le package `.wgt` de production

Utilisez le mode `--prod` (ou `TIZEN_PROD=1`) du script [`scripts/build-tizen.sh`](../scripts/build-tizen.sh) :

```bash
export PATH="$PATH:$HOME/tizen-studio/tools:$HOME/tizen-studio/tools/ide/bin"
TIZEN_PROFILE="<NOM_DE_VOTRE_PROFIL_STORE>" ./scripts/build-tizen.sh --prod
```

Ce que fait `--prod` automatiquement :
1. Compile `crates/cnd-domain-wasm` en **WebAssembly 1.0 MVP strict** (`wasm-opt --mvp-features`) compatible Tizen 3.0+ / Chromium 56+.
2. Compile le bundle web Vite + `@vitejs/plugin-legacy` (`tizen/dist/`).
3. **Retire** `<tizen:metadata key="http://samsung.com/tv/metadata/devel.mode" value="true"/>` du `config.xml` empaqueté dans `build/tizen/wgt_root/config.xml` (sans modifier `tizen/config.xml` pour vos builds de test locaux).
4. **Exige** la présence de la CLI `tizen` et signe le package vers `build/tizen/cnd-iptv-tizen.wgt`.

---

## 4. Contrôler le `.wgt` généré

1. Vérifier que le fichier existe et n'est pas vide :
   ```bash
   ls -lh build/tizen/cnd-iptv-tizen.wgt
   ```
2. Vérifier que `devel.mode` est bien absent et que la signature est présente dans l'archive :
   ```bash
   unzip -l build/tizen/cnd-iptv-tizen.wgt | grep -E "author-signature.xml|signature1.xml|config.xml"
   unzip -p build/tizen/cnd-iptv-tizen.wgt config.xml | grep -i "devel.mode" || echo "OK: devel.mode absent"
   ```
3. Tester ce `.wgt` sur une TV Samsung réelle (voir [`docs/BUILD_TIZEN.md`](BUILD_TIZEN.md)) avant soumission.

---

## 5. Soumission sur Samsung Apps TV Seller Office

1. Connectez-vous au **[Samsung Apps TV Seller Office](https://seller.samsungapps.com/tv)** et créez ou mettez à jour l'application (**Buntu**, ID d’application Tizen `cnd001iptv.CndIptv` dans [`tizen/config.xml`](../tizen/config.xml)).
2. Copiez le paquet signé sous un nom avec des underscores pour le pré-test Samsung, puis téléversez la copie dans **Applications > App Package**. Attendez le résultat **Pass**.

   ```bash
   cp build/tizen/cnd-iptv-tizen.wgt build/tizen/Buntu_Tizen.wgt
   ```
3. Renseignez les métadonnées requises :
   - **Description neutre :** préciser clairement que **Buntu est un lecteur média neutre** qui ne fournit aucun contenu, aucune chaîne et aucune playlist ; l'utilisateur ajoute ses propres sources (Xtream Codes ou M3U).
   - **Visuels et dossier QA** : préparez les éléments d’icône 1920 × 1080, [l’icône PNG 512 × 423 de Buntu](../help/Buntu_512x423.png), des captures JPG 1280 × 720 ou 1920 × 1080 et un descriptif de l’interface en PPTX. Pour tester la lecture, décrivez comment ajouter une source de test autorisée.
   - **Politique de confidentialité :** expliquer que les données (sources, favoris, reprises, clés IA chiffrées localement) restent sur l'appareil ou sur le réseau local du foyer (aucun serveur tiers Buntu).
   - **Justification des privilèges** déclarés dans [`tizen/config.xml`](../tizen/config.xml) :
     - `internet` & `network.public` : lecture des flux ajoutés par l'utilisateur et synchronisation locale du foyer.
     - `tv.inputdevice` & `tv.audio` : gestion de la télécommande Samsung et du contrôle audio.
     - `productinfo` : identification du modèle TV pour l'affichage et les réglages.
     - `application.launch` : comportement de cycle de vie / lancement sur Tizen.

---

4. Dans **Applications > Distribute > Request New Release**, choisissez la version et les groupes de TV. Vérifiez les pays configurés sur la fiche, puis envoyez la demande. Suivez la certification dans Seller Office. En cas de rejet, consultez **Applications > Defect Resolve**.
5. Pour une mise à jour, ouvrez la fiche existante et générez un paquet avec une version supérieure à la version publiée. Téléversez-le puis faites une nouvelle demande de publication.

[Procédure officielle de publication Samsung](https://developer.samsung.com/tv-seller-office/application-publication-process.html) · [Pré-test et nom du paquet](https://developer.samsung.com/tv-seller-office/guides/applications/registering-application.html)

---

## 6. Autocontrôles avant la soumission

Les numéros ci-dessous renvoient à la colonne **No** de l’onglet **List** du [checklist Samsung 3.048](../help/Self_Checklist_3.048.md). Exécuter ces essais sur une TV avec le paquet candidat.

| No | Essai | Résultat attendu |
| --- | --- | --- |
| 7, 12–15, 25 | Avec la télécommande, revenir depuis une sous-page puis depuis l’accueil. Répéter après une coupure réseau, puis essayer Exit. | Retour remonte d’un écran, puis rend la main à Smart Hub. Exit rend la main à la TV. L’image et le son de la TV reprennent normalement. |
| 9 | Avec la protection automatique activée, lire une vidéo au-delà du délai configuré, mettre en pause puis reprendre. | L’économiseur ne se déclenche pas pendant la lecture et redevient disponible en pause et après l’arrêt. |
| 10–11, 16, 19, 21–23, 43–44 | Naviguer pendant un chargement, ouvrir et fermer une fenêtre, saisir et effacer du texte, changer la langue de la TV. | Le focus reste unique et visible, la saisie fonctionne, le chargement se termine et les écrans restent lisibles dans les langues annoncées. |
| 24, 26, 34–42 | Lire au moins cinq contenus autorisés, vérifier le direct et la VOD, déconnecter puis reconnecter le réseau pendant une lecture. | Message visible en cas de coupure, reprise possible, commandes temporelles VOD, volume, format d’image et synchronisation audio/vidéo corrects. |


- **Navigation télécommande uniquement** : flèches, `OK`, `Return` (`10009`), et retour vers Smart Hub depuis l’accueil.
- **Compatibilité navigateur TV** : aucune erreur JS/CSS sur Chromium 56–76 (Tizen 3.0 à 6.0+).
- **Écran À propos** : nom de l'application, version (`APP_VERSION_LABEL`), auteur et mention légale de lecteur neutre visibles dans **Réglages > À propos**.
- **Aucun compte ou flux préchargé** au premier lancement : l'écran d'accueil / onboarding invite l'utilisateur à ajouter ses propres sources.

---

## 7. Liens utiles

- **Portail de soumission Samsung TV :** https://seller.samsungapps.com
- **Documentation Samsung Smart TV Developers :** https://developer.samsung.com/smarttv
- **Portail Tizen Developers (Tizen Studio) :** https://developer.tizen.org
- **Build & installation locale Buntu :** [`docs/BUILD_TIZEN.md`](BUILD_TIZEN.md)
- **Pilotage à distance de la TV :** [`docs/TIZEN_CONTROLE_A_DISTANCE.md`](TIZEN_CONTROLE_A_DISTANCE.md)
- **Script de build & packaging :** [`scripts/build-tizen.sh`](../scripts/build-tizen.sh)
- **Manifeste Tizen :** [`tizen/config.xml`](../tizen/config.xml)
- **Constantes version / build :** [`tizen/src/core/appInfo.ts`](../tizen/src/core/appInfo.ts)
