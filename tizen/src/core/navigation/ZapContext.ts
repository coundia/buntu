/**
 * Which list a channel was opened from, so Ch+ / Ch- in the full-screen player move through that
 * list (the favorites, the recents, a category) and not through the whole catalog.
 *
 * `category` uses the catalog's names: '' = all channels, FAVORITES_CATEGORY, RECENT_CATEGORY, or a
 * provider category. The Live TV screen sets it when it opens the player; any other navigation
 * resets it.
 */
export const zapContext: { category: string; frozen: { id: number }[] | null } = {
  category: '',
  /**
   * The "recently watched" list as it was when zapping began. Watching a channel moves it to the top
   * of that list, so it is frozen for the whole viewing session: Ch+ / Ch- then walk a stable order.
   */
  frozen: null,
};

/**
 * The item next to `currentId` in an ordered list, wrapping around at the ends.
 * `direction` 1 = next, -1 = previous. When the current item is not in the list (for instance a
 * favorite that was just removed) the list is entered from its start (or its end going backwards).
 * Undefined when the list is empty or holds only the current item.
 */
export function neighbourInList<T extends { id: number }>(list: T[], currentId: number, direction: 1 | -1): T | undefined {
  const others = list.filter((item) => item.id !== currentId);
  if (others.length === 0) return undefined;
  const index = list.findIndex((item) => item.id === currentId);
  if (index === -1) return direction === 1 ? list[0] : list[list.length - 1];
  const size = list.length;
  return list[(index + direction + size) % size];
}
