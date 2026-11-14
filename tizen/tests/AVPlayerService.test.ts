import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { aspectModeLabel, AVPlayerService, FULL_SCREEN } from '../src/core/player/AVPlayerService';

describe('AVPlayerService - TV Hardware Player', () => {
  let player: AVPlayerService;

  beforeEach(() => {
    player = AVPlayerService.getInstance();
    player.setAspectMode('fit');
    player.setDisplayArea(FULL_SCREEN);
  });

  afterEach(() => {
    delete (window as any).webapis;
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
});

