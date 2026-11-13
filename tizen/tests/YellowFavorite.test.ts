import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { registerYellowFavorite } from '../src/ui/design/yellowFavorite';
import { spatialNav } from '../src/ui/design/SpatialNav';
import { RemoteKeyHandler } from '../src/core/input/RemoteKeyHandler';

const YELLOW = 405;
const press = (keyCode: number) => window.dispatchEvent(new KeyboardEvent('keydown', { keyCode }));

describe('Yellow button = favourite', () => {
  let off: () => void = () => {};
  let appYellow: ReturnType<typeof vi.fn>;
  let offApp: () => void = () => {};
  const toggle = vi.fn();
  const movie = { id: 7 };

  beforeEach(() => {
    toggle.mockClear();
    RemoteKeyHandler.getInstance().init();
    (spatialNav as any).isInitialized = false;
    spatialNav.init();
    spatialNav.setHeader([]);
    spatialNav.setGrid([[{ id: 'movie-cat-0' }, { id: 'movie-7' }, { id: 'mv-insp-fav' }]]);
    // The app's own handler (yellow = search) is registered first, like in App.tsx.
    appYellow = vi.fn((key: string) => key === 'YELLOW');
    offApp = RemoteKeyHandler.getInstance().addListener(appYellow as any);
    off = registerYellowFavorite({
      isItemFocus: (id) => /^(?:movie|recent-mv|fav-mv)-\d+$/.test(id) || id.startsWith('mv-insp'),
      current: () => movie,
      toggle,
    });
  });
  afterEach(() => { off(); offApp(); RemoteKeyHandler.getInstance().destroy(); });

  it('toggles the favourite of the highlighted card', () => {
    spatialNav.setFocusById('movie-7');
    press(YELLOW);
    expect(toggle).toHaveBeenCalledWith(movie);
    expect(appYellow.mock.calls.filter((c) => c[0] === 'YELLOW')).toHaveLength(0);
  });

  it('works from the side panel too', () => {
    spatialNav.setFocusById('mv-insp-fav');
    press(YELLOW);
    expect(toggle).toHaveBeenCalledTimes(1);
  });

  it('on a category the yellow button keeps its usual job (search)', () => {
    spatialNav.setFocusById('movie-cat-0');
    press(YELLOW);
    expect(toggle).not.toHaveBeenCalled();
    expect(appYellow.mock.calls.filter((c) => c[0] === 'YELLOW')).toHaveLength(1);
  });

  it('does nothing without an item under the cursor, and not while a dialog is open', () => {
    off();
    off = registerYellowFavorite({ isItemFocus: () => true, current: () => null, toggle });
    spatialNav.setFocusById('movie-7');
    press(YELLOW);
    expect(toggle).not.toHaveBeenCalled();
    off();
    off = registerYellowFavorite({ isItemFocus: () => true, current: () => movie, toggle });
    spatialNav.openModal([[{ id: 'dlg' }]]);
    press(YELLOW);
    expect(toggle).not.toHaveBeenCalled();
    spatialNav.closeModal();
  });

  it('is wired in Live, Films and Séries', () => {
    for (const p of ['src/features/live/LiveView.tsx', 'src/features/movies/MoviesView.tsx', 'src/features/series/SeriesView.tsx']) {
      expect(readFileSync(resolve(__dirname, '..', p), 'utf8'), p).toContain('registerYellowFavorite');
    }
  });
});
