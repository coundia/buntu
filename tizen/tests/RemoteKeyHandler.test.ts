import { describe, it, expect } from 'vitest';
import { RemoteKeyHandler } from '../src/core/input/RemoteKeyHandler';

describe('RemoteKeyHandler - Tizen Key Normalization', () => {
  const handler = RemoteKeyHandler.getInstance();

  it('normalizes D-Pad arrow keys and Enter', () => {
    expect(handler.normalizeKey(new KeyboardEvent('keydown', { keyCode: 38, key: 'ArrowUp' }))).toBe('UP');
    expect(handler.normalizeKey(new KeyboardEvent('keydown', { keyCode: 40, key: 'ArrowDown' }))).toBe('DOWN');
    expect(handler.normalizeKey(new KeyboardEvent('keydown', { keyCode: 37, key: 'ArrowLeft' }))).toBe('LEFT');
    expect(handler.normalizeKey(new KeyboardEvent('keydown', { keyCode: 39, key: 'ArrowRight' }))).toBe('RIGHT');
    expect(handler.normalizeKey(new KeyboardEvent('keydown', { keyCode: 13, key: 'Enter' }))).toBe('ENTER');
  });

  it('normalizes Tizen hardware Return key (10009)', () => {
    expect(handler.normalizeKey(new KeyboardEvent('keydown', { keyCode: 10009 }))).toBe('BACK');
    expect(handler.normalizeKey(new KeyboardEvent('keydown', { keyCode: 27, key: 'Escape' }))).toBe('BACK');
  });

  it('normalizes Media keys (Play, Pause, FastForward, Rewind)', () => {
    expect(handler.normalizeKey(new KeyboardEvent('keydown', { keyCode: 415, key: 'MediaPlay' }))).toBe('PLAY');
    expect(handler.normalizeKey(new KeyboardEvent('keydown', { keyCode: 19, key: 'MediaPause' }))).toBe('PAUSE');
    expect(handler.normalizeKey(new KeyboardEvent('keydown', { keyCode: 417, key: 'MediaFastForward' }))).toBe('FAST_FORWARD');
    expect(handler.normalizeKey(new KeyboardEvent('keydown', { keyCode: 412, key: 'MediaRewind' }))).toBe('REWIND');
  });

  it('normalizes Tizen Color keys for shortcuts', () => {
    expect(handler.normalizeKey(new KeyboardEvent('keydown', { keyCode: 403, key: 'ColorF0Red' }))).toBe('RED');
    expect(handler.normalizeKey(new KeyboardEvent('keydown', { keyCode: 404, key: 'ColorF1Green' }))).toBe('GREEN');
    expect(handler.normalizeKey(new KeyboardEvent('keydown', { keyCode: 405, key: 'ColorF2Yellow' }))).toBe('YELLOW');
    expect(handler.normalizeKey(new KeyboardEvent('keydown', { keyCode: 406, key: 'ColorF3Blue' }))).toBe('BLUE');
  });

  it('normalizes Numeric buttons 0-9', () => {
    for (let i = 0; i <= 9; i++) {
      expect(handler.normalizeKey(new KeyboardEvent('keydown', { keyCode: 48 + i }))).toBe(`NUM_${i}`);
    }
  });
});

