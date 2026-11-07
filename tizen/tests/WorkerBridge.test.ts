import { describe, it, expect, beforeAll } from 'vitest';
import { existsSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { WorkerBridge } from '../src/worker/worker-bridge';
import { setWasmSource } from '../src/worker/handlers';

const WASM = resolve(__dirname, '../src/wasm/pkg/cnd_domain_wasm_bg.wasm');

// A TV on which no Web Worker can start (Tizen 5 and 6 cannot start a module worker) must still
// show the QR code: the domain then runs on the main thread, with the same handlers.
describe.skipIf(!existsSync(WASM))('WorkerBridge on a TV without a usable Web Worker', () => {
  beforeAll(() => {
    // jsdom has no Worker, exactly the case to cover.
    expect((globalThis as any).Worker).toBeUndefined();
    setWasmSource(readFileSync(WASM));
  });

  it('falls back to the main thread and still answers', async () => {
    const bridge = new (WorkerBridge as any)() as WorkerBridge;
    const version = await bridge.getVersion();
    expect(version).toContain('cnd-domain-wasm');
    expect(bridge.isInProcess).toBe(true);
  });

  it('draws the QR code and runs the pairing protocol on the main thread', async () => {
    const bridge = new (WorkerBridge as any)() as WorkerBridge;
    const entropy = Uint8Array.from({ length: 40 }, (_, i) => i);
    const offer = JSON.parse(await bridge.pairingCreateOffer(entropy, 'Salon TV', 'msf', '192.168.1.9', 8001, 1_800_000_000));
    const [size, modules] = (await bridge.qrMatrix(offer.link)).split(':');
    expect(Number(size) ** 2).toBe(modules.length);
    expect(offer.link.startsWith('buntu://pair')).toBe(true);
  });

  it('reports a failing call as an error, not as a hang', async () => {
    const bridge = new (WorkerBridge as any)() as WorkerBridge;
    await expect(bridge.post('NO_SUCH_REQUEST')).rejects.toThrow(/Unknown worker message type/);
  });

  it('uses strict WebAssembly 1.0 MVP function signatures (at most 1 return value, no externref)', () => {
    // Regression guard for Tizen Chromium 56..84: V8 rejects modules with multi-value returns
    // ("return count of 4 exceeds internal limit") or externref (0x6f).
    const bytes = readFileSync(WASM);
    const readLeb = (pos: number): [number, number] => {
      let result = 0;
      let shift = 0;
      while (true) {
        const byte = bytes[pos++];
        result |= (byte & 0x7f) << shift;
        if ((byte & 0x80) === 0) return [result >>> 0, pos];
        shift += 7;
      }
    };

    let offset = 8; // skip \0asm + version
    let checkedTypeSection = false;
    while (offset < bytes.length) {
      const sectionId = bytes[offset++];
      const [sectionLen, bodyStart] = readLeb(offset);
      const sectionEnd = bodyStart + sectionLen;
      if (sectionId === 1) {
        checkedTypeSection = true;
        let [typeCount, p] = readLeb(bodyStart);
        for (let i = 0; i < typeCount; i++) {
          const form = bytes[p++];
          expect(form).toBe(0x60);
          let paramCount: number;
          [paramCount, p] = readLeb(p);
          const params = Array.from(bytes.subarray(p, p + paramCount));
          p += paramCount;
          let returnCount: number;
          [returnCount, p] = readLeb(p);
          const returns = Array.from(bytes.subarray(p, p + returnCount));
          p += returnCount;

          expect(returnCount).toBeLessThanOrEqual(1);
          expect(params).not.toContain(0x6f);
          expect(returns).not.toContain(0x6f);
        }
      }
      offset = sectionEnd;
    }
    expect(checkedTypeSection).toBe(true);
  });
});
