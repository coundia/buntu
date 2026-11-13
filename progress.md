# Suivi des tâches des agents IA (`progress.md`)

Ce fichier dit, à tout moment, **ce que les agents IA font dans ce dépôt et où ils en sont**. Plusieurs agents travaillent souvent en même temps (`AGENTS.md § 2.1`) : chacun tient ici ses propres tâches, pour que l'utilisateur et les autres agents sachent ce qui est en cours, fini ou en échec.

## Règles

- **Une section par chantier**, avec la date et l'agent ou la session (« Claude, alignement Android »). On ajoute en haut ; on ne modifie pas la section d'un autre agent.
- **Chaque tâche a un état** :
  - ⏳ en cours ;
  - ✅ terminé ;
  - ❌ échec ;
  - ⏸️ en attente de l'utilisateur ;
  - 🚫 abandonné.

  Une tâche en échec dit pourquoi, en une phrase.
- **Les tâches de fond comptent aussi** : tests, builds, scripts lancés en arrière-plan. Les noter quand on les lance, puis mettre à jour leur état **dès qu'elles se terminent**.
- **Prévenir l'utilisateur** à chaque fin de tâche, réussie ou non, dans la conversation, avec le résultat : « Terminé : tests `:feature:player`, 8/8 ». Ne jamais laisser une tâche se finir en silence.
- **Distinguer vérifié et non vérifié** : « testé unitairement », « compilé », « non essayé sur l'appareil ».
- **Jamais de secret** : ni identifiant, ni mot de passe, ni clé, ni URL de flux.
- Quand un chantier est fini et commité, le résumer en quelques lignes ou le retirer. Le détail durable va dans le PRD concerné ou dans `reprise.md`.

---

## 2026-11-12 — Claude, alignement de l'app Android sur l'app iPhone

Rien n'est commité. Rien n'est essayé sur un téléphone ni sur une Android TV.

| Tâche | État | Détail |
| :--- | :--- | :--- |
| Comparaison des apps iPhone et Android | ✅ | 10 écarts classés. La liste est dans les notes de la session. |
| Lot 1 « lecteur » : fin de lecture, épisode ou film suivant, compte à rebours, « Êtes-vous toujours là ? » | ✅ codé | Le choix du titre suivant est fait en Rust (`next_up`, `recommendations_for`). Les délais d'affichage (3 %, 4 min, 3 enchaînements) sont dans `NextUpTiming.kt`, recopiés d'Apple (`UpNextModel.swift`). À déplacer un jour dans `cnd-domain`. |
| Rangée « À suivre », favori, vitesse de lecture, réglages « À suivre » | ✅ testé | 8 tests du `PlayerViewModel`. |
| Logo Buntu de l'iPhone sur Android | ✅ codé | Icône adaptative, icône monochrome, bannière TV, logo dans les menus. Dessins vectoriels générés depuis `AppLogoView.swift`. |
| Rejoindre un foyer par QR code | ✅ codé | Format du lien en Rust (`cnd_domain::sync::invite`, 5 tests). Bibliothèque Android reconstruite. XCFramework Apple **non reconstruit** : Apple garde sa version Swift. |
| Champ de recherche responsive | ✅ codé | |
| Lecteur façon YouTube : portrait 16:9 avec la liste en dessous, plein écran en paysage et sur TV | ✅ compile | Non essayé à l'écran. |
| Sources et Appareils dans le menu | ✅ codé | Téléphone : rangée de raccourcis en haut (défilante), rail et tiroir ; TV : barre du haut. |
| Comptes du Mac non reçus sur Android | ✅ codé | 3 causes : mot de passe rangé sous `source_pwd_<uuid>` alors que le compte cherche `password_ref` ; catalogues des comptes reçus jamais téléchargés ; écran Sources pas rafraîchi. Corrigé dans `RustHouseholdSyncEngineBridge.kt`. **Non essayé sur le téléphone** : après installation, toucher « Synchroniser maintenant » sur Android. |
| Enquête « comptes absents sur le mobile » (12:05) | ⏸️ en attente de l'utilisateur | Le Mac **et** Android ont 0 compte et les mêmes 6 marques de suppression de compte (`sync_tombstones`, type `source`), dont 2 posées aujourd'hui à 11:20:18 et 11:20:49. Les comptes ont été supprimés puis la suppression s'est propagée : ce n'est pas un défaut de réception. Hypothèse non prouvée : depuis le dédoublonnage (`same_account_source`), un même compte garde un uuid différent sur chaque appareil ; supprimer le « doublon » sur l'un pose une marque sur un uuid qui est le compte principal de l'autre. L'iPhone (hors ligne) a peut-être encore les comptes. |
| Boutons « Envoyer mes données » et « Recevoir les données » à la place de « Synchroniser maintenant » (Android, Mac, iPhone) | ✅ codé | Additifs : rien n'est supprimé chez l'autre, un compte n'est jamais ajouté deux fois. Testé unitairement et compilé sur les 3 ; **non essayé sur les appareils**. |
| Règle Rust : une suppression de compte ne voyage plus (`cnd_domain::sync::deletion_propagates`) | ✅ testé | Plus envoyée, ignorée si reçue d'une ancienne app, et une marque locale ne bloque plus un compte reçu. `cnd-core` : 24/24 tests de synchro. |
| Reconstruction bibliothèque Android + XCFramework | ✅ | Les deux réussies. |
| Tests Apple (`swift test`) + builds macOS et iOS | ✅ | XCTest 547 tests (2 ignorés, 0 échec) + 15 tests Swift Testing ; `CndIPTV-macOS` et `CndIPTV-iOS` : BUILD SUCCEEDED. |
| Tests Android (`core:data`, `core:platform`, `feature:devices`, `app`) + APK | ✅ | 15/15, 19/19, 4/4, 2/2 ; APK debug construit. |
| Tests Rust (`clippy`, `cnd-domain`) | ✅ | 80/80. |
| Tests Android des modules touchés et APK | ✅ | `core:domain` 10/10, `core:data` 15/15, `feature:player` 8/8, `feature:live` 1/1, `feature:search` 1/1, `feature:devices` 4/4, `app` 2/2 (dont la règle des modules) ; APK debug construit. Avant ça : 2 lancements bloqués (arrêtés), 1 erreur de dépendance, 1 test en échec, 1 boucle sans fin dans les tests du lecteur, tous corrigés. |
