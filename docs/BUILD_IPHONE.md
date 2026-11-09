# Compiler et lancer l'app sur un iPhone

Ce guide explique comment installer CND IPTV sur un iPhone (ou iPad) branché au Mac, avec un compte Apple Developer gratuit ou payant.

## En bref

```bash
task run:iphone
```

La commande détecte l'appareil branché, compile, signe, installe et lance l'app. Tout ce qui suit sert à la première mise en place et au dépannage.

## 0. Après un clone

Le XCFramework du cœur Rust (`apple/Packages/CndCoreBridge/cnd_coreFFI.xcframework`, environ 440 Mo) **n'est pas dans git** : il se construit sur votre Mac. Une seule commande prépare tout (outils, `.env`, XCFramework, projet Xcode, dépendances de la TV) :

```bash
task init
```

Elle dure plusieurs minutes la première fois et ne refait que ce qui manque (`FORCE=1 task init` reconstruit le XCFramework).

## 1. Prérequis

| Élément | Détail |
|---|---|
| Mac | macOS avec **Xcode** installé (`xcode-select -p` doit pointer vers Xcode) |
| Outils | `task` (go-task), `xcodegen`, Rust avec les cibles iOS (`task doctor` vérifie tout) |
| Compte Apple | Un Apple ID connecté dans Xcode (**Réglages > Comptes**). Un compte gratuit suffit pour installer sur son propre appareil |
| iPhone | iOS 17 ou plus récent, branché en USB ou sur le même Wi-Fi (appairé dans Xcode) |

### Préparer l'iPhone (une seule fois)

1. **Mode développeur** : Réglages > Confidentialité et sécurité > Mode développeur > activer, puis redémarrer.
2. **Faire confiance à ce Mac** : branchez l'iPhone, déverrouillez-le et touchez « Se fier » à l'invite.
3. Première installation avec un compte gratuit : Réglages > Général > VPN et gestion de l'appareil > votre compte développeur > « Faire confiance ».

Vérifier que l'appareil est vu :

```bash
task iphone:devices
```

## 2. Lancer l'app

```bash
task run:iphone                        # premier appareil connecté, build Debug
task run:iphone DEVICE="icnd 14"       # choisir un appareil par son nom ou son UDID
task run:iphone:release                # build optimisé
```

Ou directement le script, qui a plus d'options :

```bash
./scripts/run-iphone.sh --help
./scripts/run-iphone.sh --rebuild-core   # reconstruit d'abord le cœur Rust (XCFramework)
./scripts/run-iphone.sh --no-launch      # installe sans lancer
./scripts/run-iphone.sh --list           # liste les appareils
```

Le script fait, dans l'ordre :

1. détecte l'appareil iOS connecté (`xcrun devicectl`) ;
2. régénère le projet Xcode depuis `apple/project.yml` (`xcodegen`) ;
3. compile le scheme `CndIPTV-iOS` pour l'appareil, avec signature automatique ;
4. installe l'app (`devicectl device install app`) ;
5. la lance (`devicectl device process launch`).

Les fichiers de build vont dans `build/DerivedData-device/` (ignoré par git).

## 3. Signature

- L'équipe de développement se règle avec la variable `DEVELOPMENT_TEAM` (identifiant à 10 caractères visible dans Xcode > Réglages > Comptes > Détails). Par défaut, le script utilise celle du projet.

  ```bash
  DEVELOPMENT_TEAM=ABCDE12345 task run:iphone
  ```

- L'identifiant de l'app iOS est `com.pcoundia.buntu` (voir `apple/project.yml`). Il doit être unique pour votre équipe : changez-le si Xcode répond « Bundle identifier is not available ».
- Un compte gratuit signe pour 7 jours : passé ce délai, relancez `task run:iphone` pour réinstaller.
- L'option `-allowProvisioningUpdates` laisse Xcode créer ou renouveler le profil de provisionnement tout seul.

## 4. Si vous modifiez le cœur Rust

L'app iPhone embarque le cœur Rust sous forme de XCFramework. Après un changement dans `crates/` ou de l'API UniFFI :

```bash
./scripts/run-iphone.sh --rebuild-core
```

(équivalent à `./scripts/build-xcframework.sh`, puis le build normal). Sans cela, l'app Swift ne voit pas les nouvelles fonctions.

## 5. Ce qui diffère du Mac

- **Lecteur** : `libmpv` (MPVKit) est lié statiquement à l'app iPhone, donc **MKV, AVI, FLV et TS** se lisent dans l'app. `AVPlayer` reste utilisé pour les formats qu'il lit seul.
  - Le code nomme explicitement les fonctions de libmpv (`MpvLibrary.linkedSymbols`) : sans cela l'éditeur de liens les supprimait et l'app affichait « libmpv introuvable ».
  - Les films et épisodes lus par mpv passent par un relais local du cœur Rust (`relay.rs`) : une seule connexion au serveur à la fois. Sans lui, un abonnement limité à une connexion répond `429 Connection limit reached` dès que mpv saute dans le fichier (lecture de l'index d'un MKV).
  - Si le moteur manque malgré tout, un message l'indique et le bouton « Ouvrir dans une autre app » propose VLC, Infuse ou Outplayer.
- **iCloud** : désactivé avec un compte développeur gratuit (pas de droit iCloud). L'app fonctionne en local ; la clé `CndCloudKitContainerIdentifier` est volontairement absente de `Info-iOS.plist`. Ne la remettez que si l'entitlement iCloud est signé, sinon l'app plante au lancement.
- **Réseau local** : l'envoi de sources entre appareils (Sources > « Envoyer vers l'iPhone » / « Recevoir depuis un autre appareil… ») demande l'autorisation « Réseau local » au premier usage. Les deux appareils doivent être sur le même Wi-Fi.

## 6. Dépannage

| Symptôme | Cause et solution |
|---|---|
| `no connected iPhone/iPad` | Branchez, déverrouillez, touchez « Se fier ». Vérifiez `task iphone:devices`. |
| « Installed, but the device is locked » | L'app est installée : déverrouillez l'iPhone et ouvrez-la, ou relancez la commande. |
| `Developer Mode disabled` | Activez le mode développeur (section 1) et redémarrez l'iPhone. |
| Signature : « No profiles for … » ou « Bundle identifier is not available » | Vérifiez `DEVELOPMENT_TEAM`, connectez l'Apple ID dans Xcode, ou changez l'identifiant dans `apple/project.yml`. |
| « Untrusted Developer » au lancement | Réglages > Général > VPN et gestion de l'appareil > faire confiance au compte. |
| L'app se ferme tout de suite | Récupérez le rapport de crash (ci-dessous). Cause déjà rencontrée : clé iCloud présente dans l'Info.plist sans entitlement. |
| `error: … cannot find '…' in scope` après l'ajout d'un fichier Swift | Le projet Xcode n'est pas suivi par git : relancez le script (il le régénère) ou `task xcode:generate`. |
| Aucune chaîne ne se lance | Ouvrez les logs de l'app (bouton Logs) : le diagnostic indique la réponse du serveur (HTTP 429 = limite de connexions du fournisseur, 403 = accès refusé, 404 = contenu retiré). |

### Récupérer un rapport de crash

```bash
UDID=$(./scripts/run-iphone.sh --list | awk 'NR==1{print $1}')
xcrun devicectl device info files --device "$UDID" --domain-type systemCrashLogs | grep -i cnd
xcrun devicectl device copy from --device "$UDID" --domain-type systemCrashLogs \
  --source <nom-du-fichier>.ips --destination /tmp/crash.ips
```

### Lancer en suivant la console

```bash
xcrun devicectl device process launch --device "$UDID" --terminate-existing --console com.pcoundia.buntu
```

## 7. Commandes manuelles (sans le script)

```bash
cd apple
xcodegen generate
xcodebuild -project CndIPTV.xcodeproj -scheme CndIPTV-iOS -configuration Debug \
  -destination 'id=<UDID>' -derivedDataPath ../build/DerivedData-device \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=<TEAM> build
xcrun devicectl device install app --device <UDID> \
  ../build/DerivedData-device/Build/Products/Debug-iphoneos/CndIPTV.app
xcrun devicectl device process launch --device <UDID> --terminate-existing com.pcoundia.buntu
```

## 8. Simulateur iOS

Pour un test sans appareil, `task xcode:ios` compile pour le simulateur (sans signature). Le simulateur ne lit pas tous les flux comme un vrai iPhone et ne permet pas de tester l'envoi à proximité ni la signature.
