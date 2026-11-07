/**
 * CND IPTV Tizen - Platform Service
 *
 * Provides TV platform lifecycle management, including clean application termination
 * on Samsung Smart TV (Tizen) and browser/mock fallbacks.
 */

export class PlatformService {
  /**
   * Closes and terminates the current Tizen Web application.
   * On Samsung Tizen Smart TV: invokes `tizen.application.getCurrentApplication().exit()`.
   * On fallback / PC browser: invokes `window.close()`.
   */
  public static exitApp(): void {
    console.log('[PlatformService] Exiting application...');

    try {
      const tizenApp = (window as any).tizen?.application?.getCurrentApplication?.();
      if (tizenApp && typeof tizenApp.exit === 'function') {
        console.log('[PlatformService] tizen.application.getCurrentApplication().exit() called successfully.');
        tizenApp.exit();
        return;
      }
    } catch (err) {
      console.warn('[PlatformService] Error while calling tizen.application exit:', err);
    }

    try {
      console.log('[PlatformService] Fallback to window.close()');
      window.close();
    } catch (err) {
      console.warn('[PlatformService] Error while calling window.close:', err);
    }
  }
}

