/**
 * CND IPTV Tizen - Spatial Navigation Controller (PRD 38 § 5.1)
 *
 * Provides fast D-Pad focus navigation computed on registered items
 * with zero layout shifts and instant (<50ms) reaction time.
 */

import { createSignal } from 'solid-js';
import { RemoteKey, RemoteKeyHandler } from '../../core/input/RemoteKeyHandler';
import { syncDomFocus } from './a11y';

export interface FocusableItem {
  id: string;
  onSelect?: () => void;
  onFocus?: () => void;
}

class SpatialNav {
  private static instance: SpatialNav;
  private currentFocus = createSignal<string>('');
  private focusableGrid: FocusableItem[][] = [];
  private headerItems: FocusableItem[] = [];
  private headerOrientation: 'horizontal' | 'vertical' = 'horizontal';
  private savedGridRow = 0;
  private currentRow = 0; // -1 means focus is in `headerItems` (Navigation Bar / Sidebar)
  private currentCol = 0;
  private headerCol = 0;
  private isInitialized = false;
  private focusFramePending = false;
  private modalState: {
    grid: FocusableItem[][];
    header: FocusableItem[];
    headerOrientation: 'horizontal' | 'vertical';
    row: number;
    col: number;
    headerCol: number;
  } | null = null;

  private constructor() {
    this.init();
  }

  public static getInstance(): SpatialNav {
    if (!SpatialNav.instance) {
      SpatialNav.instance = new SpatialNav();
    }
    return SpatialNav.instance;
  }

  public init() {
    if (this.isInitialized) return;
    this.isInitialized = true;
    RemoteKeyHandler.getInstance().init();
    RemoteKeyHandler.getInstance().addListener(this.handleKey);
  }

  public getFocusSignal() {
    return this.currentFocus;
  }

  public getCurrentFocusId(): string {
    return this.currentFocus[0]();
  }

  public isModalOpen(): boolean {
    return this.modalState !== null;
  }

  public setHeader(items: FocusableItem[], activeIndex = 0, orientation: 'horizontal' | 'vertical' = 'horizontal') {
    if (this.modalState) {
      this.modalState.header = items;
      this.modalState.headerOrientation = orientation;
      if (items.length > 0) {
        this.modalState.headerCol = Math.min(Math.max(0, activeIndex), items.length - 1);
      }
      return;
    }
    this.headerItems = items;
    this.headerOrientation = orientation;
    if (items.length > 0) {
      this.headerCol = Math.min(Math.max(0, activeIndex), items.length - 1);
    } else if (this.currentRow === -1) {
      this.currentRow = 0;
    }
  }

  public setGrid(grid: FocusableItem[][], initialRow = 0, initialCol = 0, preserveFocus = false) {
    const nonEmpty = grid.filter((row) => row.length > 0);
    if (this.modalState) {
      this.modalState.grid = nonEmpty;
      return;
    }

    const currentId = this.getCurrentFocusId();
    this.focusableGrid = nonEmpty;

    if (nonEmpty.length === 0) {
      if (this.headerItems.length > 0) {
        this.currentRow = -1;
        const hItem = this.headerItems[this.headerCol];
        if (hItem) {
          this.applyFocus(hItem);
        }
      } else {
        this.currentFocus[1]('');
      }
      return;
    }

    if (preserveFocus && currentId) {
      for (let r = 0; r < nonEmpty.length; r++) {
        for (let c = 0; c < nonEmpty[r].length; c++) {
          if (nonEmpty[r][c].id === currentId) {
            this.currentRow = r;
            this.currentCol = c;
            this.applyFocus(nonEmpty[r][c]);
            return;
          }
        }
      }
    }

    this.currentRow = Math.min(initialRow, Math.max(0, nonEmpty.length - 1));
    this.currentCol = Math.min(initialCol, Math.max(0, (nonEmpty[this.currentRow]?.length || 1) - 1));

    const item = this.focusableGrid[this.currentRow]?.[this.currentCol];
    if (item) {
      this.applyFocus(item);
    }
  }

  public openModal(grid: FocusableItem[][], initialRow = 0, initialCol = 0) {
    if (!this.modalState) {
      this.modalState = {
        grid: this.focusableGrid,
        header: this.headerItems,
        headerOrientation: this.headerOrientation,
        row: this.currentRow,
        col: this.currentCol,
        headerCol: this.headerCol,
      };
    }
    this.headerItems = [];
    const nonEmpty = grid.filter((row) => row.length > 0);
    this.focusableGrid = nonEmpty;

    if (nonEmpty.length === 0) {
      this.currentFocus[1]('');
      return;
    }

    this.currentRow = Math.min(initialRow, Math.max(0, nonEmpty.length - 1));
    this.currentCol = Math.min(initialCol, Math.max(0, (nonEmpty[this.currentRow]?.length || 1) - 1));

    const item = this.focusableGrid[this.currentRow]?.[this.currentCol];
    if (item) {
      this.applyFocus(item);
    }
  }

  public closeModal() {
    if (!this.modalState) return;
    const prev = this.modalState;
    this.modalState = null;
    this.headerItems = prev.header;
    this.headerOrientation = prev.headerOrientation;
    this.focusableGrid = prev.grid;
    this.currentRow = prev.row;
    this.currentCol = prev.col;
    this.headerCol = prev.headerCol;

    if (this.currentRow === -1) {
      const item = this.headerItems[this.headerCol];
      if (item) this.applyFocus(item);
    } else {
      const item = this.focusableGrid[this.currentRow]?.[this.currentCol];
      if (item) this.applyFocus(item);
    }
  }

  public setFocusById(id: string) {
    for (let c = 0; c < this.headerItems.length; c++) {
      if (this.headerItems[c].id === id) {
        this.currentRow = -1;
        this.headerCol = c;
        this.applyFocus(this.headerItems[c]);
        return;
      }
    }
    for (let r = 0; r < this.focusableGrid.length; r++) {
      for (let c = 0; c < this.focusableGrid[r].length; c++) {
        if (this.focusableGrid[r][c].id === id) {
          this.currentRow = r;
          this.currentCol = c;
          this.applyFocus(this.focusableGrid[r][c]);
          return;
        }
      }
    }
  }

  private applyFocus(item: FocusableItem) {
    this.currentFocus[1](item.id);
    item.onFocus?.();
    if (!this.focusFramePending && typeof window !== 'undefined' && typeof window.requestAnimationFrame === 'function') {
      // Keys and OK stay synchronous; only the final DOM focus/scroll is needed per frame.
      this.focusFramePending = true;
      window.requestAnimationFrame(() => {
        this.focusFramePending = false;
        const el = document.getElementById(this.getCurrentFocusId());
        if (!el) return; // The screen may have been unmounted by OK or BACK.
        if (typeof el.scrollIntoView === 'function') {
          el.scrollIntoView({ behavior: 'auto', block: 'nearest', inline: 'nearest' });
        }
        syncDomFocus(el);
      });
    }
  }

  private handleKey = (key: RemoteKey): boolean => {
    // 1. Navigation inside Navigation Bar / Buntu Left Sidebar (currentRow === -1)
    if (this.currentRow === -1) {
      if (!this.headerItems.length) return false;

      if (this.headerOrientation === 'vertical') {
        if (key === 'UP') {
          if (this.headerCol > 0) {
            this.headerCol--;
            this.applyFocus(this.headerItems[this.headerCol]);
          }
          return true;
        }
        if (key === 'DOWN') {
          if (this.headerCol < this.headerItems.length - 1) {
            this.headerCol++;
            this.applyFocus(this.headerItems[this.headerCol]);
          }
          return true;
        }
        if (key === 'RIGHT') {
          if (this.focusableGrid.length > 0) {
            this.currentRow = Math.min(Math.max(0, this.savedGridRow), this.focusableGrid.length - 1);
            this.currentCol = 0;
            const item = this.focusableGrid[this.currentRow]?.[0];
            if (item) this.applyFocus(item);
          }
          return true;
        }
        if (key === 'LEFT') {
          return true;
        }
        if (key === 'ENTER') {
          const item = this.headerItems[this.headerCol];
          if (item?.onSelect) {
            item.onSelect();
            return true;
          }
          return false;
        }
        return false;
      }

      // Horizontal header bar mode
      if (key === 'LEFT' || key === 'UP') {
        if (this.headerCol > 0) {
          this.headerCol--;
          this.applyFocus(this.headerItems[this.headerCol]);
        }
        return true;
      }
      if (key === 'RIGHT') {
        if (this.headerCol < this.headerItems.length - 1) {
          this.headerCol++;
          this.applyFocus(this.headerItems[this.headerCol]);
        }
        return true;
      }
      if (key === 'DOWN') {
        if (this.focusableGrid.length > 0) {
          this.currentRow = 0;
          this.currentCol = Math.min(this.currentCol, this.focusableGrid[0].length - 1);
          const item = this.focusableGrid[0][this.currentCol];
          if (item) this.applyFocus(item);
        }
        return true;
      }
      if (key === 'ENTER') {
        const item = this.headerItems[this.headerCol];
        if (item?.onSelect) {
          item.onSelect();
          return true;
        }
        return false;
      }
      return false;
    }

    // 2. If screen grid is empty, allow jumping to Navigation
    if (!this.focusableGrid.length) {
      if ((key === 'UP' || key === 'LEFT' || key === 'RIGHT') && this.headerItems.length > 0) {
        this.currentRow = -1;
        this.applyFocus(this.headerItems[this.headerCol]);
        return true;
      }
      return false;
    }

    let r = this.currentRow;
    let c = this.currentCol;
    const currentItem = this.focusableGrid[r]?.[c];

    if (key === 'UP') {
      if (r > 0) {
        let nr = r - 1;
        while (nr >= 0) {
          const colIdx = Math.min(c, (this.focusableGrid[nr]?.length || 1) - 1);
          const candidate = this.focusableGrid[nr]?.[colIdx];
          if (candidate && (!currentItem || candidate.id !== currentItem.id)) {
            r = nr;
            c = colIdx;
            break;
          }
          nr--;
        }
        if (nr < 0) {
          if (this.headerOrientation === 'horizontal' && this.headerItems.length > 0) {
            this.currentRow = -1;
            this.applyFocus(this.headerItems[this.headerCol]);
            return true;
          }
          return false;
        }
      } else if (this.headerOrientation === 'horizontal' && this.headerItems.length > 0) {
        this.currentRow = -1;
        this.applyFocus(this.headerItems[this.headerCol]);
        return true;
      } else {
        return false;
      }
    } else if (key === 'DOWN') {
      if (r < this.focusableGrid.length - 1) {
        let nr = r + 1;
        while (nr < this.focusableGrid.length) {
          const colIdx = Math.min(c, (this.focusableGrid[nr]?.length || 1) - 1);
          const candidate = this.focusableGrid[nr]?.[colIdx];
          if (candidate && (!currentItem || candidate.id !== currentItem.id)) {
            r = nr;
            c = colIdx;
            break;
          }
          nr++;
        }
        if (nr >= this.focusableGrid.length) {
          return false;
        }
      } else {
        return false;
      }
    } else if (key === 'LEFT') {
      if (c > 0) {
        c--;
        // Snap row to canonical first occurrence if column repeats trailing element
        const target = this.focusableGrid[r]?.[c];
        if (target) {
          while (r > 0 && this.focusableGrid[r - 1]?.[Math.min(c, (this.focusableGrid[r - 1]?.length || 1) - 1)]?.id === target.id) {
            r--;
          }
        }
      } else if (this.headerItems.length > 0) {
        this.savedGridRow = r;
        this.currentRow = -1;
        this.applyFocus(this.headerItems[this.headerCol]);
        return true;
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
    const item = this.focusableGrid[r]?.[c];
    if (item) {
      this.applyFocus(item);
    }
    return true;
  };
}

export const spatialNav = SpatialNav.getInstance();
