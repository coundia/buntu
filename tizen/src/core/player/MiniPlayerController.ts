/**
 * Mini player shared by the catalog screens (Live TV, Movies, ...).
 *
 * One experience everywhere:
 *  - the right panel always shows the item under the cursor ("focused"): details, actions;
 *  - moving the cursor never touches the stream: the mini player keeps what it plays ("playing");
 *  - OK on an item plays it in the mini player, OK again on the one playing goes full screen;
 *  - the stream that plays in the mini player continues in full screen (not reopened).
 *
 * The controller holds the state and the stream lifecycle. The screen supplies how an item is shown
 * (see MiniPlayerPanel) and how to go full screen.
 */

import { createSignal, Accessor } from 'solid-js';

export type MiniPlayerStatus = 'idle' | 'connecting' | 'playing' | 'error';

export interface MiniPlayerItem {
  id: number;
}

/** What the controller needs from the engine / the player service (small, easy to fake in tests). */
export interface MiniPlayerEngine<T extends MiniPlayerItem> {
  play(item: T): Promise<void>;
  stopPlayback(): void;
  recordRecent(item: T): void;
}

export interface MiniPlayerOptions<T extends MiniPlayerItem> {
  engine: MiniPlayerEngine<T>;
  player: { setDisplayArea(area: { x: number; y: number; width: number; height: number }): void };
  /** Opens the full-screen player on this item (the screen decides how). */
  onFullscreen: (item: T) => void;
  /** How long a stream may take to start before the item is reported unavailable. */
  startTimeoutMs?: number;
  /** Message shown when the stream does not answer in time. */
  timeoutMessage?: string;
}

export interface MiniPlayerController<T extends MiniPlayerItem> {
  /** The panel is shown (the toolbar button can hide it). */
  visible: Accessor<boolean>;
  /** The item under the cursor: its details are shown below the mini player. */
  focused: Accessor<T | null>;
  /** The item running in the mini player (connecting or playing). */
  playing: Accessor<T | null>;
  status: Accessor<MiniPlayerStatus>;
  error: Accessor<string>;
  /** A stream is running or connecting. */
  active: () => boolean;
  /** The mini player runs the very item that is focused. */
  focusedIsPlaying: () => boolean;
  isPlaying: (id: number) => boolean;

  setViewport: (el: HTMLElement | undefined) => void;
  /** The cursor moved onto an item: update the details only, never the stream. */
  focus: (item: T) => void;
  start: () => Promise<void>;
  stop: () => void;
  /** Stops when the focused item is the one playing, otherwise plays the focused item. */
  toggle: () => void;
  /** OK on an item: play it in the mini player; again on the one playing: full screen. */
  activate: (item: T) => void;
  fullscreen: (item?: T | null) => void;
  /** Click on the mini player's screen: full screen on what it plays. */
  fullscreenFromScreen: () => void;
  toggleVisible: () => void;
  /** Re-aim the video at the panel's preview area (after a layout change). */
  syncRect: () => void;
  /** Leaving the screen: free the stream unless it is handed to the full-screen player. */
  dispose: () => void;
}

const nextFrame = () =>
  new Promise<void>((resolve) => {
    if (typeof requestAnimationFrame === 'function') requestAnimationFrame(() => resolve());
    else setTimeout(resolve, 0);
  });

export function createMiniPlayer<T extends MiniPlayerItem>(opts: MiniPlayerOptions<T>): MiniPlayerController<T> {
  const { engine, player } = opts;
  const timeoutMs = opts.startTimeoutMs ?? 20000;

  const [visible, setVisible] = createSignal(true);
  const [focused, setFocused] = createSignal<T | null>(null);
  const [playing, setPlaying] = createSignal<T | null>(null);
  const [status, setStatus] = createSignal<MiniPlayerStatus>('idle');
  const [error, setError] = createSignal('');

  let viewport: HTMLElement | undefined;
  let handingOver = false;

  const appRoot = () => (typeof document === 'undefined' ? null : document.querySelector('.app-root'));
  const setSeeThrough = (on: boolean) => {
    const root = appRoot();
    if (!root) return;
    if (on) root.classList.add('preview-mode');
    else root.classList.remove('preview-mode');
  };

  const active = () => playing() !== null;
  const focusedIsPlaying = () => playing() !== null && playing()!.id === focused()?.id;
  const isPlaying = (id: number) => playing() !== null && playing()!.id === id;

  const syncRect = () => {
    if (!visible() || !viewport) return;
    const rect = viewport.getBoundingClientRect();
    if (rect.width > 10 && rect.height > 10) {
      player.setDisplayArea({
        x: Math.round(rect.left),
        y: Math.round(rect.top),
        width: Math.round(rect.width),
        height: Math.round(rect.height),
      });
    }
  };

  const focus = (item: T) => {
    const changed = focused()?.id !== item.id;
    setFocused(() => item);
    // Only the "unavailable" message of a previous item is dropped; a running stream is left alone.
    if (changed && status() === 'error') {
      setStatus('idle');
      setError('');
    }
  };

  const start = async () => {
    const item = focused();
    if (!item) return;
    engine.recordRecent(item);
    setPlaying(() => item);
    setError('');
    setStatus('connecting');
    // See-through page first (the poster still covers the area while connecting): the video plane
    // must not be hidden by an opaque page when the stream starts.
    setSeeThrough(true);
    await nextFrame();
    syncRect();
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      await Promise.race([
        engine.play(item),
        new Promise<never>((_, reject) => {
          timer = setTimeout(
            () => reject(new Error(opts.timeoutMessage ?? 'Pas de réponse du serveur')),
            timeoutMs
          );
        }),
      ]);
      if (playing()?.id !== item.id) return; // stopped, or another item took over meanwhile
      setStatus('playing');
      setSeeThrough(true);
    } catch (err) {
      if (playing()?.id !== item.id) return;
      engine.stopPlayback();
      setPlaying(null);
      setStatus('error');
      setError((err as Error)?.message || 'Connexion impossible');
      setSeeThrough(false);
    } finally {
      if (timer) clearTimeout(timer);
    }
  };

  const stop = () => {
    if (!active()) return;
    engine.stopPlayback();
    setPlaying(null);
    setStatus('idle');
    setError('');
    setSeeThrough(false);
  };

  const toggle = () => {
    if (focusedIsPlaying()) stop();
    else void start();
  };

  const fullscreen = (item: T | null = focused()) => {
    if (!item) return;
    engine.recordRecent(item);
    handingOver = true;
    opts.onFullscreen(item);
  };

  const fullscreenFromScreen = () => fullscreen(playing() ?? focused());

  const activate = (item: T) => {
    if (!visible() || isPlaying(item.id)) {
      fullscreen(item);
      return;
    }
    focus(item);
    void start();
  };

  const toggleVisible = () => {
    const next = !visible();
    if (!next) stop();
    setVisible(next);
  };

  const dispose = () => {
    setSeeThrough(false);
    if (!handingOver) engine.stopPlayback();
  };

  return {
    visible,
    focused,
    playing,
    status,
    error,
    active,
    focusedIsPlaying,
    isPlaying,
    setViewport: (el) => {
      viewport = el;
    },
    focus,
    start,
    stop,
    toggle,
    activate,
    fullscreen,
    fullscreenFromScreen,
    toggleVisible,
    syncRect,
    dispose,
  };
}
