import { describe, it, expect } from 'vitest';
import { NavigationHistory, NavEntry } from '../src/core/navigation/NavigationHistory';

type Item = { id: number };
const at = (route: string, item: Item | null = null): NavEntry<Item> => ({ route, item });

describe('NavigationHistory', () => {
  it('returns to the screen that was displayed before', () => {
    const h = new NavigationHistory<Item>();
    h.enter(at('live'), at('movies'));
    h.enter(at('movies'), at('details', { id: 7 }));
    expect(h.back()).toEqual(at('movies'));
    expect(h.back()).toEqual(at('live'));
    expect(h.back()).toBeUndefined();
  });

  it('brings back the item of a details screen after the player', () => {
    const h = new NavigationHistory<Item>();
    h.enter(at('series'), at('details', { id: 3 }));
    h.enter(at('details', { id: 3 }), at('player', { id: 3 }));
    expect(h.back()).toEqual(at('details', { id: 3 }));
    expect(h.back()).toEqual(at('series'));
  });

  it('ignores a move to the screen already displayed', () => {
    const h = new NavigationHistory<Item>();
    h.enter(at('live'), at('live'));
    expect(h.size).toBe(0);
  });

  it('pops instead of stacking when going back to the previous screen through the menu', () => {
    const h = new NavigationHistory<Item>();
    h.enter(at('live'), at('movies'));
    h.enter(at('movies'), at('live'));
    expect(h.size).toBe(0);
  });

  it('keeps two different details screens apart', () => {
    const h = new NavigationHistory<Item>();
    h.enter(at('search'), at('details', { id: 1 }));
    h.enter(at('details', { id: 1 }), at('details', { id: 2 }));
    expect(h.back()).toEqual(at('details', { id: 1 }));
    expect(h.back()).toEqual(at('search'));
  });

  it('never stacks onboarding', () => {
    const h = new NavigationHistory<Item>();
    h.enter(at('onboarding'), at('live'));
    expect(h.size).toBe(0);
  });

  it('is bounded and can be reset', () => {
    const h = new NavigationHistory<Item>(3);
    for (let i = 0; i < 6; i += 1) h.enter(at(`s${i}`), at(`s${i + 1}`));
    expect(h.size).toBe(3);
    expect(h.back()?.route).toBe('s5');
    h.reset();
    expect(h.size).toBe(0);
  });
});

import { screenState, isContentFocusId, revealItem } from '../src/core/navigation/ScreenState';

describe('ScreenState', () => {
  it('only restores after BACK armed the screen, and only once', () => {
    screenState.clear();
    screenState.save('live', { category: 'FR | Sport', viewMode: 'grid', focusId: 'channel-9' });
    expect(screenState.restore('live')).toBeUndefined(); // opened from the menu: clean start
    screenState.arm('live');
    expect(screenState.restore('live')?.category).toBe('FR | Sport');
    expect(screenState.restore('live')).toBeUndefined();
  });

  it('a normal navigation cancels a pending restore', () => {
    screenState.clear();
    screenState.save('movies', { category: 'Action', viewMode: 'list', focusId: 'movie-3' });
    screenState.arm('movies');
    screenState.disarm();
    expect(screenState.restore('movies')).toBeUndefined();
  });

  it('tells content cards from categories and toolbar buttons', () => {
    expect(isContentFocusId('channel-42')).toBe(true);
    expect(isContentFocusId('recent-ch-7')).toBe(true);
    expect(isContentFocusId('movie-12')).toBe(true);
    expect(isContentFocusId('movie-cat-3')).toBe(false);
    expect(isContentFocusId('cat-2')).toBe(false);
    expect(isContentFocusId('live-mode-grid')).toBe(false);
  });

  it('loads more pages until the focused card is present', async () => {
    let items = [{ id: 1 }, { id: 2 }];
    let pages = 0;
    const list = {
      items: () => items,
      hasMore: () => items.length < 10,
      loadMore: async () => {
        pages += 1;
        items = [...items, { id: items.length + 1 }, { id: items.length + 2 }];
        return true;
      },
    };
    await revealItem(list, 'channel-7');
    expect(items.some((i) => i.id === 7)).toBe(true);
    expect(pages).toBe(3);
    await revealItem(list, 'recent-ch-99'); // shelves: nothing to load
    expect(pages).toBe(3);
  });
});
