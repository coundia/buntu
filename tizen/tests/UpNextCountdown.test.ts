import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { render } from 'solid-js/web';
import { PlayerView } from '../src/features/player/PlayerView';
import { CndEngine } from '../src/core/engine/CndEngine';
import { LocalSyncService } from '../src/core/sync/LocalSyncService';
import { AVPlayerService } from '../src/core/player/AVPlayerService';
import { spatialNav } from '../src/ui/design/SpatialNav';
import { RemoteKeyHandler } from '../src/core/input/RemoteKeyHandler';
import { COUNTDOWN_CHOICES, MAX_AUTO_CHAIN, getUpNextPrefs, nextCountdownChoice, setUpNextPrefs, upNextChain } from '../src/core/player/upNext';

const film = (id: number, over: Record<string, unknown> = {}) => ({
  id, source_id: 1, stable_hash: `h${id}`, kind: 'movie', name: `Film ${id}`, name_clean: `Film ${id}`, group_title: 'Action', year: 2010,
  stream_url: `http://x.invalid/movie/u/p/${id}.mkv`, is_favorite: 0, playback_position_ms: 0, duration_ms: 0, ...over,
}) as any;
const key = (keyCode: number) => window.dispatchEvent(new KeyboardEvent('keydown', { keyCode }));

describe('Up next preferences', () => {
  let store: Record<string, string>;
  beforeEach(() => {
    store = {};
    vi.stubGlobal('localStorage', { getItem: (k: string) => store[k] ?? null, setItem: (k: string, v: string) => { store[k] = v; } });
  });
  afterEach(() => vi.unstubAllGlobals());

  it('defaults to automatic with 10 seconds, and remembers changes', () => {
    expect(getUpNextPrefs()).toEqual({ auto: true, seconds: 10 });
    setUpNextPrefs({ auto: false });
    setUpNextPrefs({ seconds: 30 });
    expect(getUpNextPrefs()).toEqual({ auto: false, seconds: 30 });
  });

  it('refuses a duration that is not offered, and cycles through the choices', () => {
    expect(setUpNextPrefs({ seconds: 7 }).seconds).toBe(10);
    expect(COUNTDOWN_CHOICES.map(nextCountdownChoice)).toEqual([10, 15, 30, 5]);
  });

  it('the chain stops after three films in a row and starts over on a key press', () => {
    upNextChain.reset();
    for (let i = 0; i < MAX_AUTO_CHAIN; i++) {
      expect(upNextChain.isStillWatchingDue()).toBe(false);
      upNextChain.advance();
    }
    expect(upNextChain.isStillWatchingDue()).toBe(true);
    upNextChain.reset();
    expect(upNextChain.isStillWatchingDue()).toBe(false);
  });
});

describe('Player: countdown to the next film', () => {
  let listener: any;
  let dispose = () => {};
  let onPlayNext: ReturnType<typeof vi.fn>;
  const settle = async () => { for (let i = 0; i < 30; i++) await Promise.resolve(); };

  beforeEach(() => {
    const store: Record<string, string> = {};
    vi.stubGlobal('localStorage', { getItem: (k: string) => store[k] ?? null, setItem: (k: string, v: string) => { store[k] = v; } });
    vi.useFakeTimers();
    upNextChain.reset();
    setUpNextPrefs({ auto: true, seconds: 5 });
    onPlayNext = vi.fn();
    RemoteKeyHandler.getInstance().init();
    (spatialNav as any).isInitialized = false;
    spatialNav.init();
    spatialNav.setHeader([]);
    const player = AVPlayerService.getInstance() as any;
    vi.spyOn(player, 'setListener').mockImplementation((l: any) => { listener = l; });
    for (const name of ['setDisplayArea', 'stop', 'play', 'seekTo', 'open']) vi.spyOn(player, name).mockImplementation(() => {});
    vi.spyOn(player, 'getDuration').mockReturnValue(100_000);
    vi.spyOn(player, 'getCurrentTime').mockReturnValue(0);
    vi.spyOn(player, 'getStreamSummary').mockReturnValue(null);
    const engine = CndEngine.getInstance() as any;
    vi.spyOn(engine, 'getSimilarMovies').mockResolvedValue([film(2), film(3)]);
    vi.spyOn(engine, 'saveProgress').mockResolvedValue(undefined);
    vi.spyOn(engine, 'takeResumed').mockReturnValue(false);
    vi.spyOn(LocalSyncService.getInstance(), 'broadcastProgress').mockResolvedValue(undefined as any);
  });
  afterEach(() => {
    dispose();
    document.body.innerHTML = '';
    RemoteKeyHandler.getInstance().destroy();
    vi.useRealTimers();
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
    upNextChain.reset();
  });

  const mount = async (onExit = vi.fn()) => {
    dispose = render(() => PlayerView({ item: film(1), onExit, onPlayNext: onPlayNext as any }), document.body);
    await vi.advanceTimersByTimeAsync(100);
    await settle();
    return onExit;
  };

  it('at the end of the film it counts down, then plays the first suggestion by itself', async () => {
    const onExit = await mount();
    listener.onStreamCompleted();
    await vi.advanceTimersByTimeAsync(10);
    expect(document.querySelector('.tv-osd-countdown')?.textContent).toContain('5 s');
    expect(onExit).not.toHaveBeenCalled();
    await vi.advanceTimersByTimeAsync(4_000);
    expect(onPlayNext).not.toHaveBeenCalled();
    await vi.advanceTimersByTimeAsync(1_000);
    expect(onPlayNext).toHaveBeenCalledTimes(1);
    expect(onPlayNext).toHaveBeenCalledWith(expect.objectContaining({ id: 2 }));
    expect(upNextChain.count()).toBe(1);
  });

  it('BACK cancels the countdown without leaving the player; the next BACK leaves it', async () => {
    const onExit = await mount();
    listener.onStreamCompleted();
    await vi.advanceTimersByTimeAsync(10);
    key(10009);
    expect(document.querySelector('.tv-osd-countdown')).toBeNull();
    await vi.advanceTimersByTimeAsync(10_000);
    expect(onPlayNext).not.toHaveBeenCalled();
    expect(onExit).not.toHaveBeenCalled();
    key(10009);
    expect(onExit).toHaveBeenCalledTimes(1);
  });

  it('OK on a suggestion plays it at once and starts the chain over', async () => {
    await mount();
    upNextChain.advance();
    listener.onStreamCompleted();
    await vi.advanceTimersByTimeAsync(10);
    key(13); // the cursor is on the first suggestion
    expect(onPlayNext).toHaveBeenCalledWith(expect.objectContaining({ id: 2 }));
    expect(upNextChain.count()).toBe(0);
    await vi.advanceTimersByTimeAsync(10_000);
    expect(onPlayNext).toHaveBeenCalledTimes(1);
  });

  it('with automatic play off the shelf stays, nothing starts by itself', async () => {
    setUpNextPrefs({ auto: false });
    const onExit = await mount();
    listener.onStreamCompleted();
    await vi.advanceTimersByTimeAsync(20_000);
    expect(document.querySelector('.tv-osd-next')).not.toBeNull();
    expect(document.querySelector('.tv-osd-countdown')).toBeNull();
    expect(onPlayNext).not.toHaveBeenCalled();
    expect(onExit).not.toHaveBeenCalled();
  });

  it('after three films in a row it asks « Toujours là ? » instead of starting the next', async () => {
    for (let i = 0; i < MAX_AUTO_CHAIN; i++) upNextChain.advance();
    await mount();
    listener.onStreamCompleted();
    await vi.advanceTimersByTimeAsync(20_000);
    expect(document.body.textContent).toContain('Toujours là ?');
    expect(onPlayNext).not.toHaveBeenCalled();
  });

  it('a film with no suggestion still closes the player at the end, as before', async () => {
    (CndEngine.getInstance() as any).getSimilarMovies.mockResolvedValue([]);
    const onExit = await mount();
    listener.onStreamCompleted();
    expect(onExit).toHaveBeenCalledTimes(1);
  });
});
