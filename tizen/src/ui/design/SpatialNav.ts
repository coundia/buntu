/**
 * CND IPTV Tizen - Spatial Navigation Controller (PRD 38 § 5.1)
 *
 * Provides fast D-Pad focus navigation computed on registered items
 * with zero layout shifts and instant (<50ms) reaction time.
 */

import { createSignal } from 'solid-js';
import { RemoteKey, RemoteKeyHandler } from '../../core/input/RemoteKeyHandler';

export interface FocusableItem {
  id: string;
  onSelect?: () => void;
  onFocus?: () => void;
}

class SpatialNav {
  private static instance: SpatialNav;
  private currentFocus = createSignal<string>('');
  private focusableGrid: FocusableItem[][] = [];
  private currentRow = 0;
  private currentCol = 0;

  public static getInstance(): SpatialNav {
    if (!SpatialNav.instance) {
      SpatialNav.instance = new SpatialNav();
    }
    return SpatialNav.instance;
  }

  public init() {
    RemoteKeyHandler.getInstance().addListener(this.handleKey);
  }

  public getFocusSignal() {
    return this.currentFocus;
  }

  public getCurrentFocusId(): string {
    return this.currentFocus[0]();
  }

  public setGrid(grid: FocusableItem[][], initialRow = 0, initialCol = 0) {
    this.focusableGrid = grid;
    this.currentRow = Math.min(initialRow, Math.max(0, grid.length - 1));
    this.currentCol = Math.min(initialCol, Math.max(0, (grid[this.currentRow]?.length || 1) - 1));

    const item = this.focusableGrid[this.currentRow]?.[this.currentCol];
    if (item) {
      this.currentFocus[1](item.id);
      item.onFocus?.();
    }
  }

  public setFocusById(id: string) {
    for (let r = 0; r < this.focusableGrid.length; r++) {
      for (let c = 0; c < this.focusableGrid[r].length; c++) {
        if (this.focusableGrid[r][c].id === id) {
          this.currentRow = r;
          this.currentCol = c;
          this.currentFocus[1](id);
          this.focusableGrid[r][c].onFocus?.();
          return;
        }
      }
    }
  }

  private handleKey = (key: RemoteKey): boolean => {
    if (!this.focusableGrid.length) return false;

    let r = this.currentRow;
    let c = this.currentCol;

    if (key === 'UP') {
      if (r > 0) {
        r--;
        c = Math.min(c, this.focusableGrid[r].length - 1);
      } else {
        return false;
      }
    } else if (key === 'DOWN') {
      if (r < this.focusableGrid.length - 1) {
        r++;
        c = Math.min(c, this.focusableGrid[r].length - 1);
      } else {
        return false;
      }
    } else if (key === 'LEFT') {
      if (c > 0) {
        c--;
      } else {
        return false;
      }
    } else if (key === 'RIGHT') {
      if (c < this.focusableGrid[r].length - 1) {
        c++;
      } else {
        return false;
      }
    } else if (key === 'ENTER') {
      const item = this.focusableGrid[this.currentRow]?.[this.currentCol];
      if (item && item.onSelect) {
        item.onSelect();
        return true;
      }
      return false;
    } else {
      return false;
    }

    this.currentRow = r;
    this.currentCol = c;
    const item = this.focusableGrid[r][c];
    if (item) {
      this.currentFocus[1](item.id);
      item.onFocus?.();
    }
    return true;
  };
}

export const spatialNav = SpatialNav.getInstance();
