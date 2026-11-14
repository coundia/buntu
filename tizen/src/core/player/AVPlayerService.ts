/**
 * CND IPTV Tizen - Samsung AVPlay Wrapper (PRD 38 § 4.1 & § 4.3)
 *
 * Implements:
 * 1. Hardware-accelerated playback via webapis.avplay (MKV, TS, HLS, MP4, HEVC 4K, HDR10).
 * 2. Audio track and embedded / external subtitle selection with sync offset.
 * 3. Stall watchdog and bandwidth detection.
 * 4. Suspend / restore lifecycle on TV sleep and HDMI source switch.
 * 5. Mock fallback for emulator and browser test environments.
 *
 * Picture: AVPlay renders on a hardware plane BEHIND the web page. Three things are needed to see it:
 * an `<object type="application/avplayer">` in the page, a transparent page where the video is, and
 * `setDisplayRect` set to that area. Without them the sound plays and the screen stays black.
 */

import { BufferHint, bufferPolicy } from './bufferPolicy';
import { StreamSummary, summarizeStream } from './streamInfo';

export type PlayerState = 'NONE' | 'IDLE' | 'READY' | 'PLAYING' | 'PAUSED' | 'BUFFERING';
export type VideoAspectMode = 'fit' | 'stretch';

export function nextAspectMode(mode: VideoAspectMode): VideoAspectMode {
  return mode === 'fit' ? 'stretch' : 'fit';
}

export function aspectModeLabel(mode: VideoAspectMode): string {
  return mode === 'stretch' ? 'Étirer 16:9' : 'Ajuster';
}

export interface TrackInfo {
  index: number;
  type: 'AUDIO' | 'TEXT' | 'VIDEO';
  extra_info: {
    language?: string;
    track_num?: number;
    fourCC?: string;
    channels?: number | string;
  };
}

export interface DisplayArea {
  x: number;
  y: number;
  width: number;
  height: number;
}

/**
 * The largest rectangle of the given picture aspect (width / height) that fits in `area`, centered.
 * Even numbers (hardware windows dislike odd sizes). Unknown aspect: the area itself.
 */
export function fitRect(area: DisplayArea, aspect: number): DisplayArea {
  if (!(aspect > 0) || area.width <= 0 || area.height <= 0) return area;
  let width = area.width;
  let height = Math.round(width / aspect);
  if (height > area.height) {
    height = area.height;
    width = Math.round(height * aspect);
  }
  width -= width % 2;
  height -= height % 2;
  return {
    x: area.x + Math.floor((area.width - width) / 2),
    y: area.y + Math.floor((area.height - height) / 2),
    width: Math.max(2, width),
    height: Math.max(2, height),
  };
}

export interface AVPlayerListener {
  onBufferingStart?: () => void;
  onBufferingProgress?: (percent: number) => void;
  onBufferingComplete?: () => void;
  onCurrentPlayTime?: (ms: number) => void;
  onError?: (error: string) => void;
  onSubtitleChange?: (text: string, durationMs: number) => void;
  onStreamCompleted?: () => void;
  onStallDetected?: () => void;
  onStateChange?: (state: PlayerState) => void;
}

export const FULL_SCREEN: DisplayArea = { x: 0, y: 0, width: 1920, height: 1080 };

/** AVPlay error codes, in words a viewer understands. */
const ERROR_MESSAGES: Record<string, string> = {
  PLAYER_ERROR_CONNECTION_FAILED: 'Connexion au flux impossible : le serveur ne répond pas.',
  PLAYER_ERROR_INVALID_URI: 'Adresse du flux invalide.',
  PLAYER_ERROR_NOT_SUPPORTED_FILE: 'Format vidéo non pris en charge par cette TV.',
  PLAYER_ERROR_NOT_SUPPORTED_FORMAT: 'Format vidéo non pris en charge par cette TV.',
  PLAYER_ERROR_NOT_SUPPORTED_AUDIO_CODEC: 'Codec audio non pris en charge par cette TV.',
  PLAYER_ERROR_NOT_SUPPORTED_VIDEO_CODEC: 'Codec vidéo non pris en charge par cette TV.',
  PLAYER_ERROR_INVALID_OPERATION: 'Lecture interrompue : réessayez.',
  PLAYER_ERROR_SEEK_FAILED: 'Déplacement dans la vidéo impossible.',
  PLAYER_ERROR_GENEREIC: 'Erreur de lecture.',
  PLAYER_ERROR_GENERIC: 'Erreur de lecture.',
  PLAYER_ERROR_NONE: 'Erreur de lecture.',
  PLAYER_ERROR_NO_SUCH_FILE: 'Vidéo introuvable sur le serveur.',
  PLAYER_ERROR_DRM_INFO: 'Contenu protégé non lisible.',
};

export function describePlayerError(raw: unknown): string {
  const text = typeof raw === 'string' ? raw : (raw as any)?.name || (raw as any)?.message || JSON.stringify(raw);
  for (const code of Object.keys(ERROR_MESSAGES)) {
    if (String(text).includes(code)) return ERROR_MESSAGES[code];
  }
  if (/401|403/.test(String(text))) return 'Accès refusé par le fournisseur (identifiants ou connexions simultanées).';
  return 'Lecture impossible. Vérifiez votre connexion ou essayez une autre chaîne.';
}

function parseExtraInfo(raw: unknown): TrackInfo['extra_info'] {
  if (raw && typeof raw === 'object') return raw as TrackInfo['extra_info'];
  if (typeof raw === 'string') {
    try {
      return JSON.parse(raw);
    } catch {
      return {};
    }
  }
  return {};
}

export class AVPlayerService {
  private static instance: AVPlayerService;
  private state: PlayerState = 'NONE';
  private currentUrl = '';
  private isLive = false;
  private durationMs = 0;
  private currentTimeMs = 0;
  private listener: AVPlayerListener = {};
  private stallWatchdogTimer: any = null;
  private bufferHint: BufferHint = {};
  private lastPlayTimeTick = 0;
  private lastTickTimestamp = 0;
  private isSuspended = false;
  private resumeTimeMs = 0;
  private displayArea: DisplayArea = { ...FULL_SCREEN };
  private aspectMode: VideoAspectMode = 'fit';
  /** Increases on every open/stop: callbacks of an older stream are ignored (fast zapping). */
  private openToken = 0;
  private pausedByStop = false;
  private mockTimer: any = null;

  public static getInstance(): AVPlayerService {
    if (!AVPlayerService.instance) {
      AVPlayerService.instance = new AVPlayerService();
    }
    return AVPlayerService.instance;
  }

  private get avplay(): any {
    return (window as any).webapis?.avplay || null;
  }

  private healthListeners = new Set<(state: 'failed' | 'playing') => void>();
  private healthTimeMs = 0;

  /** Independent of the current screen's listener; also observes audio-only live playback. */
  public onStreamHealth(listener: (state: 'failed' | 'playing') => void): () => void {
    this.healthListeners.add(listener);
    return () => { this.healthListeners.delete(listener); };
  }
  private reportFailure(): void {
    for (const listener of this.healthListeners) listener('failed');
  }
  private reportPlayback(timeMs: number): void {
    const advancing = timeMs > this.healthTimeMs;
    this.healthTimeMs = timeMs;
    if (advancing) {
      if (this.state === 'BUFFERING') this.setState('PLAYING');
      for (const listener of this.healthListeners) listener('playing');
    }
  }

  public setListener(listener: AVPlayerListener) {
    this.listener = listener;
  }

  public getState(): PlayerState {
    return this.state;
  }

  public isActive(): boolean {
    return this.state === 'PLAYING' || this.state === 'BUFFERING' || this.state === 'READY' || this.state === 'PAUSED';
  }

  public getDuration(): number {
    return this.durationMs;
  }

  public getCurrentTime(): number {
    return this.currentTimeMs;
  }

  /** What the TV decodes right now (size, codecs, audio), or null before the stream has told. */
  public getStreamSummary(): StreamSummary | null {
    if (!this.avplay) return null;
    try {
      return summarizeStream(this.avplay.getCurrentStreamInfo?.());
    } catch {
      return null;
    }
  }

  public getIsLive(): boolean {
    return this.isLive;
  }

  /** Width / height of the current picture, 0 until the stream tells (fits it inside a small window). */
  private videoAspect = 0;

  private readVideoAspect(): number {
    try {
      const infos = this.avplay.getCurrentStreamInfo?.() as { type?: string; extra_info?: string }[] | undefined;
      for (const info of infos || []) {
        if (info.type !== 'VIDEO' || !info.extra_info) continue;
        const extra = JSON.parse(info.extra_info);
        const w = Number(extra.Width ?? extra.width);
        const h = Number(extra.Height ?? extra.height);
        if (w > 0 && h > 0) return w / h;
      }
    } catch {
      /* stream info not available yet */
    }
    return 0;
  }

  private setState(newState: PlayerState) {
    this.state = newState;
    this.listener.onStateChange?.(newState);
  }

  /** The `<object>` AVPlay needs to show the picture; created if the page does not have it. */
  private videoPlane(): HTMLElement | null {
    if (typeof document === 'undefined') return null;
    let el = document.querySelector('object[type="application/avplayer"]') as HTMLElement | null;
    if (!el) {
      el = document.createElement('object');
      el.id = 'av-player';
      el.setAttribute('type', 'application/avplayer');
      el.setAttribute('aria-hidden', 'true');
      (document.getElementById('avplay-container') || document.body).appendChild(el);
    }
    return el;
  }

  /**
   * Where the video shows, in the page's 1920×1080 coordinates: full screen in the player, a small window
   * in the Live TV preview. Applied at once when a stream is open, and to every next stream.
   */
  public setDisplayArea(area: DisplayArea) {
    this.displayArea = {
      x: Math.max(0, Math.round(area.x)),
      y: Math.max(0, Math.round(area.y)),
      width: Math.max(2, Math.round(area.width)),
      height: Math.max(2, Math.round(area.height)),
    };
    this.applyDisplayArea();
  }

  /** Kept for callers of the first version. */
  public initDisplayRect(x = 0, y = 0, width = 1920, height = 1080) {
    this.setDisplayArea({ x, y, width, height });
  }

  /** Aspect ratio mode for the current session ('fit' preserves aspect, 'stretch' fills 16:9). */
  public getAspectMode(): VideoAspectMode {
    return this.aspectMode;
  }

  public setAspectMode(mode: VideoAspectMode) {
    this.aspectMode = mode;
    this.applyDisplayArea();
  }

  public cycleAspectMode(): VideoAspectMode {
    const next = nextAspectMode(this.aspectMode);
    this.setAspectMode(next);
    return next;
  }

  private applyDisplayArea() {
    const { x, y, width, height } = this.displayArea;
    const isFullScreen = x === 0 && y === 0 && width === 1920 && height === 1080;
    const stretch = this.aspectMode === 'stretch';
    const plane = this.videoPlane();
    if (plane) {
      plane.style.position = 'absolute';
      if (isFullScreen) {
        plane.style.left = '0';
        plane.style.top = '0';
        plane.style.width = '100%';
        plane.style.height = '100%';
      } else {
        plane.style.left = `${x}px`;
        plane.style.top = `${y}px`;
        plane.style.width = `${width}px`;
        plane.style.height = `${height}px`;
      }
    }
    if (!this.avplay) return;
    try {
      const st = this.avplay.getState();
      if (st === 'NONE') return;
      // In a window smaller than the screen (Live TV preview) the letter-box mode shows no picture on
      // the TV (sound only); the "full screen" mode fills the given window. Verified on a Tizen 6.0 TV.
      try {
        this.avplay.setDisplayMethod(
          !isFullScreen || stretch ? 'PLAYER_DISPLAY_MODE_FULL_SCREEN' : 'PLAYER_DISPLAY_MODE_LETTER_BOX'
        );
      } catch {
        /* older firmware: default display mode */
      }
      if (isFullScreen) {
        this.avplay.setDisplayRect(0, 0, 1920, 1080);
      } else {
        if (this.videoAspect === 0 && st !== 'IDLE') this.videoAspect = this.readVideoAspect();
        // The "full screen" mode fills the window it is given, so the picture is fitted by hand
        // unless the viewer explicitly asked to stretch.
        const fit = stretch ? { x, y, width, height } : fitRect({ x, y, width, height }, this.videoAspect);
        const vw = typeof window !== 'undefined' && window.innerWidth > 0 ? window.innerWidth : 1920;
        const vh = typeof window !== 'undefined' && window.innerHeight > 0 ? window.innerHeight : 1080;
        const sx = 1920 / vw;
        const sy = 1080 / vh;
        this.avplay.setDisplayRect(
          Math.round(fit.x * sx),
          Math.round(fit.y * sy),
          Math.max(2, Math.round(fit.width * sx)),
          Math.max(2, Math.round(fit.height * sy))
        );
      }
    } catch (err) {
      console.warn('AVPlay setDisplayRect failed:', err);
    }
  }

  /**
   * Opens stream and sets up buffering and callbacks.
   */
  public async open(url: string, isLive: boolean, hint: BufferHint = {}): Promise<void> {
    this.closeCurrent();
    this.bufferHint = hint;
    const token = ++this.openToken;
    this.currentUrl = url;
    this.videoAspect = 0;
    this.isLive = isLive;
    this.durationMs = 0;
    this.currentTimeMs = 0;
    this.healthTimeMs = 0;

    if (!this.avplay) {
      console.log(`[AVPlayer Mock] Open: ${url} (isLive=${isLive})`);
      this.setState('READY');
      this.startMockPlayback();
      return;
    }

    try {
      this.videoPlane();
      this.avplay.open(url);
      this.setState('IDLE');
      this.applyDisplayArea(); // window + display mode (see applyDisplayArea)

      // Direct: rapid startup (small buffer). Films: larger, and larger still in 4K (see bufferPolicy).
      try {
        const buffer = bufferPolicy(isLive, hint);
        this.avplay.setBufferingParam('PLAYER_BUFFER_FOR_PLAY', 'PLAYER_BUFFER_SIZE_IN_SECOND', buffer.play);
        this.avplay.setBufferingParam('PLAYER_BUFFER_FOR_RESUME', 'PLAYER_BUFFER_SIZE_IN_SECOND', buffer.resume);
      } catch {
        /* not supported for this stream type */
      }

      this.registerCallbacks(token);

      return new Promise<void>((resolve, reject) => {
        this.avplay.prepareAsync(
          () => {
            if (token !== this.openToken) return resolve(); // a newer stream replaced this one
            this.setState('READY');
            this.videoAspect = this.readVideoAspect();
            this.applyDisplayArea();
            try {
              this.durationMs = this.avplay.getDuration();
            } catch {
              this.durationMs = 0;
            }
            resolve();
          },
          (err: any) => {
            if (token !== this.openToken) return resolve();
            const msg = describePlayerError(err);
            this.reportFailure();
            this.listener.onError?.(msg);
            reject(new Error(msg));
          }
        );
      });
    } catch (e: any) {
      const msg = describePlayerError(e);
      this.reportFailure();
      this.listener.onError?.(msg);
      throw new Error(msg);
    }
  }

  private async reopenAndPlay() {
    const expectedToken = this.openToken + 1;
    try {
      await this.open(this.currentUrl, this.isLive, this.bufferHint);
      if (this.openToken === expectedToken) {
        this.play();
      }
    } catch {
      /* error already reported via listener.onError inside open() */
    }
  }

  public play() {
    if (this.pausedByStop && this.currentUrl) {
      this.pausedByStop = false;
      void this.reopenAndPlay();
      return;
    }
    if (!this.avplay) {
      this.setState('PLAYING');
      return;
    }
    try {
      this.avplay.play();
      this.setState('PLAYING');
      // Some firmwares only honor a window smaller than the screen once the stream is running.
      this.applyDisplayArea();
      this.startStallWatchdog();
    } catch (err: any) {
      if (this.isLive && this.currentUrl && this.state === 'PAUSED') {
        void this.reopenAndPlay();
        return;
      }
      this.reportFailure();
      this.listener.onError?.(describePlayerError(err));
    }
  }

  public pause() {
    this.stopStallWatchdog();
    if (!this.avplay) {
      this.setState('PAUSED');
      return;
    }
    let stoppedForLivePause = false;
    try {
      this.avplay.pause();
      if (this.isLive && this.avplay.getState?.() === 'PLAYING') {
        this.avplay.stop();
        stoppedForLivePause = true;
      }
    } catch (err: any) {
      if (this.isLive) {
        try {
          this.avplay.stop();
          stoppedForLivePause = true;
        } catch {
          /* already stopped or none */
        }
      } else {
        console.warn('AVPlay pause failed:', err);
      }
    }
    this.pausedByStop = stoppedForLivePause;
    this.setState('PAUSED');
  }

  public seekTo(ms: number) {
    const clamped = Math.max(0, ms);
    const target = this.durationMs > 0 ? Math.min(clamped, Math.max(0, this.durationMs - 1000)) : clamped;
    this.currentTimeMs = target;
    if (!this.avplay) {
      this.listener.onCurrentPlayTime?.(target);
      return;
    }
    try {
      this.avplay.seekTo(
        target,
        () => {
          this.listener.onCurrentPlayTime?.(target);
        },
        (err: any) => {
          console.warn('AVPlay seekTo failed:', err);
        }
      );
    } catch (err: any) {
      console.warn('AVPlay seek error:', err);
    }
  }

  /** Stops and closes the current stream; pending callbacks of that stream are ignored. */
  public stop() {
    this.openToken++;
    this.closeCurrent();
  }

  private closeCurrent() {
    this.pausedByStop = false;
    this.stopStallWatchdog();
    if (this.mockTimer) {
      clearInterval(this.mockTimer);
      this.mockTimer = null;
    }
    if (!this.avplay) {
      if (this.state !== 'NONE') this.setState('NONE');
      return;
    }
    try {
      const state = this.avplay.getState();
      if (state !== 'NONE' && state !== 'IDLE') {
        this.avplay.stop();
      }
      if (state !== 'NONE') this.avplay.close();
    } catch (err) {
      console.warn('AVPlay stop error:', err);
    } finally {
      if (this.state !== 'NONE') this.setState('NONE');
    }
  }

  /**
   * Tracks and subtitles selection.
   */
  public getTracks(): TrackInfo[] {
    if (!this.avplay) return [];
    try {
      const raw: any[] = this.avplay.getTotalTrackInfo() || [];
      return raw.map((t) => ({ index: Number(t.index), type: t.type, extra_info: parseExtraInfo(t.extra_info) }));
    } catch {
      return [];
    }
  }

  public selectTrack(type: 'AUDIO' | 'TEXT', index: number) {
    if (!this.avplay) return;
    try {
      this.avplay.selectTrack(type, index);
    } catch (err) {
      console.warn('AVPlay selectTrack error:', err);
    }
  }

  /** AVPlay only sends the subtitle text (the app draws it); silent = no more text events. */
  public setSubtitlesEnabled(enabled: boolean) {
    if (!this.avplay) return;
    try {
      this.avplay.setSilentSubtitle(!enabled);
    } catch (err) {
      console.warn('AVPlay setSilentSubtitle error:', err);
    }
  }

  public setExternalSubtitlePath(path: string) {
    if (!this.avplay) return;
    try {
      this.avplay.setExternalSubtitlePath(path);
    } catch (err) {
      console.warn('AVPlay setExternalSubtitlePath error:', err);
    }
  }

  public setSubtitlePosition(offsetMs: number) {
    if (!this.avplay) return;
    try {
      this.avplay.setSubtitlePosition(offsetMs);
    } catch (err) {
      console.warn('AVPlay setSubtitlePosition error:', err);
    }
  }

  /**
   * TV Lifecycle: smart hub / standby suspension and restoration.
   */
  public suspend() {
    if (this.isSuspended || this.state === 'NONE') return;
    this.isSuspended = true;
    this.resumeTimeMs = this.currentTimeMs;
    this.stopStallWatchdog();
    if (this.avplay) {
      try {
        this.avplay.suspend();
      } catch {
        this.closeCurrent();
      }
    }
  }

  public async restore() {
    if (!this.isSuspended) return;
    this.isSuspended = false;
    if (this.avplay) {
      try {
        this.avplay.restore();
        this.applyDisplayArea();
        if (this.resumeTimeMs > 0 && !this.isLive) {
          this.seekTo(this.resumeTimeMs);
        }
        this.play();
      } catch {
        // Reopen fresh if restore fails
        if (this.currentUrl) {
          await this.open(this.currentUrl, this.isLive, this.bufferHint);
          if (this.resumeTimeMs > 0 && !this.isLive) {
            this.seekTo(this.resumeTimeMs);
          }
          this.play();
        }
      }
    }
  }

  private registerCallbacks(token: number) {
    const current = () => token === this.openToken;
    const listenerObj = {
      onbufferingstart: () => {
        if (!current() || this.state === 'PAUSED') return;
        this.setState('BUFFERING');
        this.listener.onBufferingStart?.();
      },
      onbufferingprogress: (percent: number) => {
        if (!current() || this.state === 'PAUSED') return;
        this.listener.onBufferingProgress?.(percent);
      },
      onbufferingcomplete: () => {
        if (!current() || this.state === 'PAUSED') return;
        this.setState('PLAYING');
        this.lastTickTimestamp = Date.now();
        this.listener.onBufferingComplete?.();
      },
      oncurrentplaytime: (timeMs: number) => {
        if (!current() || this.state === 'PAUSED') return;
        this.currentTimeMs = timeMs;
        this.lastPlayTimeTick = timeMs;
        this.lastTickTimestamp = Date.now();
        this.reportPlayback(timeMs);
        this.listener.onCurrentPlayTime?.(timeMs);
      },
      onerror: (eventType: string) => {
        if (!current()) return;
        this.stopStallWatchdog();
        this.reportFailure();
        this.listener.onError?.(describePlayerError(eventType));
      },
      onevent: (eventType: string, eventData: any) => {
        console.log('AVPlay event:', eventType, eventData);
      },
      onsubtitlechange: (duration: number, text: string) => {
        if (!current()) return;
        this.listener.onSubtitleChange?.(text, Number(duration) || 0);
      },
      onstreamcompleted: () => {
        if (!current()) return;
        this.listener.onStreamCompleted?.();
      },
    };

    try {
      this.avplay.setListener(listenerObj);
    } catch (err) {
      console.warn('AVPlay setListener error:', err);
    }
  }

  private startStallWatchdog() {
    this.stopStallWatchdog();
    this.lastTickTimestamp = Date.now();
    this.stallWatchdogTimer = setInterval(() => {
      if (this.state === 'PLAYING' || this.state === 'BUFFERING') {
        const gap = Date.now() - this.lastTickTimestamp;
        if (gap > 8000) {
          // Playhead stalled for 8s
          this.lastTickTimestamp = Date.now();
          this.reportFailure();
          this.listener.onStallDetected?.();
        }
      }
    }, 2000);
  }

  private stopStallWatchdog() {
    if (this.stallWatchdogTimer) {
      clearInterval(this.stallWatchdogTimer);
      this.stallWatchdogTimer = null;
    }
  }

  private startMockPlayback() {
    let current = 0;
    this.mockTimer = setInterval(() => {
      if (this.state === 'PLAYING') {
        current += 1000;
        this.currentTimeMs = current;
        this.durationMs = this.isLive ? 0 : 7200000; // 2 hours
        this.reportPlayback(current);
        this.listener.onCurrentPlayTime?.(current);
      }
    }, 1000);
  }
}
