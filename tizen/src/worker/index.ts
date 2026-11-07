/**
 * CND IPTV Tizen - Dedicated Web Worker (PRD 38 § 2.3)
 *
 * Runs the WebAssembly domain off the main UI thread. The work itself lives in `handlers.ts`, shared
 * with the main-thread fallback for TVs where a worker cannot start.
 */
import { handleRequest, ensureWasm } from './handlers';

void ensureWasm().catch((err) => console.error('[Worker] Failed to initialize wasm:', err));

self.onmessage = async (e: MessageEvent) => {
  const { id, type, payload } = e.data;
  try {
    const result = await handleRequest(type, payload);
    (self as any).postMessage({ id, success: true, result });
  } catch (err: any) {
    (self as any).postMessage({ id, success: false, error: err?.message || String(err) });
  }
};
