/**
 * Remote-control navigation for the mini player panel, shared by every screen that has one.
 *
 * Panel buttons: the preview screen on top, then ONE row of actions (Play/Stop, Favorite, Full screen, then any
 * screen-specific extra actions), left to right. Their DOM ids are `${idPrefix}-screen|play|fav|full` (extras bring
 * their own id).
 */

import type { FocusableItem } from './SpatialNav';
import { spatialNav } from './SpatialNav';
import { RemoteKeyHandler } from '../../core/input/RemoteKeyHandler';
import type { MiniPlayerController, MiniPlayerItem } from '../../core/player/MiniPlayerController';

export interface PanelExtraAction {
  /** Full DOM id, e.g. `mv-insp-details`. */
  id: string;
  label: string;
  onSelect: () => void;
}

/** The focusable buttons of the panel, in their vertical order. */
export function panelFocusItems<T extends MiniPlayerItem>(
  ctl: MiniPlayerController<T>,
  idPrefix: string,
  onToggleFavorite: (item: T) => void,
  extras: PanelExtraAction[] = []
): FocusableItem[] {
  return [
    { id: `${idPrefix}-screen`, onSelect: () => ctl.fullscreenFromScreen() },
    { id: `${idPrefix}-play`, onSelect: () => ctl.toggle() },
    {
      id: `${idPrefix}-fav`,
      onSelect: () => {
        const item = ctl.focused();
        if (item) onToggleFavorite(item);
      },
    },
    { id: `${idPrefix}-full`, onSelect: () => ctl.fullscreen() },
    ...extras.map((e) => ({ id: e.id, onSelect: e.onSelect })),
  ];
}

/**
 * The panel button reachable with RIGHT from body row `row`. Below the panel's own rows the last
 * button is repeated: navigation skips same-id neighbours, so UP walks back up through the panel.
 */
export function panelItemForRow(items: FocusableItem[], row: number): FocusableItem | undefined {
  if (items.length === 0) return undefined;
  return items[Math.min(row, items.length - 1)];
}

/**
 * The panel buttons reachable with RIGHT from body row `row`: the preview screen on row 0, then the whole row of
 * actions on every other row (the same ids repeat on each row: navigation skips same-id neighbours, so UP goes back
 * to the preview screen and DOWN stays on the actions). The grid needs at least two body rows for this.
 */
export function panelItemsForRow(items: FocusableItem[], row: number): FocusableItem[] {
  if (items.length === 0) return [];
  if (row === 0 || items.length === 1) return [items[0]];
  return items.slice(1);
}

/** Body rows the grid needs so the preview screen and the row of actions can both be reached. */
export const PANEL_MIN_ROWS = 2;

/**
 * LEFT from the first panel stop (the preview screen, or the first action) goes back to the card the cursor came
 * from (not to the first row); LEFT between two actions moves along the row.
 * Returns the function that removes the listener.
 */
export function installPanelLeftReturn(
  idPrefix: string,
  focusId: () => string,
  lastContentFocus: () => string
): () => void {
  return RemoteKeyHandler.getInstance().addListener((key) => {
    const here = focusId();
    if (key !== 'LEFT' || (here !== `${idPrefix}-screen` && here !== `${idPrefix}-play`)) return false;
    const target = lastContentFocus();
    if (!target || !document.getElementById(target)) return false;
    spatialNav.setFocusById(target);
    return true;
  });
}
