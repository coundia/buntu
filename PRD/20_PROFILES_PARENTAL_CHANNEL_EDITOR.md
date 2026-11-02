# PRD 20 — Éditeur de bouquets, Multi-profils & Contrôle parental

- **ID :** `PRD-20`
- **Prérequis :** `PRD-05` (Catalogue, Favoris, Historique), `PRD-09`/`PRD-10` (écrans), `PRD-12` (synchronisation iCloud)
- **Couches impactées :** `Rust (db/ : schéma, requêtes, sync_repo)`, `UniFFI`, `SwiftUI (Features/Profiles, Features/ChannelEditor, Security)`
- **Origine :** `PRD-14` §3.3 et §3.4
- **Objectif SLA :** les filtres de masquage et l'ordre personnalisé n'ajoutent pas plus de **5 ms** aux requêtes de catalogue sur 100 000 éléments ; changement de profil **< 300 ms**.

Trois lots livrés et validés **dans l'ordre**, chacun utilisable seul.

---

## Lot 20.1 — Éditeur de bouquets & dossiers de favoris

- **Masquer** une catégorie entière ou une chaîne (ex. langues non désirées) ; **réordonner** les catégories et les chaînes favorites par glisser-déposer ; **dossiers de favoris** personnalisés (« Sport », « Info »…).
- Persistance **indépendante de la playlist** : clés `group_title` normalisé et `stable_hash`, donc survit aux actualisations.
- Tables : `hidden_groups(profile_id, kind, group_key)`, `hidden_items(profile_id, stable_hash)`, `custom_order(profile_id, scope, key, position)`, `favorite_folders(id, profile_id, name, position)`, `favorite_folder_items(folder_id, stable_hash, position)`.
- `CatalogFilter` gagne `include_hidden: bool` (faux par défaut) et un tri `SortField::Custom`. Les facettes (`get_groups`) excluent les catégories masquées et suivent l'ordre personnalisé.
- Écran « Organiser » (macOS : réglages ou menu contextuel d'une catégorie ; iOS : mode édition des listes).

## Lot 20.2 — Profils

- Table `profiles(id, uuid, name, avatar, is_kids, created_at)` ; profil `1` « Principal » créé par migration et propriétaire des données existantes.
- `favorites`, `watch_history`, `favorite_folders`, `hidden_*`, `custom_order` reçoivent `profile_id` (migration : valeur 1). Sources, catalogue, EPG, téléchargements et signalements de panne restent **communs**.
- Le moteur garde un **profil actif** (`set_active_profile`) ; toutes les requêtes concernées le filtrent.
- Synchronisation iCloud (`sync_repo`) : chaque enregistrement porte l'`uuid` du profil ; les profils eux-mêmes sont synchronisés.
- Sélecteur de profil au lancement (si plus d'un profil) et dans la barre latérale / les Réglages.

## Lot 20.3 — Contrôle parental

- **Code PIN** à 4–6 chiffres : stocké dans le **Trousseau** sous forme de hash salé (PBKDF2 via `CommonCrypto`), jamais en clair. Déverrouillage par **Face ID / Touch ID** (`LocalAuthentication`, `LAPolicy.deviceOwnerAuthentication`) quand disponible.
- **Catégories adultes** : détection par mots-clés sur le nom de catégorie (`adult`, `adults`, `xxx`, `+18`, `18+`, `porn`, configurable) et par l'indicateur `is_adult` des catégories Xtream quand il est fourni ; masquées par défaut, déverrouillables pour la session (15 min) avec le PIN.
- **Profil Enfants** (`is_kids`) : seules les catégories autorisées explicitement sont visibles, pas d'accès aux Réglages, aux Sources ni à l'assistant IA distant ; sortir du profil demande le PIN.
- Verrouillage optionnel des Réglages et des Sources pour tous les profils.

---

## Contraintes Non-Négociables (Guardrails IA)

- Le PIN et ses hashs ne sont jamais écrits dans SQLite, `UserDefaults`, iCloud ni les journaux.
- Migrations idempotentes (`apply_incremental_migrations`), aucune perte des favoris ni de l'historique existants.
- Les requêtes FTS5 restent indexées : filtrage par sous-requêtes `NOT EXISTS` indexées, pas de balayage complet.

## Critères d'Acceptation & Commandes de Validation

1. Lot 20.1 : tests Rust (masquage de catégories et chaînes, ordre personnalisé, dossiers, survie à une ré-ingestion de la playlist), mesure de performance sur 100 000 éléments.
2. Lot 20.2 : tests de migration (données existantes → profil 1), isolement des favoris/historique entre profils, synchronisation avec l'`uuid` de profil.
3. Lot 20.3 : tests Swift du PIN (création, vérification, hash salé dans le Trousseau isolé de test), masquage adulte par mots-clés et indicateur Xtream, restrictions du profil Enfants.
4. `task check` au vert.
