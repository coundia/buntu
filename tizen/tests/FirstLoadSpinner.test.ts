import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { render } from 'solid-js/web';
import { MoviesView } from '../src/features/movies/MoviesView';
import { SeriesView } from '../src/features/series/SeriesView';
import { CndEngine } from '../src/core/engine/CndEngine';
import { spatialNav } from '../src/ui/design/SpatialNav';
import { RemoteKeyHandler } from '../src/core/input/RemoteKeyHandler';

const settle = async () => { for (let i = 0; i < 30; i++) await Promise.resolve(); await new Promise((r) => setTimeout(r, 120)); };
let dispose = () => {};
const film = (id: number) => ({ id, source_id: 1, stable_hash: `h${id}`, kind: 'movie', name: `Film ${id}`, name_clean: `Film ${id}`, stream_url: 'http://x.invalid/movie/u/p/1.mkv', is_favorite: 0, playback_position_ms: 0, duration_ms: 0 }) as any;
let release: (cats: string[]) => void = () => {};

beforeEach(() => {
  RemoteKeyHandler.getInstance().init();
  (spatialNav as any).isInitialized = false;
  spatialNav.init();
  spatialNav.setHeader([]);
  const engine = CndEngine.getInstance() as any;
  // The categories answer late, like a big catalogue on the TV.
  vi.spyOn(engine, 'getCategories').mockImplementation(() => new Promise<string[]>((resolve) => { release = resolve; }));
  vi.spyOn(engine, 'getCategoryCounts').mockResolvedValue({ total: 3, favCount: 1, counts: { Action: 3 } });
  vi.spyOn(engine, 'getRecentItems').mockResolvedValue([]);
  vi.spyOn(engine, 'getFavoritesByKind').mockResolvedValue([]);
  vi.spyOn(engine, 'countCatalog').mockResolvedValue(3);
  vi.spyOn(engine, 'getCatalog').mockResolvedValue([film(1), film(2), film(3)]);
  vi.spyOn(engine, 'getMovieInfo').mockResolvedValue(null);
});
afterEach(() => { dispose(); document.body.innerHTML = ''; RemoteKeyHandler.getInstance().destroy(); vi.restoreAllMocks(); });

describe('Films: a spinner instead of zeros while the first load runs', () => {
  it('shows the spinner and no count, then the counts once loaded', async () => {
    dispose = render(() => MoviesView({ onSelectMovie: vi.fn(), onPlayMovie: vi.fn() } as any), document.body);
    await settle();
    expect(document.querySelector('.buntu-first-load .tv-spinner')).not.toBeNull();
    expect(document.body.textContent).toContain('Chargement des films');
    expect(document.querySelectorAll('.buntu-cat-count')).toHaveLength(0);
    expect(document.body.textContent).not.toMatch(/\b0 films\b/);
    expect(document.querySelector('.buntu-section-meta')).toBeNull();

    release(['Action']);
    await settle();
    expect(document.querySelector('.buntu-first-load')).toBeNull();
    expect(document.querySelectorAll('.buntu-cat-count').length).toBeGreaterThan(0);
    expect(document.querySelector('.buntu-section-meta')).not.toBeNull();
  });

  it('a failing first load does not leave the spinner forever', async () => {
    (CndEngine.getInstance() as any).getCategories.mockRejectedValue(new Error('offline'));
    dispose = render(() => MoviesView({ onSelectMovie: vi.fn(), onPlayMovie: vi.fn() } as any), document.body);
    await settle();
    expect(document.querySelector('.buntu-first-load')).toBeNull();
  });
});

describe('Séries: the same spinner instead of zeros', () => {
  it('shows the spinner and no count, then the counts once loaded', async () => {
    dispose = render(() => SeriesView({ onSelectSeries: vi.fn() }), document.body);
    await settle();
    expect(document.querySelector('.buntu-first-load .tv-spinner')).not.toBeNull();
    expect(document.body.textContent).toContain('Chargement des séries');
    expect(document.querySelectorAll('.buntu-cat-count')).toHaveLength(0);
    expect(document.body.textContent).not.toMatch(/\b0 séries\b/);
    expect(document.querySelector('.buntu-section-meta')).toBeNull();

    release(['Drame']);
    await settle();
    expect(document.querySelector('.buntu-first-load')).toBeNull();
    expect(document.querySelectorAll('.buntu-cat-count').length).toBeGreaterThan(0);
    expect(document.querySelector('.buntu-section-meta')).not.toBeNull();
  });

  it('a failing first load does not leave the spinner forever', async () => {
    (CndEngine.getInstance() as any).getCategories.mockRejectedValue(new Error('offline'));
    dispose = render(() => SeriesView({ onSelectSeries: vi.fn() }), document.body);
    await settle();
    expect(document.querySelector('.buntu-first-load')).toBeNull();
  });
});
