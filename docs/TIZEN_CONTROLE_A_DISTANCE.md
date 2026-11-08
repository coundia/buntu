# Piloter l'application sur la TV Samsung depuis le Mac

Ce document explique comment l'application Buntu a été installée, lancée, inspectée et **pilotée à distance** sur une vraie TV Samsung (Tizen 6.0, modèle UN43AU8000BXZA) pendant le développement : appuyer sur la télécommande, lire l'écran, mesurer des temps, trouver un bug, sans toucher la télécommande.

Aucun outil magique : trois briques standard, assemblées.

```
Mac                                             TV Samsung
┌────────────────────────┐   sdb (port 26101)   ┌───────────────────────────┐
│ scripts/run-tizen.sh   │ ───────────────────► │ installation, lancement   │
│  tizen package/install │                      │                           │
└────────────────────────┘                      │  Application Buntu        │
┌────────────────────────┐  sdb forward 9222    │  (Chromium 76, mode debug)│
│ script Node            │ ◄──────────────────► │  Web Inspector            │
│  Chrome DevTools       │  WebSocket (CDP)     │                           │
│  Protocol              │                      │  AVPlay (plan vidéo)      │
└────────────────────────┘                      └───────────────────────────┘
```

| Brique | Rôle | Outil |
|---|---|---|
| **sdb** (Smart Development Bridge) | Se connecter à la TV, lancer l'application, ouvrir un port de débogage | `~/tizen-studio/tools/sdb` |
| **Tizen CLI** | Empaqueter, signer et installer le `.wgt` | `~/tizen-studio/tools/ide/bin/tizen` |
| **Chrome DevTools Protocol (CDP)** | Lire la page, exécuter du JavaScript, envoyer des touches, lire la console | un WebSocket, depuis Node |

## 1. Prérequis sur la TV

1. **Mode développeur** activé : Apps, touches `1 2 3 4 5` de la télécommande, « Developer mode » sur **On**, et saisir **l'adresse IP du Mac** (`ipconfig getifaddr en0`). Redémarrer la TV.
2. TV et Mac sur le **même réseau**.
3. Un **certificat** Samsung (profil actif dans Tizen Studio : Certificate Manager). Sans lui, la TV refuse le paquet (« Check certificate error »). Voir [BUILD_TIZEN.md](BUILD_TIZEN.md).

L'adresse IP de la TV **change** (DHCP) : elle a changé plusieurs fois pendant le développement.

## 2. Trouver la TV et se connecter

```bash
export PATH="$PATH:$HOME/tizen-studio/tools:$HOME/tizen-studio/tools/ide/bin"
sdb connect 192.168.1.7:26101
sdb devices        # 192.168.1.7:26101   device   UN43AU8000BXZA
```

Si l'adresse est inconnue, chercher qui expose les ports Samsung (`8001` = canal de la TV, `26101` = sdb) :

```bash
for i in $(seq 2 60); do
  ( nc -z -G 1 192.168.1.$i 26101 2>/dev/null && echo "192.168.1.$i : sdb ouvert" ) &
done; wait
```

Une adresse qui répond au `ping` mais dont `26101` est fermé est une TV **en veille** ou dont le mode développeur est coupé, ou un autre appareil (téléphone) qui a repris l'ancienne adresse. `sdb kill-server && sdb start-server` règle les connexions capricieuses.

## 3. Installer et lancer : `scripts/run-tizen.sh`

```bash
./scripts/run-tizen.sh 192.168.1.7            # construit, signe, installe, lance
./scripts/run-tizen.sh --no-build             # réinstalle le dernier paquet
./scripts/run-tizen.sh --launch-only          # relance sans réinstaller
./scripts/run-tizen.sh --uninstall
./scripts/run-tizen.sh --debug                # lance en mode débogage (voir plus bas)
```

Le script enchaîne : `sdb connect` (avec une nouvelle tentative après redémarrage de sdb), `build-tizen.sh` (Vite, puis `tizen package` qui signe avec le profil actif), arrêt de l'ancienne instance (`sdb shell 0 was_kill <appId>`), `tizen install -n cnd-iptv-tizen.wgt -t <cible>`, puis le lancement. L'identifiant de l'application est `cnd001iptv.CndIptv`. Il mémorise la dernière IP dans `~/.cache/cnd-iptv/last-tv-ip`.

Une installation peut échouer **une fois** sur une erreur de signature sans raison : relancer suffit.

## 4. Le mode débogage : la porte d'entrée

C'est ce qui permet de tout piloter. La TV lance l'application avec un **Web Inspector** (le même que celui de Chrome) sur un port aléatoire, qu'on rend accessible sur le Mac :

```bash
sdb -s 192.168.1.7:26101 shell 0 was_kill cnd001iptv.CndIptv      # l'application ne doit pas déjà tourner
sdb -s 192.168.1.7:26101 shell 0 debug cnd001iptv.CndIptv
#   ... successfully launched pid = 28033 with debug 1 port: 40327
sdb -s 192.168.1.7:26101 forward tcp:9222 tcp:40327               # le port est dans la ligne ci-dessus
curl -s http://localhost:9222/json                                # liste des pages inspectables
```

`./scripts/run-tizen.sh --launch-only --debug` fait ces étapes (arrêt, lancement, lecture du port, `forward`). Points à connaître :

- l'application doit être **arrêtée avant** : sinon la commande `debug` ne renvoie rien ;
- la réponse de `/json` contient l'`id` de la page et son `webSocketDebuggerUrl` (`ws://localhost:9222/devtools/page/<id>`) ;
- **l'`id` change à chaque lancement** : le relire à chaque fois ;
- ouvrir `http://localhost:9222` dans Chrome donne l'inspecteur complet (console, éléments, réseau).

## 5. Piloter par le Chrome DevTools Protocol

Le protocole est du JSON sur un WebSocket. Node 22 ou plus a `WebSocket` en natif (pas de dépendance). Voici l'outil minimal qui a servi pour tous les tests :

```js
// tv-cdp.mjs : node tv-cdp.mjs <idDeLaPage>
const ws = new WebSocket("ws://localhost:9222/devtools/page/" + process.argv[2]);
let n = 0; const pending = {};
const send = (method, params = {}) =>
  new Promise((resolve) => { pending[++n] = resolve; ws.send(JSON.stringify({ id: n, method, params })); });
ws.onmessage = (e) => { const d = JSON.parse(e.data); if (d.id && pending[d.id]) pending[d.id](d.result); };

// exécute du JavaScript dans la page de la TV et renvoie la valeur
const ev = async (expression) => {
  const r = await send("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true });
  if (r.exceptionDetails) console.log("EXC", r.exceptionDetails.exception?.description);
  return r.result?.value;
};
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

// appuie sur une touche de la télécommande
const KEYS = { UP: [38, "ArrowUp"], DOWN: [40, "ArrowDown"], LEFT: [37, "ArrowLeft"],
               RIGHT: [39, "ArrowRight"], ENTER: [13, "Enter"], BACK: [10009, "XF86Back"] };
const press = async (k) => {
  const [code, key] = KEYS[k];
  await send("Input.dispatchKeyEvent", { type: "rawKeyDown", windowsVirtualKeyCode: code, key, code: key });
  await send("Input.dispatchKeyEvent", { type: "keyUp", windowsVirtualKeyCode: code, key, code: key });
  await wait(500);
  return ev('(document.querySelector(".focused") || {}).id');   // où est le curseur ?
};

ws.onopen = async () => {
  console.log(await press("DOWN"));
  process.exit(0);
};
```

### Recettes utilisées

| Besoin | Comment |
|---|---|
| Savoir sur quel écran on est | `ev('document.querySelector(".buntu-toolbar-title").innerText')` |
| Cliquer un élément | `ev('document.getElementById("cat-recent").click()')` |
| Où est le curseur (cadre de sélection) | l'élément `.focused` ; son `id` donne la carte ou le bouton |
| Simuler la télécommande | `Input.dispatchKeyEvent` avec `windowsVirtualKeyCode` (flèches 37 à 40, OK 13, Retour **10009**) |
| Lire la console de la TV | `Runtime.enable`, puis écouter `Runtime.consoleAPICalled` et `Runtime.exceptionThrown` |
| Recharger l'application | `Page.reload` avec `{ ignoreCache: true }` |
| État du lecteur vidéo | `webapis.avplay.getState()` : `NONE`, `IDLE`, `READY`, `PLAYING` |
| Pistes du flux (résolution, codec) | `JSON.stringify(webapis.avplay.getCurrentStreamInfo())` |
| Taille et résolution de l'écran | `innerWidth`, `screen.width`, `devicePixelRatio`, `navigator.userAgent` |
| Qu'est-ce qui recouvre la vidéo | `document.elementsFromPoint(x, y)` puis `getComputedStyle` de chaque élément |
| Lire la base de la TV | ouvrir `indexedDB.open("cnd_iptv_db")` dans la page |
| Mesurer un temps | noter l'heure, appuyer sur la touche, interroger toutes les 50 ms jusqu'au résultat |

Exemple de parcours complet : ouvrir une catégorie, cliquer une chaîne, attendre `PLAYING`, descendre de trois chaînes, vérifier que la lecture continue, passer en plein écran, appuyer sur Retour, vérifier qu'on revient sur la même catégorie.

### Ce que ça a permis de trouver

- **Le menu mal adapté** : mesure sur la TV d'un menu de 1104 px et d'une police de 13 px. Cause : le navigateur de la TV (Chromium 76) ignore `clamp()`.
- **La liste de chaînes vide** : des traces dans la console ont montré que les requêtes partaient avant l'ouverture de la base.
- **Le retour lent** : 3,9 s mesurées, puis 0,7 s après correction.
- **Le cadre de sélection coupé** : 80 cas sur 106 appuis simulés, aucun après correction.
- **Le mini lecteur sans image** : lecture et flux valides (`PLAYING`, vidéo H.264 1080p), zone transparente, plan vidéo bien placé. Le défaut venait du mode d'affichage de la petite fenêtre.

## 6. Pièges rencontrés

- **Chromium 76 sur la TV** : pas de `?.` ni de `??` dans le code évalué avec `Runtime.evaluate` (erreur de syntaxe silencieuse : la valeur renvoyée est `undefined`). Pas de `clamp()`, `aspect-ratio`, `inset`, ni de `gap` en flex dans le CSS. Le projet compense à la construction (`tizen/build-plugins/clampFallback.cjs`).
- **`elementsFromPoint`** peut renvoyer autre chose qu'un élément : filtrer avec `nodeType === 1` avant `getComputedStyle`.
- **Valeur `undefined` sans erreur** : afficher `exceptionDetails` (voir `ev` plus haut).
- **`Page.captureScreenshot` a bloqué** sur la TV. Une capture de toute façon ne contiendrait pas la vidéo (voir limites).
- **L'inspecteur disparaît** quand l'application est relancée ou arrêtée : relancer en mode débogage et relire l'`id` de la page.
- **Les essais se chevauchent** : l'abonnement n'autorise qu'**une connexion** à la fois. Une lecture lancée juste avant un test peut le faire échouer. Attendre quelques secondes ou arrêter le lecteur.
- **Délais** : une chaîne met 3 à 6 s à démarrer. Interroger l'état plutôt que d'attendre un temps fixe.

## 7. Ce qui ne peut pas être vu à distance

L'image vidéo. AVPlay la dessine sur un **plan matériel derrière la page web** : ni le protocole de débogage ni une capture de la page ne la contiennent. Ce qu'on peut vérifier par programme : l'état du lecteur, les pistes décodées, la position et la taille de la zone vidéo, et que rien d'opaque ne la recouvre. Le dernier mot revient à quelqu'un qui regarde l'écran.

Technique utilisée dans ce cas : un test qui tourne sur la TV et change de réglage toutes les 8 secondes, avec une **étiquette à l'écran** (« A », « B », … injectée par `Runtime.evaluate`). Il suffit de dire quelles lettres montrent l'image. C'est ainsi que le bon mode d'affichage a été trouvé.

## 8. Sécurité

- Le **mode développeur** et l'inspecteur ouvert sont accessibles à tout appareil du réseau local qui connaît l'adresse. Les désactiver (mode développeur sur Off, arrêt de l'application) hors développement, et ne pas le faire sur un réseau public.
- Les scripts de test lisent la base de la TV, qui contient les **identifiants du fournisseur IPTV** dans les adresses de flux. Ne jamais les afficher ni les coller dans un rapport ; les tests n'affichent que des noms et des états.
- N'installer que sur **la TV que vous avez désignée**. Une installation sur une adresse que le propriétaire n'a pas confirmée a d'ailleurs été refusée par les garde-fous de l'outil de développement, à raison.

## 9. En résumé, pour reproduire

```bash
./scripts/run-tizen.sh 192.168.1.7                 # installer
./scripts/run-tizen.sh --launch-only --debug       # lancer avec l'inspecteur sur localhost:9222
ID=$(curl -s http://localhost:9222/json | grep -o '"id": "[^"]*"' | head -1 | cut -d'"' -f4)
node tv-cdp.mjs "$ID"                              # le script de la section 5
```
