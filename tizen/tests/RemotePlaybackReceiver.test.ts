import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { RemotePlaybackCoordinator } from '../src/core/remote/RemotePlayback';
import { LocalSyncService } from '../src/core/sync/LocalSyncService';
import { Database, ItemRecord } from '../src/core/storage/Database';
import { HouseholdStore } from '../src/core/sync/HouseholdStore';
import { AVPlayerService } from '../src/core/player/AVPlayerService';
import { CndEngine } from '../src/core/engine/CndEngine';

describe('PRD-45 Samsung TV Playback Receiver & Single Stream Rule', () => {
  let coordinator: RemotePlaybackCoordinator;
  let localSync: LocalSyncService;
  let sentMessages: any[] = [];

  const mockItem: ItemRecord = {
    id: 101,
    source_id: 1,
    stable_hash: 'movie_test_hash',
    kind: 'movie',
    name: 'Inception',
    name_clean: 'Inception',
    stream_url: 'http://test.server/movie/user/pass/101.mp4',
    is_favorite: 0,
    playback_position_ms: 0,
    duration_ms: 7200000,
  };

  beforeEach(() => {
    sentMessages = [];
    localSync = LocalSyncService.getInstance();
    vi.spyOn(localSync, 'sendMessage').mockImplementation(async (msg: any) => {
      sentMessages.push(msg);
    });

    const store = HouseholdStore.getInstance();
    vi.spyOn(store, 'getHouseholdKey').mockResolvedValue('0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef');
    vi.spyOn(store, 'getHouseholdInfo').mockReturnValue({
      household_id: 'test_house',
      household_name: 'Test Foyer',
      created_at: 1000,
    });
    vi.spyOn(store, 'getLocalDeviceId').mockReturnValue('tv_samsung_001');
    vi.spyOn(store, 'getLocalDeviceName').mockReturnValue('Salon TV');

    const db = Database.getInstance();
    vi.spyOn(db, 'getItemByStableHash').mockResolvedValue(mockItem);
    vi.spyOn(db, 'getSources').mockResolvedValue([
      {
        id: 1,
        uuid: 'src_1',
        name: 'Account 1',
        source_type: 'xtream',
        server: 'http://test.server',
        username: 'user',
        password: 'pass',
        item_count: 100,
      },
    ]);

    const engine = CndEngine.getInstance();
    vi.spyOn(engine, 'isItemAllowedForActiveProfile').mockResolvedValue(true);
    vi.spyOn(engine, 'stopPlayback').mockImplementation(() => {});

    coordinator = RemotePlaybackCoordinator.getInstance();
    (coordinator as any).reservation = null;
    (coordinator as any).lastRequestAt.clear();
    coordinator.accessPolicy = 'open';
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it('accepts play_request directly without prompt when TV is playing under open policy (PRD-45 § 3.3)', async () => {
    // Simulate active playback on TV
    vi.spyOn(coordinator as any, 'isPlayingHere').mockReturnValue(true);
    let promptCalled = false;
    coordinator.onPrompt = (_title, _sender, cb) => {
      promptCalled = true;
      cb(true);
    };

    const reqMsg = {
      type: 'play_request',
      request_id: 'req_123',
      content_key: 'movie_test_hash',
      target_device_id: 'tv_samsung_001',
      title: 'Inception',
    };

    await (coordinator as any).handleIncomingMessage(reqMsg, 'sender_iphone');

    // With open policy, no prompt is displayed even if TV is playing
    expect(promptCalled).toBe(false);

    // play_ready should be sent
    const readyMsg = sentMessages.find((m) => m.type === 'play_ready');
    expect(readyMsg).toBeDefined();
    expect(readyMsg.request_id).toBe('req_123');
  });

  it('stops current playback and releases stream on play_go (PRD-45 § 3.3 & § 3.4)', async () => {
    vi.spyOn(coordinator as any, 'isPlayingHere').mockReturnValue(true);
    const stopHereSpy = vi.spyOn(coordinator as any, 'stopHere');
    let playedItem: any = null;
    let playedPos = -1;
    coordinator.onPlayItem = async (item, pos) => {
      playedItem = item;
      playedPos = pos;
    };

    // First, play_request to reserve
    await (coordinator as any).handleIncomingMessage(
      {
        type: 'play_request',
        request_id: 'req_456',
        content_key: 'movie_test_hash',
        source_key: 'xtream_test_key',
        target_device_id: 'tv_samsung_001',
      },
      'sender_mac'
    );

    // Next, play_go
    await (coordinator as any).handleIncomingMessage(
      {
        type: 'play_go',
        request_id: 'req_456',
        position_ms: 45000,
      },
      'sender_mac'
    );

    // stopHere must have been called to interrupt active stream
    expect(stopHereSpy).toHaveBeenCalled();

    // release_stream must have been broadcast
    const releaseMsg = sentMessages.find((m) => m.type === 'release_stream');
    expect(releaseMsg).toBeDefined();

    // App playback must have started with requested position
    expect(playedItem).toBeDefined();
    expect(playedItem?.stable_hash).toBe('movie_test_hash');
    expect(playedPos).toBe(45000);
  });
});
