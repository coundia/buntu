import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { CndEngine } from '../src/core/engine/CndEngine';
import { Database } from '../src/core/storage/Database';

const channel = (id: number) => ({
  id, source_id: 1, stable_hash: `h${id}`, kind: 'live', name: `Chaîne ${id}`, name_clean: `Chaîne ${id}`, group_title: 'TV',
  stream_url: `http://x.invalid/live/u/p/${id}.ts`, is_favorite: 0, playback_position_ms: 0, duration_ms: 0,
}) as any;

describe('A live channel is not called out of service because the server cut it', () => {
  const engine = CndEngine.getInstance() as any;
  let health: (state: 'failed' | 'playing') => void;
  let setBroken: any;

  beforeEach(() => {
    vi.useFakeTimers();
    setBroken = vi.spyOn(Database.getInstance() as any, 'setBroken').mockResolvedValue(undefined);
    vi.spyOn(engine, 'localItem').mockImplementation(async (i: unknown) => i);
    const player = engine.player as any;
    vi.spyOn(player, 'onStreamHealth').mockImplementation((l: any) => { health = l; return () => {}; });
    for (const name of ['open', 'play', 'stop']) vi.spyOn(player, name).mockImplementation(async () => {});
    vi.spyOn(player, 'isActive').mockReturnValue(true);
  });
  afterEach(() => { engine.stopPlayback(); vi.useRealTimers(); vi.restoreAllMocks(); });

  it('a channel that never connected is marked out of service at once', async () => {
    await engine.play(channel(1), { force: true });
    health('failed');
    expect(setBroken).toHaveBeenCalledWith(1, true);
  });

  it('a channel that played then went silent is only marked after 90 seconds without recovering', async () => {
    await engine.play(channel(2), { force: true });
    health('playing');
    health('failed');
    await vi.advanceTimersByTimeAsync(89_000);
    expect(setBroken).not.toHaveBeenCalledWith(2, true);
    await vi.advanceTimersByTimeAsync(2_000);
    expect(setBroken).toHaveBeenCalledWith(2, true);
  });

  it('if it recovers in time it is never marked, and a later cut starts a new wait', async () => {
    await engine.play(channel(3), { force: true });
    health('playing');
    health('failed');
    await vi.advanceTimersByTimeAsync(40_000);
    health('playing');
    await vi.advanceTimersByTimeAsync(120_000);
    expect(setBroken).not.toHaveBeenCalledWith(3, true);
    health('failed');
    await vi.advanceTimersByTimeAsync(89_000);
    expect(setBroken).not.toHaveBeenCalledWith(3, true);
  });

  it('a reconnection of the same channel keeps knowing it played', async () => {
    await engine.play(channel(4), { force: true });
    health('playing');
    await engine.play(channel(4), { force: true }); // the player reopens it after a stall
    health('failed');
    expect(setBroken).not.toHaveBeenCalledWith(4, true);
  });

  it('stopping cancels the wait', async () => {
    await engine.play(channel(5), { force: true });
    health('playing');
    health('failed');
    engine.stopPlayback();
    await vi.advanceTimersByTimeAsync(200_000);
    expect(setBroken).not.toHaveBeenCalledWith(5, true);
  });
});
