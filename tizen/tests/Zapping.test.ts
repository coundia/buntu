import { describe, it, expect, vi, afterEach } from 'vitest';
import { render } from 'solid-js/web';
import { neighbourInList, zapContext } from '../src/core/navigation/ZapContext';
import {
  buildLiveCatchupUrl,
  createZapDebouncer,
  findChannelByNumber,
  isSameLiveChannel,
  rankLiveMirrors,
} from '../src/core/engine/livePlayerHelpers';
import { PlayerView } from '../src/features/player/PlayerView';
import { AVPlayerService } from '../src/core/player/AVPlayerService';
import { CndEngine } from '../src/core/engine/CndEngine';
import { Database, type ItemRecord } from '../src/core/storage/Database';
import { LocalSyncService } from '../src/core/sync/LocalSyncService';
import { RemoteKeyHandler } from '../src/core/input/RemoteKeyHandler';
import { spatialNav } from '../src/ui/design/SpatialNav';

const list = [{ id: 10 }, { id: 20 }, { id: 30 }];

describe('Ch+ / Ch- neighbour in a list', () => {
  it('goes to the next and previous item', () => {
    expect(neighbourInList(list, 10, 1)).toEqual({ id: 20 });
    expect(neighbourInList(list, 30, -1)).toEqual({ id: 20 });
  });

  it('wraps around at both ends', () => {
    expect(neighbourInList(list, 30, 1)).toEqual({ id: 10 });
    expect(neighbourInList(list, 10, -1)).toEqual({ id: 30 });
  });

  it('enters the list from its start (or end) when the current item is not in it', () => {
    expect(neighbourInList(list, 99, 1)).toEqual({ id: 10 });
    expect(neighbourInList(list, 99, -1)).toEqual({ id: 30 });
  });

  it('has nowhere to go with an empty list or only the current item', () => {
    expect(neighbourInList([], 1, 1)).toBeUndefined();
    expect(neighbourInList([{ id: 5 }], 5, 1)).toBeUndefined();
    expect(neighbourInList([{ id: 5 }], 5, -1)).toBeUndefined();
  });

  it('starts with the whole catalog as the zapping list', () => {
    expect(zapContext.category).toBe('');
  });
});

function makeLive(overrides: Partial<ItemRecord>): ItemRecord {
  return {
    id: 1,
    source_id: 1,
    stable_hash: 'h1',
    kind: 'live',
    name: 'TF1 HD',
    name_clean: 'TF1 HD',
    stream_url: 'http://tv.example/live/u/p/1.ts',
    is_favorite: 0,
    playback_position_ms: 0,
    duration_ms: 0,
    ...overrides,
  };
}

describe('PRD-46 Live TV pure helpers', () => {
  afterEach(() => {
    vi.useRealTimers();
  });

  it('matches mirrors by tvg_id or normalized family and ranks 4K > FHD > HD > SD', () => {
    const primary = makeLive({ id: 1, name: 'TF1 HD', name_clean: 'TF1 HD', tvg_id: 'tf1.fr', source_id: 1 });
    const sdBroken = makeLive({ id: 2, name: 'TF1', name_clean: 'TF1', tvg_id: 'tf1.fr', is_broken: 1 });
    const fhdOther = makeLive({ id: 3, name: 'TF1 FHD', name_clean: 'TF1 FHD', tvg_id: 'tf1.fr', source_id: 2 });
    const fhdSame = makeLive({ id: 4, name: 'TF1 FHD', name_clean: 'TF1 FHD', tvg_id: 'tf1.fr', source_id: 1 });
    const uhd = makeLive({ id: 5, name: 'FR: TF1 4K UHD', name_clean: 'TF1 4K', source_id: 2 });
    const other = makeLive({ id: 6, name: 'France 2 FHD', name_clean: 'France 2 FHD', tvg_id: 'f2.fr' });

    expect(isSameLiveChannel(primary, uhd)).toBe(true);
    expect(isSameLiveChannel(primary, other)).toBe(false);

    const ranked = rankLiveMirrors(primary, [primary, sdBroken, fhdOther, fhdSame, uhd, other]);
    expect(ranked.map((r) => r.id)).toEqual([5, 4, 3]);
  });

  it('resolves channels by explicit chno (preferring healthy) with 1-based fallback', () => {
    const broken = makeLive({ id: 10, chno: 5, is_broken: 1 });
    const healthy = makeLive({ id: 11, chno: 5, is_broken: 0 });
    const other = makeLive({ id: 12, chno: 1 });

    expect(findChannelByNumber([broken, healthy, other], 5)?.id).toBe(11);
    expect(findChannelByNumber([broken, healthy, other], 99)).toBeNull();

    const noNumbers = [makeLive({ id: 20 }), makeLive({ id: 21 }), makeLive({ id: 22 })];
    expect(findChannelByNumber(noNumbers, 2)?.id).toBe(21);
    expect(findChannelByNumber(noNumbers, 4)).toBeNull();
  });

  it('builds Start-Over catchup URLs for Xtream, flussonic, shift and default', () => {
    const startTs = 1763078400; // 2025-11-14T00:00:00Z
    const endTs = startTs + 3600;
    const nowTs = startTs + 900;

    const xtreamUrl = buildLiveCatchupUrl(
      { stream_url: 'http://tv.example/live/demo/tok/101.ts', catchup_type: 'xtream', catchup_days: 7 },
      { start_ts: startTs, end_ts: endTs },
      nowTs
    );
    expect(xtreamUrl).toBe('http://tv.example/timeshift/demo/tok/60/2025-11-14:00-00/101.ts');

    const flussonicUrl = buildLiveCatchupUrl(
      { stream_url: 'http://cdn.example/ch1/index.m3u8', catchup_type: 'flussonic', catchup_days: 3 },
      { start_ts: startTs, end_ts: endTs },
      nowTs
    );
    expect(flussonicUrl).toBe(`http://cdn.example/ch1/timeshift_abs-${startTs}.m3u8`);

    const defaultUrl = buildLiveCatchupUrl(
      { stream_url: 'http://cdn.example/stream.m3u8?token=abc', catchup_type: 'default', catchup_days: 1 },
      { start_ts: startTs, end_ts: endTs },
      nowTs
    );
    expect(defaultUrl).toBe(`http://cdn.example/stream.m3u8?token=abc&utc=${startTs}&lutc=${nowTs}`);

    expect(
      buildLiveCatchupUrl(
        { stream_url: 'http://tv.example/live/demo/tok/101.ts', catchup_type: undefined, catchup_days: 0 },
        { start_ts: startTs, end_ts: endTs },
        nowTs
      )
    ).toBeNull();
  });

  it('coalesces rapid zapping within 250 ms to avoid HTTP 429 bursts', () => {
    vi.useFakeTimers();
    const committed: number[] = [];
    const debouncer = createZapDebouncer<number>(250, (id) => committed.push(id));

    debouncer.schedule(2);
    expect(debouncer.currentTarget()).toBe(2);
    vi.advanceTimersByTime(100);
    debouncer.schedule(3);
    vi.advanceTimersByTime(100);
    debouncer.schedule(4);
    expect(committed).toEqual([]);

    vi.advanceTimersByTime(249);
    expect(committed).toEqual([]);
    vi.advanceTimersByTime(1);
    expect(committed).toEqual([4]);
    expect(debouncer.currentTarget()).toBeNull();

    debouncer.schedule(5);
    debouncer.cancel();
    vi.advanceTimersByTime(500);
    expect(committed).toEqual([4]);
  });
});

describe('PlayerView pause button on Live TV and VOD', () => {
  let dispose = () => {};
  const settle = async () => {
    for (let i = 0; i < 30; i++) await Promise.resolve();
    await new Promise((r) => setTimeout(r, 30));
  };

  afterEach(() => {
    dispose();
    document.body.innerHTML = '';
    AVPlayerService.getInstance().stop();
    RemoteKeyHandler.getInstance().destroy();
    delete (window as any).webapis;
    vi.restoreAllMocks();
  });

  it('pauses live TV and VOD on clicking #btn-osd-play-pause and ignores subsequent time ticks while paused', async () => {
    RemoteKeyHandler.getInstance().init();
    (spatialNav as any).isInitialized = false;
    spatialNav.init();
    spatialNav.setHeader([]);

    let avListener: any = null;
    let avState = 'PLAYING';
    (window as any).webapis = {
      avplay: {
        open: vi.fn(() => { avState = 'IDLE'; }),
        close: vi.fn(() => { avState = 'NONE'; }),
        stop: vi.fn(() => { avState = 'IDLE'; }),
        play: vi.fn(() => { avState = 'PLAYING'; }),
        pause: vi.fn(() => { avState = 'PAUSED'; }),
        prepareAsync: vi.fn((ok: () => void) => { avState = 'READY'; ok(); }),
        setListener: vi.fn((l: any) => { avListener = l; }),
        setDisplayMethod: vi.fn(),
        setDisplayRect: vi.fn(),
        setBufferingParam: vi.fn(),
        getDuration: vi.fn(() => 0),
        getState: vi.fn(() => avState),
        getCurrentStreamInfo: vi.fn(() => []),
      },
    };

    const player = AVPlayerService.getInstance();
    const engine = CndEngine.getInstance() as any;
    vi.spyOn(engine, 'saveProgress').mockResolvedValue(undefined);
    vi.spyOn(engine, 'takeResumed').mockReturnValue(false);
    vi.spyOn(engine, 'getSimilarMovies').mockResolvedValue([]);
    vi.spyOn(engine, 'findMirrors').mockResolvedValue([]);
    vi.spyOn(Database.getInstance() as any, 'onBrokenChange').mockReturnValue(() => {});
    vi.spyOn(Database.getInstance() as any, 'getEpgUpcoming').mockResolvedValue([]);
    vi.spyOn(LocalSyncService.getInstance(), 'broadcastProgress').mockResolvedValue(undefined as any);

    for (const isLive of [true, false]) {
      const item = isLive
        ? makeLive({ id: 42 })
        : ({
            ...makeLive({ id: 43, kind: 'movie', name: 'Film Test', name_clean: 'Film Test' }),
            stream_url: 'http://vod.example/movie/43.mp4',
          } as ItemRecord);

      await player.open(item.stream_url, isLive);
      player.play();

      dispose = render(() => PlayerView({ item, onExit: vi.fn() }), document.body);
      await settle();

      const btn = document.getElementById('btn-osd-play-pause') as HTMLButtonElement;
      expect(btn).not.toBeNull();
      expect(btn.textContent).toContain('Pause');

      btn.click();
      await settle();

      expect(player.getState()).toBe('PAUSED');
      expect(btn.textContent).toContain('Lecture');

      // Late playback time tick while paused must not flip the button back to Pause.
      avListener?.oncurrentplaytime(12000);
      await settle();
      expect(player.getState()).toBe('PAUSED');
      expect(btn.textContent).toContain('Lecture');

      btn.click();
      await settle();
      expect(player.getState()).toBe('PLAYING');
      expect(btn.textContent).toContain('Pause');

      dispose();
      document.body.innerHTML = '';
    }
  });

  it('seeks forward and backward from the progress bar on movie, live TV and episode (remote keys + pointer click)', async () => {
    RemoteKeyHandler.getInstance().init();
    (spatialNav as any).isInitialized = false;
    spatialNav.init();
    spatialNav.setHeader([]);

    const key = (keyCode: number) => window.dispatchEvent(new KeyboardEvent('keydown', { keyCode }));
    const seekToSpy = vi.fn();
    let avDuration = 120_000;

    (window as any).webapis = {
      avplay: {
        open: vi.fn(),
        close: vi.fn(),
        stop: vi.fn(),
        play: vi.fn(),
        pause: vi.fn(),
        seekTo: seekToSpy,
        prepareAsync: vi.fn((ok: () => void) => ok()),
        setListener: vi.fn(),
        setDisplayMethod: vi.fn(),
        setDisplayRect: vi.fn(),
        setBufferingParam: vi.fn(),
        getDuration: vi.fn(() => avDuration),
        getState: vi.fn(() => 'PLAYING'),
        getCurrentStreamInfo: vi.fn(() => []),
      },
    };

    const player = AVPlayerService.getInstance();
    const engine = CndEngine.getInstance() as any;
    vi.spyOn(engine, 'saveProgress').mockResolvedValue(undefined);
    vi.spyOn(engine, 'takeResumed').mockReturnValue(false);
    vi.spyOn(engine, 'getSimilarMovies').mockResolvedValue([]);
    vi.spyOn(engine, 'findMirrors').mockResolvedValue([]);
    vi.spyOn(Database.getInstance() as any, 'onBrokenChange').mockReturnValue(() => {});
    vi.spyOn(Database.getInstance() as any, 'getEpgUpcoming').mockResolvedValue([]);
    vi.spyOn(LocalSyncService.getInstance(), 'broadcastProgress').mockResolvedValue(undefined as any);

    const cases: Array<{ item: ItemRecord; expectedHalfMs: number }> = [
      {
        item: {
          ...makeLive({ id: 101, kind: 'movie', name: 'Film Seek', name_clean: 'Film Seek' }),
          duration_ms: 120_000,
          stream_url: 'http://vod.example/movie/101.mp4',
        } as ItemRecord,
        expectedHalfMs: 60_000,
      },
      {
        item: makeLive({ id: 102, kind: 'live', name: 'TV Seek', name_clean: 'TV Seek' }),
        expectedHalfMs: 1_800_000,
      },
      {
        item: {
          ...makeLive({ id: 103, kind: 'episode', name: 'Serie S1E1', name_clean: 'Serie S1E1' }),
          season_num: 1,
          episode_num: 1,
          duration_ms: 120_000,
          stream_url: 'http://vod.example/series/103.mp4',
        } as ItemRecord,
        expectedHalfMs: 60_000,
      },
    ];

    for (const { item, expectedHalfMs } of cases) {
      seekToSpy.mockClear();
      avDuration = item.kind === 'live' ? 0 : 120_000;
      await player.open(item.stream_url, item.kind === 'live');
      player.play();

      dispose = render(() => PlayerView({ item, onExit: vi.fn() }), document.body);
      await settle();

      const bar = document.getElementById('osd-progress-bar') as HTMLElement;
      expect(bar).not.toBeNull();

      // Remote UP from btn-osd-play-pause focuses the progress bar, RIGHT (+10s), LEFT (-10s).
      spatialNav.setFocusById('btn-osd-play-pause');
      key(38); // UP
      expect(spatialNav.getCurrentFocusId()).toBe('osd-progress-bar');

      key(39); // RIGHT -> +10 s
      expect(seekToSpy).toHaveBeenLastCalledWith(10_000, expect.any(Function), expect.any(Function));

      key(37); // LEFT -> -10 s back to 0
      expect(seekToSpy).toHaveBeenLastCalledWith(0, expect.any(Function), expect.any(Function));

      // Pointer click at 50% width (fallback viewport 1920 -> clientX 960).
      bar.dispatchEvent(new MouseEvent('click', { bubbles: true, clientX: 960 }));
      await settle();
      expect(seekToSpy).toHaveBeenLastCalledWith(expectedHalfMs, expect.any(Function), expect.any(Function));
      expect((document.querySelector('.tv-osd-progress-fill') as HTMLElement)?.style.width).toBe('50%');

      dispose();
      document.body.innerHTML = '';
    }
  });
});
