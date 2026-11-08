use super::clock::HlcClock;
use super::envelope::*;
use super::merge::*;
use super::records::*;
use crate::identity::*;

#[test]
fn test_three_devices_convergence_with_clock_skew_and_unordered_delivery() {
    // Device A (Mac) at t=1000ms
    // Device B (iPhone) with clock lagging by 500ms (t=500ms)
    // Device C (Samsung TV) at t=1010ms
    let mut clock_a = HlcClock::new("dev_mac");
    let mut clock_b = HlcClock::new("dev_iphone");
    let mut clock_c = HlcClock::new("dev_tv");

    let mut state_a = HouseholdState::new();
    let mut state_b = HouseholdState::new();
    let mut state_c = HouseholdState::new();

    // 1. On iPhone (lagging clock): User adds Favorite F1 (France 2)
    let t_b1 = clock_b.now(510);
    let fav_f1 = SyncFavoriteRecord {
        profile_uuid: "p_main".to_string(),
        content_key: "ck_france_2".to_string(),
        item_kind: "live".to_string(),
        hlc: t_b1.clone(),
    };
    state_b.favorites.insert(format!("{}:{}", fav_f1.profile_uuid, fav_f1.content_key), fav_f1.clone());

    // 2. On Mac: User watches movie M1 at position 45_000 ms
    let t_a1 = clock_a.now(1_020);
    let prog_m1 = SyncProgressRecord {
        profile_uuid: "p_main".to_string(),
        content_key: "ck_movie_1".to_string(),
        item_kind: "movie".to_string(),
        position_ms: 45_000,
        duration_ms: 7_200_000,
        completed: false,
        hlc: t_a1.clone(),
    };
    state_a.progress.insert(format!("{}:{}", prog_m1.profile_uuid, prog_m1.content_key), prog_m1.clone());

    // 3. Sync iPhone -> TV
    let delta_b_to_c = state_b.export_delta(None, clock_b.now(520));
    state_c.apply_delta(&delta_b_to_c);
    clock_c.update(&delta_b_to_c.to_hlc, 1_015);

    // 4. On TV: User watches M1 further to 60_000 ms (t_c1 > t_a1)
    let t_c1 = clock_c.now(1_050);
    let prog_m1_tv = SyncProgressRecord {
        profile_uuid: "p_main".to_string(),
        content_key: "ck_movie_1".to_string(),
        item_kind: "movie".to_string(),
        position_ms: 60_000,
        duration_ms: 7_200_000,
        completed: false,
        hlc: t_c1.clone(),
    };
    state_c.progress.insert(format!("{}:{}", prog_m1_tv.profile_uuid, prog_m1_tv.content_key), prog_m1_tv.clone());

    // 5. On iPhone: User removes favorite F1 (tombstone)
    // iPhone clock advances due to causality
    let _ = clock_b.update(&t_b1, 550);
    let t_b2 = clock_b.now(560);
    let tb_f1 = SyncTombstone {
        kind: TombstoneKind::Favorite,
        key: format!("{}:{}", fav_f1.profile_uuid, fav_f1.content_key),
        hlc: t_b2.clone(),
    };
    state_b.tombstones.insert(format!("{:?}:{}", tb_f1.kind, tb_f1.key), tb_f1.clone());
    state_b.favorites.remove(&tb_f1.key);

    // 6. Cross-sync: All devices exchange deltas with each other
    let delta_a = state_a.export_delta(None, clock_a.now(1_100));
    let delta_b = state_b.export_delta(None, clock_b.now(600));
    let delta_c = state_c.export_delta(None, clock_c.now(1_100));

    // Apply into A
    state_a.apply_delta(&delta_b);
    state_a.apply_delta(&delta_c);

    // Apply into B in reverse order
    state_b.apply_delta(&delta_c);
    state_b.apply_delta(&delta_a);

    // Apply into C
    state_c.apply_delta(&delta_a);
    state_c.apply_delta(&delta_b);

    // 7. Verify CONVERGENCE: All 3 devices have converged to identical state!
    assert_eq!(state_a.favorites, state_b.favorites);
    assert_eq!(state_b.favorites, state_c.favorites);
    // Favorite F1 was deleted by tombstone tb_f1 -> must not exist in live favorites
    assert!(!state_a.favorites.contains_key("p_main:ck_france_2"));
    assert!(!state_b.favorites.contains_key("p_main:ck_france_2"));
    assert!(!state_c.favorites.contains_key("p_main:ck_france_2"));

    // Progress for movie M1 must be 60_000 ms (TV's progress was newer than Mac's)
    assert_eq!(state_a.progress, state_b.progress);
    assert_eq!(state_b.progress, state_c.progress);
    let prog = state_a.progress.get("p_main:ck_movie_1").unwrap();
    assert_eq!(prog.position_ms, 60_000);
}

#[test]
fn test_vectors_parity() {
    let raw = include_str!("vectors.json");
    let v: serde_json::Value = serde_json::from_str(raw).expect("valid vectors.json");

    // 1. Identity vectors
    let xtream_v = &v["identity"]["xtream_source"];
    let s_key = source_key_xtream(
        xtream_v["server"].as_str().unwrap(),
        xtream_v["username"].as_str().unwrap(),
    );
    assert_eq!(s_key, xtream_v["expected_source_key"].as_str().unwrap());

    let m3u_v = &v["identity"]["m3u_source"];
    let m_key = source_key_m3u(m3u_v["url"].as_str().unwrap());
    assert_eq!(m_key, m3u_v["expected_source_key"].as_str().unwrap());

    let live_ck = &v["identity"]["content_keys"]["live_channel"];
    let c_key_live = compute_content_key(
        live_ck["source_key"].as_str().unwrap(),
        live_ck["kind"].as_str().unwrap(),
        live_ck["item_id"].as_str().unwrap(),
    );
    assert_eq!(c_key_live, live_ck["expected_content_key"].as_str().unwrap());

    let vod_ck = &v["identity"]["content_keys"]["vod_movie"];
    let c_key_vod = compute_content_key(
        vod_ck["source_key"].as_str().unwrap(),
        vod_ck["kind"].as_str().unwrap(),
        vod_ck["item_id"].as_str().unwrap(),
    );
    assert_eq!(c_key_vod, vod_ck["expected_content_key"].as_str().unwrap());

    let m3u_v = &v["identity"]["m3u_source"];
    let m_key = source_key_m3u(m3u_v["url"].as_str().unwrap());
    assert_eq!(m_key, m3u_v["expected_source_key"].as_str().unwrap());

    let live_ck = &v["identity"]["content_keys"]["live_channel"];
    let c_key = compute_content_key(
        live_ck["source_key"].as_str().unwrap(),
        live_ck["kind"].as_str().unwrap(),
        live_ck["item_id"].as_str().unwrap(),
    );
    assert_eq!(c_key, live_ck["expected_content_key"].as_str().unwrap());

    // 2. Envelope vectors
    let env_v = &v["envelope"];
    let key_hex = env_v["household_key_hex"].as_str().unwrap();
    let mut key = [0u8; 32];
    for (i, chunk) in key_hex.as_bytes().chunks(2).enumerate() {
        let s = std::str::from_utf8(chunk).unwrap();
        key[i] = u8::from_str_radix(s, 16).unwrap();
    }
    let h_id = derive_household_id(&key);
    assert_eq!(h_id, env_v["expected_household_id"].as_str().unwrap());
}
