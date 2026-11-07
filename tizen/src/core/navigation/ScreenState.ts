/**
 * Remembers where the viewer was on a browsing screen (category, view mode, focused card) so that
 * BACK from a details page or the player lands on the very same spot instead of a fresh screen.
 *
 * The saved state is only handed back after a BACK ("armed" by the app); opening the screen from
 * the menu starts clean, as before.
 */

/** What the screen displayed, so BACK can show it again instantly while a refresh runs behind. */
export interface BrowseSnapshot<T = unknown> {
  categories: string[];
  catCounts: Record<string, number>;
  totalCount: number;
  favCount: number;
  recent: T[];
  favs: T[];
  items: T[];
  total: number;
  scrollTop: number;
  /** Program lines already loaded (live only). */
  epg?: Record<string, unknown>;
}

export interface BrowseState {
  /** Selected category ('' = all items). */
  category: string;
  viewMode: 'grid' | 'list';
  /** DOM id of the card that had the focus (e.g. `channel-42`). */
  focusId: string;
  snapshot?: BrowseSnapshot;
}

/** A card of the content area, not a category row, toolbar button or menu entry. */
export function isContentFocusId(id: string): boolean {
  return /-\d+$/.test(id) && !/(^|-)cat-\d+$/.test(id);
}

class ScreenStateStore {
  private saved = new Map<string, BrowseState>();
  private armed = new Set<string>();

  save(screen: string, state: BrowseState): void {
    this.saved.set(screen, state);
  }

  /** The next mount of `screen` must restore its saved state. */
  arm(screen: string): void {
    this.armed.clear();
    if (this.saved.has(screen)) this.armed.add(screen);
  }

  /** Any other navigation cancels a pending restore. */
  disarm(): void {
    this.armed.clear();
  }

  /** The state to restore on mount, only if a BACK targeted this screen. One-shot. */
  restore(screen: string): BrowseState | undefined {
    if (!this.armed.delete(screen)) return undefined;
    return this.saved.get(screen);
  }

  clear(): void {
    this.saved.clear();
    this.armed.clear();
  }
}

export const screenState = new ScreenStateStore();

interface PagedList {
  items: () => { id: number }[];
  hasMore: () => boolean;
  loadMore: () => Promise<boolean>;
}

/** Loads further pages until the card with this DOM id is part of the list (bounded). */
export async function revealItem(list: PagedList, focusId: string, maxPages = 8): Promise<void> {
  if (/^(recent|fav)-/.test(focusId)) return; // shelves are always rendered
  const match = /-(\d+)$/.exec(focusId);
  if (!match) return;
  const wanted = Number(match[1]);
  for (let i = 0; i < maxPages; i += 1) {
    if (list.items().some((item) => item.id === wanted) || !list.hasMore()) return;
    if (!(await list.loadMore())) return;
  }
}
