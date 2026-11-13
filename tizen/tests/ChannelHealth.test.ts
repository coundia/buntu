import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { AVPlayerService } from '../src/core/player/AVPlayerService';
import { CndEngine } from '../src/core/engine/CndEngine';
import { Database, ItemRecord } from '../src/core/storage/Database';

const channel = (id: number): ItemRecord => ({ id, source_id: 1, stable_hash: `health-${id}`, name: `Chaîne ${id}`, name_clean: `Chaîne ${id}`, kind: 'live', stream_url: `https://example.invalid/live/${id}.ts`, is_favorite: 0, is_broken: 0, playback_position_ms: 0, duration_ms: 0 });
const settle = async () => { for (let i = 0; i < 30; i++) await Promise.resolve(); };
let callbacks: any;
let records: Map<number, ItemRecord>;

beforeEach(() => {
  vi.useFakeTimers();
  callbacks = null;
  records = new Map([[301, channel(301)], [302, channel(302)]]);
  (window as any).webapis = { avplay: {
    open: vi.fn(), play: vi.fn(), stop: vi.fn(), close: vi.fn(), getState: () => 'PLAYING',
    getDuration: () => 0, setDisplayRect: vi.fn(), setDisplayMethod: vi.fn(), setBufferingParam: vi.fn(),
    // No video track: audio recovery must be sufficient.
    getCurrentStreamInfo: () => [{ type: 'AUDIO', extra_info: '{}' }],
    setListener: (listener: any) => { callbacks = listener; },
    prepareAsync: (ready: () => void) => ready(),
  } };
  const db = Database.getInstance();
  (db as any).db = {};
  vi.spyOn(db, 'getSharedSources').mockResolvedValue([]);
  vi.spyOn(db as any, 'getById').mockImplementation(async (_store, id) => records.has(id as number) ? { ...records.get(id as number)! } : null);
  vi.spyOn(db as any, 'put').mockImplementation(async (_store, item) => { records.set((item as ItemRecord).id, { ...(item as ItemRecord) }); });
  AVPlayerService.getInstance().setListener({});
});
afterEach(() => {
  CndEngine.getInstance().stopPlayback();
  delete (window as any).webapis;
  vi.restoreAllMocks();
  vi.useRealTimers();
});

describe('Live stream health independent of full-screen UI', () => {
  it('automatically marks errors and clears HS when audio-only playback advances', async () => {
    const item = channel(301);
    await CndEngine.getInstance().play(item, { force: true });
    callbacks.onerror('PLAYER_ERROR_CONNECTION_FAILED');
    await settle();
    expect(item.is_broken).toBe(1);
    expect(records.get(301)?.is_broken).toBe(1);
    callbacks.oncurrentplaytime(0);
    await settle();
    expect(records.get(301)?.is_broken).toBe(1);
    callbacks.oncurrentplaytime(1000);
    await settle();
    expect(item.is_broken).toBe(0);
    expect(records.get(301)?.is_broken).toBe(0);
  });

  it('ignores late events of the previously selected channel', async () => {
    await CndEngine.getInstance().play(channel(301), { force: true });
    const old = callbacks;
    old.onerror('PLAYER_ERROR_CONNECTION_FAILED');
    await settle();
    await CndEngine.getInstance().play(channel(302), { force: true });
    old.oncurrentplaytime(3000);
    old.onerror('PLAYER_ERROR_CONNECTION_FAILED');
    await settle();
    expect(records.get(301)?.is_broken).toBe(1);
    expect(records.get(302)?.is_broken).toBe(0);
    callbacks.onbufferingstart();
    callbacks.oncurrentplaytime(1000);
    expect(AVPlayerService.getInstance().getState()).toBe('PLAYING');
  });

  it('marks a stream that played then stayed silent only after a long silence, and clears it when sound resumes', async () => {
    await CndEngine.getInstance().play(channel(301), { force: true });
    callbacks.oncurrentplaytime(1000);
    await settle();
    callbacks.onbufferingstart();
    // A server cut is not a broken channel: the player reconnects first, so nothing is marked after 10 s...
    await vi.advanceTimersByTimeAsync(10000);
    expect(records.get(301)?.is_broken).not.toBe(1);
    // ...only a silence that lasts (90 s) marks it out of service.
    await vi.advanceTimersByTimeAsync(95000);
    expect(records.get(301)?.is_broken).toBe(1);
    callbacks.oncurrentplaytime(2000);
    await settle();
    expect(records.get(301)?.is_broken).toBe(0);
  });

});
