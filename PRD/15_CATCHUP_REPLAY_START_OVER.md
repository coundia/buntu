# PRD 15 — Catch-up TV (Replay serveur) & « Revoir depuis le début »

- **ID :** `PRD-15`
- **Statut :** `Complété & Validé` (Tests unitaires Rust & Swift au vert)
- **Prérequis :** `PRD-03` (Xtream), `PRD-04` (EPG), `PRD-08` (Lecteur), `PRD-09` (Live TV & Guide)
- **Couches impactées :** `Rust (crates/cnd-core/src/iptv/catchup.rs, db/epg_repo.rs, iptv/xtream.rs)`, `UniFFI`, `SwiftUI (Features/EPG, Features/LiveTV, Player)`
- **Origine :** `PRD-14` §3.1 et §4.2 (navigation EPG rétrospective)
- **Objectif SLA :** URL de replay calculée en **< 5 ms**, lecture d'un programme passé en **un clic** depuis la grille EPG, **aucune** URL contenant des identifiants dans les journaux.

---

## 1. Contexte & Objectif

Beaucoup de fournisseurs IPTV gardent 1 à 7 jours d'archives par chaîne. Les métadonnées sont **déjà ingérées** mais inutilisées :

- `iptv_items.catchup_type`, `catchup_source`, `catchup_days` (M3U : attributs `catchup`, `catchup-source`, `catchup-days`) ;
- côté Xtream, `iptv/xtream.rs` écrit `catchup_type = "default"` quand `tv_archive > 0` et `catchup_days = tv_archive_duration`.

Ce PRD rend ces archives jouables : programmes passés de la grille EPG, programme en cours depuis son début (« start-over »), et liste « Replay » dans le programme d'une chaîne.

---

## 2. Constat technique à corriger d'abord

1. **Ambiguïté Xtream / M3U :** `catchup_type = "default"` désigne aussi le mode M3U « default ». Les chaînes Xtream doivent porter **`"xc"`** (migration : `UPDATE iptv_items SET catchup_type='xc' WHERE catchup_type='default' AND source_id IN (SELECT id FROM iptv_sources WHERE source_type='xtream')`, puis écriture correcte dans `xtream.rs`).
2. **Rétention EPG :** `refresh_source_epg` appelle `purge_expired_epg(now_ts - 86_400)` : seules les **24 dernières heures** sont gardées. La purge doit conserver `max(catchup_days)` de la source (plafond 7 jours, défaut 1 jour sans catch-up).
3. **Filtre à l'ingestion XMLTV :** vérifier que `parse_xmltv_auto_gzip(…, now_ts, …)` ne jette pas les programmes passés ; sinon lui passer la borne `now - catchup_window`.

---

## 3. Fichiers à Créer / Modifier

- `crates/cnd-core/src/iptv/catchup.rs` *(nouveau : expansion des modèles d'URL, fenêtre de disponibilité, construction Xtream)*
- `crates/cnd-core/src/db/epg_repo.rs` *(purge paramétrée par la fenêtre de catch-up ; requête des programmes passés d'une chaîne)*
- `crates/cnd-core/src/iptv/xtream.rs` *(type `"xc"`, extraction du `stream_id`)*
- `crates/cnd-core/src/lib.rs` *(exports `catchup_playback`, `catchup_window`)*
- `apple/Sources/CndIptvApp/Features/EPG/EpgGuideView.swift` & `EpgGuideModel.swift` *(navigation arrière jusqu'à `catchup_days`, badge « Replay », lecture d'un programme passé)*
- `apple/Sources/CndIptvApp/Features/LiveTV/ChannelCardView.swift` & menu contextuel *(« Revoir depuis le début »)*
- `apple/Sources/CndIptvApp/Player/PlayableMedia.swift`, `CndPlayerController.swift`, `CndVideoPlayerView.swift` *(nouveau genre de média `replay` : durée bornée, déplaçable, badge « REPLAY 20:00–20:40 »)*

---

## 4. Spécifications Techniques Détaillées

### 4.1. Modes de catch-up pris en charge (`catchup.rs`)

| `catchup_type` | Construction de l'URL |
|---|---|
| `xc` (Xtream) | `{serveur}/timeshift/{user}/{pass}/{durée_min}/{YYYY-MM-DD:HH-MM}/{stream_id}.ts` (variante `.m3u8` si la source est en HLS). `stream_id` = dernier segment numérique de `stream_url`. Heure de début dans le fuseau du serveur (`XtreamAccountInfo.server_timezone`, UTC par défaut). |
| `default` | `catchup_source` est une **URL complète** à placeholders. |
| `append` | `stream_url` + `catchup_source` (placeholders développés). |
| `shift` | `stream_url` + `?utc={start}&lutc={now}` (ou `&` si l'URL a déjà une requête). |
| `flussonic` / `fs` | `…/{chemin}/archive-{start}-{duration}.m3u8` (ou `.ts` selon l'extension d'origine). |

**Placeholders** à développer (toutes les dates en UTC sauf `xc`) : `{utc}` `{start}` `${start}` `{end}` `{utcend}` `{lutc}` `{now}` `${now}` `{timestamp}` `{duration}` (secondes), `{duration:N}` (unités de N secondes), `{offset}` (secondes écoulées depuis le début), `{Y}` `{m}` `{d}` `{H}` `{M}` `{S}`. Un placeholder inconnu laisse l'URL **non jouable** (pas d'URL devinée).

### 4.2. Disponibilité

`catchup_window(item, programme, now)` renvoie `Unavailable | Replay | StartOver` :
- `Replay` si `programme.end_ts <= now` et `now - programme.start_ts <= catchup_days × 86 400` ;
- `StartOver` si le programme est **en cours** (début ≤ now < fin) ;
- `Unavailable` si pas de catch-up, programme futur ou trop ancien.

### 4.3. Contrat UniFFI

```rust
struct CatchupPlayback { url: String, start_ts: i64, end_ts: i64, title: String, user_agent: Option<String>, referer: Option<String>, headers_json: Option<String> }
fn catchup_playback(item_id: i64, programme_id: i64) -> Result<Option<CatchupPlayback>, CndError>;
fn catchup_programmes(item_id: i64, from_ts: i64, to_ts: i64) -> Result<Vec<EpgProgramRecord>, CndError>; // passés + en cours, triés
```

### 4.4. Interface

- **Grille EPG :** le bouton « 6 h plus tôt » descend jusqu'à `catchup_days` (au lieu de s'arrêter à la fenêtre actuelle). Les programmes passés rejouables portent un badge ⟲ ; les autres sont grisés. Un clic lance la lecture (lecteur ancré à droite, comme le Live TV).
- **Programme d'une chaîne :** section « Replay » (jours précédents) avec lecture directe.
- **Carte chaîne / menu contextuel :** « Revoir depuis le début » si le programme en cours est `StartOver`.
- **Lecteur :** un replay se comporte comme un film (barre de progression bornée à la durée du programme, ±10 s), badge « REPLAY » avec l'horaire ; « Retour au direct » ramène sur le flux live. La progression n'est **pas** enregistrée dans `watch_history` (pas de pollution des Récents).

---

## 5. Contraintes Non-Négociables (Guardrails IA)

- Les URL de replay contiennent souvent `user`/`pass` : **jamais** dans les journaux (le masquage `redact_url` couvre `/timeshift/` et les paramètres `username`/`password` ; ajouter un test).
- Aucune requête réseau pour décider de la disponibilité : tout se calcule depuis SQLite.
- Pas de nouvelle crate : dates via `chrono_now_ts` et arithmétique entière (pas de crate de fuseaux ; fuseau Xtream = décalage fixe lu dans `server_timezone` quand il est donné en `±HH:MM`, sinon UTC, documenté).

---

## 6. Critères d'Acceptation & Commandes de Validation

1. Tests Rust : chaque mode du tableau 4.1 avec dates fixes (dont minuit, changement de jour, durée non entière en minutes), placeholder inconnu → `None`, fenêtre de disponibilité (passé, en cours, futur, trop ancien), migration `default → xc`, purge qui garde `catchup_days`, masquage des identifiants dans une URL `/timeshift/` journalisée.
2. Tests Swift : `EpgGuideModel` navigue jusqu'à J-`catchup_days` et pas au-delà ; le lecteur traite un replay comme borné et non live ; « Retour au direct ».
3. Test manuel : une source Xtream avec `tv_archive=1` rejoue un programme d'hier.
4. `task check` au vert (XCFramework régénéré).

---

## Audit (statut réel)

Le statut « Complété & Validé » ci-dessus était trop large. Ce qui est réel : `catchup.rs` (modes Xtream `timeshift`, `default`, `append`, `shift`, Flussonic, développement des placeholders, fenêtre de disponibilité), conservation de l'EPG sur 14 jours, replay d'un programme passé depuis la grille EPG (`build_catchup_url`).

**Corrigé à l'audit**
- **Horloge du serveur Xtream** : l'heure de début de l'URL `timeshift` était écrite en UTC ; un serveur Xtream lit l'heure de **sa** horloge, donc le mauvais programme se lisait dès que le serveur n'est pas en UTC. Le décalage est maintenant déduit de `server_info` (`time_now` face à `timestamp_now`, arrondi au quart d'heure), enregistré à la synchronisation (`iptv_sources.server_utc_offset_secs`) et appliqué à l'URL. 4 tests Rust (zones entières et demi-heures, changement de date, valeurs absurdes). Limite : le décalage est celui de la dernière synchronisation (un changement d'heure d'été entre deux synchronisations décale d'une heure).
- **Genre de média `replay`** : un replay se lisait comme un film avec l'identité de la chaîne, donc sa position était enregistrée dans l'historique de visionnage de la chaîne (le PRD l'interdit). Nouveau `PlayableKind.replay` : barre de progression bornée, jamais enregistré dans `watch_history`, badge « REPLAY » et bouton « Retour au direct » dans le lecteur. 4 tests Swift.
- **« Revoir depuis le début »** : absent du menu des chaînes ; ajouté (affiché quand la chaîne a une archive et qu'un programme est en cours).

**Non réalisé / écarts**
- Le type `xc` du PRD n'est pas écrit en base : l'URL Xtream est reconnue par la forme de l'adresse de flux (équivalent, mais une source M3U dont les adresses ressemblent à du Xtream utilise aussi `timeshift`).
- Exports `catchup_playback`, `catchup_window` et `catchup_programmes` : remplacés par `build_catchup_url` et `is_catchup_available` ; pas de section « Replay » dans le programme d'une chaîne (seule la grille EPG remonte dans le temps).
- Flussonic : l'adresse produite est `timeshift_abs-{début}.m3u8`, pas le `archive-{début}-{durée}` décrit ci-dessus.
- Aucun essai de lecture de replay contre un vrai fournisseur.
