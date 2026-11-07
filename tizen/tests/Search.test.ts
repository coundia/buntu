import { describe, it, expect, beforeAll, vi } from 'vitest';
import { existsSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { Database, ItemRecord } from '../src/core/storage/Database';
import { CndEngine } from '../src/core/engine/CndEngine';
import { setWasmSource } from '../src/worker/handlers';

const WASM = resolve(__dirname, '../src/wasm/pkg/cnd_domain_wasm_bg.wasm');

describe('Full-Screen & In-Screen IPTV Search Architecture', () => {
  const db = Database.getInstance();
  const engine = CndEngine.getInstance();

  const sampleItems: ItemRecord[] = [
    {
      id: 1,
      source_id: 1,
      stable_hash: 'hash_live_tf1',
      kind: 'live',
      name: 'FR: TF1 HD',
      name_clean: 'TF1 HD',
      group_title: 'GENERAL',
      chno: 1,
      stream_url: 'http://example.com/live/tf1.ts',
      is_favorite: 0,
      playback_position_ms: 0,
    },
    {
      id: 2,
      source_id: 1,
      stable_hash: 'hash_live_canal',
      kind: 'live',
      name: 'FR: CANAL+ SPORT',
      name_clean: 'CANAL+ SPORT',
      group_title: 'SPORT',
      chno: 4,
      stream_url: 'http://example.com/live/canal.ts',
      is_favorite: 0,
      playback_position_ms: 0,
    },
    {
      id: 3,
      source_id: 1,
      stable_hash: 'hash_movie_gladiator',
      kind: 'movie',
      name: 'Gladiator II (2024)',
      name_clean: 'Gladiator II',
      group_title: 'ACTION',
      year: 2024,
      stream_url: 'http://example.com/movie/gladiator.mkv',
      is_favorite: 0,
      playback_position_ms: 0,
    },
    {
      id: 4,
      source_id: 1,
      stable_hash: 'hash_series_shogun',
      kind: 'series',
      name: 'Shogun (2024)',
      name_clean: 'Shogun',
      group_title: 'DRAMA',
      year: 2024,
      season_num: 1,
      episode_num: 1,
      stream_url: 'http://example.com/series/shogun_s01e01.mkv',
      is_favorite: 0,
      playback_position_ms: 0,
    },
  ];

  beforeAll(() => {
    if (existsSync(WASM)) {
      setWasmSource(readFileSync(WASM));
    }

    vi.spyOn(db, 'searchItems').mockImplementation(async (query: string, kind?: any, limit = 60) => {
      const q = query.toLowerCase();
      return sampleItems.filter((item) => {
        if (kind && item.kind !== kind) return false;
        const name = (item.name || '').toLowerCase();
        const cleanName = (item.name_clean || '').toLowerCase();
        const group = (item.group_title || '').toLowerCase();
        const year = item.year ? String(item.year) : '';
        const chno = item.chno ? String(item.chno) : '';
        return (
          name.includes(q) ||
          cleanName.includes(q) ||
          group.includes(q) ||
          year === q ||
          chno === q
        );
      }).slice(0, limit);
    });
  });

  it('searches channels by name query', async () => {
    const results = await engine.searchCatalog('canal', 'live');
    expect(results.length).toBeGreaterThan(0);
    expect(results[0].name).toContain('CANAL+ SPORT');
  });

  it('searches channels by channel number', async () => {
    const results = await engine.searchCatalog('4', 'live');
    expect(results.length).toBeGreaterThan(0);
    expect(results[0].chno).toBe(4);
  });

  it('filters search by kind (movie vs live)', async () => {
    const movieResults = await engine.searchCatalog('gladiator', 'movie');
    expect(movieResults.length).toBeGreaterThan(0);
    expect(movieResults[0].kind).toBe('movie');

    // Searching 'gladiator' in live returns empty
    const liveResults = await engine.searchCatalog('gladiator', 'live');
    expect(liveResults.length).toBe(0);
  });

  it('searches across all kinds when kind is not specified', async () => {
    const allResults = await engine.searchCatalog('2024');
    expect(allResults.length).toBeGreaterThanOrEqual(2);
    const kinds = allResults.map((r) => r.kind);
    expect(kinds).toContain('movie');
    expect(kinds).toContain('series');
  });
});
