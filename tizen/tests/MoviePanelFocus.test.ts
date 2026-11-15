import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { render } from 'solid-js/web';
import { MoviesView } from '../src/features/movies/MoviesView';
import { CndEngine } from '../src/core/engine/CndEngine';
import { spatialNav } from '../src/ui/design/SpatialNav';
import { RemoteKeyHandler } from '../src/core/input/RemoteKeyHandler';
import { screenState } from '../src/core/navigation/ScreenState';

const settle = async () => { for (let i = 0; i < 30; i++) await Promise.resolve(); await new Promise((r) => setTimeout(r, 250)); };
const key = (keyCode: number) => window.dispatchEvent(new KeyboardEvent('keydown', { keyCode }));
let dispose = () => {};
const film = (id: number) => ({ id, source_id: 1, stable_hash: `h${id}`, kind: 'movie', name: `Film ${id}`, name_clean: `Film ${id}`, stream_url: 'http://x.invalid/movie/u/p/1.mkv', is_favorite: 0, playback_position_ms: 0, duration_ms: 0, plot: 'Un long résumé à lire.' }) as any;

beforeEach(() => {
  RemoteKeyHandler.getInstance().init();
  (spatialNav as any).isInitialized = false;
  spatialNav.init();
  spatialNav.setHeader([]);
  const engine = CndEngine.getInstance() as any;
  vi.spyOn(engine, 'getCategories').mockResolvedValue(['Action']);
  vi.spyOn(engine, 'getCategoryCounts').mockResolvedValue({ total: 3, favCount: 0, counts: { Action: 3 } });
  vi.spyOn(engine, 'getRecentItems').mockResolvedValue([]);
  vi.spyOn(engine, 'getFavoritesByKind').mockResolvedValue([]);
  vi.spyOn(engine, 'countCatalog').mockResolvedValue(3);
  vi.spyOn(engine, 'getCatalog').mockResolvedValue([film(1), film(2), film(3)]);
  vi.spyOn(engine, 'getMovieInfo').mockResolvedValue(null);
  vi.spyOn(engine, 'play').mockResolvedValue(undefined);
  vi.spyOn(engine, 'stopPlayback').mockImplementation(() => {});
  vi.spyOn(engine, 'recordRecent').mockImplementation(() => {});
});
afterEach(() => { dispose(); screenState.clear(); document.body.innerHTML = ''; RemoteKeyHandler.getInstance().destroy(); vi.restoreAllMocks(); });

describe('Films: OK on a film plays it in the mini player and moves the cursor to it', () => {
  it('does not open full screen; the cursor lands on the mini player so the text can be read', async () => {
    const onPlayMovie = vi.fn();
    const onSelectMovie = vi.fn();
    dispose = render(() => MoviesView({ onSelectMovie, onPlayMovie }), document.body);
    await settle();
    spatialNav.setFocusById('movie-1');
    key(13); // OK on the film
    await settle();
    expect(CndEngine.getInstance().play).toHaveBeenCalledTimes(1);
    expect(onPlayMovie).not.toHaveBeenCalled();
    expect(onSelectMovie).not.toHaveBeenCalled();
    expect(spatialNav.getCurrentFocusId()).toBe('mv-insp-screen');
    expect(document.body.textContent).toContain('Un long résumé à lire.');
    // LEFT goes back to the film the cursor came from.
    key(37);
    expect(spatialNav.getCurrentFocusId()).toBe('movie-1');
  });

  it('OK a second time on the same film does not go full screen either', async () => {
    const onPlayMovie = vi.fn();
    dispose = render(() => MoviesView({ onSelectMovie: vi.fn(), onPlayMovie }), document.body);
    await settle();
    spatialNav.setFocusById('movie-1');
    key(13);
    await settle();
    key(37);
    key(13);
    await settle();
    expect(onPlayMovie).not.toHaveBeenCalled();
    expect(spatialNav.getCurrentFocusId()).toBe('mv-insp-screen');
  });

  it('the four buttons are on one line: arrows move along it, UP goes to the screen, LEFT from the first goes back to the film', async () => {
    dispose = render(() => MoviesView({ onSelectMovie: vi.fn(), onPlayMovie: vi.fn() }), document.body);
    await settle();
    spatialNav.setFocusById('movie-1');
    key(13);
    await settle();
    expect(spatialNav.getCurrentFocusId()).toBe('mv-insp-screen');
    key(40);
    expect(spatialNav.getCurrentFocusId()).toBe('mv-insp-play');
    key(39);
    expect(spatialNav.getCurrentFocusId()).toBe('mv-insp-fav');
    key(39);
    expect(spatialNav.getCurrentFocusId()).toBe('mv-insp-full');
    key(39);
    expect(spatialNav.getCurrentFocusId()).toBe('mv-insp-details');
    key(37);
    expect(spatialNav.getCurrentFocusId()).toBe('mv-insp-full');
    key(38);
    expect(spatialNav.getCurrentFocusId()).toBe('mv-insp-screen');
    key(40);
    key(37); // LEFT from the first action
    expect(spatialNav.getCurrentFocusId()).toBe('movie-1');
  });

  it('puts the actions in a single row of the panel', async () => {
    dispose = render(() => MoviesView({ onSelectMovie: vi.fn(), onPlayMovie: vi.fn() }), document.body);
    await settle();
    spatialNav.setFocusById('movie-1');
    key(13);
    await settle();
    const row = document.querySelector('.mini-panel .buntu-inspector-actions')!;
    expect([...row.querySelectorAll('button')].map((b) => b.id)).toEqual(['mv-insp-play', 'mv-insp-fav', 'mv-insp-full', 'mv-insp-details']);
  });

  it('queries the selected category in the selected sort order from the remote', async () => {
    const engine = CndEngine.getInstance();
    dispose = render(() => MoviesView({ onSelectMovie: vi.fn(), onPlayMovie: vi.fn() }), document.body);
    await settle();
    document.getElementById('movie-cat-0')!.click();
    await settle();
    spatialNav.setFocusById('mv-sort');
    key(13);
    await settle();
    expect(engine.getCatalog).toHaveBeenLastCalledWith('movie', 'Action', 0, expect.any(Number), 'nameAsc');
    key(13);
    await settle();
    expect(engine.getCatalog).toHaveBeenLastCalledWith('movie', 'Action', 0, expect.any(Number), 'nameDesc');
  });

  it.each(['details', 'full'])('restores the category scroll and clicked film after leaving via %s', async (action) => {
    const onSelectMovie = vi.fn();
    const onPlayMovie = vi.fn();
    const mountMovies = () => render(() => MoviesView({ onSelectMovie, onPlayMovie }), document.body);
    const content = () => document.querySelector<HTMLElement>('.buntu-content-scroll')!;
    const categories = () => document.querySelector<HTMLElement>('.buntu-cat-list')!;
    dispose = mountMovies();
    await settle();
    document.getElementById('movie-cat-0')!.click();
    await settle();
    document.getElementById('movie-2')!.click();
    await settle();
    content().scrollTop = 480;
    categories().scrollTop = 120;
    document.getElementById(`mv-insp-${action}`)!.click();
    expect(action === 'details' ? onSelectMovie : onPlayMovie).toHaveBeenCalledWith(expect.objectContaining({ id: 2 }));
    dispose();
    screenState.arm('movies');
    dispose = mountMovies();
    await settle();
    expect(document.querySelector('.buntu-cat-row.active')?.id).toBe('movie-cat-0');
    expect(spatialNav.getCurrentFocusId()).toBe('movie-2');
    expect(content().scrollTop).toBe(480);
    expect(categories().scrollTop).toBe(120);
  });
});

