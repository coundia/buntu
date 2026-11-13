import { RemoteKeyHandler } from '../../core/input/RemoteKeyHandler';
import { spatialNav } from './SpatialNav';

export interface YellowFavoriteOptions<T> {
  /** `true` when the remote highlights a card (or the side panel) whose item can be a favourite. */
  isItemFocus: (focusId: string) => boolean;
  /** The item under the cursor. */
  current: () => T | null;
  toggle: (item: T) => void | Promise<void>;
}

/**
 * The yellow button adds or removes the highlighted film, series or channel from the favourites.
 * Anywhere else on the screen it is left to the app (yellow opens the search). Returns the unsubscribe function.
 */
export function registerYellowFavorite<T>(options: YellowFavoriteOptions<T>): () => void {
  return RemoteKeyHandler.getInstance().addListener((key) => {
    if (key !== 'YELLOW') return false;
    if (spatialNav.isModalOpen()) return false;
    if (!options.isItemFocus(spatialNav.getCurrentFocusId())) return false;
    const item = options.current();
    if (!item) return false;
    void options.toggle(item);
    return true;
  });
}
