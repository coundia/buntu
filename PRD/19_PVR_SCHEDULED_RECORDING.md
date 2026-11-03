# PRD 19 — PVR : enregistrement programmé depuis le guide EPG

- **ID :** `PRD-19`
- **Prérequis :** `PRD-04` (EPG), `PRD-07` (Moteur de téléchargement), `PRD-11` (Dossier de téléchargement), `PRD-23` facultatif (lancement à l'ouverture de session sur macOS)
- **Couches impactées :** `Rust (crates/cnd-core/src/recorder/, db/)`, `UniFFI`, `SwiftUI (Features/Recordings/, Features/EPG)`
- **Origine :** `PRD-14` §4.5
- **Objectif SLA :** démarrage de l'enregistrement **≤ 2 s** après l'heure prévue (marge incluse), **aucune perte** de segment HLS en régime normal, reprise automatique après une coupure réseau de moins de 60 s.

---

## 1. Contexte & Objectif

Enregistrer une émission à venir depuis le guide, ou toutes les diffusions d'une émission (« Series-Link »), et la revoir plus tard dans l'app. Plateforme cible : **macOS**. Sur iOS, seul l'enregistrement **immédiat** pendant que l'app est au premier plan est proposé (iOS ne permet pas une tâche de fond longue et à heure fixe) ; ce choix est affiché dans l'interface.

---

## 2. Fichiers à Créer / Modifier

- `crates/cnd-core/src/recorder/mod.rs` *(planificateur, état des enregistrements, conflits)*
- `crates/cnd-core/src/recorder/ts_capture.rs` *(capture d'un flux TS continu)*
- `crates/cnd-core/src/recorder/hls_capture.rs` *(capture d'un flux HLS live : suivi de playlist, téléchargement des segments)*
- `crates/cnd-core/src/db/schema.rs`, `db/recording_repo.rs` *(tables `recordings`, `series_rules`)*
- `crates/cnd-core/src/lib.rs` *(exports : `schedule_recording`, `record_now`, `cancel_recording`, `list_recordings`, `add_series_rule`, `remove_series_rule`, `list_series_rules`)*
- `apple/Sources/CndIptvApp/Features/Recordings/RecordingsView.swift` *(planifiés, en cours, terminés ; lecture d'un enregistrement)*
- `apple/Sources/CndIptvApp/Features/EPG/EpgGuideView.swift` *(menus « Enregistrer », « Enregistrer toutes les diffusions »)*

---

## 3. Spécifications Techniques Détaillées

### 3.1. Capture

- **TS continu :** réutiliser le client HTTP du moteur de téléchargement en mode flux sans fin (`UNBOUNDED_END` de `downloader/worker.rs`), écriture séquentielle dans `<fichier>.part`, arrêt à `fin + marge`, renommage atomique.
- **HLS live :** relecture de la playlist toutes les `EXT-X-TARGETDURATION / 2` secondes, téléchargement des nouveaux segments dans l'ordre (`EXT-X-MEDIA-SEQUENCE`), concaténation en `.ts`. Segments chiffrés (`EXT-X-KEY` autre que `NONE`) : **non pris en charge** dans ce PRD, l'enregistrement échoue avec ce motif explicite.
- **Robustesse :** reconnexion avec reprise (backoff 1/2/4/8 s) pendant au plus 60 s, puis l'enregistrement passe en `partial` en gardant ce qui a été capturé.
- **Marges :** 2 min avant, 5 min après (réglables 0–15 min).

### 3.2. Planification

- Table `recordings(id, item_id, stable_hash, channel_name, title, subtitle, start_ts, end_ts, pre_padding_s, post_padding_s, state, file_path, bytes, rule_id, error, created_at)` ; états `scheduled | recording | completed | partial | failed | cancelled`.
- Planificateur tokio dans le moteur : réveil au prochain départ, re-planification à chaque changement. Au lancement de l'app, les enregistrements manqués passent en `failed` (« app fermée à l'heure prévue »).
- **Series-Link :** `series_rules(id, channel_tvg_id, title_key, created_at)` ; à chaque actualisation de l'EPG, les programmes futurs dont le titre normalisé correspond sont planifiés ; dédoublonnage par `(title, subtitle, start_ts)`.
- **Conflits :** un enregistrement consomme une connexion de la source ; refuser (ou signaler) si les enregistrements simultanés dépassent `max_connections`.
- **Espace disque :** vérification avant départ (estimation 4 Go/h par défaut, réglable) ; arrêt propre si le disque passe sous 1 Go libre.

### 3.3. macOS : garder la machine éveillée

- Pendant un enregistrement : `ProcessInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled])` (pas de mise en veille, pas d'App Nap).
- Option « Ouvrir CND IPTV à l'ouverture de session » via `SMAppService.mainApp` (nécessite le bundle signé de `PRD-23`).
- Le réveil d'un Mac en veille à heure fixe (`pmset schedule`) exige des droits administrateur : **hors périmètre**, documenté dans l'interface.

### 3.4. Stockage & lecture

- Fichiers dans `<Dossier de téléchargement>/Enregistrements/<Chaîne>/<AAAA-MM-JJ HHhMM> - <Titre>.ts` (noms nettoyés comme `DownloadPlanner.sanitize`).
- Les enregistrements terminés se lisent dans le lecteur (fichier local, moteur mpv) ; suppression avec ou sans le fichier.

---

## 4. Contraintes Non-Négociables (Guardrails IA)

- Aucune perte silencieuse : tout segment manquant est consigné dans les journaux de l'enregistrement et l'état devient `partial`.
- Respect de `max_connections` et de l'espace disque.
- Pas de nouvelle crate ; parseur de playlist HLS écrit à la main (sous-ensemble : `EXTINF`, `EXT-X-TARGETDURATION`, `EXT-X-MEDIA-SEQUENCE`, `EXT-X-ENDLIST`, `EXT-X-KEY`).

---

## 5. Critères d'Acceptation & Commandes de Validation

1. Tests Rust : capture TS bornée dans le temps contre un serveur local, capture HLS avec playlist qui avance (segments dans l'ordre, sans doublon, fin sur `ENDLIST`), segments chiffrés refusés, coupure réseau < 60 s reprise et > 60 s → `partial`, planificateur (heures fixes simulées), Series-Link (dédoublonnage), conflits de connexions, espace disque.
2. Tests Swift : `RecordingsView` model (états, lecture d'un fichier), menus EPG.
3. Test manuel macOS : enregistrement de 10 min d'une chaîne HLS et d'une chaîne TS, relecture.
4. `task check` au vert.

---

## Statut d'Implémentation & Validation (audit)

**Réalisé ✅** : capture TS et HLS (`recorder/ts_capture.rs`, `hls_capture.rs`), planificateur, Series-Link, écran Enregistrements, éveil de la machine sur macOS, marges avant/après.

**Corrigé lors de l'audit** : le PRD exige des garde-fous qui n'existaient pas.
- **Conflits de connexions** : un enregistrement qui dépasserait `max_connections` de sa source est refusé (état `failed`, motif en français). Seuls les enregistrements entre eux sont comptés : regarder une chaîne de la même source en même temps n'est pas détecté côté Rust, et le message le rappelle.
- **Espace disque** : avant le départ (estimation 4 Go par heure plus 1 Go de marge, message avec les chiffres) et pendant la capture (vérification toutes les 10 s : sous 1 Go libre, l'enregistrement s'arrête proprement en `partial` en gardant ce qui est capturé).
- Un enregistrement qui échouait à l'ouverture du client HTTP restait compté comme actif : corrigé.
- Tests : `recorder/limits.rs` et `recorder/mod.rs` (limite à 1 connexion, sources distinctes, disque insuffisant, libération).

**Non vérifié** : captures de bout en bout sur un vrai fournisseur ; l'option « ouvrir à l'ouverture de session » (`SMAppService`) n'a pas été contrôlée.