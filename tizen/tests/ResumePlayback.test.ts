import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { CndEngine } from '../src/core/engine/CndEngine';
import { Database } from '../src/core/storage/Database';

const movie = (over: Record<string, unknown> = {}) => ({
  id: 5, source_id: 1, stable_hash: 'h5', kind: 'movie', name: 'Film', name_clean: 'Film',
  stream_url: 'http://srv.invalid/movie/u/p/5.mkv', is_favorite: 0, playback_position_ms: 0, duration_ms: 0, ...over,
}) as any;

describe('A film resumes where it stopped', () => {
  const engine = CndEngine.getInstance() as any;
  const db = Database.getInstance() as any;
  let player: any;
  let saved: any;
  let seeks: number[];
  let order: string[];

  beforeEach(() => {
    seeks = [];
    order = [];
    saved = new Map<number, { position_ms: number; duration_ms: number }>();
    db.progressCache = saved;
    vi.spyOn(db, 'put').mockResolvedValue(undefined);
    vi.spyOn(engine, 'localItem').mockImplementation(async (i: unknown) => i);
    vi.spyOn(engine.net as any, 'resolveFinalUrl').mockImplementation((async (u: string) => u) as any);
    player = engine.player as any;
    vi.spyOn(player, 'open').mockImplementation(async () => { order.push('open'); });
    vi.spyOn(player, 'play').mockImplementation(() => { order.push('play'); });
    vi.spyOn(player, 'seekTo').mockImplementation(((ms: number) => { seeks.push(ms); order.push('seek'); }) as any);
    vi.spyOn(player, 'stop').mockImplementation(() => {});
    vi.spyOn(player, 'isActive').mockReturnValue(true);
    vi.spyOn(player, 'getCurrentTime').mockReturnValue(42 * 60_000);
    vi.spyOn(player, 'getDuration').mockReturnValue(120 * 60_000);
    vi.useFakeTimers();
  });
  afterEach(() => { engine.stopProgressSaver(); vi.useRealTimers(); db.progressCache = null; vi.restoreAllMocks(); });

  it('saves the position every 10 seconds while it plays, and when it stops', async () => {
    await engine.play(movie(), { force: true });
    expect(saved.size).toBe(0);
    await vi.advanceTimersByTimeAsync(10_000);
    expect(saved.get(5)).toEqual({ position_ms: 42 * 60_000, duration_ms: 120 * 60_000 });
    player.getCurrentTime.mockReturnValue(50 * 60_000);
    engine.stopPlayback();
    await vi.advanceTimersByTimeAsync(0);
    expect(saved.get(5)!.position_ms).toBe(50 * 60_000);
    // Stopped: nothing more is saved.
    player.getCurrentTime.mockReturnValue(99 * 60_000);
    await vi.advanceTimersByTimeAsync(30_000);
    expect(saved.get(5)!.position_ms).toBe(50 * 60_000);
  });

  it('saves nothing for a channel, a stream that has not started, or a stopped player', async () => {
    await engine.play(movie({ id: 6, kind: 'live' }), { force: true });
    await vi.advanceTimersByTimeAsync(10_000);
    expect(saved.size).toBe(0);
    engine.stopPlayback();
    player.getDuration.mockReturnValue(0);
    await engine.play(movie({ id: 7 }), { force: true });
    await vi.advanceTimersByTimeAsync(10_000);
    expect(saved.size).toBe(0);
    engine.stopPlayback();
    player.getDuration.mockReturnValue(120 * 60_000);
    player.isActive.mockReturnValue(false);
    await engine.play(movie({ id: 8 }), { force: true });
    await vi.advanceTimersByTimeAsync(10_000);
    expect(saved.size).toBe(0);
  });

  it('starts at the saved position, moving the stream before it plays, and tells the player not to seek again', async () => {
    saved.set(5, { position_ms: 42 * 60_000, duration_ms: 120 * 60_000 });
    await engine.play(movie(), { force: true });
    expect(seeks).toEqual([42 * 60_000]);
    expect(order).toEqual(['open', 'seek', 'play']);
    expect(engine.takeResumed(5)).toBe(true);
    expect(engine.takeResumed(5)).toBe(false);
  });

  it('prefers the position given with the item (a film sent from another device)', async () => {
    saved.set(5, { position_ms: 10 * 60_000, duration_ms: 120 * 60_000 });
    await engine.play(movie({ playback_position_ms: 77 * 60_000 }), { force: true });
    expect(seeks).toEqual([77 * 60_000]);
  });

  it('starts from the beginning when it barely started or is practically finished', async () => {
    saved.set(5, { position_ms: 8_000, duration_ms: 120 * 60_000 });
    await engine.play(movie(), { force: true });
    expect(seeks).toEqual([]);
    saved.set(9, { position_ms: 118 * 60_000, duration_ms: 120 * 60_000 });
    await engine.play(movie({ id: 9 }), { force: true });
    expect(seeks).toEqual([]);
    expect(engine.takeResumed(9)).toBe(false);
  });

  it('never seeks a channel', async () => {
    saved.set(6, { position_ms: 42 * 60_000, duration_ms: 0 });
    await engine.play(movie({ id: 6, kind: 'live' }), { force: true });
    expect(seeks).toEqual([]);
  });

  it('lists fill in the saved position (the « Reprendre à … » of the film panel and the home)', async () => {
    saved.set(5, { position_ms: 42 * 60_000, duration_ms: 120 * 60_000 });
    const [a, b, live] = await db.withProgress([movie(), movie({ id: 6 }), movie({ id: 5, kind: 'live' })]);
    expect(a.playback_position_ms).toBe(42 * 60_000);
    expect(a.duration_ms).toBe(120 * 60_000);
    expect(b.playback_position_ms).toBe(0);
    expect(live.playback_position_ms).toBe(0);
  });
});
