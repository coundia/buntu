import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { RemotePlaybackCoordinator } from '../src/core/remote/RemotePlayback';
import { LocalSyncService } from '../src/core/sync/LocalSyncService';
import { Database, ItemRecord } from '../src/core/storage/Database';
import { HouseholdStore } from '../src/core/sync/HouseholdStore';
import { AVPlayerService } from '../src/core/player/AVPlayerService';
import { CndEngine } from '../src/core/engine/CndEngine';
import { WorkerBridge } from '../src/worker/worker-bridge';

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

  it('finds a channel sent by the iPhone by its stream id, without the slow scan', async () => {
    const db = Database.getInstance();
    const liveItem: ItemRecord = { ...mockItem, id: 202, stable_hash: 'live_1234', kind: 'live', name: 'TF1' };
    vi.spyOn(db, 'getItemByStableHashIndexed').mockImplementation(async (hash: string) =>
      hash === 'live_1234' ? liveItem : null
    );
    const slowScan = vi.spyOn(db, 'getItemByStableHash');

    await (coordinator as any).handleIncomingMessage(
      {
        type: 'play_request',
        request_id: 'req_iphone_live',
        // The iPhone's own hash: blake3(<account uuid>:xtream_live:1234), unknown to the TV.
        content_key: 'ef246dddb1a33d3150ed631c00000000000000000000000000000000000000aa',
        provider_ref: '1234',
        item_kind: 'live',
        target_device_id: 'tv_samsung_001',
        title: 'TF1',
      },
      'sender_iphone'
    );

    expect(sentMessages.find((m) => m.type === 'play_ready')?.request_id).toBe('req_iphone_live');
    expect(slowScan).not.toHaveBeenCalled();
  });

  /** The Rust calls of the worker (WebAssembly is not loaded under Node). */
  function mockWorker(rebuilt: string[] = []) {
    vi.spyOn(WorkerBridge.getInstance(), 'post').mockImplementation(async (type: string, payload: any) => {
      if (type === 'COMPUTE_SOURCE_KEY') return (`key_${payload.serverOrUrl}_${payload.username}`) as any;
      if (type === 'REMOTE_RECONSTRUCT_XTREAM_URL') {
        const ext = payload.kind === 'live' ? 'ts' : payload.containerExt || 'mp4';
        const path = payload.kind === 'episode' ? 'series' : payload.kind;
        const url = `${payload.server}/${path}/${payload.username}/${payload.password}/${payload.providerRef}.${ext}`;
        rebuilt.push(url);
        return url as any;
      }
      throw new Error(`unexpected ${type}`);
    });
  }

  it('refuses at once (unknown_content) when the account named by the origin is not on the TV', async () => {
    mockWorker();
    const db = Database.getInstance();
    vi.spyOn(db, 'getItemByStableHashIndexed').mockResolvedValue(null);
    const slowScan = vi.spyOn(db, 'getItemByStableHash');

    await (coordinator as any).handleIncomingMessage(
      {
        type: 'play_request',
        request_id: 'req_missing',
        content_key: 'ef246dddb1a33d3150ed631c00000000000000000000000000000000000000bb',
        source_key: 'key_of_an_account_the_tv_does_not_have',
        provider_ref: '999999',
        item_kind: 'movie',
        target_device_id: 'tv_samsung_001',
      },
      'sender_iphone_2'
    );

    expect(sentMessages.find((m) => m.type === 'play_refused')?.reason).toBe('unknown_content');
    expect(slowScan).not.toHaveBeenCalled();
  });

  it('finds a channel saved as "<source id>_live_<id>" in the account named by the origin', async () => {
    mockWorker();
    const db = Database.getInstance();
    const liveItem: ItemRecord = { ...mockItem, id: 303, stable_hash: '1_live_1234', kind: 'live', name: 'TF1' };
    const looked: string[] = [];
    vi.spyOn(db, 'getItemByStableHashIndexed').mockImplementation(async (hash: string) => {
      looked.push(hash);
      return hash === '1_live_1234' ? liveItem : null;
    });
    let played: ItemRecord | null = null;
    coordinator.onPlayItem = async (item) => {
      played = item;
    };

    await (coordinator as any).handleIncomingMessage(
      {
        type: 'play_request',
        request_id: 'req_android_live',
        content_key: 'ef246dddb1a33d3150ed631c00000000000000000000000000000000000000cc',
        source_key: 'key_http://test.server_user',
        provider_ref: '1234',
        item_kind: 'live',
        target_device_id: 'tv_samsung_001',
      },
      'sender_android'
    );
    expect(sentMessages.find((m) => m.type === 'play_ready')?.request_id).toBe('req_android_live');
    expect(looked).toContain('1_live_1234');

    await (coordinator as any).handleIncomingMessage({ type: 'play_go', request_id: 'req_android_live', position_ms: 0 }, 'sender_android');
    expect(played!.id).toBe(303);
  });

  it('rebuilds the address of an episode the TV does not store, with the sent extension', async () => {
    const rebuilt: string[] = [];
    mockWorker(rebuilt);
    const db = Database.getInstance();
    vi.spyOn(db, 'getItemByStableHashIndexed').mockResolvedValue(null);
    let played: ItemRecord | null = null;
    coordinator.onPlayItem = async (item) => {
      played = item;
    };

    await (coordinator as any).handleIncomingMessage(
      {
        type: 'play_request',
        request_id: 'req_mac_episode',
        content_key: 'ef246dddb1a33d3150ed631c00000000000000000000000000000000000000dd',
        source_key: 'key_http://test.server_user',
        provider_ref: '777',
        container_ext: 'mkv',
        item_kind: 'episode',
        title: 'Série - S01E02',
        target_device_id: 'tv_samsung_001',
      },
      'sender_mac'
    );
    expect(sentMessages.find((m) => m.type === 'play_ready')?.request_id).toBe('req_mac_episode');

    await (coordinator as any).handleIncomingMessage({ type: 'play_go', request_id: 'req_mac_episode', position_ms: 120000 }, 'sender_mac');
    expect(rebuilt).toEqual(['http://test.server/series/user/pass/777.mkv']);
    expect(played!.stream_url).toBe('http://test.server/series/user/pass/777.mkv');
    expect(played!.kind).toBe('episode');
    expect(played!.name).toBe('Série - S01E02');
    expect(played!.id).toBeLessThan(0);
  });

  it('never plays a rebuilt item (unknown category) on a Kids profile', async () => {
    mockWorker();
    const db = Database.getInstance();
    vi.spyOn(db, 'getItemByStableHashIndexed').mockResolvedValue(null);
    vi.spyOn(CndEngine.getInstance(), 'getActiveProfile').mockReturnValue({ isKids: true } as any);

    await (coordinator as any).handleIncomingMessage(
      {
        type: 'play_request',
        request_id: 'req_kids',
        content_key: 'ef246dddb1a33d3150ed631c00000000000000000000000000000000000000ee',
        source_key: 'key_http://test.server_user',
        provider_ref: '888',
        item_kind: 'movie',
        target_device_id: 'tv_samsung_001',
      },
      'sender_kid_tablet'
    );
    expect(sentMessages.find((m) => m.type === 'play_refused')?.reason).toBe('kids_restricted');
  });
});
