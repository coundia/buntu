import { describe, it, expect, beforeAll, afterEach, vi } from 'vitest';
import { existsSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { setWasmSource } from '../src/worker/handlers';
import { accountIdentity, findSameAccount } from '../src/core/sync/AccountIdentity';
import { LocalSyncService } from '../src/core/sync/LocalSyncService';
import { CndEngine } from '../src/core/engine/CndEngine';
import { Database, SourceRecord } from '../src/core/storage/Database';

const WASM = resolve(__dirname, '../src/wasm/pkg/cnd_domain_wasm_bg.wasm');

const tvAccount: SourceRecord = {
  id: 7,
  uuid: 'src_tv_1',
  name: 'Mon IPTV',
  source_type: 'xtream',
  server: 'http://srv.example:8080',
  username: 'bob',
  password: 'secret',
  item_count: 1200,
};

// The rule is the Rust one (`account_identity_key`), run from the real WebAssembly.
describe.skipIf(!existsSync(WASM))('Same IPTV account never stored twice on the TV', () => {
  beforeAll(() => {
    setWasmSource(readFileSync(WASM));
    const store = new Map<string, string>();
    (globalThis as any).localStorage = {
      getItem: (k: string) => store.get(k) || null,
      setItem: (k: string, v: string) => store.set(k, v),
      removeItem: (k: string) => store.delete(k),
      clear: () => store.clear(),
    };
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it('recognises an account written differently, or read through its get.php playlist', async () => {
    const same = await findSameAccount(
      { uuid: 'src_iphone_9', source_type: 'xtream', server: 'http://SRV.example:8080/', username: 'bob' },
      [tvAccount]
    );
    expect(same?.id).toBe(7);

    const playlist = await findSameAccount(
      { source_type: 'm3u', url: 'http://srv.example:8080/get.php?username=bob&password=x&type=m3u_plus' },
      [tvAccount]
    );
    expect(playlist?.id).toBe(7);

    const otherUser = await findSameAccount(
      { source_type: 'xtream', server: 'http://srv.example:8080', username: 'alice' },
      [tvAccount]
    );
    expect(otherUser).toBeUndefined();
    expect(await accountIdentity(tvAccount)).toMatch(/^[0-9a-f]{64}$/);
  });

  it('does not add a second copy when the household sends an account the TV already has', async () => {
    const db = Database.getInstance();
    vi.spyOn(db, 'getSources').mockResolvedValue([tvAccount]);
    const upsert = vi.spyOn(db, 'upsertSource').mockResolvedValue(7);
    const download = vi.spyOn(CndEngine.getInstance(), 'syncXtreamSource').mockResolvedValue(0);

    await LocalSyncService.getInstance().applyHouseholdDataDelta(
      {
        sources: [
          { uuid: 'src_mac_1', name: 'Compte du Mac', source_type: 'xtream', server: 'http://srv.example:8080/', username: 'Bob', password: 'secret' },
          { uuid: 'src_mac_2', name: 'Doublon du Mac', source_type: 'xtream', server: 'http://srv.example:8080', username: 'bob', password: 'secret' },
        ],
        favorites: [],
        watch_history: [],
        tombstones: [],
      },
      'mac_1'
    );

    expect(upsert).not.toHaveBeenCalled();
    expect(download).not.toHaveBeenCalled();
  });

  it('adds a new account once, even when the delta carries it twice', async () => {
    const db = Database.getInstance();
    const saved: SourceRecord[] = [];
    vi.spyOn(db, 'getSources').mockImplementation(async () => [...saved]);
    vi.spyOn(db, 'upsertSource').mockImplementation(async (s: any) => {
      saved.push({ ...s, id: saved.length + 1 });
      return saved.length;
    });
    vi.spyOn(CndEngine.getInstance(), 'syncXtreamSource').mockResolvedValue(0);

    await LocalSyncService.getInstance().applyHouseholdDataDelta(
      {
        sources: [
          { uuid: 'src_a', name: 'Compte', source_type: 'xtream', server: 'http://new.example', username: 'zoe', password: 'p' },
          { uuid: 'src_b', name: 'Compte bis', source_type: 'xtream', server: 'http://NEW.example/', username: 'zoe', password: 'p' },
        ],
        favorites: [],
        watch_history: [],
        tombstones: [],
      },
      'phone_1'
    );

    expect(saved.map((s) => s.uuid)).toEqual(['src_a']);
  });

  it('re-synchronising or re-typing an account updates it and keeps its uuid and name', async () => {
    const db = Database.getInstance();
    vi.spyOn(db, 'getSources').mockResolvedValue([tvAccount]);
    const upsert = vi.spyOn(db, 'upsertSource').mockResolvedValue(7);

    const id = await (CndEngine.getInstance() as any).saveSource({
      uuid: 'src_' + Date.now(),
      name: 'Nouveau nom',
      source_type: 'xtream',
      server: 'http://srv.example:8080',
      username: 'bob',
      password: 'new-secret',
      item_count: 1300,
    });

    expect(id).toBe(7);
    const written = upsert.mock.calls[0][0] as any;
    expect(written.id).toBe(7);
    expect(written.uuid).toBe('src_tv_1');
    expect(written.name).toBe('Mon IPTV');
    expect(written.password).toBe('new-secret');
  });
});
