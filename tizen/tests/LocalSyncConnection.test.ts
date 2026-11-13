import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { LocalSyncService } from '../src/core/sync/LocalSyncService';
import { HouseholdStore } from '../src/core/sync/HouseholdStore';
import { WorkerBridge } from '../src/worker/worker-bridge';

class Socket {
  static OPEN = 1;
  static instances: Socket[] = [];
  readyState = Socket.OPEN;
  onmessage: ((event: { data: string }) => void) | null = null;
  onclose: (() => void) | null = null;
  send = vi.fn();
  close = vi.fn();
  constructor(public url: string) { Socket.instances.push(this); }
}

async function flush() {
  for (let i = 0; i < 20; i++) await Promise.resolve();
}

describe('Samsung household connection and TV discovery', () => {
  let service: LocalSyncService;
  let store: HouseholdStore;

  beforeEach(() => {
    vi.useFakeTimers();
    Socket.instances = [];
    vi.stubGlobal('WebSocket', Socket);
    service = new (LocalSyncService as any)();
    store = HouseholdStore.getInstance();
    vi.spyOn(store, 'getHouseholdInfo').mockReturnValue({ household_id: 'test-house', household_name: 'Maison', created_at: 1 });
    vi.spyOn(store, 'getHouseholdKey').mockResolvedValue('test-key');
    vi.spyOn(store, 'getLocalDeviceId').mockReturnValue('test-tv');
    vi.spyOn(store, 'getLocalDeviceName').mockReturnValue('Salon');
    vi.spyOn(store, 'getPairedDevices').mockReturnValue([]);
    vi.spyOn(WorkerBridge.getInstance(), 'post').mockImplementation(async (_type, payload) => ({ message: payload.message }));
  });

  afterEach(() => {
    service.stop();
    vi.clearAllTimers();
    vi.useRealTimers();
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
  });

  it('connects after pairing when first launched without a household', async () => {
    vi.mocked(store.getHouseholdInfo).mockReturnValueOnce(null);
    vi.mocked(store.getHouseholdKey).mockResolvedValueOnce(null);
    await service.start();
    expect(Socket.instances).toHaveLength(0);
    await service.start();
    expect(Socket.instances).toHaveLength(1);
    await service.start();
    expect(Socket.instances).toHaveLength(1);
  });

  it('announces a playable TV only after Samsung confirms channel membership', async () => {
    await service.start();
    const socket = Socket.instances[0];
    expect(socket.send).not.toHaveBeenCalled();
    socket.onmessage!({ data: JSON.stringify({ event: 'ms.channel.connect' }) });
    await flush();
    const messages = socket.send.mock.calls.map(([frame]) => JSON.parse(frame).params.data.message);
    expect(messages).toContainEqual(expect.objectContaining({ type: 'device_announce', device_id: 'test-tv', can_play: true }));
    expect(messages).toContainEqual({ type: 'sync_request' });
    socket.send.mockClear();
    await vi.advanceTimersByTimeAsync(30_000);
    expect(socket.send.mock.calls.map(([frame]) => JSON.parse(frame).params.data.message)).toContainEqual(
      expect.objectContaining({ type: 'device_announce', can_play: true })
    );
  });

  it('does not duplicate the socket on concurrent starts', async () => {
    await Promise.all([service.start(), service.start()]);
    expect(Socket.instances).toHaveLength(1);
  });
});
