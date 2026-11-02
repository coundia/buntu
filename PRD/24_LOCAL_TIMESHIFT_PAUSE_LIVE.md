# PRD 24 — Time-shifting local : mettre le direct en pause et revenir en arrière

- **ID :** `PRD-24`
- **Prérequis :** `PRD-08` (Lecteur hybride) ; lot 24.2 : `PRD-19` (capture TS/HLS)
- **Couches impactées :** `Player/MpvVideoToolboxBackend.swift`, `CndPlayerController`, HUD ; lot 24.2 : `Rust (recorder/)`
- **Origine :** `PRD-14` §3.2 et §4.2 (« Circular Ring-Buffer »)
- **Objectif SLA :** pause du direct et retour arrière de **30 min** minimum sans aucun service de replay du fournisseur, reprise **< 500 ms**, espace disque borné (réglable, **2 Go** par défaut).

---

## 1. Contexte & Objectif

Même sans catch-up côté fournisseur (`PRD-15`), l'utilisateur doit pouvoir mettre un direct en pause, revenir 30 s en arrière sur une action, puis rattraper le direct. Deux lots : le premier s'appuie sur le cache de `mpv` (peu de code), le second sur un tampon circulaire du moteur Rust (indépendant du moteur de lecture).

---

## Lot 24.1 — Tampon de `mpv` (prioritaire)

- `mpv` sait garder ce qu'il a déjà lu et y revenir : options `cache=yes`, `demuxer-seekable-cache=yes`, `demuxer-max-back-bytes=<taille>`, `demuxer-max-bytes`, et cache sur disque (`cache-on-disk=yes` / `demuxer-cache-dir=<Caches/CndTimeshift>` — **vérifier les noms d'options dans la version de libmpv embarquée**).
- Activation quand l'utilisateur met un direct en pause (ou en permanence si le réglage « Toujours pouvoir revenir en arrière » est actif).
- **Direct en HLS lu par `AVPlayer`** : `AVPlayer` permet déjà de revenir en arrière dans la fenêtre DVR que le serveur expose ; si elle est absente ou trop courte, proposer de rouvrir la chaîne avec `mpv` (même règle que `PRD-18`).
- **Interface** : en direct, la barre « LIVE » devient une barre de progression sur la fenêtre tamponnée ; badge « −04:12 » quand on est en retard ; bouton « Direct ⏭ » ; ±10 s et pause actifs aussi en direct ; le zapping vide le tampon.
- Les tailles du tampon viennent d'un réglage (Désactivé, 30 min ≈ 1 Go, 1 h ≈ 2 Go, 2 h ≈ 4 Go) ; le dossier est vidé à la fermeture du lecteur et au lancement.

## Lot 24.2 — Tampon circulaire du moteur Rust (facultatif)

- Le module de capture du `PRD-19` écrit le direct regardé dans un **anneau de segments** (fichiers de 10 s environ, coupés sur une frontière de paquet TS de 188 octets, ou segments HLS d'origine), borné en durée et en octets.
- Un **serveur HLS local** (`127.0.0.1`, port aléatoire, jeton dans l'URL) expose cet anneau en playlist `EVENT` : `AVPlayer` comme `mpv` peuvent alors se déplacer dans le tampon.
- À démarrer seulement si le lot 24.1 se révèle insuffisant (moteur `AVPlayer` majoritaire, limites de mpv).

---

## Contraintes Non-Négociables (Guardrails IA)

- Espace disque strictement borné ; suppression systématique du tampon (fermeture, zapping, lancement après plantage).
- Le tampon compte comme la lecture en cours : **aucune connexion supplémentaire** au fournisseur.
- Lot 24.2 : serveur local lié à `127.0.0.1` uniquement, jeton aléatoire par session, aucune donnée exposée sur le réseau local.

## Critères d'Acceptation & Commandes de Validation

1. Lot 24.1 : tests du contrôleur avec un faux backend (pause en direct, retard affiché, « Direct », zapping qui vide le tampon), options mpv appliquées selon le réglage ; essai manuel : pause de 5 min sur une chaîne TS puis reprise et rattrapage.
2. Lot 24.2 : tests Rust de l'anneau (rotation, borne d'octets, coupe sur 188 octets), playlist `EVENT` valide, serveur local inaccessible sans jeton.
3. `task check` au vert.
