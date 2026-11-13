import { describe, it, expect, beforeEach } from 'vitest';
import { getAiSettings, saveAiSettings } from '../src/core/ai/AiSettings';
import { AiKeyStore } from '../src/core/ai/AiKeyStore';

function createMockIndexedDB() {
  const stores = new Map<string, Map<string, any>>();

  return {
    open(dbName: string, version: number) {
      const req: any = {
        onsuccess: null,
        onerror: null,
        onupgradeneeded: null,
        result: null,
      };

      setTimeout(() => {
        const db: any = {
          objectStoreNames: {
            contains(name: string) {
              return stores.has(name);
            },
          },
          createObjectStore(name: string) {
            stores.set(name, new Map());
            return {};
          },
          transaction(storeName: string, mode: string) {
            if (!stores.has(storeName)) {
              stores.set(storeName, new Map());
            }
            const map = stores.get(storeName)!;

            return {
              set oncomplete(callback: () => void) { setTimeout(callback, 0); },
              objectStore(name: string) {
                return {
                  get(key: string) {
                    const r: any = { onsuccess: null, onerror: null, result: undefined };
                    setTimeout(() => {
                      r.result = map.get(key);
                      if (r.onsuccess) r.onsuccess();
                    }, 0);
                    return r;
                  },
                  put(val: any, key: string) {
                    const r: any = { onsuccess: null, onerror: null };
                    setTimeout(() => {
                      map.set(key, val);
                      if (r.onsuccess) r.onsuccess();
                    }, 0);
                    return r;
                  },
                  delete(key: string) {
                    const r: any = { onsuccess: null, onerror: null };
                    setTimeout(() => {
                      map.delete(key);
                      if (r.onsuccess) r.onsuccess();
                    }, 0);
                    return r;
                  },
                };
              },
            };
          },
        };

        req.result = db;
        if (req.onupgradeneeded) {
          req.onupgradeneeded({ target: { result: db } });
        }
        if (req.onsuccess) {
          req.onsuccess({ target: { result: db } });
        }
      }, 0);

      return req;
    },
    _stores: stores,
  };
}

describe('AiKeyStore', () => {
  let mockIdb: ReturnType<typeof createMockIndexedDB>;

  beforeEach(() => {
    mockIdb = createMockIndexedDB();
    (globalThis as any).indexedDB = mockIdb;
    // Reset private singleton state between tests
    (AiKeyStore as any).instance = new (AiKeyStore as any)();
  });

  it('encrypts and stores API key in vault and retrieves plaintext', async () => {
    const store = AiKeyStore.getInstance();
    expect(await store.hasApiKey()).toBe(false);
    expect(await store.getApiKey()).toBe(null);

    await store.setApiKey('AIzaSyD-SecretKey-9999');

    expect(await store.hasApiKey()).toBe(true);
    expect(await store.getApiKey()).toBe('AIzaSyD-SecretKey-9999');

    // Verify stored data is encrypted (iv and ciphertext present, plaintext absent)
    const vault = mockIdb._stores.get('keys');
    expect(vault).toBeDefined();
    const storedRecord = vault?.get(`encrypted_api_key_${getAiSettings().provider}`);
    expect(storedRecord).toBeDefined();
    expect(storedRecord.iv).toBeInstanceOf(Uint8Array);
    expect(storedRecord.ciphertext).toBeDefined();
    expect(storedRecord.ciphertext.byteLength).toBeGreaterThan(0);
    expect(JSON.stringify(storedRecord)).not.toContain('AIzaSyD-SecretKey-9999');
  });

  it('masks the API key appropriately', async () => {
    const store = AiKeyStore.getInstance();
    await store.setApiKey('AIzaSyD-TestKey-5678');
    expect(await store.getMaskedKey()).toBe('••••••••5678');

    await store.setApiKey('123');
    expect(await store.getMaskedKey()).toBe('••••');
  });

  it('keeps each provider in a separate encrypted slot', async () => {
    const store = AiKeyStore.getInstance();
    await store.setApiKey('test-only-gemini', 'gemini');
    await store.setApiKey('test-only-claude', 'anthropic');
    expect(await store.getApiKey('gemini')).toBe('test-only-gemini');
    expect(await store.getApiKey('anthropic')).toBe('test-only-claude');
    await store.deleteApiKey('gemini');
    expect(await store.getApiKey('gemini')).toBeNull();
    expect(await store.getApiKey('anthropic')).toBe('test-only-claude');
  });

  it('migrates the old encrypted slot only to the selected provider', async () => {
    saveAiSettings({ provider: 'gemini' });
    const store = AiKeyStore.getInstance();
    await store.setApiKey('test-only-legacy');
    const records = mockIdb._stores.get('keys')!;
    records.set('encrypted_api_key', records.get('encrypted_api_key_gemini'));
    records.delete('encrypted_api_key_gemini');
    expect(await store.getApiKey('anthropic')).toBeNull();
    expect(await store.getApiKey('gemini')).toBe('test-only-legacy');
    expect(records.has('encrypted_api_key')).toBe(false);
  });

  it('deletes API key from vault', async () => {
    const store = AiKeyStore.getInstance();
    await store.setApiKey('test-key-to-delete');
    expect(await store.hasApiKey()).toBe(true);

    await store.deleteApiKey();
    expect(await store.hasApiKey()).toBe(false);
    expect(await store.getApiKey()).toBe(null);
    expect(await store.getMaskedKey()).toBe(null);
  });

  it('treats empty or whitespace keys as delete', async () => {
    const store = AiKeyStore.getInstance();
    await store.setApiKey('temporary-key');
    expect(await store.hasApiKey()).toBe(true);

    await store.setApiKey('   ');
    expect(await store.hasApiKey()).toBe(false);
    expect(await store.getApiKey()).toBe(null);
  });
});
