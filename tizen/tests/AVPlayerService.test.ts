import { describe, it, expect, beforeEach } from 'vitest';
import { AVPlayerService } from '../src/core/player/AVPlayerService';

describe('AVPlayerService - TV Hardware Player', () => {
  let player: AVPlayerService;

  beforeEach(() => {
    player = AVPlayerService.getInstance();
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
});
