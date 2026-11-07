import { describe, it, expect, beforeEach, vi } from 'vitest';
import { PlatformService } from '../src/core/platform/PlatformService';
import { spatialNav } from '../src/ui/design/SpatialNav';

describe('PlatformService & SpatialNav Modal Handling', () => {
  beforeEach(() => {
    delete (window as any).tizen;
  });

  it('PlatformService.exitApp calls tizen exit when available', () => {
    const exitSpy = vi.fn();
    (window as any).tizen = {
      application: {
        getCurrentApplication: () => ({
          exit: exitSpy,
        }),
      },
    };

    PlatformService.exitApp();
    expect(exitSpy).toHaveBeenCalledTimes(1);
  });

  it('PlatformService.exitApp falls back to window.close when tizen is not present', () => {
    const closeSpy = vi.fn();
    window.close = closeSpy;

    PlatformService.exitApp();
    expect(closeSpy).toHaveBeenCalledTimes(1);
  });

  it('SpatialNav openModal snapshots state and sets modal focus, closeModal restores it', () => {
    spatialNav.setHeader([
      { id: 'nav-live' },
      { id: 'nav-settings' },
      { id: 'nav-exit' },
    ], 0);

    spatialNav.setGrid([
      [{ id: 'item-1' }, { id: 'item-2' }],
    ]);

    expect(spatialNav.getCurrentFocusId()).toBe('item-1');
    expect(spatialNav.isModalOpen()).toBe(false);

    // Open exit confirmation modal
    spatialNav.openModal([
      [{ id: 'btn-exit-confirm' }, { id: 'btn-exit-cancel' }],
    ], 0, 0);

    expect(spatialNav.isModalOpen()).toBe(true);
    expect(spatialNav.getCurrentFocusId()).toBe('btn-exit-confirm');

    // Close modal
    spatialNav.closeModal();

    expect(spatialNav.isModalOpen()).toBe(false);
    expect(spatialNav.getCurrentFocusId()).toBe('item-1');
  });
});

