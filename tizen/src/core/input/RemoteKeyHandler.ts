/**
 * CND IPTV Tizen - Remote Control Key Handler (PRD 38 § 5.2)
 *
 * Implements:
 * 1. Samsung TV Remote special keys registration via tizen.tvinputdevice.registerKey.
 * 2. Unified key event normalization for D-Pad, OK, Back, Ch+/Ch-, Media, Numbers, and Color buttons.
 * 3. Spatial focus event dispatching and Tizen IME (virtual keyboard) key handling.
 */

import { UiSounds } from '../audio/UiSounds';

export type RemoteKey =
  | 'UP'
  | 'DOWN'
  | 'LEFT'
  | 'RIGHT'
  | 'ENTER'
  | 'BACK'
  | 'PLAY'
  | 'PAUSE'
  | 'PLAY_PAUSE'
  | 'STOP'
  | 'FAST_FORWARD'
  | 'REWIND'
  | 'CHANNEL_UP'
  | 'CHANNEL_DOWN'
  | 'RED'
  | 'GREEN'
  | 'YELLOW'
  | 'BLUE'
  | 'INFO'
  | 'NUM_0'
  | 'NUM_1'
  | 'NUM_2'
  | 'NUM_3'
  | 'NUM_4'
  | 'NUM_5'
  | 'NUM_6'
  | 'NUM_7'
  | 'NUM_8'
  | 'NUM_9';

export type KeyHandler = (key: RemoteKey, rawEvent: KeyboardEvent) => boolean | void;

export class RemoteKeyHandler {
  private static instance: RemoteKeyHandler;
  private handlers: KeyHandler[] = [];
  private isInitialized = false;

  public static getInstance(): RemoteKeyHandler {
    if (!RemoteKeyHandler.instance) {
      RemoteKeyHandler.instance = new RemoteKeyHandler();
    }
    return RemoteKeyHandler.instance;
  }

  public init() {
    if (this.isInitialized) return;
    this.isInitialized = true;

    try {
      window.focus();
    } catch {
      // Ignore in test environments
    }
    this.registerTizenHardwareKeys();
    window.addEventListener('keydown', this.handleKeyDown, true);
  }

  public destroy() {
    window.removeEventListener('keydown', this.handleKeyDown, true);
    this.isInitialized = false;
  }

  public addListener(handler: KeyHandler): () => void {
    if (!this.handlers.includes(handler)) {
      this.handlers.push(handler);
    }
    return () => {
      this.handlers = this.handlers.filter((h) => h !== handler);
    };
  }

  private registerTizenHardwareKeys() {
    const tvInputDevice = (window as any).tizen?.tvinputdevice;
    if (!tvInputDevice) return;

    const keysToRegister = [
      'MediaPlay',
      'MediaPause',
      'MediaPlayPause',
      'MediaStop',
      'MediaFastForward',
      'MediaRewind',
      'ChannelUp',
      'ChannelDown',
      'ColorF0Red',
      'ColorF1Green',
      'ColorF2Yellow',
      'ColorF3Blue',
      'Info',
      '0', '1', '2', '3', '4', '5', '6', '7', '8', '9',
    ];

    for (const key of keysToRegister) {
      try {
        tvInputDevice.registerKey(key);
      } catch (err) {
        console.warn(`Failed to register Tizen key: ${key}`, err);
      }
    }
  }

  private handleKeyDown = (event: KeyboardEvent) => {
    const active = document.activeElement;
    const isInputFocused = active && (active.tagName === 'INPUT' || active.tagName === 'TEXTAREA');

    // Samsung Tizen virtual keyboard Done (65376) / Cancel (65385)
    if (event.keyCode === 65376 || event.keyCode === 65385) {
      if (isInputFocused && typeof (active as HTMLElement).blur === 'function') {
        (active as HTMLElement).blur();
      }
      event.preventDefault();
      // Let IME Done (65376) reach the focused input's onKeyDown handler so it can submit.
      if (event.keyCode === 65385 || !isInputFocused) {
        event.stopPropagation();
      }
      return;
    }

    const key = this.normalizeKey(event);
    if (!key) return;

    // When an input field has active DOM focus:
    // - BACK exits the input field (closes virtual keyboard) without leaving the screen
    // - UP / DOWN blurs the input field and moves spatial focus to the adjacent row
    // - ENTER / LEFT / RIGHT / numbers are handled by the focused input while editing
    if (isInputFocused) {
      if (key === 'BACK') {
        (active as HTMLElement).blur();
        event.preventDefault();
        event.stopPropagation();
        return;
      }
      if (key === 'ENTER' || key === 'LEFT' || key === 'RIGHT' || key.startsWith('NUM_')) {
        return;
      }
      if (key === 'UP' || key === 'DOWN') {
        (active as HTMLElement).blur();
      }
    }

    // Dispatch from top/latest handler to first
    for (let i = this.handlers.length - 1; i >= 0; i--) {
      const consumed = this.handlers[i](key, event);
      if (consumed) {
        UiSounds.getInstance().onHandledKey(key);
        event.preventDefault();
        event.stopPropagation();
        break;
      }
    }
  };

  public normalizeKey(event: KeyboardEvent): RemoteKey | null {
    const code = event.keyCode || event.which;
    const keyName = event.key;

    // D-Pad & Action
    if (code === 38 || keyName === 'ArrowUp') return 'UP';
    if (code === 40 || keyName === 'ArrowDown') return 'DOWN';
    if (code === 37 || keyName === 'ArrowLeft') return 'LEFT';
    if (code === 39 || keyName === 'ArrowRight') return 'RIGHT';
    if (code === 13 || keyName === 'Enter') return 'ENTER';

    // Back / Return
    if (code === 10009 || code === 27 || keyName === 'Escape' || keyName === 'GoBack' || keyName === 'XF86Back') {
      return 'BACK';
    }

    // Media
    if (code === 415 || keyName === 'MediaPlay') return 'PLAY';
    if (code === 19 || keyName === 'MediaPause') return 'PAUSE';
    if (code === 10252 || keyName === 'MediaPlayPause') return 'PLAY_PAUSE';
    if (code === 413 || keyName === 'MediaStop') return 'STOP';
    if (code === 417 || keyName === 'MediaFastForward') return 'FAST_FORWARD';
    if (code === 412 || keyName === 'MediaRewind') return 'REWIND';

    // Channels
    if (code === 427 || keyName === 'ChannelUp') return 'CHANNEL_UP';
    if (code === 428 || keyName === 'ChannelDown') return 'ChannelDown' as any === 'ChannelDown' ? 'CHANNEL_DOWN' : 'CHANNEL_DOWN';

    // Color buttons
    if (code === 403 || keyName === 'ColorF0Red') return 'RED';
    if (code === 404 || keyName === 'ColorF1Green') return 'GREEN';
    if (code === 405 || keyName === 'ColorF2Yellow') return 'YELLOW';
    if (code === 406 || keyName === 'ColorF3Blue') return 'BLUE';

    // Info
    if (code === 457 || keyName === 'Info') return 'INFO';

    // Numbers
    if (code >= 48 && code <= 57) {
      return `NUM_${code - 48}` as RemoteKey;
    }

    return null;
  }
}
