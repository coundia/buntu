# PRD 16 — Multi-View : mosaïque de 2 à 4 chaînes en direct

- **ID :** `PRD-16`
- **Prérequis :** `PRD-08` (Lecteur hybride), `PRD-09` (Live TV, `LiveZapper`), `PRD-13` (Assistant IA, pour le lot 16.3)
- **Couches impactées :** `SwiftUI (Features/MultiView/, Player/)`, `Rust (ai/ pour le lot 16.3 uniquement)`
- **Origine :** `PRD-14` §4.1
- **Objectif SLA :** passage 1 → 4 flux sans couper le flux principal, changement du son actif **< 100 ms**, CPU **< 60 %** sur Apple Silicon pour 4 flux 1080p (décodage matériel), mémoire **< 1,2 Go**.

---

## 1. Contexte & Objectif

Regarder plusieurs directs à la fois (multiplex sport, actualités) est la fonction phare des lecteurs concurrents. Le lecteur actuel (`CndPlayerController`) gère **un** média ; ce PRD ajoute un mode mosaïque où chaque tuile a son propre contrôleur, avec un seul son actif à la fois.

Livraison en **trois lots indépendants**, chacun validé avant le suivant.

---

## 2. Fichiers à Créer / Modifier

- `apple/Sources/CndIptvApp/Features/MultiView/MultiViewController.swift` *(@Observable @MainActor : 1 à 4 `CndPlayerController`, tuile active, disposition, limites)*
- `apple/Sources/CndIptvApp/Features/MultiView/MultiViewLayout.swift` *(calcul pur des cadres : 1+1, 2×2, 1 grand + 3 petits ; testable)*
- `apple/Sources/CndIptvApp/Features/MultiView/MultiViewScreen.swift` *(rendu, mini-HUD par tuile, glisser-déposer d'une chaîne sur une tuile)*
- `apple/Sources/CndIptvApp/App/AppShellView.swift`, `KeyboardCommands.swift` *(entrée « Multi-View », raccourcis)*
- `apple/Sources/CndIptvApp/Features/LiveTV/ChannelCardView.swift` *(menu « Ajouter à la mosaïque »)*
- Lot 16.3 : `crates/cnd-core/src/ai/{intent,prompt,mod}.rs` *(nouvelle action `MultiView { item_ids }`)* + `Features/Assistant/AssistantModel.swift`

---

## 3. Spécifications Techniques Détaillées

### Lot 16.1 — Mosaïque de base

- `MultiViewController` possède jusqu'à **4** `CndPlayerController` créés à la demande (même fabrique de backends que le lecteur principal : `AVPlayer` pour HLS, `mpv` sinon). Le premier reprend le média du lecteur principal **sans le relancer** (transfert de la couche).
- Dispositions : `sideBySide` (2), `grid2x2` (3 ou 4), `onePlusThree` (4, la tuile active en grand). Changement automatique selon le nombre de tuiles, choix manuel possible. Calcul des cadres dans `MultiViewLayout` (fonction pure, ratio 16:9 respecté, gouttières de 4 pt).
- **Audio :** une seule tuile non muette (la tuile active, bordure accentuée). Clic sur une tuile = elle devient active ; `1`–`4` au clavier (macOS) ; survol optionnel (réglage).
- **Tuile :** nom de la chaîne + programme en cours, bouton fermer, bouton « plein écran » (repasse en lecteur unique avec cette chaîne), zapping propre à la tuile (`⌘↑/⌘↓` agit sur la tuile active via `LiveZapper`).
- **Garde-fous de ressources :**
  - **Connexions du fournisseur :** avant d'ouvrir un flux, compter les flux ouverts par source ; si `IptvSourceRecord.max_connections` serait dépassé, refuser avec un message clair (« Votre abonnement autorise 2 connexions simultanées »).
  - 4 tuiles maximum ; sur iPhone, 2 maximum (portrait 2 empilées) ; sur iPad, 4.
  - Les tuiles non actives demandent une qualité réduite quand c'est possible (`AVPlayerItem.preferredMaximumResolution`, mpv `hls-bitrate=min` pour les variantes HLS).
- **Sortie :** fermer la mosaïque garde la tuile active dans le lecteur principal.

### Lot 16.2 — Ergonomie

- Glisser une chaîne de la liste (macOS) sur une tuile pour la remplacer, ou dans une zone vide pour l'ajouter.
- Mémorisation de la dernière mosaïque (`@AppStorage`) et proposition « Reprendre la mosaïque ».
- PiP : seule la tuile active passe en image dans l'image.

### Lot 16.3 — Commande vocale / ⌘K

- Nouvelle action `AiAction::MultiView { item_ids: Vec<i64> }` (2 à 4 ids). Résolution locale : « X et Y côte à côte », « mosaïque A, B, C » (séparateurs `et`, `,`, `&`, `+`) → chaque nom résolu par `local_matcher` ; si tous sont certains, action directe sans IA.
- Côté fournisseur : schéma JSON étendu (`"action": "multiview"`, `"item_ids": [..]`), **chaque id validé** contre les candidats comme pour `play`.

---

## 4. Contraintes Non-Négociables (Guardrails IA)

- Ne jamais dépasser `max_connections` d'une source (refus explicite, jamais d'erreur réseau surprise).
- Aucune tuile ne bloque le Main Thread ; création/fermeture des backends hors des chemins critiques d'affichage.
- Pas de nouvelle dépendance ; réutiliser `CndPlayerController` tel quel (pas de second moteur de lecture).

---

## 5. Critères d'Acceptation & Commandes de Validation

1. Tests Swift : `MultiViewLayout` (cadres exacts pour 1–4 tuiles et chaque disposition), audio exclusif (une seule tuile non muette après chaque action), refus au-delà de `max_connections`, transfert de la tuile active au lecteur principal, limites iPhone/iPad.
2. Tests Rust (lot 16.3) : découpage « A et B », ids validés, id inventé rejeté.
3. Mesure manuelle documentée : CPU et mémoire avec 4 flux 1080p sur un Mac Apple Silicon.
4. `task check` au vert.

---

## 6. Statut d'Implémentation & Validation ✅

- **Lot 16.1 (Mosaïque de base) & Lot 16.2 (Ergonomie)** : Implémentés dans `MultiViewController.swift`, `MultiViewLayout.swift`, `MultiViewScreen.swift`, `AppShellView.swift`, `ChannelCardView.swift`, `LiveTvView.swift`, `KeyboardCommands.swift`.
- **Lot 16.3 (IA & Intent)** : Implémenté dans `crates/cnd-core/src/ai/{intent, prompt, providers, local_matcher, mod}.rs`.
- **Validation** : 9 tests unitaires Swift `MultiViewTests` passés, 98 tests Rust passés, 187 tests Swift globaux passés à 100%.
- **Statut** : Terminé `[x]`.
