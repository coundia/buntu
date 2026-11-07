import { describe, it, expect, beforeEach, beforeAll } from 'vitest';
import { existsSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { Database } from '../src/core/storage/Database';
import { CndEngine } from '../src/core/engine/CndEngine';
import { setWasmSource } from '../src/worker/handlers';

const WASM = resolve(__dirname, '../src/wasm/pkg/cnd_domain_wasm_bg.wasm');

describe('Pagination & Micro-Cache Optimization', () => {
  const store = new Map<string, string>();
  const mockLocalStorage = {
    getItem: (key: string) => store.get(key) || null,
    setItem: (key: string, val: string) => store.set(key, val),
    removeItem: (key: string) => store.delete(key),
    clear: () => store.clear(),
  };

  beforeAll(() => {
    if (existsSync(WASM)) {
      setWasmSource(readFileSync(WASM));
    }
  });

  beforeEach(() => {
    store.clear();
    (globalThis as any).localStorage = mockLocalStorage;
  });

  it('Database saves and retrieves categories from instant localStorage cache', async () => {
    const db = Database.getInstance();
    const testCats = ['Action', 'Comédie', 'Drame', 'Science-Fiction'];

    db.saveCategoriesCache('movie', testCats);

    const retrieved = await db.getCategories('movie');
    expect(retrieved).toEqual(testCats);
  });

  it('CndEngine getCategories returns from in-memory cache without rescanning', async () => {
    const engine = CndEngine.getInstance();
    mockLocalStorage.setItem('cnd_categories_live', JSON.stringify(['France', 'Sport', 'Cinéma']));

    const cats1 = await engine.getCategories('live');
    expect(cats1).toEqual(['France', 'Sport', 'Cinéma']);

    // Changing localStorage won't affect in-memory cache until invalidated
    mockLocalStorage.setItem('cnd_categories_live', JSON.stringify(['OnlyNews']));
    const cats2 = await engine.getCategories('live');
    expect(cats2).toEqual(['France', 'Sport', 'Cinéma']);
  });
});

