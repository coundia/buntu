import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { render } from 'solid-js/web';
import { PlayerView } from '../src/features/player/PlayerView';
import { AVPlayerService } from '../src/core/player/AVPlayerService';
import { Database, ItemRecord } from '../src/core/storage/Database';
import { spatialNav } from '../src/ui/design/SpatialNav';
import { RemoteKeyHandler } from '../src/core/input/RemoteKeyHandler';

describe('Issue #2: Samsung TV Live TV Error Handling & Zapping', () => {
  let container: HTMLDivElement;
  let dispose: () => void = () => {};
  let player: AVPlayerService;
  let db: Database;
  let itemStore: Map<number, ItemRecord>;

  const mockChannel: ItemRecord = {
    id: 101,
    source_id: 1,
    stable_hash: 'live-test-101',
    kind: 'live',
    name: 'TF1 HD',
    name_clean: 'TF1',
    chno: 1,
    group_title: 'Généraliste',
    stream_url: 'http://fake-stream.test/live/101.ts',
    is_favorite: 0,
    is_broken: 0,
    playback_position_ms: 0,
    duration_ms: 0,
  };

  beforeEach(() => {
    container = document.createElement('div');
    document.body.appendChild(container);
    RemoteKeyHandler.getInstance().init();
    spatialNav.init();
    player = AVPlayerService.getInstance();
    db = Database.getInstance();

    itemStore = new Map<number, ItemRecord>();
    itemStore.set(mockChannel.id, { ...mockChannel });

    (db as any).db = { objectStoreNames: { contains: () => true } };
    (vi.spyOn(db as any, 'getById') as any).mockImplementation(async (_store: string, id: number) => {
      return itemStore.get(id) ? { ...itemStore.get(id)! } : null;
    });
    (vi.spyOn(db as any, 'put') as any).mockImplementation(async (_store: string, item: ItemRecord) => {
      itemStore.set(item.id, { ...item });
      return item.id;
    });
  });

  afterEach(() => {
    dispose();
    container.remove();
    RemoteKeyHandler.getInstance().destroy();
    player.stop();
    vi.restoreAllMocks();
    vi.useRealTimers();
  });

  it('marks a channel as broken (HS) and heals it via Database.setBroken', async () => {
    // 1. Mark broken
    const isBroken = await db.setBroken(mockChannel.id, true);
    expect(isBroken).toBe(true);
    expect(itemStore.get(mockChannel.id)?.is_broken).toBe(1);

    // 2. Heal broken
    const isHealed = await db.setBroken(mockChannel.id, false);
    expect(isHealed).toBe(false);
    expect(itemStore.get(mockChannel.id)?.is_broken).toBe(0);
  });

  it('automatically retries 3 times on stream error, displays attempt indicator, and on 3rd failure sets focus on btn-player-retry', async () => {
    vi.useFakeTimers();

    // Mock player open to fail when executed
    vi.spyOn(player, 'open').mockImplementation(async () => {
      throw new Error('Connexion au flux impossible');
    });

    const onExit = vi.fn();
    const onNextChannel = vi.fn();
    const onPrevChannel = vi.fn();

    const channelItem = { ...mockChannel };
    dispose = render(
      () =>
        PlayerView({
          item: channelItem,
          onExit,
          onNextChannel,
          onPrevChannel,
        }),
      container
    );

    // Initial state: Attempt 1/3 indicator
    expect(container.textContent).toContain('Connexion… (tentative 1/3)');

    // 1st failure: triggers retry 2 after 1200ms delay
    (player as any).listener.onError?.('Connexion au flux impossible');
    expect(container.textContent).toContain('tentative 2/3');

    // Advance timers: executeRetry triggers and fails, causing retry 3
    await vi.advanceTimersByTimeAsync(1300);
    expect(container.textContent).toContain('tentative 3/3');

    // Advance timers: 3rd attempt executeRetry triggers and fails -> forfeit!
    await vi.advanceTimersByTimeAsync(1300);

    // Panel error is now displayed
    expect(container.textContent).toContain('Problème de lecture');
    expect(container.textContent).toContain('Cette chaîne a été marquée temporairement hors service (HS)');

    // Broken flag set on item and in DB
    expect(channelItem.is_broken).toBe(1);
    await vi.waitFor(() => expect(itemStore.get(channelItem.id)?.is_broken).toBe(1));

    // Focus must be placed explicitly on btn-player-retry without losing focus
    await vi.advanceTimersByTimeAsync(60);
    expect(spatialNav.getCurrentFocusId()).toBe('btn-player-retry');
    const retryBtn = container.querySelector('#btn-player-retry');
    expect(retryBtn).not.toBeNull();
    expect(retryBtn?.classList.contains('focused')).toBe(true);

    // Next channel button should be available
    const nextBtn = container.querySelector('#btn-player-next');
    expect(nextBtn).not.toBeNull();

    // Zapping with remote keys UP / DOWN should work immediately even in error state
    window.dispatchEvent(new KeyboardEvent('keydown', { keyCode: 38 })); // UP
    expect(onNextChannel).toHaveBeenCalledTimes(1);

    window.dispatchEvent(new KeyboardEvent('keydown', { keyCode: 40 })); // DOWN
    expect(onPrevChannel).toHaveBeenCalledTimes(1);

    window.dispatchEvent(new KeyboardEvent('keydown', { keyCode: 427 })); // CHANNEL_UP
    expect(onNextChannel).toHaveBeenCalledTimes(2);

    window.dispatchEvent(new KeyboardEvent('keydown', { keyCode: 428 })); // CHANNEL_DOWN
    expect(onPrevChannel).toHaveBeenCalledTimes(2);

    vi.useRealTimers();
  });

  it('heals broken channel status when stream buffers successfully', async () => {
    const brokenChannel = { ...mockChannel, is_broken: 1 };
    itemStore.set(brokenChannel.id, { ...brokenChannel });

    const onExit = vi.fn();

    dispose = render(
      () =>
        PlayerView({
          item: brokenChannel,
          onExit,
        }),
      container
    );

    // Simulate successful buffering
    (player as any).listener.onBufferingComplete?.();

    // Channel should now be healed locally and in DB
    expect(brokenChannel.is_broken).toBe(0);
    await vi.waitFor(() => expect(itemStore.get(brokenChannel.id)?.is_broken).toBe(0));
  });

  it('hides the connection overlay when playback advances without buffering-complete', async () => {
    vi.useFakeTimers();
    const open = vi.spyOn(player, 'open').mockResolvedValue();
    dispose = render(() => PlayerView({ item: { ...mockChannel }, onExit: vi.fn() }), container);
    expect(container.textContent).toContain('Connexion… (tentative 1/3)');
    // No buffering-complete notification: the picture has already started.
    (player as any).listener.onCurrentPlayTime(1000);
    expect(container.querySelector('[aria-label="Chargement du flux vidéo"]')).toBeNull();
    await vi.advanceTimersByTimeAsync(14000);
    expect(open).not.toHaveBeenCalled();
    expect(container.textContent).not.toContain('Problème de lecture');
    vi.useRealTimers();
  });

  it('cancels a pending reconnect when the current stream starts playing again', async () => {
    vi.useFakeTimers();
    const open = vi.spyOn(player, 'open').mockResolvedValue();
    dispose = render(() => PlayerView({ item: { ...mockChannel }, onExit: vi.fn() }), container);
    (player as any).listener.onError('Erreur transitoire');
    expect(container.textContent).toContain('tentative 2/3');
    (player as any).listener.onCurrentPlayTime(1000);
    expect(container.querySelector('[aria-label="Chargement du flux vidéo"]')).toBeNull();
    await vi.advanceTimersByTimeAsync(14000);
    expect(open).not.toHaveBeenCalled();
    vi.useRealTimers();
  });

  it('keeps buffering visible for repeated timestamps and hides it on real progress', () => {
    dispose = render(() => PlayerView({ item: { ...mockChannel }, onExit: vi.fn() }), container);
    (player as any).listener.onCurrentPlayTime(1000);
    (player as any).listener.onBufferingStart();
    (player as any).listener.onCurrentPlayTime(1000);
    expect(container.querySelector('[aria-label="Chargement du flux vidéo"]')).not.toBeNull();
    (player as any).listener.onCurrentPlayTime(2000);
    expect(container.querySelector('[aria-label="Chargement du flux vidéo"]')).toBeNull();
  });

  it('still retries a live connection stuck at timestamp zero', async () => {
    vi.useFakeTimers();
    vi.spyOn(player, 'open').mockResolvedValue();
    dispose = render(() => PlayerView({ item: { ...mockChannel }, onExit: vi.fn() }), container);
    (player as any).listener.onCurrentPlayTime(0);
    await vi.advanceTimersByTimeAsync(12000);
    expect(container.textContent).toContain('tentative 2/3');
    vi.useRealTimers();
  });


  it('removes the visible hors-service tag as soon as playback time advances', async () => {
    const channel = { ...mockChannel, is_broken: 1 };
    itemStore.set(channel.id, { ...channel });
    dispose = render(() => PlayerView({ item: channel, onExit: vi.fn() }), container);
    expect(container.textContent).toContain('HORS SERVICE');
    (player as any).listener.onCurrentPlayTime(1000);
    expect(container.textContent).not.toContain('HORS SERVICE');
    await vi.waitFor(() => expect(itemStore.get(channel.id)?.is_broken).toBe(0));
  });

  it('applies failed and recovered status writes in order', async () => {
    const events: boolean[] = [];
    const unsubscribe = db.onBrokenChange((_id, broken) => events.push(broken));
    try {
      await Promise.all([db.setBroken(mockChannel.id, true), db.setBroken(mockChannel.id, false)]);
      expect(events).toEqual([true, false]);
      expect(itemStore.get(mockChannel.id)?.is_broken).toBe(0);
    } finally { unsubscribe(); }
  });

});
