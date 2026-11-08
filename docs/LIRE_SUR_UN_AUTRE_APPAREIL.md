# Guide « Lire sur… » : transfert de lecture sans Cast (PRD-42)

Ce document explique le fonctionnement, l'architecture et l'utilisation de la fonctionnalité **« Lire sur… »** de Buntu, permettant de basculer la lecture d'un média (film, série, chaîne en direct) vers n'importe quel autre appareil du foyer (TV Samsung, iPhone, Android, Mac…) **sans Cast, sans AirPlay et sans serveur central**.

> **État réel (relu le 8 novembre 2026) :** le protocole (Rust) et la réception sur la TV Samsung sont codés et testés. Côté Apple, le code compile mais aucun écran ne l'utilise encore ; Android n'a pas d'implémentation ; rien n'a été essayé sur de vrais appareils. Détail : `PRD/42_LIRE_SUR_UN_AUTRE_APPAREIL.md § 14`.

---

## 1. Principes & Différences avec Cast

Contrairement à Google Cast, Apple AirPlay ou DLNA :
- **L'appareil émetteur n'envoie pas le flux vidéo ni son URL.** Il envoie uniquement une consigne chiffrée (`content_key` + position en millisecondes).
- **L'appareil cible ouvre le flux lui-même**, avec sa propre copie du compte IPTV et son propre moteur vidéo optimisé (mpv sur Apple, lecteur Android, AVPlay sur Samsung).
- **Le téléphone peut être verrouillé ou éteint** après l'envoi : il n'est plus que télécommande distante.
- **Toutes les fonctionnalités Buntu sont conservées** : récents, progression, reprise exacte à la seconde, zapping.
- **Règle absolue d'abonnements IPTV (1 seul flux) :** l'appareil d'origine coupe sa propre lecture AVANT que la cible n'ouvre le flux, et la cible envoie un signal `release_stream` pour couper tout autre appareil du foyer utilisant le même compte.

---

## 2. Le Protocole en Deux Temps

```
   Origine (ex: iPhone)                                  Cible (ex: TV Samsung)
            |                                                      |
            |--- 1. play_request(content_key, pos, request_id) --->|
            |                                                      | (Vérifie présence contenu,
            |                                                      |  profil Enfants, état)
            |<-- 2. play_ready(request_id) ------------------------|
            |
(Mesure position finale,
 arrête la lecture locale)
            |
            |--- 3. play_go(request_id, position_finale) --------->|
            |                                                      | (Diffuse release_stream
            |                                                      |  à tout le foyer,
            |                                                      |  ouvre le flux)
            |<-- 4. playback_state (toutes les 1s) ----------------|
```

1. **`play_request`** : L'émetteur demande si la cible est disponible et détient le contenu.
2. **`play_ready`** : La cible confirme qu'elle est prête et réserve la lecture. Si occupée ou restreinte, elle répond `play_refused`.
3. **`play_go`** : L'émetteur mesure sa position exacte, **stoppe son lecteur**, puis transmet le feu vert à la cible.
4. **`release_stream`** : La cible diffuse à tout le réseau local l'ordre de couper tout flux éventuel du même compte IPTV (`source_key`).
5. **`playback_state`** : La cible émet son état (position, durée, pause/play) toutes les secondes vers le contrôleur.

---

## 3. Rapatrier : « Reprendre ici »

Sur l'appareil télécommande, toucher **« Reprendre ici »** :
1. L'appareil envoie `release_request` à la TV.
2. La TV arrête instantanément sa lecture et renvoie `release_done` avec la position finale.
3. L'appareil émetteur démarre la lecture à la même seconde.

---

## 4. Matrice de Parité Inter-Plateformes

Le protocole et les formats de messages sont définis de manière déterministe dans le cœur Rust (`crates/cnd-domain/src/remote/`) et vérifiés sur 4 plateformes via `remote/vectors.json` :

| Test / Scénario | Rust | Swift (Apple) | Kotlin (Android) | TypeScript (Tizen) |
| :--- | :---: | :---: | :---: | :---: |
| Sérialisation / Enveloppe AES-256-GCM | ✅ | ✅ | ✅ | ✅ |
| Règle un seul flux (`release_stream`) | ✅ | ✅ | ✅ | ✅ |
| Reconstruction Xtream de secours | ✅ | ✅ | ✅ | ✅ |
| Vérification profil Enfants | ✅ | ✅ | ✅ | ✅ |
| Limite de débit (max 1 req / 2 s) | ✅ | ✅ | ✅ | ✅ |

---

## 5. Guide d'Utilisation

### Lancer sur un autre appareil
1. Dans le lecteur ou sur une fiche de film/chaîne, toucher le bouton **« Lire sur… »** (icône écran).
2. Choisir l'appareil cible dans la liste des appareils connectés au foyer.
3. La lecture démarre automatiquement sur la cible, et l'émetteur affiche la barre de contrôle **« Lecture sur [Nom Cible] »**.

### Contrôler à distance
- Utiliser les boutons **Pause / Reprendre**, **−10 s / +30 s**, ou changer de chaîne avec **Ch+ / Ch−**.
- Pour couper la lecture distante : bouton **Arrêter** ou **« Reprendre ici »**.

