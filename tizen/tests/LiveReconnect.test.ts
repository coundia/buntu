import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { render } from 'solid-js/web';
import { PlayerView } from '../src/features/player/PlayerView';
import { CndEngine } from '../src/core/engine/CndEngine';
import { Database } from '../src/core/storage/Database';
import { LocalSyncService } from '../src/core/sync/LocalSyncService';
import { AVPlayerService } from '../src/core/player/AVPlayerService';
import { spatialNav } from '../src/ui/design/SpatialNav';
import { RemoteKeyHandler } from '../src/core/input/RemoteKeyHandler';

const channel = (id: number, over: Record<string, unknown> = {}) => ({
  id, source_id: 1, stable_hash: `h${id}`, kind: 'live', name: `Chaîne ${id}`, name_clean: `Chaîne ${id}`, group_title: 'TV', tvg_id: '',
  stream_url: `http://x.invalid/live/u/p/${id}.ts`, is_favorite: 0, playback_position_ms: 0, duration_ms: 0, ...over,
}) as any;

describe('Live stream that stops answering: the player reconnects by itself', () => {
  let listener: any;
  let dispose = () => {};
  let play: any;
  const settle = async () => { for (let i = 0; i < 30; i++) await Promise.resolve(); };
  const text = () => document.body.textContent ?? '';

  beforeEach(() => {
    vi.useFakeTimers();
    RemoteKeyHandler.getInstance().init();
    (spatialNav as any).isInitialized = false;
    spatialNav.init();
    spatialNav.setHeader([]);
    const player = AVPlayerService.getInstance() as any;
    vi.spyOn(player, 'setListener').mockImplementation((l: any) => { listener = l; });
    for (const name of ['setDisplayArea', 'stop', 'play', 'seekTo', 'open', 'pause']) vi.spyOn(player, name).mockImplementation(() => {});
    vi.spyOn(player, 'getDuration').mockReturnValue(0);
    vi.spyOn(player, 'getCurrentTime').mockReturnValue(0);
    vi.spyOn(player, 'getStreamSummary').mockReturnValue(null);
    const engine = CndEngine.getInstance() as any;
    play = vi.spyOn(engine, 'play').mockResolvedValue(undefined);
    vi.spyOn(engine, 'saveProgress').mockResolvedValue(undefined);
    vi.spyOn(engine, 'takeResumed').mockReturnValue(false);
    vi.spyOn(engine, 'getSimilarMovies').mockResolvedValue([]);
    vi.spyOn(Database.getInstance() as any, 'onBrokenChange').mockReturnValue(() => {});
    vi.spyOn(Database.getInstance() as any, 'setBroken').mockResolvedValue(undefined);
    vi.spyOn(LocalSyncService.getInstance(), 'broadcastProgress').mockResolvedValue(undefined as any);
  });
  afterEach(() => { dispose(); document.body.innerHTML = ''; RemoteKeyHandler.getInstance().destroy(); vi.useRealTimers(); vi.restoreAllMocks(); });

  const mount = async (item = channel(1)) => {
    dispose = render(() => PlayerView({ item, onExit: vi.fn(), onNextChannel: vi.fn() }), document.body);
    await vi.advanceTimersByTimeAsync(50);
    await settle();
    listener.onBufferingComplete(); // the channel plays
    await settle();
  };

  it('a stall shows what is happening and reopens the channel through the engine after 1 second', async () => {
    await mount();
    listener.onStallDetected();
    await settle();
    expect(text()).toContain('Connexion perdue… reconnexion (1/5)');
    expect(play).not.toHaveBeenCalled();
    await vi.advanceTimersByTimeAsync(1000);
    expect(play).toHaveBeenCalledTimes(1);
    expect(play).toHaveBeenCalledWith(expect.objectContaining({ id: 1 }), { force: true });
  });

  it('when the stream comes back, the message goes away and the next stall starts over from 1', async () => {
    await mount();
    listener.onStallDetected();
    await vi.advanceTimersByTimeAsync(1000);
    listener.onBufferingComplete();
    await settle();
    expect(text()).not.toContain('Connexion perdue');
    await vi.advanceTimersByTimeAsync(30_000);
    expect(play).toHaveBeenCalledTimes(1); // no further attempt: it plays
    listener.onStallDetected();
    await settle();
    expect(text()).toContain('reconnexion (1/5)');
  });

  it('keeps trying with growing delays, then asks: retry or next channel, without calling it out of service', async () => {
    await mount();
    listener.onStallDetected();
    await settle();
    for (const wait of [1000, 10_000 + 2000, 10_000 + 4000, 10_000 + 8000, 10_000 + 15_000]) {
      await vi.advanceTimersByTimeAsync(wait);
      await settle();
    }
    await vi.advanceTimersByTimeAsync(10_000);
    await settle();
    expect(play.mock.calls.length).toBeGreaterThanOrEqual(5);
    expect(text()).toContain('Le serveur ne répond plus.');
    expect(document.getElementById('btn-player-retry')).not.toBeNull();
    expect(document.getElementById('btn-player-next')).not.toBeNull();
    expect(text()).not.toContain('marquée temporairement hors service');
    expect(Database.getInstance().setBroken).not.toHaveBeenCalled();
  });

  it('a film that stalls keeps the old pause / play recovery (no reconnection banner)', async () => {
    await mount(channel(9, { kind: 'movie' }));
    listener.onStallDetected();
    await settle();
    expect(text()).not.toContain('Connexion perdue');
    expect(play).not.toHaveBeenCalled();
  });
});
