import { describe, it, expect, beforeEach, vi } from 'vitest';
import { LocalSyncService } from '../src/core/sync/LocalSyncService';
import { Database } from '../src/core/storage/Database';

describe('HouseholdSyncDelta Tests (PRD-45 Sync & Logging on Tizen)', () => {
  const localStore = new Map<string, string>();
  const mockLocalStorage = {
    getItem: (key: string) => localStore.get(key) || null,
    setItem: (key: string, val: string) => localStore.set(key, val),
    removeItem: (key: string) => localStore.delete(key),
    clear: () => localStore.clear(),
  };

  beforeEach(() => {
    localStore.clear();
    (globalThis as any).localStorage = mockLocalStorage;
  });

  it('records logs and notifies subscribers via onLogChange', () => {
    const service = LocalSyncService.getInstance();
    const recordedLogs: any[] = [];
    const unsub = service.onLogChange((logs) => {
      recordedLogs.push(...logs);
    });

    service.log('Test unitaire log message');
    service.log('Test unitaire warning message', true);

    const logs = service.getLogs();
    expect(logs.length).toBeGreaterThanOrEqual(2);
    expect(logs[0].text).toBe('Test unitaire warning message');
    expect(logs[0].warning).toBe(true);
    expect(logs[1].text).toBe('Test unitaire log message');
    expect(logs[1].warning).toBe(false);

    unsub();
  });

  it('applies household_data_delta with favorites and tombstones', async () => {
    const service = LocalSyncService.getInstance();
    const db = Database.getInstance();

    // Mock Database methods
    let favToggled = 0;
    const itemsMap = new Map<string, any>([
      ['hash_movie_1', { id: 10, stable_hash: 'hash_movie_1', is_favorite: 0, duration_ms: 7200000 }],
      ['hash_movie_2', { id: 20, stable_hash: 'hash_movie_2', is_favorite: 1, duration_ms: 5400000 }],
    ]);

    vi.spyOn(db, 'getItemByStableHashIndexed').mockImplementation(async (hash: string) => {
      return itemsMap.get(hash) || null;
    });

    vi.spyOn(db, 'toggleFavorite').mockImplementation(async (id: number) => {
      for (const item of itemsMap.values()) {
        if (item.id === id) {
          item.is_favorite = item.is_favorite === 1 ? 0 : 1;
          favToggled++;
          return item.is_favorite === 1;
        }
      }
      return false;
    });

    let progressUpdated: { id: number; pos: number; dur: number } | null = null;
    vi.spyOn(db, 'updateWatchProgress').mockImplementation(async (id: number, pos: number, dur: number) => {
      progressUpdated = { id, pos, dur };
    });

    // 1. Delta containing 1 new favorite, 1 tombstone removal, and 1 watch progress
    const delta = {
      sources: [],
      profiles: [],
      favorites: [
        { stable_hash: 'hash_movie_1', item_kind: 'movie', created_at: Date.now() },
      ],
      watch_history: [
        { stable_hash: 'hash_movie_1', position_ms: 120000, duration_ms: 7200000, completed: false },
      ],
      tombstones: [
        { kind: 'favorite', key: 'hash_movie_2', deleted_at: Date.now() },
      ],
    };

    await service.applyHouseholdDataDelta(delta, 'iphone_device_123');

    // Item 1 should have become favorite
    expect(itemsMap.get('hash_movie_1')?.is_favorite).toBe(1);
    // Item 2 should have been removed from favorites
    expect(itemsMap.get('hash_movie_2')?.is_favorite).toBe(0);
    // Progress should be updated
    expect(progressUpdated).toEqual({ id: 10, pos: 120000, dur: 7200000 });

    // Verify sync logs recorded the arrival and application
    const logs = service.getLogs();
    const lastLog = logs[0].text;
    expect(lastLog).toContain('Synchronisation appliquée');
    expect(lastLog).toContain('1 favori(s)');
    expect(lastLog).toContain('1 supprimé(s)');
  });

  it('immediately persists received IPTV sources and logs their arrival', async () => {
    const service = LocalSyncService.getInstance();
    const db = Database.getInstance();

    let upsertedSource: any = null;
    vi.spyOn(db, 'getSharedSources').mockResolvedValue([]);
    vi.spyOn(db, 'upsertSource').mockImplementation(async (src: any) => {
      upsertedSource = src;
      return 42;
    });

    const delta = {
      sources: [
        {
          uuid: 'src_test_123',
          name: 'Mon Abonnement Premium',
          source_type: 'xtream',
          server: 'http://fournisseur.test:8080',
          username: 'user_demo',
          password: 'pwd_secret_123',
          item_count: 500,
        },
      ],
      favorites: [],
      watch_history: [],
      tombstones: [],
    };

    await service.applyHouseholdDataDelta(delta, 'iphone_device_999');

    // Verify source was saved immediately in database
    expect(upsertedSource).not.toBeNull();
    expect(upsertedSource.uuid).toBe('src_test_123');
    expect(upsertedSource.name).toBe('Mon Abonnement Premium');
    expect(upsertedSource.source_type).toBe('xtream');
    expect(upsertedSource.server).toBe('http://fournisseur.test:8080');
    expect(upsertedSource.username).toBe('user_demo');
    expect(upsertedSource.password).toBe('pwd_secret_123');

    // Verify logs
    const logs = service.getLogs().map((l) => l.text);
    expect(logs.some((t) => t.includes('Compte récupéré du foyer') && t.includes('Mon Abonnement Premium'))).toBe(true);
    expect(logs.some((t) => t.includes('enregistré dans les sources de la TV') && t.includes('Mon Abonnement Premium'))).toBe(true);
    // Ensure secrets are never exposed in log output
    expect(logs.some((t) => t.includes('pwd_secret_123'))).toBe(false);
  });

  it('stores the accounts even when the favorite lookups never answer (65 000 items on the TV)', async () => {
    const service = LocalSyncService.getInstance();
    const db = Database.getInstance();

    let upserted = 0;
    vi.spyOn(db, 'getSharedSources').mockResolvedValue([]);
    vi.spyOn(db, 'upsertSource').mockImplementation(async () => {
      upserted++;
      return 7;
    });
    // A lookup that never resolves: before the fix, the accounts waited behind it forever.
    vi.spyOn(db, 'getItemByStableHashIndexed').mockImplementation(() => new Promise(() => {}));

    void service.applyHouseholdDataDelta(
      {
        sources: [{ uuid: 'src_slow', name: 'Compte M3U', source_type: 'm3u', url: 'http://playlist.test/list.m3u' }],
        favorites: [{ stable_hash: 'h1', item_kind: 'movie' }],
        watch_history: [{ stable_hash: 'h2', position_ms: 1, duration_ms: 2 }],
        tombstones: [],
      },
      'iphone_device_999'
    );
    await new Promise((r) => setTimeout(r, 20));

    expect(upserted).toBe(1);
  });
});
