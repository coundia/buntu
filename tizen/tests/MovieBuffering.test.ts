import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { render } from 'solid-js/web';
import { BufferHint, LIVE_BUFFER, UHD_BUFFER, VOD_BUFFER, bufferPolicy } from '../src/core/player/bufferPolicy';
import { isUhdTitle } from '../src/core/player/uhd';
import { AVPlayerService } from '../src/core/player/AVPlayerService';
import { CndEngine } from '../src/core/engine/CndEngine';
import { Database } from '../src/core/storage/Database';
import { LocalSyncService } from '../src/core/sync/LocalSyncService';
import { PlayerView } from '../src/features/player/PlayerView';
import { spatialNav } from '../src/ui/design/SpatialNav';
import { RemoteKeyHandler } from '../src/core/input/RemoteKeyHandler';

const item = (over: Record<string, unknown> = {}) => ({
  id: 5, source_id: 1, stable_hash: 'h5', kind: 'movie', name: 'Film', name_clean: 'Film', group_title: 'Films',
  stream_url: 'http://x.invalid/movie/u/p/5.mkv', is_favorite: 0, playback_position_ms: 0, duration_ms: 0, ...over,
}) as any;

describe('Buffer policy', () => {
  it('live stays small, films keep more video ready, 4K films the most, never over 20 s', () => {
    expect(bufferPolicy(true)).toEqual(LIVE_BUFFER);
    expect(bufferPolicy(true, { uhd: true })).toEqual(LIVE_BUFFER);
    expect(bufferPolicy(false)).toEqual(VOD_BUFFER);
    expect(bufferPolicy(false, { uhd: true })).toEqual(UHD_BUFFER);
    expect(VOD_BUFFER.play).toBeGreaterThan(4); // it was 4 / 6
    expect(VOD_BUFFER.resume).toBeGreaterThan(6);
    expect(UHD_BUFFER.play).toBeGreaterThan(VOD_BUFFER.play);
    expect(UHD_BUFFER.resume).toBeGreaterThan(VOD_BUFFER.resume);
    for (const b of [LIVE_BUFFER, VOD_BUFFER, UHD_BUFFER]) expect(Math.max(b.play, b.resume)).toBeLessThanOrEqual(20);
  });

  it('a film is 4K when its title or category says so', () => {
    expect(isUhdTitle(item({ name: 'Dune 2021 4K HDR' }))).toBe(true);
    expect(isUhdTitle(item({ name: 'Dune UHD' }))).toBe(true);
    expect(isUhdTitle(item({ name: 'Dune', group_title: 'FILMS 4K' }))).toBe(true);
    expect(isUhdTitle(item({ name: 'Dune 1080p' }))).toBe(false);
    expect(isUhdTitle(item({ name: 'Dune', group_title: undefined }))).toBe(false);
  });
});

describe('The player receives the buffer hint', () => {
  const engine = CndEngine.getInstance() as any;
  let open: any;
  beforeEach(() => {
    vi.spyOn(engine, 'localItem').mockImplementation(async (i: unknown) => i);
    vi.spyOn(engine.net as any, 'resolveFinalUrl').mockImplementation((async (u: string) => u) as any);
    vi.spyOn(Database.getInstance() as any, 'getWatchProgress').mockResolvedValue(null);
    const player = engine.player as any;
    open = vi.spyOn(player, 'open').mockImplementation(async () => {});
    vi.spyOn(player, 'play').mockImplementation(() => {});
    vi.spyOn(player, 'stop').mockImplementation(() => {});
    vi.spyOn(player, 'isActive').mockReturnValue(false);
  });
  afterEach(() => { engine.stopPlayback(); vi.restoreAllMocks(); });

  it('a 4K film asks for the large buffer, an HD film and a channel do not', async () => {
    await engine.play(item({ name: 'Dune 4K' }), { force: true });
    expect(open.mock.calls[0][2]).toEqual<BufferHint>({ uhd: true });
    await engine.play(item({ id: 6, name: 'Dune 1080p' }), { force: true });
    expect(open.mock.calls[1][2]).toEqual<BufferHint>({ uhd: false });
    await engine.play(item({ id: 7, kind: 'live', name: 'Chaîne 4K' }), { force: true });
    expect(open.mock.calls[2][2]).toEqual<BufferHint>({ uhd: false });
  });
});

describe('AVPlay gets the buffer sizes', () => {
  it('sets the play and resume buffers from the policy', async () => {
    const calls: [string, number][] = [];
    const avplay = {
      open: vi.fn(), close: vi.fn(), stop: vi.fn(), play: vi.fn(), pause: vi.fn(), seekTo: vi.fn(),
      setListener: vi.fn(), setDisplayRect: vi.fn(), setDisplayMethod: vi.fn(),
      setBufferingParam: (which: string, _unit: string, value: number) => calls.push([which, value]),
      prepareAsync: (ok: () => void) => ok(),
      getDuration: () => 0, getState: () => 'READY', getCurrentStreamInfo: () => [],
    };
    (globalThis as any).webapis = { avplay };
    const player = AVPlayerService.getInstance();
    await player.open('http://x.invalid/movie/u/p/5.mkv', false, { uhd: true }).catch(() => {});
    delete (globalThis as any).webapis;
    expect(calls).toEqual([['PLAYER_BUFFER_FOR_PLAY', UHD_BUFFER.play], ['PLAYER_BUFFER_FOR_RESUME', UHD_BUFFER.resume]]);
  });
});

describe('Player: slow stream message', () => {
  let listener: any;
  let dispose = () => {};
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
    vi.spyOn(player, 'getDuration').mockReturnValue(100_000);
    vi.spyOn(player, 'getCurrentTime').mockReturnValue(0);
    vi.spyOn(player, 'getStreamSummary').mockReturnValue(null);
    const engine = CndEngine.getInstance() as any;
    vi.spyOn(engine, 'saveProgress').mockResolvedValue(undefined);
    vi.spyOn(engine, 'takeResumed').mockReturnValue(false);
    vi.spyOn(engine, 'getSimilarMovies').mockResolvedValue([]);
    vi.spyOn(Database.getInstance() as any, 'onBrokenChange').mockReturnValue(() => {});
    vi.spyOn(LocalSyncService.getInstance(), 'broadcastProgress').mockResolvedValue(undefined as any);
  });
  afterEach(() => { dispose(); document.body.innerHTML = ''; RemoteKeyHandler.getInstance().destroy(); vi.useRealTimers(); vi.restoreAllMocks(); });

  const mount = async (it = item({ name: 'Dune 4K' })) => {
    dispose = render(() => PlayerView({ item: it, onExit: vi.fn() }), document.body);
    await vi.advanceTimersByTimeAsync(50);
    await settle();
  };

  it('the first loading shows the percentage, not a speed message', async () => {
    await mount();
    listener.onBufferingStart();
    await settle();
    expect(text()).toContain('Chargement');
    expect(text()).not.toContain('Débit trop faible');
  });

  it('a 4K film that pauses to load after it played says the speed is too low and suggests Ethernet or HD', async () => {
    await mount();
    listener.onBufferingComplete();
    await vi.advanceTimersByTimeAsync(20_000);
    listener.onBufferingStart();
    await settle();
    expect(text()).toContain('Débit trop faible pour ce film 4K');
    expect(text()).toContain('câble Ethernet');
  });

  it('another film gets the general message (not the 4K one)', async () => {
    await mount(item({ name: 'Dune 1080p' }));
    listener.onBufferingComplete();
    await vi.advanceTimersByTimeAsync(20_000);
    listener.onBufferingStart();
    await settle();
    expect(text()).toContain('Débit trop faible pour ce flux');
    expect(text()).not.toContain('4K');
  });

  it('a channel never gets this message', async () => {
    await mount(item({ kind: 'live', name: 'Chaîne' }));
    listener.onBufferingComplete();
    await vi.advanceTimersByTimeAsync(20_000);
    listener.onBufferingStart();
    await settle();
    expect(text()).not.toContain('Débit trop faible');
  });
});
