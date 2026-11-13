import { describe, it, expect, vi } from 'vitest';
import { createRoot } from 'solid-js';
import { createMiniPlayer } from '../src/core/player/MiniPlayerController';
import { panelFocusItems, panelItemForRow, panelItemsForRow } from '../src/ui/design/miniPlayerFocus';
import { fitRect } from '../src/core/player/AVPlayerService';

type Item = { id: number; name: string };
const a: Item = { id: 1, name: 'A' };
const b: Item = { id: 2, name: 'B' };

function setup(playImpl?: (item: Item) => Promise<void>, startTimeoutMs = 50, focusPanelOnActivate?: () => void) {
  const engine = {
    play: vi.fn(playImpl ?? (async () => {})),
    stopPlayback: vi.fn(),
    recordRecent: vi.fn(),
  };
  const player = { setDisplayArea: vi.fn() };
  const onFullscreen = vi.fn();
  let dispose = () => {};
  const ctl = createRoot((d) => {
    dispose = d;
    return createMiniPlayer<Item>({ engine, player, onFullscreen, startTimeoutMs, focusPanelOnActivate });
  });
  return { ctl, engine, player, onFullscreen, dispose };
}

describe('mini player controller', () => {
  it('first OK plays in the mini player, second OK on it goes full screen', async () => {
    const { ctl, engine, onFullscreen } = setup();
    ctl.activate(a);
    await vi.waitFor(() => expect(ctl.status()).toBe('playing'));
    expect(engine.play).toHaveBeenCalledTimes(1);
    expect(onFullscreen).not.toHaveBeenCalled();
    ctl.activate(a);
    expect(onFullscreen).toHaveBeenCalledWith(a);
    expect(engine.play).toHaveBeenCalledTimes(1); // the stream is handed over, not reopened by the mini player
  });

  it('moving the focus never stops or changes what plays', async () => {
    const { ctl, engine } = setup();
    ctl.activate(a);
    await vi.waitFor(() => expect(ctl.status()).toBe('playing'));
    ctl.focus(b);
    expect(ctl.focused()?.id).toBe(2);
    expect(ctl.playing()?.id).toBe(1);
    expect(engine.stopPlayback).not.toHaveBeenCalled();
    expect(ctl.focusedIsPlaying()).toBe(false);
  });

  it('OK on another item switches the stream to it', async () => {
    const { ctl, engine } = setup();
    ctl.activate(a);
    await vi.waitFor(() => expect(ctl.status()).toBe('playing'));
    ctl.activate(b);
    await vi.waitFor(() => expect(ctl.playing()?.id).toBe(2));
    await vi.waitFor(() => expect(ctl.status()).toBe('playing'));
    expect(engine.play).toHaveBeenCalledTimes(2);
  });

  it('toggle stops the focused playing item, and plays a focused item that is not playing', async () => {
    const { ctl, engine } = setup();
    ctl.focus(a);
    ctl.toggle();
    await vi.waitFor(() => expect(ctl.status()).toBe('playing'));
    ctl.toggle();
    expect(ctl.status()).toBe('idle');
    expect(engine.stopPlayback).toHaveBeenCalled();
    expect(ctl.playing()).toBeNull();
  });

  it('reports an unavailable item instead of staying on "connecting"', async () => {
    const { ctl, engine } = setup(async () => {
      throw new Error('Lecture impossible');
    });
    ctl.activate(a);
    await vi.waitFor(() => expect(ctl.status()).toBe('error'));
    expect(ctl.error()).toBe('Lecture impossible');
    expect(ctl.active()).toBe(false);
    expect(engine.stopPlayback).toHaveBeenCalled();
    ctl.focus(b); // the message belongs to the item that failed
    expect(ctl.status()).toBe('idle');
  });

  it('calls onItemFailed callback when playback errors', async () => {
    const onItemFailed = vi.fn();
    const engine = {
      play: vi.fn(async () => {
        throw new Error('Flux hors service');
      }),
      stopPlayback: vi.fn(),
      recordRecent: vi.fn(),
    };
    const player = { setDisplayArea: vi.fn() };
    const onFullscreen = vi.fn();
    const ctl = createRoot(() =>
      createMiniPlayer<Item>({ engine, player, onFullscreen, startTimeoutMs: 50, onItemFailed })
    );
    ctl.activate(a);
    await vi.waitFor(() => expect(ctl.status()).toBe('error'));
    expect(onItemFailed).toHaveBeenCalledWith(a, 'Flux hors service');
  });

  it('gives up when the stream does not answer in time', async () => {
    const { ctl } = setup(() => new Promise<void>(() => {}), 30);
    ctl.activate(a);
    expect(ctl.status()).toBe('connecting');
    await vi.waitFor(() => expect(ctl.status()).toBe('error'));
    expect(ctl.error()).toContain('Pas de réponse');
  });

  it('full screen from the screen uses what plays, not what is focused', async () => {
    const { ctl, onFullscreen } = setup();
    ctl.activate(a);
    await vi.waitFor(() => expect(ctl.status()).toBe('playing'));
    ctl.focus(b);
    ctl.fullscreenFromScreen();
    expect(onFullscreen).toHaveBeenCalledWith(a);
  });

  it('playItem resumes an item without changing the focused one', async () => {
    const { ctl, engine } = setup();
    ctl.focus(b);
    await ctl.playItem(a);
    expect(ctl.playing()?.id).toBe(1);
    expect(ctl.focused()?.id).toBe(2); // the details still follow the cursor
    expect(ctl.status()).toBe('playing');
    expect(engine.play).toHaveBeenCalledWith(a);
  });

  it('with the panel hidden, OK goes straight to full screen', () => {
    const { ctl, onFullscreen, engine } = setup();
    ctl.toggleVisible();
    ctl.activate(a);
    expect(onFullscreen).toHaveBeenCalledWith(a);
    expect(engine.play).not.toHaveBeenCalled();
  });

  it('leaving the screen frees the stream, except when handed to the full-screen player', async () => {
    const left = setup();
    left.ctl.activate(a);
    await vi.waitFor(() => expect(left.ctl.status()).toBe('playing'));
    left.ctl.dispose();
    expect(left.engine.stopPlayback).toHaveBeenCalled();

    const handed = setup();
    handed.ctl.activate(a);
    await vi.waitFor(() => expect(handed.ctl.status()).toBe('playing'));
    handed.ctl.activate(a); // -> full screen
    handed.ctl.dispose();
    expect(handed.engine.stopPlayback).not.toHaveBeenCalled();
  });
});

describe('mini player panel navigation', () => {
  it('lists the buttons in vertical order and repeats the last one below the panel rows', () => {
    const { ctl } = setup();
    const extra = [{ id: 'mv-insp-details', label: 'Fiche', onSelect: () => {} }];
    const items = panelFocusItems(ctl, 'mv-insp', () => {}, extra);
    expect(items.map((i) => i.id)).toEqual([
      'mv-insp-screen',
      'mv-insp-play',
      'mv-insp-fav',
      'mv-insp-full',
      'mv-insp-details',
    ]);
    expect(panelItemForRow(items, 0)?.id).toBe('mv-insp-screen');
    expect(panelItemForRow(items, 2)?.id).toBe('mv-insp-fav');
    expect(panelItemForRow(items, 40)?.id).toBe('mv-insp-details');
    expect(panelItemForRow([], 3)).toBeUndefined();
  });
});

describe('fitRect', () => {
  const area = { x: 1402, y: 78, width: 518, height: 292 };

  it('keeps a 16:9 picture in a 16:9 window', () => {
    const r = fitRect(area, 16 / 9);
    expect(r.width).toBeLessThanOrEqual(518);
    expect(r.height).toBeLessThanOrEqual(292);
    expect(Math.abs(r.width / r.height - 16 / 9)).toBeLessThan(0.03);
  });

  it('puts a wide film in the middle with bars above and below', () => {
    const r = fitRect(area, 2.39);
    expect(r.width).toBe(518);
    expect(r.height).toBeLessThan(292);
    expect(r.y).toBeGreaterThan(78);
    expect(r.y + r.height).toBeLessThan(78 + 292);
  });

  it('does not stretch a 4:3 channel', () => {
    const r = fitRect(area, 4 / 3);
    expect(r.height).toBe(292);
    expect(r.width).toBeLessThan(518);
    expect(r.x).toBeGreaterThan(1402);
  });

  it('uses the whole area when the aspect is unknown', () => {
    expect(fitRect(area, 0)).toEqual(area);
  });

  it('only returns even sizes', () => {
    const r = fitRect({ x: 0, y: 0, width: 517, height: 291 }, 1.85);
    expect(r.width % 2).toBe(0);
    expect(r.height % 2).toBe(0);
  });

  describe('films: OK moves the cursor to the panel instead of going full screen', () => {
    it('plays in the mini player, focuses the panel, and a second OK on the same film still does not go full screen', async () => {
      const focusPanel = vi.fn();
      const { ctl, engine, onFullscreen } = setup(undefined, 50, focusPanel);
      ctl.activate(a);
      expect(focusPanel).toHaveBeenCalledTimes(1);
      await vi.waitFor(() => expect(ctl.status()).toBe('playing'));
      ctl.activate(a);
      expect(focusPanel).toHaveBeenCalledTimes(2);
      expect(onFullscreen).not.toHaveBeenCalled();
      expect(engine.play).toHaveBeenCalledTimes(1);
    });

    it('full screen stays available from the panel buttons', async () => {
      const { ctl, onFullscreen } = setup(undefined, 50, vi.fn());
      ctl.activate(a);
      await vi.waitFor(() => expect(ctl.status()).toBe('playing'));
      ctl.fullscreen();
      expect(onFullscreen).toHaveBeenCalledWith(a);
    });

    it('without a panel (hidden) OK still opens full screen', () => {
      const { ctl, onFullscreen } = setup(undefined, 50, vi.fn());
      ctl.toggleVisible();
      ctl.activate(a);
      expect(onFullscreen).toHaveBeenCalledWith(a);
    });

    it('live TV (no option) keeps « OK again goes full screen »', async () => {
      const { ctl, onFullscreen } = setup();
      ctl.activate(a);
      await vi.waitFor(() => expect(ctl.status()).toBe('playing'));
      ctl.activate(a);
      expect(onFullscreen).toHaveBeenCalledWith(a);
    });
  });

  it('panelItemsForRow: the screen on row 0, then the whole row of actions on every other row', () => {
    const { ctl } = setup();
    const items = panelFocusItems(ctl, 'mv-insp', () => {}, [{ id: 'mv-insp-details', label: 'Fiche', onSelect: () => {} }]);
    expect(panelItemsForRow(items, 0).map((i) => i.id)).toEqual(['mv-insp-screen']);
    expect(panelItemsForRow(items, 1).map((i) => i.id)).toEqual(['mv-insp-play', 'mv-insp-fav', 'mv-insp-full', 'mv-insp-details']);
    expect(panelItemsForRow(items, 30).map((i) => i.id)).toEqual(['mv-insp-play', 'mv-insp-fav', 'mv-insp-full', 'mv-insp-details']);
    expect(panelItemsForRow([], 1)).toEqual([]);
  });
});
