/**
 * Navigation sounds of the TV: the ones built into the Samsung system (`tizen.tvaudiocontrol.playSound`),
 * not sound files of the app. Nothing is loaded or decoded, and nothing is played when the TV does not offer
 * the API (older models, browser, tests): the app then stays silent.
 */

export type UiSound = 'select' | 'back' | 'move' | 'cancel' | 'warning';

/** Names of the system beeps (`AudioBeepType` of the Samsung TV product API). */
const BEEP: Record<UiSound, string> = {
  select: 'SELECT',
  back: 'BACK',
  move: 'MOVE',
  cancel: 'CANCEL',
  warning: 'WARNING',
};

const STORAGE_KEY = 'buntu.ui.sounds';
/** Held arrows repeat several times a second: no two sounds closer than this. */
const MIN_GAP_MS = 80;

interface TvAudioControl {
  playSound?: (type: string) => void;
}

export class UiSounds {
  private static instance: UiSounds;
  private enabled = UiSounds.loadEnabled();
  private suppressed = false;
  private lastPlayedAt = 0;

  public static getInstance(): UiSounds {
    if (!UiSounds.instance) UiSounds.instance = new UiSounds();
    return UiSounds.instance;
  }

  private static loadEnabled(): boolean {
    try {
      return localStorage.getItem(STORAGE_KEY) !== 'off';
    } catch {
      return true;
    }
  }

  private api(): TvAudioControl | undefined {
    return (globalThis as any).tizen?.tvaudiocontrol as TvAudioControl | undefined;
  }

  /** `true` when this TV can play its system sounds. */
  public isAvailable(): boolean {
    return typeof this.api()?.playSound === 'function';
  }

  public isEnabled(): boolean {
    return this.enabled;
  }

  public setEnabled(enabled: boolean): void {
    this.enabled = enabled;
    try {
      localStorage.setItem(STORAGE_KEY, enabled ? 'on' : 'off');
    } catch {
      /* storage unavailable: the choice lasts for this visit */
    }
  }

  /** Silent while the video plays full screen: the sound must not cut into the programme's audio. */
  public setSuppressed(suppressed: boolean): void {
    this.suppressed = suppressed;
  }

  public play(sound: UiSound, now: number = Date.now()): void {
    if (!this.enabled || this.suppressed) return;
    const api = this.api();
    if (typeof api?.playSound !== 'function') return;
    const gap = now - this.lastPlayedAt;
    // A clock that went backwards must not silence the sounds.
    if (gap >= 0 && gap < MIN_GAP_MS) return;
    this.lastPlayedAt = now;
    try {
      api.playSound(BEEP[sound]);
    } catch {
      /* a sound is never worth an error on screen */
    }
  }

  /** The sound of a remote key the app handled: OK selects, Back goes back, the arrows move. */
  public onHandledKey(key: string): void {
    if (key === 'ENTER') this.play('select');
    else if (key === 'BACK') this.play('back');
    else if (key === 'UP' || key === 'DOWN' || key === 'LEFT' || key === 'RIGHT') this.play('move');
  }
}
