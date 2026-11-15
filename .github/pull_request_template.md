## Résumé

<!-- Décrivez clairement les changements apportés et le problème résolu (référence PRD ou issue si applicable). -->

## Couches et plateformes touchées

- [ ] Cœur métier pur (`crates/cnd-domain`)
- [ ] Moteur natif (`crates/cnd-core` / `crates/cnd-cli`)
- [ ] WebAssembly (`crates/cnd-domain-wasm`)
- [ ] Apple (`apple/` — macOS / iOS / tvOS / visionOS)
- [ ] Android / Android TV (`android/`)
- [ ] Samsung Smart TV Tizen (`tizen/`)
- [ ] Scripts / CI / Documentation

## Vérifications obligatoires

- [ ] `./scripts/check-secrets.sh` retourne `secrets check: clean` (aucun secret, `.env`, keystore/certificat ou chemin `/Users/...`)
- [ ] `./scripts/test-gen-default-keys.sh` passe sans erreur
- [ ] Rust : `cargo clippy --workspace --all-targets -- -D warnings` et `cargo test -p cnd-domain -p cnd-core`
- [ ] Apple (si touché) : `cd apple && swift test`
- [ ] Android (si touché) : `cd android && ./gradlew :core:data:testDebugUnitTest :core:domain:test :app:testDebugUnitTest`
- [ ] Tizen (si touché) : `cd tizen && npx tsc --noEmit && npm test`

## Checklist d'architecture

- [ ] Toute règle métier ou de validation partagée est implémentée dans `crates/cnd-domain` (sans I/O)
- [ ] Aucun chargement complet en mémoire de playlist M3U, XMLTV ou gros JSON
- [ ] Aucune opération bloquante sur le fil principal UI
- [ ] Aucun module Android `feature/*` ne dépend de `:core:engine`
- [ ] Code Tizen compatible Chromium 56–76 (CSS/JS) et WebAssembly 1.0 MVP strict
