import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { aspectModeLabel, AVPlayerService, FULL_SCREEN } from '../src/core/player/AVPlayerService';
import { setLiveBufferSeconds } from '../src/core/player/bufferPolicy';

describe('AVPlayerService - TV Hardware Player', () => {
  let player: AVPlayerService;

  beforeEach(() => {
    player = AVPlayerService.getInstance();
    player.setAspectMode('fit');
    player.setDisplayArea(FULL_SCREEN);
  });

  afterEach(() => {
    vi.unstubAllGlobals();
    player.setListener({});
    player.stop();
    delete (window as any).webapis;
    vi.useRealTimers();
    vi.restoreAllMocks();
  });

  it('starts in NONE state and transitions through lifecycle', async () => {
    expect(player.getState()).toBe('NONE');

    await player.open('http://example.com/test.mkv', false);
    expect(player.getState()).toBe('READY');

    player.play();
    expect(player.getState()).toBe('PLAYING');

    player.pause();
    expect(player.getState()).toBe('PAUSED');

    player.stop();
    expect(player.getState()).toBe('NONE');
  });

  it('exposes an active stream bandwidth estimate when the firmware provides it', async () => {
    const getStreamingProperty = vi.fn()
      .mockReturnValueOnce('4500000')
      .mockReturnValueOnce('')
      .mockImplementationOnce(() => { throw new Error('not supported'); });
    expect(player.getBandwidthEstimateBps()).toBeNull();
    await player.open('https://example.com/sample.m3u8', false);
    (window as any).webapis = { avplay: { getStreamingProperty } };

    expect(player.getBandwidthEstimateBps()).toBe(4_500_000);
    expect(player.getBandwidthEstimateBps()).toBeNull();
    expect(player.getBandwidthEstimateBps()).toBeNull();
    expect(getStreamingProperty).toHaveBeenCalledWith('CURRENT_BANDWIDTH');

    delete (window as any).webapis;
    player.stop();
    expect(player.getBandwidthEstimateBps()).toBeNull();
  });

  it('handles TV sleep suspend and restore without crash', async () => {
    await player.open('http://example.com/test.mkv', false);
    player.play();

    player.suspend();
    await player.restore();
    expect(player.getState()).toBe('PLAYING');

    player.stop();
  });

  it('cycles aspect ratio mode and switches AVPlay display method', () => {
    const setDisplayMethod = vi.fn();
    const setDisplayRect = vi.fn();
    (window as any).webapis = {
      avplay: {
        getState: () => 'PLAYING',
        setDisplayMethod,
        setDisplayRect,
        getCurrentStreamInfo: () => [],
      },
    };

    expect(player.getAspectMode()).toBe('fit');
    expect(aspectModeLabel('fit')).toBe('Ajuster');

    const cycled = player.cycleAspectMode();
    expect(cycled).toBe('stretch');
    expect(aspectModeLabel(cycled)).toBe('Étirer 16:9');
    expect(setDisplayMethod).toHaveBeenLastCalledWith('PLAYER_DISPLAY_MODE_FULL_SCREEN');
    expect(setDisplayRect).toHaveBeenLastCalledWith(0, 0, 1920, 1080);

    player.setAspectMode('fit');
    expect(player.getAspectMode()).toBe('fit');
    expect(setDisplayMethod).toHaveBeenLastCalledWith('PLAYER_DISPLAY_MODE_LETTER_BOX');
  });

  it('pauses a live stream directly and ignores late playback callbacks until resumed', async () => {
    let avState = 'NONE';
    let avListener: any = null;
    const pauseFn = vi.fn(() => {
      avState = 'PAUSED';
    });
    const stopFn = vi.fn(() => {
      avState = 'IDLE';
    });
    const playFn = vi.fn(() => {
      avState = 'PLAYING';
    });
    const openFn = vi.fn(() => {
      avState = 'IDLE';
    });
    (window as any).webapis = {
      avplay: {
        open: openFn,
        close: vi.fn(() => { avState = 'NONE'; }),
        stop: stopFn,
        play: playFn,
        pause: pauseFn,
        prepareAsync: vi.fn((ok: () => void) => {
          avState = 'READY';
          ok();
        }),
        setListener: vi.fn((l: any) => { avListener = l; }),
        setDisplayMethod: vi.fn(),
        setDisplayRect: vi.fn(),
        setBufferingParam: vi.fn(),
        getDuration: vi.fn(() => 0),
        getState: vi.fn(() => avState),
        getCurrentStreamInfo: vi.fn(() => []),
      },
    };

    await player.open('http://example.com/live.ts', true);
    player.play();
    expect(player.getState()).toBe('PLAYING');

    player.pause();
    expect(pauseFn).toHaveBeenCalledTimes(1);
    expect(stopFn).not.toHaveBeenCalled();
    expect(player.getState()).toBe('PAUSED');

    // Late ticks from hardware AVPlay must not flip the state back to PLAYING.
    avListener?.oncurrentplaytime(2500);
    avListener?.onbufferingcomplete();
    expect(player.getState()).toBe('PAUSED');

    // Fallback: if live hardware pause fails, stop the socket cleanly and reopen on play().
    playFn();
    player.play();
    pauseFn.mockImplementationOnce(() => {
      throw new Error('PLAYER_ERROR_INVALID_OPERATION');
    });
    player.pause();
    expect(stopFn).toHaveBeenCalledTimes(1);
    expect(player.getState()).toBe('PAUSED');

    player.play();
    for (let i = 0; i < 10; i++) await Promise.resolve();
    expect(openFn).toHaveBeenCalledTimes(2);
    expect(player.getState()).toBe('PLAYING');

    player.stop();
  });

  const setupLiveMock = (tracks = [
    { index: 0, type: 'VIDEO', extra_info: '{}' },
    { index: 1, type: 'AUDIO', extra_info: '{"language":"fra"}' },
    { index: 2, type: 'AUDIO', extra_info: '{"language":"eng"}' },
  ]) => {
    let avState = 'NONE';
    let avListener: any = null;
    const openFn = vi.fn(() => { avState = 'IDLE'; });
    const playFn = vi.fn(() => { avState = 'PLAYING'; });
    const stopFn = vi.fn(() => { avState = 'IDLE'; });
    const closeFn = vi.fn(() => { avState = 'NONE'; });
    const selectTrackFn = vi.fn();
    const setBufferingParam = vi.fn();
    const setTimeoutForBuffering = vi.fn();
    (window as any).webapis = {
      avplay: {
        open: openFn,
        close: closeFn,
        stop: stopFn,
        play: playFn,
        pause: vi.fn(() => { avState = 'PAUSED'; }),
        prepareAsync: vi.fn((ok: () => void) => {
          avState = 'READY';
          ok();
        }),
        setListener: vi.fn((l: any) => { avListener = l; }),
        setDisplayMethod: vi.fn(),
        setDisplayRect: vi.fn(),
        setBufferingParam,
        setTimeoutForBuffering,
        getDuration: vi.fn(() => 0),
        getState: vi.fn(() => avState),
        getCurrentStreamInfo: vi.fn(() => []),
        getTotalTrackInfo: vi.fn(() => tracks),
        selectTrack: selectTrackFn,
        setSilentSubtitle: vi.fn(),
        seekTo: vi.fn(),
      },
    };
    return {
      openFn,
      playFn,
      stopFn,
      selectTrackFn,
      setBufferingParam,
      setTimeoutForBuffering,
      getListener: () => avListener,
    };
  };

  it.each([false, true])('changes VOD subtitles in place (paused: %s)', async (paused) => {
    const { openFn, playFn, stopFn, selectTrackFn, getListener } = setupLiveMock();
    const avplay = (window as any).webapis.avplay;
    await player.open('https://example.com/movie.mkv', false);
    player.play();
    getListener().oncurrentplaytime(75_000);
    if (paused) player.pause();

    player.setSubtitlesEnabled(true);
    player.selectTrack('TEXT', 3);
    player.setSubtitlesEnabled(false);

    expect(selectTrackFn).toHaveBeenLastCalledWith('TEXT', 3);
    expect(avplay.setSilentSubtitle.mock.calls).toEqual([[false], [true]]);
    expect(player.getCurrentTime()).toBe(75_000);
    expect(player.getState()).toBe(paused ? 'PAUSED' : 'PLAYING');
    expect(openFn).toHaveBeenCalledTimes(1);
    expect(playFn).toHaveBeenCalledTimes(1);
    expect(stopFn).not.toHaveBeenCalled();
    expect(avplay.seekTo).not.toHaveBeenCalled();
  });

  it.each([25, 30] as const)('applies a %i-second live buffer without reopening during refill', async (seconds) => {
    vi.useFakeTimers();
    const { openFn, getListener, setBufferingParam, setTimeoutForBuffering } = setupLiveMock();
    const onStallDetected = vi.fn();
    player.setListener({ onStallDetected });
    const storage = new Map<string, string>();
    vi.stubGlobal('localStorage', {
      getItem: (key: string) => storage.get(key) ?? null,
      setItem: (key: string, value: string) => storage.set(key, value),
    });
    setLiveBufferSeconds(seconds);

    await player.open('http://example.com/live.ts', true);
    expect(setBufferingParam).toHaveBeenCalledWith('PLAYER_BUFFER_FOR_PLAY', 'PLAYER_BUFFER_SIZE_IN_SECOND', seconds);
    expect(setBufferingParam).toHaveBeenCalledWith('PLAYER_BUFFER_FOR_RESUME', 'PLAYER_BUFFER_SIZE_IN_SECOND', seconds);
    expect(setTimeoutForBuffering).toHaveBeenCalledWith(seconds + 10);

    player.play();
    getListener().oncurrentplaytime(1000);
    getListener().onbufferingstart();
    await vi.advanceTimersByTimeAsync(seconds * 1000);
    expect(onStallDetected).not.toHaveBeenCalled();
    getListener().onbufferingcomplete();
    getListener().oncurrentplaytime(2000);
    expect(openFn).toHaveBeenCalledTimes(1);
  });

  it.each([false, true])('restores the VOD position after an offline/online transition (paused: %s)', async (paused) => {
    const { openFn, playFn, stopFn, getListener } = setupLiveMock();
    const avplay = (window as any).webapis.avplay;
    const onError = vi.fn();
    player.setListener({ onError });
    let seekDone: (() => void) | undefined;
    avplay.seekTo.mockImplementation((_position: number, done: () => void) => { seekDone = done; });

    await player.open('http://example.com/vod/recover.mkv', false);
    player.play();
    getListener().oncurrentplaytime(65_000);
    if (paused) player.pause();

    window.dispatchEvent(new Event('offline'));
    getListener().onerror('PLAYER_ERROR_CONNECTION_FAILED');
    expect(onError).not.toHaveBeenCalled();
    window.dispatchEvent(new Event('online'));

    if (paused) {
      expect(player.getState()).toBe('PAUSED');
      expect(openFn).toHaveBeenCalledTimes(1);
      player.play();
    }
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();
    expect(openFn).toHaveBeenCalledTimes(2);
    expect(avplay.close.mock.invocationCallOrder[0]).toBeGreaterThan(stopFn.mock.invocationCallOrder[0]);
    expect(openFn.mock.invocationCallOrder[1]).toBeGreaterThan(avplay.close.mock.invocationCallOrder[0]);
    expect(avplay.seekTo).toHaveBeenCalledWith(65_000, expect.any(Function), expect.any(Function));
    expect(playFn).toHaveBeenCalledTimes(1);
    seekDone?.();
    expect(playFn).toHaveBeenCalledTimes(2);
  });

  it('reopens live stream and restores audio track after a prolonged network rebuffer or offline/online transition', async () => {
    vi.useFakeTimers();
    const { openFn, playFn, selectTrackFn, getListener } = setupLiveMock();

    await player.open('http://example.com/live/rebuffer.ts', true);
    player.play();
    getListener().oncurrentplaytime(1000);
    expect(openFn).toHaveBeenCalledTimes(1);
    expect(selectTrackFn).toHaveBeenLastCalledWith('AUDIO', 1);

    // Mid-stream live network drop (> 1500ms buffering) followed by buffering complete: must reopen cleanly.
    selectTrackFn.mockClear();
    getListener().onbufferingstart();
    await vi.advanceTimersByTimeAsync(2000);
    getListener().onbufferingcomplete();
    for (let i = 0; i < 10; i++) await Promise.resolve();

    expect(openFn).toHaveBeenCalledTimes(2);
    expect(playFn).toHaveBeenCalledTimes(2);
    expect(selectTrackFn).toHaveBeenCalledWith('AUDIO', 1);

    // Explicit browser/TV offline -> online transition on live stream: must reopen cleanly as well.
    selectTrackFn.mockClear();
    getListener().oncurrentplaytime(2000);
    window.dispatchEvent(new Event('offline'));
    await vi.advanceTimersByTimeAsync(1000);
    window.dispatchEvent(new Event('online'));
    for (let i = 0; i < 10; i++) await Promise.resolve();

    expect(openFn).toHaveBeenCalledTimes(3);
    expect(playFn).toHaveBeenCalledTimes(3);
    expect(selectTrackFn).toHaveBeenCalledWith('AUDIO', 1);
  });

  it('reopens live stream when playhead freezes >= 3000ms without buffering callbacks and preserves user audio track', async () => {
    vi.useFakeTimers();
    const { openFn, playFn, selectTrackFn, getListener } = setupLiveMock();

    await player.open('http://example.com/live/tickgap.ts', true);
    player.play();
    player.selectTrack('AUDIO', 2);
    getListener().oncurrentplaytime(1000);

    // Network drops silently for 4s while AVPlay keeps socket open, then video packets return.
    selectTrackFn.mockClear();
    await vi.advanceTimersByTimeAsync(4000);
    getListener().oncurrentplaytime(5000);
    for (let i = 0; i < 10; i++) await Promise.resolve();

    expect(openFn).toHaveBeenCalledTimes(2);
    expect(playFn).toHaveBeenCalledTimes(2);
    expect(selectTrackFn).toHaveBeenCalledWith('AUDIO', 2);
  });
});

