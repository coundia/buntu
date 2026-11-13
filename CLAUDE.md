# CLAUDE.md

Les règles communes à tous les agents IA sont dans `AGENTS.md` ; elles s'appliquent entièrement à Claude Code.

@AGENTS.md

## Spécifique à Claude Code

- **Langue :** répondre en français, même si la demande mélange français et anglais.
- **Plan et suivi :** pour toute tâche de plusieurs étapes, tenir la liste de tâches à jour ; terminer par un récapitulatif qui dit ce qui est vérifié et ce qui ne l'est pas.
- **`progress.md` :** y inscrire ses tâches et leur état (`AGENTS.md § 2`). À chaque notification de fin d'une commande en arrière-plan, mettre `progress.md` à jour **et** dire tout de suite à l'utilisateur ce qui s'est terminé et avec quel résultat, même s'il parle d'autre chose.
- **Sous-agents et sessions parallèles :** ils travaillent souvent dans ce même dossier. Relire `git status` avant de commiter et n'ajouter que ses propres fichiers (`AGENTS.md § 2.1`).
- **Commits :** seulement sur demande ; terminer le message par la ligne `Co-Authored-By` indiquée par l'outil.
- **TV Samsung :** pour installer, inspecter ou simuler la télécommande, suivre `docs/TIZEN_CONTROLE_A_DISTANCE.md` (le script `scripts/run-tizen.sh --debug` ouvre l'inspecteur sur `localhost:9222`). Ne pas installer sur une adresse IP que l'utilisateur n'a pas confirmée.
- **Commandes longues** (`xcodebuild`, `build-xcframework.sh`, Gradle complet) : les lancer en arrière-plan et attendre la notification plutôt que d'interroger en boucle.
