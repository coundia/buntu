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

export type PlayerState = 'NONE' | 'IDLE' | 'READY' | 'PLAYING' | 'PAUSED' | 'BUFFERING';

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
  private lastPlayTimeTick = 0;
  private lastTickTimestamp = 0;
  private isSuspended = false;
  private resumeTimeMs = 0;
  private displayArea: DisplayArea = { ...FULL_SCREEN };
  /** Increases on every open/stop: callbacks of an older stream are ignored (fast zapping). */
  private openToken = 0;
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

  public getIsLive(): boolean {
    return this.isLive;
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

  private applyDisplayArea() {
    const { x, y, width, height } = this.displayArea;
    const isFullScreen = x === 0 && y === 0 && width === 1920 && height === 1080;
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
      if (isFullScreen) {
        this.avplay.setDisplayRect(0, 0, 1920, 1080);
      } else {
        const vw = typeof window !== 'undefined' && window.innerWidth > 0 ? window.innerWidth : 1920;
        const vh = typeof window !== 'undefined' && window.innerHeight > 0 ? window.innerHeight : 1080;
        const sx = 1920 / vw;
        const sy = 1080 / vh;
        this.avplay.setDisplayRect(
          Math.round(x * sx),
          Math.round(y * sy),
          Math.max(2, Math.round(width * sx)),
          Math.max(2, Math.round(height * sy))
        );
      }
    } catch (err) {
      console.warn('AVPlay setDisplayRect failed:', err);
    }
  }

  /**
   * Opens stream and sets up buffering and callbacks.
   */
  public async open(url: string, isLive: boolean): Promise<void> {
    this.closeCurrent();
    const token = ++this.openToken;
    this.currentUrl = url;
    this.isLive = isLive;
    this.durationMs = 0;
    this.currentTimeMs = 0;

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
      try {
        this.avplay.setDisplayMethod('PLAYER_DISPLAY_MODE_LETTER_BOX');
      } catch {
        /* older firmware: default display mode */
      }
      this.applyDisplayArea();

      // Direct: rapid startup (small initial buffer). Movies: longer buffer for stability.
      try {
        if (isLive) {
          this.avplay.setBufferingParam('PLAYER_BUFFER_FOR_PLAY', 'PLAYER_BUFFER_SIZE_IN_SECOND', 2);
          this.avplay.setBufferingParam('PLAYER_BUFFER_FOR_RESUME', 'PLAYER_BUFFER_SIZE_IN_SECOND', 3);
        } else {
          this.avplay.setBufferingParam('PLAYER_BUFFER_FOR_PLAY', 'PLAYER_BUFFER_SIZE_IN_SECOND', 4);
          this.avplay.setBufferingParam('PLAYER_BUFFER_FOR_RESUME', 'PLAYER_BUFFER_SIZE_IN_SECOND', 6);
        }
      } catch {
        /* not supported for this stream type */
      }

      this.registerCallbacks(token);

      return new Promise<void>((resolve, reject) => {
        this.avplay.prepareAsync(
          () => {
            if (token !== this.openToken) return resolve(); // a newer stream replaced this one
            this.setState('READY');
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
            this.listener.onError?.(msg);
            reject(new Error(msg));
          }
        );
      });
    } catch (e: any) {
      const msg = describePlayerError(e);
      this.listener.onError?.(msg);
      throw new Error(msg);
    }
  }

  public play() {
    if (!this.avplay) {
      this.setState('PLAYING');
      return;
    }
    try {
      this.avplay.play();
      this.setState('PLAYING');
      this.startStallWatchdog();
    } catch (err: any) {
      this.listener.onError?.(describePlayerError(err));
    }
  }

  public pause() {
    if (this.isLive) return; // Live TV is not paused
    if (!this.avplay) {
      this.setState('PAUSED');
      return;
    }
    try {
      this.avplay.pause();
      this.setState('PAUSED');
      this.stopStallWatchdog();
    } catch (err: any) {
      console.warn('AVPlay pause failed:', err);
    }
  }

  public seekTo(ms: number) {
    if (this.isLive) return;
    const target = this.durationMs > 0 ? Math.min(ms, Math.max(0, this.durationMs - 1000)) : ms;
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
          await this.open(this.currentUrl, this.isLive);
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
        if (!current()) return;
        this.setState('BUFFERING');
        this.listener.onBufferingStart?.();
      },
      onbufferingprogress: (percent: number) => {
        if (!current()) return;
        this.listener.onBufferingProgress?.(percent);
      },
      onbufferingcomplete: () => {
        if (!current()) return;
        this.setState('PLAYING');
        this.lastTickTimestamp = Date.now();
        this.listener.onBufferingComplete?.();
      },
      oncurrentplaytime: (timeMs: number) => {
        if (!current()) return;
        this.currentTimeMs = timeMs;
        this.lastPlayTimeTick = timeMs;
        this.lastTickTimestamp = Date.now();
        this.listener.onCurrentPlayTime?.(timeMs);
      },
      onerror: (eventType: string) => {
        if (!current()) return;
        this.stopStallWatchdog();
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
      if (this.state === 'PLAYING') {
        const gap = Date.now() - this.lastTickTimestamp;
        if (gap > 8000) {
          // Playhead stalled for 8s
          this.lastTickTimestamp = Date.now();
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
        this.listener.onCurrentPlayTime?.(current);
      }
    }, 1000);
  }
}
