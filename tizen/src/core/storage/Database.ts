/**
 * CND IPTV Tizen - Storage & IndexedDB Database (PRD 38 § 2.2 & § 6)
 *
 * Implements:
 * 1. Persistent storage matching the schema of cnd-core (iptv_sources, iptv_items, series_catalog, epg_programs, profiles, settings).
 * 2. Secondary indexes for fast pagination, categories, and instant full-text search.
 * 3. Watch progress and favorites persistence per profile.
 */

export interface SourceRecord {
  id: number;
  uuid: string;
  name: string;
  source_type: 'm3u' | 'xtream';
  url?: string;
  server?: string;
  username?: string;
  password?: string;
  epg_url?: string;
  exp_date?: number;
  max_connections?: number;
  active_cons?: number;
  item_count: number;
  last_sync_at?: number;
}

export const FAVORITES_CATEGORY = '★ Favoris';
/** Virtual category: the items watched most recently, newest first (kept in the engine, not in the database). */
export const RECENT_CATEGORY = '🕒 Récemment vus';
/** How many recently watched items are remembered per kind. */
export const RECENT_LIMIT = 50;

export interface ItemRecord {
  id: number;
  source_id: number;
  series_id?: number;
  stable_hash: string;
  kind: 'live' | 'movie' | 'episode' | 'series';
  name: string;
  name_clean: string;
  year?: number;
  group_title?: string;
  tvg_id?: string;
  tvg_name?: string;
  logo_url?: string;
  chno?: number;
  country?: string;
  language?: string;
  catchup_type?: string;
  catchup_days?: number;
  stream_url: string;
  container_ext?: string;
  is_favorite: number;
  is_broken?: number;
  season_num?: number;
  episode_num?: number;
  playback_position_ms: number;
  duration_ms: number;
  imdb_rating?: number;
  plot?: string;
}

export interface SeriesRecord {
  id: number;
  source_id: number;
  canonical_key: string;
  title: string;
  group_title?: string;
  poster_url?: string;
  plot?: string;
  episode_count: number;
  season_count: number;
}

export interface EpgProgramRecord {
  id: number;
  source_id: number;
  channel_tvg_id: string;
  title: string;
  subtitle?: string;
  description?: string;
  category?: string;
  start_ts: number;
  end_ts: number;
}

export class Database {
  private static instance: Database;
  private db: IDBDatabase | null = null;
  private readonly DB_NAME = 'cnd_iptv_db';
  private readonly DB_VERSION = 1;

  public static getInstance(): Database {
    if (!Database.instance) {
      Database.instance = new Database();
    }
    return Database.instance;
  }

  public async init(): Promise<void> {
    if (this.db) return;

    return new Promise<void>((resolve, reject) => {
      const request = indexedDB.open(this.DB_NAME, this.DB_VERSION);

      request.onupgradeneeded = (event: any) => {
        const db = event.target.result as IDBDatabase;

        // Sources store
        if (!db.objectStoreNames.contains('sources')) {
          const sStore = db.createObjectStore('sources', { keyPath: 'id', autoIncrement: true });
          sStore.createIndex('uuid', 'uuid', { unique: true });
        }

        // Items store
        if (!db.objectStoreNames.contains('items')) {
          const iStore = db.createObjectStore('items', { keyPath: 'id', autoIncrement: true });
          iStore.createIndex('source_id', 'source_id', { unique: false });
          iStore.createIndex('kind', 'kind', { unique: false });
          iStore.createIndex('group_title', 'group_title', { unique: false });
          iStore.createIndex('series_id', 'series_id', { unique: false });
          iStore.createIndex('stable_hash', 'stable_hash', { unique: true });
          iStore.createIndex('is_favorite', 'is_favorite', { unique: false });
          iStore.createIndex('kind_group', ['kind', 'group_title'], { unique: false });
        }

        // Series store
        if (!db.objectStoreNames.contains('series')) {
          const serStore = db.createObjectStore('series', { keyPath: 'id', autoIncrement: true });
          serStore.createIndex('canonical_key', 'canonical_key', { unique: true });
          serStore.createIndex('source_id', 'source_id', { unique: false });
        }

        // EPG store
        if (!db.objectStoreNames.contains('epg')) {
          const epgStore = db.createObjectStore('epg', { keyPath: 'id', autoIncrement: true });
          epgStore.createIndex('channel_tvg_id', 'channel_tvg_id', { unique: false });
          epgStore.createIndex('channel_time', ['channel_tvg_id', 'start_ts', 'end_ts'], { unique: false });
        }

        // Watch progress store
        if (!db.objectStoreNames.contains('progress')) {
          db.createObjectStore('progress', { keyPath: 'item_id' });
        }

        // Settings store
        if (!db.objectStoreNames.contains('settings')) {
          db.createObjectStore('settings', { keyPath: 'key' });
        }
      };

      request.onsuccess = (event: any) => {
        this.db = event.target.result;
        resolve();
      };

      request.onerror = (event: any) => {
        reject(new Error(`Failed to open IndexedDB: ${event.target.error}`));
      };
    });
  }

  // Sources CRUD
  public async getSources(): Promise<SourceRecord[]> {
    return this.getAll<SourceRecord>('sources');
  }

  public async insertSource(source: Omit<SourceRecord, 'id'>): Promise<number> {
    return this.add('sources', source);
  }

  public async deleteSource(sourceId: number): Promise<void> {
    if (!this.db) return;
    return new Promise<void>((resolve, reject) => {
      const stores = ['sources', 'items', 'series'].filter((s) => this.db!.objectStoreNames.contains(s));
      const tx = this.db!.transaction(stores, 'readwrite');
      const sourcesStore = tx.objectStore('sources');
      sourcesStore.delete(sourceId);

      if (this.db!.objectStoreNames.contains('items')) {
        const itemsStore = tx.objectStore('items');
        if (itemsStore.indexNames.contains('source_id')) {
          const itemIndex = itemsStore.index('source_id');
          const itemCursorReq = itemIndex.openKeyCursor(IDBKeyRange.only(sourceId));
          itemCursorReq.onsuccess = () => {
            const cursor = itemCursorReq.result;
            if (cursor) {
              itemsStore.delete(cursor.primaryKey);
              cursor.continue();
            }
          };
        }
      }

      if (this.db!.objectStoreNames.contains('series')) {
        const seriesStore = tx.objectStore('series');
        if (seriesStore.indexNames.contains('source_id')) {
          const seriesIndex = seriesStore.index('source_id');
          const seriesCursorReq = seriesIndex.openKeyCursor(IDBKeyRange.only(sourceId));
          seriesCursorReq.onsuccess = () => {
            const cursor = seriesCursorReq.result;
            if (cursor) {
              seriesStore.delete(cursor.primaryKey);
              cursor.continue();
            }
          };
        }
      }

      tx.oncomplete = () => resolve();
      tx.onerror = () => reject(tx.error);
    });
  }

  // Items CRUD & Queries
  public async insertItemsBatch(
    items: Omit<ItemRecord, 'id'>[],
    onBatchProgress?: (saved: number, total: number) => void
  ): Promise<void> {
    if (!this.db || items.length === 0) return;

    // Ensure unique stable_hash within batch so a provider's duplicate streams never abort the IndexedDB transaction
    const seenHashes = new Set<string>();
    const prepared = items.map((item, idx) => {
      let hash = `${item.source_id}_${item.stable_hash}`;
      if (seenHashes.has(hash)) {
        hash = `${hash}_dup_${idx}`;
      }
      seenHashes.add(hash);
      return { ...item, stable_hash: hash };
    });

    const CHUNK_SIZE = 2500;
    const catMap = new Map<string, Set<string>>();
    for (const item of prepared) {
      if (item.group_title) {
        const k = item.kind === 'series' || item.kind === 'episode' ? 'series' : item.kind;
        let set = catMap.get(k);
        if (!set) {
          set = new Set<string>();
          catMap.set(k, set);
        }
        set.add(item.group_title);
      }
    }

    for (let offset = 0; offset < prepared.length; offset += CHUNK_SIZE) {
      const slice = prepared.slice(offset, offset + CHUNK_SIZE);
      await new Promise<void>((resolve, reject) => {
        const tx = this.db!.transaction(['items'], 'readwrite');
        const store = tx.objectStore('items');
        for (const item of slice) {
          const req = store.put(item);
          // Prevent any single ConstraintError from aborting the entire batch transaction
          req.onerror = (ev) => {
            ev.preventDefault();
            ev.stopPropagation();
          };
        }
        tx.oncomplete = () => resolve();
        tx.onerror = () => reject(tx.error);
      });
      onBatchProgress?.(Math.min(offset + slice.length, prepared.length), prepared.length);
    }

    // Persist discovered categories for instant (0ms) access on all tabs
    for (const [k, set] of catMap.entries()) {
      if (set.size > 0) {
        this.saveCategoriesCache(k, Array.from(set).sort());
      }
      try {
        localStorage.removeItem(`cnd_cat_counts_${k}`);
      } catch {}
    }
  }

  private kindsFor(kind: 'live' | 'movie' | 'series'): string[] {
    return kind === 'series' ? ['series', 'episode'] : [kind];
  }

  public async getItemsByKindAndGroup(
    kind: 'live' | 'movie' | 'series',
    groupTitle?: string,
    offset = 0,
    limit = 30
  ): Promise<ItemRecord[]> {
    if (!this.db) return [];
    const targetKinds = this.kindsFor(kind);
    const results: ItemRecord[] = [];

    // Fast-path: Favorites query across kinds
    if (groupTitle === FAVORITES_CATEGORY || groupTitle === 'Favoris') {
      await new Promise<void>((resolve, reject) => {
        const tx = this.db!.transaction(['items'], 'readonly');
        const store = tx.objectStore('items');
        const req = store.index('is_favorite').openCursor(IDBKeyRange.only(1));

        let skipped = 0;
        req.onsuccess = (ev: any) => {
          const cursor: IDBCursorWithValue | null = ev.target.result;
          if (!cursor || results.length >= limit) {
            resolve();
            return;
          }
          const item = cursor.value as ItemRecord;
          if (targetKinds.includes(item.kind)) {
            if (skipped < offset) {
              skipped++;
            } else {
              results.push(item);
            }
          }
          cursor.continue();
        };
        req.onerror = () => reject(req.error);
      });
      return results;
    }

    for (const k of targetKinds) {
      if (results.length >= limit) break;
      await new Promise<void>((resolve, reject) => {
        const tx = this.db!.transaction(['items'], 'readonly');
        const store = tx.objectStore('items');
        const req = groupTitle
          ? store.index('kind_group').openCursor(IDBKeyRange.only([k, groupTitle]))
          : store.index('kind').openCursor(IDBKeyRange.only(k));

        let hasAdvanced = false;
        req.onsuccess = (ev: any) => {
          const cursor: IDBCursorWithValue | null = ev.target.result;
          if (!cursor || results.length >= limit) {
            resolve();
            return;
          }
          if (offset > 0 && !hasAdvanced) {
            hasAdvanced = true;
            cursor.advance(offset);
            return;
          }
          results.push(cursor.value as ItemRecord);
          cursor.continue();
        };
        req.onerror = () => reject(req.error);
      });
    }

    return results;
  }

  /**
   * The item after (or before) `fromId` of this kind, optionally inside a group, in catalog order;
   * wraps around at the ends. Reads only what it needs, so it is cheap even in a huge catalog.
   */
  public async getNeighbourItem(
    kind: 'live' | 'movie' | 'series',
    groupTitle: string | undefined,
    fromId: number,
    direction: 'next' | 'prev'
  ): Promise<ItemRecord | null> {
    if (!this.db) return null;
    const forward = direction === 'next';
    const scan = (range: IDBKeyRange | undefined) =>
      new Promise<ItemRecord | null>((resolve, reject) => {
        const req = this.db!
          .transaction(['items'], 'readonly')
          .objectStore('items')
          .openCursor(range, forward ? 'next' : 'prev');
        req.onsuccess = (ev: any) => {
          const cursor: IDBCursorWithValue | null = ev.target.result;
          if (!cursor) return resolve(null);
          const item = cursor.value as ItemRecord;
          if (item.kind === kind && (!groupTitle || item.group_title === groupTitle)) return resolve(item);
          cursor.continue();
        };
        req.onerror = () => reject(req.error);
      });
    const beyond = await scan(forward ? IDBKeyRange.lowerBound(fromId, true) : IDBKeyRange.upperBound(fromId, true));
    return beyond ?? scan(undefined);
  }

  public async countItemsByKindAndGroup(
    kind: 'live' | 'movie' | 'series',
    groupTitle?: string
  ): Promise<number> {
    if (!this.db) return 0;
    const targetKinds = this.kindsFor(kind);

    // Fast-path: Count favorites
    if (groupTitle === FAVORITES_CATEGORY || groupTitle === 'Favoris') {
      let total = 0;
      await new Promise<void>((resolve, reject) => {
        const tx = this.db!.transaction(['items'], 'readonly');
        const store = tx.objectStore('items');
        const req = store.index('is_favorite').openCursor(IDBKeyRange.only(1));

        req.onsuccess = (ev: any) => {
          const cursor: IDBCursorWithValue | null = ev.target.result;
          if (!cursor) {
            resolve();
            return;
          }
          const item = cursor.value as ItemRecord;
          if (targetKinds.includes(item.kind)) {
            total++;
          }
          cursor.continue();
        };
        req.onerror = () => reject(req.error);
      });
      return total;
    }

    let total = 0;

    for (const k of targetKinds) {
      await new Promise<void>((resolve, reject) => {
        const tx = this.db!.transaction(['items'], 'readonly');
        const store = tx.objectStore('items');
        const req = groupTitle
          ? store.index('kind_group').count(IDBKeyRange.only([k, groupTitle]))
          : store.index('kind').count(IDBKeyRange.only(k));

        req.onsuccess = (ev: any) => {
          total += Number(ev.target.result || 0);
          resolve();
        };
        req.onerror = () => reject(req.error);
      });
    }

    return total;
  }

  public async searchItems(
    query: string,
    kind?: 'live' | 'movie' | 'series',
    limit = 60
  ): Promise<ItemRecord[]> {
    if (!this.db || !query.trim()) return [];
    const normalized = query.trim().toLowerCase();
    const targetKinds = kind ? this.kindsFor(kind) : ['live', 'movie', 'series', 'episode'];
    const results: ItemRecord[] = [];

    for (const k of targetKinds) {
      if (results.length >= limit) break;
      await new Promise<void>((resolve, reject) => {
        const tx = this.db!.transaction(['items'], 'readonly');
        const store = tx.objectStore('items');
        const req = store.index('kind').openCursor(IDBKeyRange.only(k));

        req.onsuccess = (ev: any) => {
          const cursor: IDBCursorWithValue | null = ev.target.result;
          if (!cursor || results.length >= limit) {
            resolve();
            return;
          }
          const item = cursor.value as ItemRecord;
          const name = (item.name || '').toLowerCase();
          const cleanName = (item.name_clean || '').toLowerCase();
          const group = (item.group_title || '').toLowerCase();
          const year = item.year ? String(item.year) : '';
          const chno = item.chno ? String(item.chno) : '';

          if (
            name.includes(normalized) ||
            cleanName.includes(normalized) ||
            group.includes(normalized) ||
            year === normalized ||
            chno === normalized
          ) {
            results.push(item);
          }
          cursor.continue();
        };
        req.onerror = () => reject(req.error);
      });
    }

    return results;
  }

  public saveCategoriesCache(kind: string, categories: string[]): void {
    try {
      localStorage.setItem(`cnd_categories_${kind}`, JSON.stringify(categories));
    } catch {}
    this.put('settings', { key: `categories_${kind}`, value: categories }).catch(() => {});
  }

  public async getCategories(kind: 'live' | 'movie' | 'series'): Promise<string[]> {
    // 1. Instant cache from localStorage (0.1ms)
    try {
      const cached = localStorage.getItem(`cnd_categories_${kind}`);
      if (cached) {
        const parsed = JSON.parse(cached);
        if (Array.isArray(parsed) && parsed.length > 0) {
          return parsed;
        }
      }
    } catch {}

    // 2. Fast cache from settings in IndexedDB (1ms)
    try {
      const setting = await this.getById<{ key: string; value: string[] }>('settings', `categories_${kind}`);
      if (setting?.value && Array.isArray(setting.value) && setting.value.length > 0) {
        try { localStorage.setItem(`cnd_categories_${kind}`, JSON.stringify(setting.value)); } catch {}
        return setting.value;
      }
    } catch {}

    // 3. Fallback: single scan and persist for subsequent tabs
    if (!this.db) return [];
    const targetKinds = this.kindsFor(kind);
    const set = new Set<string>();

    for (const k of targetKinds) {
      await new Promise<void>((resolve, reject) => {
        const tx = this.db!.transaction(['items'], 'readonly');
        const store = tx.objectStore('items');
        const req = store.index('kind').openCursor(IDBKeyRange.only(k));
        req.onsuccess = (ev: any) => {
          const cursor: IDBCursorWithValue | null = ev.target.result;
          if (!cursor) {
            resolve();
            return;
          }
          const item = cursor.value as ItemRecord;
          if (item.group_title) {
            set.add(item.group_title);
          }
          cursor.continue();
        };
        req.onerror = () => reject(req.error);
      });
    }
    const sorted = Array.from(set).sort();
    if (sorted.length > 0) {
      this.saveCategoriesCache(kind, sorted);
    }
    return sorted;
  }

  public async toggleFavorite(itemId: number): Promise<boolean> {
    if (!this.db) return false;
    const item = await this.getById<ItemRecord>('items', itemId);
    if (!item) return false;
    item.is_favorite = item.is_favorite ? 0 : 1;
    await this.put('items', item);
    return item.is_favorite === 1;
  }

  public async setBroken(itemId: number, broken = true): Promise<boolean> {
    if (!this.db) return false;
    const item = await this.getById<ItemRecord>('items', itemId);
    if (!item) return false;
    item.is_broken = broken ? 1 : 0;
    await this.put('items', item);
    return item.is_broken === 1;
  }

  public async getFavorites(): Promise<ItemRecord[]> {
    const all = await this.getAll<ItemRecord>('items');
    return all.filter((i) => i.is_favorite === 1);
  }

  public async getItemById(id: number): Promise<ItemRecord | null> {
    return this.getById<ItemRecord>('items', id);
  }

  public async getItemByStableHash(stableHash: string): Promise<ItemRecord | null> {
    if (!this.db || !stableHash) return null;
    return new Promise((resolve, reject) => {
      const tx = this.db!.transaction(['items'], 'readonly');
      const store = tx.objectStore('items');
      const index = store.index('stable_hash');
      const req = index.get(stableHash);
      req.onsuccess = () => {
        if (req.result) return resolve(req.result);
        const scanReq = store.openCursor();
        scanReq.onsuccess = (ev: any) => {
          const cursor = ev.target.result as IDBCursorWithValue;
          if (cursor) {
            const val = cursor.value as ItemRecord;
            if (val.stable_hash && (val.stable_hash === stableHash || val.stable_hash.endsWith(`_${stableHash}`))) {
              return resolve(val);
            }
            cursor.continue();
          } else {
            resolve(null);
          }
        };
        scanReq.onerror = () => resolve(null);
      };
      req.onerror = () => reject(req.error);
    });
  }

  public async getItemsByIds(ids: number[]): Promise<ItemRecord[]> {
    if (!this.db || ids.length === 0) return [];
    const results: ItemRecord[] = [];
    for (const id of ids) {
      const item = await this.getById<ItemRecord>('items', id);
      if (item) results.push(item);
    }
    return results;
  }

  public async getCategoryCounts(kind: 'live' | 'movie' | 'series'): Promise<{ total: number; favCount: number; counts: Record<string, number> }> {
    const favCount = await this.countItemsByKindAndGroup(kind, FAVORITES_CATEGORY);
    try {
      const cached = localStorage.getItem(`cnd_cat_counts_${kind}`);
      if (cached) {
        const parsed = JSON.parse(cached);
        if (parsed && typeof parsed.total === 'number' && parsed.counts) {
          return { total: parsed.total, favCount, counts: parsed.counts };
        }
      }
    } catch {}

    if (!this.db) return { total: 0, favCount, counts: {} };
    const targetKinds = this.kindsFor(kind);
    const counts: Record<string, number> = {};
    let total = 0;

    for (const k of targetKinds) {
      await new Promise<void>((resolve, reject) => {
        const tx = this.db!.transaction(['items'], 'readonly');
        const store = tx.objectStore('items');
        const req = store.index('kind').openCursor(IDBKeyRange.only(k));
        req.onsuccess = (ev: any) => {
          const cursor: IDBCursorWithValue | null = ev.target.result;
          if (!cursor) {
            resolve();
            return;
          }
          const item = cursor.value as ItemRecord;
          total++;
          const grp = item.group_title || 'Autres';
          counts[grp] = (counts[grp] || 0) + 1;
          cursor.continue();
        };
        req.onerror = () => reject(req.error);
      });
    }

    if (total > 0) {
      try {
        localStorage.setItem(`cnd_cat_counts_${kind}`, JSON.stringify({ total, counts }));
      } catch {}
    }

    return { total, favCount, counts };
  }

  public async updateWatchProgress(itemId: number, positionMs: number, durationMs: number): Promise<void> {
    await this.put('progress', {
      item_id: itemId,
      position_ms: positionMs,
      duration_ms: durationMs,
      updated_at: Date.now(),
    });
  }

  /** The programs of a channel that have not ended yet, in time order (read through the channel index). */
  public async getEpgUpcoming(channelTvgId: string, nowTs: number, count = 4): Promise<EpgProgramRecord[]> {
    const programs = await new Promise<EpgProgramRecord[]>((resolve, reject) => {
      if (!this.db) return resolve([]);
      const req = this.db
        .transaction(['epg'], 'readonly')
        .objectStore('epg')
        .index('channel_tvg_id')
        .getAll(IDBKeyRange.only(channelTvgId));
      req.onsuccess = () => resolve((req.result as EpgProgramRecord[]) || []);
      req.onerror = () => reject(req.error);
    });
    return programs
      .filter((p) => p.end_ts > nowTs)
      .sort((a, b) => a.start_ts - b.start_ts)
      .slice(0, count);
  }

  public async getEpgNowNext(channelTvgId: string, nowTs: number): Promise<{ now?: EpgProgramRecord; next?: EpgProgramRecord }> {
    const matching = await this.getEpgUpcoming(channelTvgId, nowTs, 2);
    return { now: matching[0], next: matching[1] };
  }

  // Generic Helpers
  private getAll<T>(storeName: string): Promise<T[]> {
    return new Promise((resolve, reject) => {
      if (!this.db) return resolve([]);
      const tx = this.db.transaction([storeName], 'readonly');
      const store = tx.objectStore(storeName);
      const req = store.getAll();
      req.onsuccess = () => resolve(req.result || []);
      req.onerror = () => reject(req.error);
    });
  }

  private getById<T>(storeName: string, id: any): Promise<T | null> {
    return new Promise((resolve, reject) => {
      if (!this.db) return resolve(null);
      const tx = this.db.transaction([storeName], 'readonly');
      const store = tx.objectStore(storeName);
      const req = store.get(id);
      req.onsuccess = () => resolve(req.result || null);
      req.onerror = () => reject(req.error);
    });
  }

  private add(storeName: string, value: any): Promise<number> {
    return new Promise((resolve, reject) => {
      if (!this.db) return reject(new Error('DB not initialized'));
      const tx = this.db.transaction([storeName], 'readwrite');
      const store = tx.objectStore(storeName);
      const req = store.add(value);
      req.onsuccess = () => resolve(req.result as number);
      req.onerror = () => reject(req.error);
    });
  }

  private put(storeName: string, value: any): Promise<void> {
    return new Promise((resolve, reject) => {
      if (!this.db) return reject(new Error('DB not initialized'));
      const tx = this.db.transaction([storeName], 'readwrite');
      const store = tx.objectStore(storeName);
      const req = store.put(value);
      req.onsuccess = () => resolve();
      req.onerror = () => reject(req.error);
    });
  }
}

