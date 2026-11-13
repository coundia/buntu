import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { spatialNav } from '../src/ui/design/SpatialNav';

let frames: FrameRequestCallback[] = [];
const flushFrame = () => {
  const pending = frames;
  frames = [];
  pending.forEach((callback) => callback(0));
};
const press = (keyCode: number) => window.dispatchEvent(new KeyboardEvent('keydown', { keyCode, bubbles: true }));

beforeEach(() => {
  frames = [];
  vi.spyOn(window, 'requestAnimationFrame').mockImplementation((callback) => {
    frames.push(callback);
    return frames.length;
  });
  spatialNav.setHeader([]);
  document.body.innerHTML = '<button id="first"></button><button id="second"></button><button id="third"></button>';
});
afterEach(() => {
  spatialNav.setGrid([]);
  flushFrame();
  document.body.innerHTML = '';
  vi.restoreAllMocks();
});

describe('Remote focus responsiveness', () => {
  it('handles every key immediately but scrolls and focuses only the final card once per frame', () => {
    const selected = vi.fn();
    const scroll = vi.fn();
    const third = document.getElementById('third')!;
    third.scrollIntoView = scroll;
    const focus = vi.spyOn(third, 'focus');
    spatialNav.setGrid([[{ id: 'first' }, { id: 'second' }, { id: 'third', onSelect: selected }]]);
    flushFrame();
    const raf = vi.mocked(window.requestAnimationFrame);
    raf.mockClear();

    press(39); press(39); press(37); press(39);
    expect(spatialNav.getCurrentFocusId()).toBe('third');
    press(13);
    expect(selected).toHaveBeenCalledTimes(1); // OK does not wait for the next paint.
    expect(raf).toHaveBeenCalledTimes(1);
    expect(scroll).not.toHaveBeenCalled();
    flushFrame();
    expect(scroll).toHaveBeenCalledTimes(1);
    expect(document.activeElement).toBe(third);
    expect(focus).toHaveBeenCalledTimes(1);

    press(37);
    expect(raf).toHaveBeenCalledTimes(2); // The following frame is still scheduled normally.
    flushFrame();
    expect(document.activeElement?.id).toBe('second');
  });

  it('uses the new screen focus when OK replaces the screen before the pending frame', () => {
    spatialNav.setGrid([[{ id: 'first', onSelect: () => {
      document.body.innerHTML = '<button id="new-screen"></button>';
      spatialNav.setGrid([[{ id: 'new-screen' }]]);
    } }]]);
    press(13);
    expect(frames).toHaveLength(1);
    flushFrame();
    expect(document.activeElement?.id).toBe('new-screen');
  });

  it('does not focus an old element if the screen clears its grid before the pending frame', () => {
    spatialNav.setGrid([[{ id: 'first' }]]);
    spatialNav.setGrid([]);
    expect(() => flushFrame()).not.toThrow();
    expect(document.activeElement).toBe(document.body);
  });
});
