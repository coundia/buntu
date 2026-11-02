# PRD 17 — Health-Check proactif & bascule automatique vers un flux miroir

- **ID :** `PRD-17`
- **Prérequis :** `PRD-05` (Catalogue, Favoris, Récents), `PRD-08` (Lecteur : watchdog et reconnexion), `PRD-13` (normalisation des noms de chaînes dans `ai/local_matcher.rs`), table `broken_flags` existante
- **Couches impactées :** `Rust (crates/cnd-core/src/health/, db/)`, `UniFFI`, `SwiftUI (Player/CndPlayerController, Features/LiveTV)`
- **Origine :** `PRD-14` §4.3
- **Objectif SLA :** bascule vers un miroir **< 3 s** après l'échec définitif du flux, vérification de fond **< 1 % CPU** et **zéro** connexion au-delà de la limite de l'abonnement.

---

## 1. Contexte & Objectif

Un flux IPTV tombe souvent (serveur saturé pendant un match, flux retiré). Aujourd'hui le lecteur tente 3 reconnexions puis affiche une erreur, et l'utilisateur peut signaler la chaîne « en panne » à la main. Ce PRD ajoute :
1. la **détection de miroirs** (la même chaîne dans une autre qualité ou une autre source) ;
2. la **bascule automatique** du lecteur vers le meilleur miroir quand le flux échoue ;
3. une **vérification périodique légère** des chaînes favorites et récentes, qui alimente les indicateurs de santé et les signalements automatiques.

---

## 2. Fichiers à Créer / Modifier

- `crates/cnd-core/src/health/mirrors.rs` *(clé d'équivalence, classement des miroirs)*
- `crates/cnd-core/src/health/probe.rs` *(sonde d'un flux : TS, HLS, HTTP)*
- `crates/cnd-core/src/health/mod.rs` *(worker périodique, persistance, signalement auto)*
- `crates/cnd-core/src/db/schema.rs` *(tables `stream_health`, colonne `origin` de `broken_flags`)*
- `crates/cnd-core/src/lib.rs` *(exports `find_mirrors`, `probe_stream`, `start_health_checks`, `stop_health_checks`, `get_stream_health`)*
- `apple/Sources/CndIptvApp/Player/CndPlayerController.swift` *(étape « bascule miroir » après les reconnexions)*
- `apple/Sources/CndIptvApp/Features/LiveTV/ChannelCardView.swift` *(pastille de santé, menu « Alternatives »)*
- `apple/Sources/CndIptvApp/Features/Settings/SettingsView.swift` *(réglages « Bascule automatique » et « Vérification périodique »)*

---

## 3. Spécifications Techniques Détaillées

### 3.1. Miroirs (`mirrors.rs`)

- Deux chaînes sont équivalentes si elles partagent un `tvg_id` non vide, **ou** la même clé de nom normalisée (`channel_name_tokens` de `ai/local_matcher.rs` : préfixe pays, tags `HD/FHD/4K/HEVC` retirés).
- Classement : santé connue (OK > inconnu > en échec), qualité préférée de l'utilisateur (par défaut 4K/UHD > FHD > HD > SD, déduite du nom), même source avant autre source, flux non signalés en panne.
- `find_mirrors(item_id) -> Vec<IptvItemRecord>` exclut l'élément lui-même et les miroirs signalés en panne par l'utilisateur.

### 3.2. Sonde (`probe.rs`)

- Délai 5 s, lecture **≤ 64 Kio**, puis fermeture :
  - flux TS : `GET` avec `Range: bytes=0-65535` (ou sans Range si refusé), succès si au moins 3 octets de synchro `0x47` alignés sur 188 octets ;
  - HLS : lecture de la playlist (maître → première variante), succès si au moins un segment est listé et que son `HEAD`/`GET` partiel répond 2xx ;
  - autre : succès sur 2xx avec un `Content-Type` vidéo/binaire.
- Résultat : `Ok { latency_ms } | Http(status) | Timeout | Dns | Invalid`. En-têtes de la chaîne appliqués (User-Agent, Referer, `headers_json`). URL jamais journalisée en clair (masquage existant).

### 3.3. Worker périodique (`health/mod.rs`)

- Cible : favoris live + 20 dernières chaînes regardées (50 au plus), toutes les **30 min** (réglable 15–120 min), **une sonde à la fois**, pause de 2 s entre sondes.
- **Jamais** de sonde sur une source déjà à sa limite `max_connections` (flux en lecture, mosaïque, téléchargements, enregistrements comptent). Sur iOS, pas de sonde sur un réseau coûteux (`NWPath.isExpensive`) ni en mode Économie d'énergie.
- Table `stream_health(stable_hash, status, latency_ms, checked_at, consecutive_failures, last_ok_at)`.
- **Signalement automatique :** 3 échecs consécutifs → `broken_flags` avec `origin='auto'` ; une sonde réussie retire uniquement les signalements `auto`. Les signalements de l'utilisateur (`origin='user'`) ne sont jamais modifiés par le worker.

### 3.4. Bascule dans le lecteur

- Après l'échec des 3 reconnexions **ou** 2 décrochages en moins de 60 s, `CndPlayerController` demande `find_mirrors` et ouvre le premier miroir (volume, sourdine, PiP conservés). Bandeau non bloquant : « Bascule vers TF1 FHD (abonnement B) ». Au plus 2 bascules par session de visionnage ; ensuite, message d'erreur habituel avec la liste des alternatives.
- Réglage « Bascule automatique » (activé par défaut) ; désactivé, le lecteur propose les alternatives au lieu de basculer.

### 3.5. Interface

- Pastille sur les cartes de chaîne : verte (OK < 1 h), orange (lente ou 1–2 échecs), rouge (signalée en panne), aucune si inconnue.
- Menu contextuel « Alternatives » listant les miroirs avec leur santé.

---

## 4. Contraintes Non-Négociables (Guardrails IA)

- Respect strict de `max_connections` : une sonde ne doit **jamais** faire couper le flux regardé par l'utilisateur.
- Aucune donnée de chaîne ne quitte l'appareil ; les sondes ne vont qu'aux serveurs des flux concernés.
- Pas de nouvelle crate (`reqwest`, `tokio` suffisent).

---

## 5. Critères d'Acceptation & Commandes de Validation

1. Tests Rust : clé d'équivalence (préfixes, tags, `tvg_id`), classement des miroirs, sonde contre un serveur local (TS valide, TS invalide, HLS maître/variante, 404, délai), signalement auto après 3 échecs et retrait au succès sans toucher aux signalements `user`, respect de `max_connections`.
2. Tests Swift : bascule après échec final (faux backend), limite de 2 bascules, bandeau, réglage désactivé → alternatives proposées.
3. `task check` au vert.

---

## 6. Statut d'Implémentation & Validation ✅

- **Miroirs (`crates/cnd-core/src/health/mirrors.rs`)** : Clé d'équivalence `tvg_id` + tokens normalisés de chaînes (`channel_name_tokens`), scoring de qualité (4K > FHD > HD > SD), bonus même source, tri et filtrage des chaînes en panne.
- **Sonde HTTP/TS/HLS (`crates/cnd-core/src/health/probe.rs`)** : Sonde de 5 s, lecture $\le 64$ Kio, vérification des 3 octets de synchronisation MPEG-TS `0x47` espacés de 188 octets, résolution HLS master/variante/segment, masquage des identifiants dans les logs.
- **Worker Périodique & Persistance (`crates/cnd-core/src/health/mod.rs`, `db/mod.rs`, `schema.rs`)** : Table `stream_health`, gestion d'`origin` (`user` vs `auto`) dans `broken_flags`, auto-signalement après 3 échecs et retrait automatique au succès sans altérer les signalements utilisateur, respect strict de `max_connections`.
- **Bascule Lecteur (`CndPlayerController.swift`, `CndVideoPlayerView.swift`)** : Bascule automatique vers le meilleur miroir après 3 échecs ou 2 décrochages rapides (< 60 s), plafonnement strict à 2 bascules par session, bandeau visuel non bloquant (« Bascule vers ... »), alternatives manuelles en overlay d'erreur et pastilles de santé sur `ChannelCardView`.
- **Réglages & Options (`SettingsView.swift`, `LiveTvView.swift`)** : Toggles pour « Bascule automatique vers un miroir » et « Vérification périodique de santé », feuille de consultation des alternatives miroirs.
- **Validation** : 103 tests Rust passés, 191 tests Swift passés, 0 échec. Statut : Terminé `[x]`.
