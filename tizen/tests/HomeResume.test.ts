import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { render } from 'solid-js/web';
import { describeResume } from '../src/features/home/resumeInfo';
import { HomeView } from '../src/features/home/HomeView';
import { CndEngine } from '../src/core/engine/CndEngine';
import { spatialNav } from '../src/ui/design/SpatialNav';
import { RemoteKeyHandler } from '../src/core/input/RemoteKeyHandler';

const item = (over: Record<string, unknown> = {}) => ({
  id: 5, source_id: 1, stable_hash: 'h5', kind: 'movie', name: 'Inception.2010.FHD', name_clean: 'Inception',
  stream_url: 'http://x.invalid/movie/u/p/5.mkv', is_favorite: 0, playback_position_ms: 0, duration_ms: 0, ...over,
}) as any;

describe('What the home says about the last thing watched', () => {
  it('a started film shows where it stopped and how far', () => {
    const info = describeResume(item({ playback_position_ms: 42 * 60_000, duration_ms: 120 * 60_000 }));
    expect(info.kind).toBe('Film');
    expect(info.title).toBe('Inception');
    expect(info.action).toContain('Reprendre à');
    expect(info.action).toContain('35 %');
    expect(info.percent).toBe(35);
  });

  it('a film not really started has no percentage', () => {
    const info = describeResume(item());
    expect(info.action).toBe('Reprendre la lecture');
    expect(info.percent).toBeUndefined();
  });

  it('an episode names its season and number; a series opens; a channel goes back to live', () => {
    expect(describeResume(item({ kind: 'episode', season_num: 2, episode_num: 5 })).kind).toBe('Épisode S02E05');
    expect(describeResume(item({ kind: 'series' })).action).toBe('Ouvrir la série');
    const live = describeResume(item({ kind: 'live', name: 'TF1', name_clean: 'TF1', playback_position_ms: 9999 }));
    expect(live.kind).toBe('En direct');
    expect(live.percent).toBeUndefined();
  });
});

describe('CndEngine.getLastWatched', () => {
  const engine = CndEngine.getInstance() as any;
  let store: Record<string, string>;
  beforeEach(() => {
    store = {};
    vi.stubGlobal('localStorage', { getItem: (k: string) => store[k] ?? null, setItem: (k: string, v: string) => { store[k] = v; }, removeItem: (k: string) => { delete store[k]; } });
    vi.spyOn(engine.db as any, 'getItemsByIds').mockImplementation((async (ids: number[]) => ids.map((id) => item({ id }))) as any);
    vi.spyOn(engine, 'checkAdultCategory').mockResolvedValue(false);
  });
  afterEach(() => { vi.unstubAllGlobals(); vi.restoreAllMocks(); });

  it('remembers the last item played, whatever its kind, and gives it back', async () => {
    expect(await engine.getLastWatched()).toBeNull();
    engine.recordRecent(item({ id: 7, kind: 'live' }));
    engine.recordRecent(item({ id: 9, kind: 'movie' }));
    expect((await engine.getLastWatched()).id).toBe(9);
  });

  it('ignores a film that is practically finished, and an item the profile may not see', async () => {
    vi.spyOn(engine.db, 'getItemsByIds').mockResolvedValue([item({ id: 9, playback_position_ms: 96, duration_ms: 100 })]);
    engine.recordRecent(item({ id: 9 }));
    expect(await engine.getLastWatched()).toBeNull();
    vi.spyOn(engine.db, 'getItemsByIds').mockResolvedValue([item({ id: 9, group_title: 'XXX' })]);
    engine.checkAdultCategory.mockResolvedValue(true);
    expect(await engine.getLastWatched()).toBeNull();
  });

  it('does not remember an item that is not in the database (negative id)', async () => {
    engine.recordRecent(item({ id: -3 }));
    expect(store['cnd_last_watched']).toBeUndefined();
  });
});

describe('Home: the « Reprendre » card', () => {
  const settle = async () => { for (let i = 0; i < 30; i++) await Promise.resolve(); await new Promise((r) => setTimeout(r, 30)); };
  let dispose = () => {};
  beforeEach(() => {
    RemoteKeyHandler.getInstance().init();
    (spatialNav as any).isInitialized = false;
    spatialNav.init();
  });
  afterEach(() => { dispose(); document.body.innerHTML = ''; RemoteKeyHandler.getInstance().destroy(); vi.restoreAllMocks(); });
  const mount = async (onResume: (i: any) => void) => {
    dispose = render(() => HomeView({ initialSection: 'live', onOpen: vi.fn(), onExit: vi.fn(), onResume }), document.body);
    await settle();
  };

  it('does not appear when nothing was watched: the home is unchanged and starts on Live', async () => {
    vi.spyOn(CndEngine.getInstance(), 'getLastWatched').mockResolvedValue(null);
    await mount(vi.fn());
    expect(document.getElementById('home-resume')).toBeNull();
    expect(spatialNav.getCurrentFocusId()).toBe('home-live');
  });

  it('appears with the title, takes the focus, and OK resumes that item', async () => {
    const last = item({ playback_position_ms: 42 * 60_000, duration_ms: 120 * 60_000 });
    vi.spyOn(CndEngine.getInstance(), 'getLastWatched').mockResolvedValue(last);
    const onResume = vi.fn();
    await mount(onResume);
    const card = document.getElementById('home-resume')!;
    expect(card).not.toBeNull();
    expect(card.textContent).toContain('Inception');
    expect(card.textContent).toContain('35 %');
    expect(spatialNav.getCurrentFocusId()).toBe('home-resume');
    window.dispatchEvent(new KeyboardEvent('keydown', { keyCode: 13 }));
    expect(onResume).toHaveBeenCalledWith(last);
    // DOWN reaches the three sections as before.
    window.dispatchEvent(new KeyboardEvent('keydown', { keyCode: 40 }));
    expect(spatialNav.getCurrentFocusId()).toBe('home-live');
  });

  it('a failing read leaves the plain home', async () => {
    vi.spyOn(CndEngine.getInstance(), 'getLastWatched').mockRejectedValue(new Error('storage'));
    await mount(vi.fn());
    expect(document.getElementById('home-resume')).toBeNull();
    expect(document.getElementById('home-live')).not.toBeNull();
  });
});
