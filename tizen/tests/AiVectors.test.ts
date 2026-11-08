import { describe, it, expect, beforeAll } from 'vitest';
import { existsSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { WorkerBridge } from '../src/worker/worker-bridge';
import { setWasmSource } from '../src/worker/handlers';

const WASM = resolve(__dirname, '../src/wasm/pkg/cnd_domain_wasm_bg.wasm');
const VECTORS_PATH = resolve(__dirname, '../../crates/cnd-domain/src/ai/vectors.json');

describe.skipIf(!existsSync(WASM) || !existsSync(VECTORS_PATH))('AI Vectors Parity (Domain Wasm -> Tizen Worker)', () => {
  let bridge: WorkerBridge;
  let vectors: any;

  beforeAll(() => {
    setWasmSource(readFileSync(WASM));
    bridge = new (WorkerBridge as any)() as WorkerBridge;
    vectors = JSON.parse(readFileSync(VECTORS_PATH, 'utf-8'));
  });

  it('builds requests matching canonical vectors for Gemini, OpenAI and Anthropic', async () => {
    for (const [providerKey, vec] of Object.entries<any>(vectors.build_request)) {
      const res = await bridge.post('AI_BUILD_REQUEST', {
        config: vec.config,
        task: vec.task,
        payload: {
          system: vec.system,
          user: vec.user,
          mode: vec.mode,
        },
      });

      expect(res.url).toBe(vec.expected_url);
      expect(res.method).toBe('POST');
      const hasHeader = res.headers.some(
        ([k, v]: [string, string]) =>
          k.toLowerCase() === vec.expected_header_key.toLowerCase() && v === vec.expected_header_val
      );
      expect(hasHeader).toBe(true);
    }
  });

  it('translates HTTP error statuses into user-friendly explanations', async () => {
    for (const errCase of vectors.explain_error) {
      const res = await bridge.post('AI_READ_RESPONSE', {
        kind: 'gemini',
        status: errCase.status,
        body: errCase.body,
      });

      expect(res.ok).toBe(false);
      expect(res.error).toBeDefined();
      expect(res.error.toLowerCase()).toContain(errCase.expected_contains.toLowerCase());
    }
  });

  it('validates decision command payloads against candidates', async () => {
    const vc = vectors.validate_command;

    // 1. Valid play command
    const res1 = await bridge.post('AI_VALIDATE', {
      task: 'command',
      text: vc.valid_play.json,
      candidates: vc.valid_play.candidates,
      profile: {},
    });
    expect(res1.ok).toBe(true);
    expect(res1.action.action).toBe(vc.valid_play.expected_action);
    expect(res1.action.item_id).toBe(vc.valid_play.expected_item_id);

    // 2. Unknown channel rejection
    const res2 = await bridge.post('AI_VALIDATE', {
      task: 'command',
      text: vc.unknown_channel.json,
      candidates: vc.unknown_channel.candidates,
      profile: {},
    });
    expect(res2.ok).toBe(false);
    expect(res2.error).toContain(vc.unknown_channel.expected_error);

    // 3. Valid search command
    const res3 = await bridge.post('AI_VALIDATE', {
      task: 'command',
      text: vc.valid_search.json,
      candidates: vc.valid_search.candidates,
      profile: {},
    });
    expect(res3.ok).toBe(true);
    expect(res3.action.action).toBe(vc.valid_search.expected_action);
    expect(res3.action.query).toBe(vc.valid_search.expected_query);
  });

  it('resolves commands locally with zero network calls', async () => {
    for (const testCase of vectors.resolve_local) {
      const res = await bridge.post('AI_RESOLVE_LOCAL', {
        command: testCase.command,
        candidates: testCase.candidates,
        context: {},
      });

      expect(res.action).toBeDefined();
      expect(res.action.action).toBe(testCase.expected_action);
      if (testCase.expected_item_id !== undefined) {
        expect(res.action.item_id).toBe(testCase.expected_item_id);
      }
    }
  });
});
