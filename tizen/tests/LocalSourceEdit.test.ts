import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { webcrypto } from 'node:crypto';
import { Database, SourceRecord } from '../src/core/storage/Database';
import { LocalSourceVault, SourceConnectionEdit } from '../src/core/storage/LocalSourceVault';
import { LocalSyncService } from '../src/core/sync/LocalSyncService';
import { HouseholdStore } from '../src/core/sync/HouseholdStore';
import { CndEngine } from '../src/core/engine/CndEngine';
import { RemotePlaybackCoordinator } from '../src/core/remote/RemotePlayback';
import { AVPlayerService } from '../src/core/player/AVPlayerService';
import { WorkerBridge } from '../src/worker/worker-bridge';
import { setWasmSource } from '../src/worker/handlers';

const base: SourceRecord = { id: 22, uuid: 'source-household', name: 'Compte reçu', source_type: 'xtream', server: 'http://shared.invalid', username: 'shared-user', password: 'shared-password', item_count: 10, local_override: true };
const edit: SourceConnectionEdit = { source_type: 'xtream', server: 'https://local.invalid', username: 'local-user', password: 'local-password', url: '' };

afterEach(() => { vi.restoreAllMocks(); vi.unstubAllGlobals(); });

describe('Local source edits and household separation', () => {
  beforeEach(() => {
    vi.spyOn(Database.getInstance(), 'getSharedSources').mockResolvedValue([{ ...base }]);
    vi.spyOn(LocalSourceVault.getInstance(), 'get').mockResolvedValue({ ...edit });
    setWasmSource(readFileSync(resolve(__dirname, '../src/wasm/pkg/cnd_domain_wasm_bg.wasm')));
  });

  it('applies local credentials to the TV while exporting only the household original', async () => {
    const db = Database.getInstance();
    const effective = await db.getSources();
    expect(effective[0].server).toBe(edit.server);
    expect(effective[0].password).toBe(edit.password);
    expect(effective[0].uuid).toBe(base.uuid);
    vi.spyOn(db, 'getFavorites').mockResolvedValue([]);
    vi.spyOn(HouseholdStore.getInstance(), 'getHouseholdKey').mockResolvedValue('fixture-key');
    const send = vi.spyOn(LocalSyncService.getInstance(), 'sendMessage').mockResolvedValue();
    await LocalSyncService.getInstance().sendHouseholdDataDelta();
    const source = send.mock.calls[0][0].delta.sources[0];
    expect(source.server).toBe(base.server);
    expect(source.username).toBe(base.username);
    expect(source.password).toBe(base.password);
    expect(JSON.stringify(source)).not.toContain(edit.password);
  });

  it('receiving the household source cannot overwrite the local correction', async () => {
    const update = vi.spyOn(Database.getInstance(), 'upsertSource').mockResolvedValue(base.id);
    await LocalSyncService.getInstance().applyHouseholdDataDelta({ sources: [{ ...base, password: 'new-household-password' }], favorites: [], watch_history: [], tombstones: [] });
    expect(update).not.toHaveBeenCalled();
    expect((await Database.getInstance().getSources())[0].password).toBe(edit.password);
  });

  it('uses the local connection when playing an already indexed live channel', async () => {
    const player = AVPlayerService.getInstance();
    const open = vi.spyOn(player, 'open').mockResolvedValue();
    vi.spyOn(player, 'play').mockImplementation(() => {});
    await CndEngine.getInstance().play({ id: 990, source_id: base.id, stable_hash: 'fixture-channel', name: 'Chaîne', name_clean: 'Chaîne', kind: 'live', stream_url: 'http://shared.invalid/live/shared-user/shared-password/99.ts', is_favorite: 0, playback_position_ms: 0, duration_ms: 0 }, { force: true });
    expect(open).toHaveBeenCalledWith('https://local.invalid/live/local-user/local-password/99.ts', true, { uhd: false });
  });

  it('keeps the household identity for remote playback after a local host change', async () => {
    const expected = await WorkerBridge.getInstance().post('COMPUTE_SOURCE_KEY', { sourceType: base.source_type, serverOrUrl: base.server, username: base.username });
    const actual = await (RemotePlaybackCoordinator.getInstance() as any).sourceKeyOfSource({ ...base, ...edit });
    expect(actual).toBe(expected);
  });

  it('refreshing the original household account preserves the override and never creates a duplicate', async () => {
    const update = vi.spyOn(Database.getInstance(), 'updateSource').mockResolvedValue();
    const insert = vi.spyOn(Database.getInstance(), 'upsertSource').mockResolvedValue(999);
    const id = await (CndEngine.getInstance() as any).saveSource({ ...base, uuid: 'other-device-uuid', item_count: 20 });
    expect(id).toBe(base.id);
    expect(insert).not.toHaveBeenCalled();
    expect(update.mock.calls[0][0].server).toBe(base.server);
    expect(update.mock.calls[0][0].password).toBe(base.password);
    expect(update.mock.calls[0][0].local_override).toBe(true);
  });

  it('saves validated edits in the vault and writes only a marker on the shared source', async () => {
    const set = vi.spyOn(LocalSourceVault.getInstance(), 'set').mockResolvedValue();
    const update = vi.spyOn(Database.getInstance(), 'updateSource').mockResolvedValue();
    await CndEngine.getInstance().updateLocalSource(base.id, edit);
    expect(set).toHaveBeenCalledWith(base.uuid, edit);
    expect(update).toHaveBeenCalledWith({ ...base, local_override: true });
    expect(update.mock.calls[0][0].password).toBe(base.password);
  });
});

// An in-memory IndexedDB transport: real WebCrypto encrypts and decrypts the vault records.
function memoryIndexedDb() {
  const records = new Map<string, any>();
  return { records, open: () => {
    const db = { transaction: () => {
      const tx: any = { objectStore: () => ({
        get: (id: string) => { const request: any = {}; queueMicrotask(() => { request.result = records.get(id); request.onsuccess?.(); }); return request; },
        put: (value: any, id: string) => { records.set(id, value); queueMicrotask(() => tx.oncomplete?.()); },
        delete: (id: string) => { records.delete(id); queueMicrotask(() => tx.oncomplete?.()); },
      }) };
      return tx;
    } };
    const request: any = { result: db };
    queueMicrotask(() => request.onsuccess?.()); return request;
  } };
}

describe('Encrypted local source vault', () => {
  it('persists ciphertext only, survives reloading and deletes corrections', async () => {
    const db = memoryIndexedDb();
    vi.stubGlobal('indexedDB', db);
    vi.stubGlobal('crypto', webcrypto);
    const vault = new LocalSourceVault();
    await vault.set('source-1', edit);
    const stored = db.records.get('source:source-1');
    expect(stored.ciphertext.byteLength).toBeGreaterThan(0);
    expect(db.records.get('master').extractable).toBe(false);
    expect(JSON.stringify(stored)).not.toContain(edit.password);
    expect(await new LocalSourceVault().get('source-1')).toEqual(edit);
    await vault.delete('source-1');
    expect(await new LocalSourceVault().get('source-1')).toBeNull();
  });
});
