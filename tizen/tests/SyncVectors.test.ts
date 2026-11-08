import { describe, it, expect, beforeAll } from 'vitest';
import { existsSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { WorkerBridge } from '../src/worker/worker-bridge';
import { setWasmSource } from '../src/worker/handlers';

const WASM = resolve(__dirname, '../src/wasm/pkg/cnd_domain_wasm_bg.wasm');
const VECTORS_PATH = resolve(__dirname, '../../crates/cnd-domain/src/sync/vectors.json');

describe.skipIf(!existsSync(WASM) || !existsSync(VECTORS_PATH))('Sync Vectors Parity (PRD 41 - Domain Wasm -> Tizen Worker)', () => {
  let bridge: WorkerBridge;
  let vectors: any;

  beforeAll(() => {
    setWasmSource(readFileSync(WASM));
    bridge = new (WorkerBridge as any)() as WorkerBridge;
    vectors = JSON.parse(readFileSync(VECTORS_PATH, 'utf-8'));
  });

  it('computes deterministic source_key matching canonical vectors', async () => {
    const xtream = vectors.identity.xtream_source;
    const computedXtreamKey = await bridge.post('COMPUTE_SOURCE_KEY', {
      sourceKind: 'xtream',
      serverUrl: xtream.server,
      username: xtream.username,
    });
    expect(computedXtreamKey).toBe(xtream.expected_source_key);

    const m3u = vectors.identity.m3u_source;
    const computedM3uKey = await bridge.post('COMPUTE_SOURCE_KEY', {
      sourceKind: 'm3u',
      serverUrl: m3u.url,
      username: null,
    });
    expect(computedM3uKey).toBe(m3u.expected_source_key);
  });

  it('computes deterministic content_key matching canonical vectors', async () => {
    const live = vectors.identity.content_keys.live_channel;
    const liveKey = await bridge.post('COMPUTE_CONTENT_KEY', {
      sourceKey: live.source_key,
      itemKind: live.kind,
      providerId: live.item_id,
    });
    expect(liveKey).toBe(live.expected_content_key);

    const vod = vectors.identity.content_keys.vod_movie;
    const vodKey = await bridge.post('COMPUTE_CONTENT_KEY', {
      sourceKey: vod.source_key,
      itemKind: vod.kind,
      providerId: vod.item_id,
    });
    expect(vodKey).toBe(vod.expected_content_key);
  });

  it('seals and opens household envelope with AES-256-GCM and verifies anti-replay', async () => {
    const envVec = vectors.envelope;
    const testMessage = {
      type: 'play_remote',
      content_key: 'eeeb12e4004a2cc37dbf6b5a296d06cf9540088628158a4ed8eb2cbec359ebfe',
      position_ms: 124500,
      title: 'TF1 HD',
      source_key: null,
    };

    // 1. Seal envelope
    const envelope = await bridge.post('SYNC_SEAL_ENVELOPE', {
      householdKeyHex: envVec.household_key_hex,
      senderId: envVec.sender_device_id,
      sequence: envVec.sequence,
      nonceHex: envVec.nonce_hex,
      message: testMessage,
    });

    expect(envelope.household_id).toBe(envVec.expected_household_id);
    expect(envelope.sender_device_id).toBe(envVec.sender_device_id);
    expect(envelope.sequence).toBe(envVec.sequence);
    expect(envelope.nonce_hex).toBe(envVec.nonce_hex);
    expect(envelope.ciphertext_hex).toBeDefined();

    // 2. Open envelope with valid sequence (lastSeen = 0, sequence = 1)
    const opened = await bridge.post('SYNC_OPEN_ENVELOPE', {
      householdKeyHex: envVec.household_key_hex,
      envelope,
      lastSeenSequence: 0,
    });
    expect(opened).toEqual(testMessage);

    // 3. Replay attack verification: opening with lastSeen >= sequence MUST fail
    await expect(
      bridge.post('SYNC_OPEN_ENVELOPE', {
        householdKeyHex: envVec.household_key_hex,
        envelope,
        lastSeenSequence: 1,
      })
    ).rejects.toThrow();
  });

  it('merges deltas deterministically using LWW and tombstone rules', async () => {
    const baseState = {
      favorites: {},
      sources: {},
      profiles: {},
      progress: {
        '00000000-0000-0000-0000-000000000001:ck_gladiator': {
          profile_uuid: '00000000-0000-0000-0000-000000000001',
          content_key: 'ck_gladiator',
          item_kind: 'movie',
          position_ms: 60000,
          duration_ms: 7200000,
          completed: false,
          hlc: '1000.0.node_phone',
        },
      },
      recents: {},
      last_channel: {},
      tombstones: {},
    };

    const delta = {
      to_hlc: '2000.0.node_tv',
      sources: [],
      profiles: [],
      favorites: [],
      progress: [
        {
          profile_uuid: '00000000-0000-0000-0000-000000000001',
          content_key: 'ck_gladiator',
          item_kind: 'movie',
          position_ms: 180000,
          duration_ms: 7200000,
          completed: false,
          hlc: '2000.0.node_tv',
        },
      ],
      recents: [],
      tombstones: [],
    };

    const res = await bridge.post('SYNC_MERGE_DELTA', {
      baseState,
      delta,
    });

    expect(res.report.applied_progress).toBe(1);
    const updated = res.merged_state.progress['00000000-0000-0000-0000-000000000001:ck_gladiator'];
    expect(updated.position_ms).toBe(180000);
    expect(updated.hlc).toBe('2000.0.node_tv');
  });
});
