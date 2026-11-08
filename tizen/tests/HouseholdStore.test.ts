import { describe, it, expect, beforeEach } from 'vitest';
import { HouseholdStore } from '../src/core/sync/HouseholdStore';

function createMockIndexedDB() {
  const stores = new Map<string, Map<string, any>>();

  return {
    open(dbName: string, version: number) {
      const req: any = {
        onsuccess: null,
        onerror: null,
        onupgradeneeded: null,
        result: null,
      };

      setTimeout(() => {
        const db: any = {
          objectStoreNames: {
            contains(name: string) {
              return stores.has(name);
            },
          },
          createObjectStore(name: string) {
            stores.set(name, new Map());
            return {};
          },
          transaction(storeName: string, mode: string) {
            if (!stores.has(storeName)) {
              stores.set(storeName, new Map());
            }
            const map = stores.get(storeName)!;

            return {
              objectStore(name: string) {
                return {
                  get(key: string) {
                    const r: any = { onsuccess: null, onerror: null, result: undefined };
                    setTimeout(() => {
                      r.result = map.get(key);
                      if (r.onsuccess) r.onsuccess();
                    }, 0);
                    return r;
                  },
                  put(val: any, key: string) {
                    const r: any = { onsuccess: null, onerror: null };
                    setTimeout(() => {
                      map.set(key, val);
                      if (r.onsuccess) r.onsuccess();
                    }, 0);
                    return r;
                  },
                  delete(key: string) {
                    const r: any = { onsuccess: null, onerror: null };
                    setTimeout(() => {
                      map.delete(key);
                      if (r.onsuccess) r.onsuccess();
                    }, 0);
                    return r;
                  },
                };
              },
            };
          },
        };

        if (req.onupgradeneeded) {
          req.onupgradeneeded({ target: { result: db } });
        }
        req.result = db;
        if (req.onsuccess) {
          req.onsuccess({ target: { result: db } });
        }
      }, 0);

      return req;
    },
  };
}

describe('HouseholdStore (PRD 41 § 5)', () => {
  let store: HouseholdStore;
  const localStore = new Map<string, string>();
  const mockLocalStorage = {
    getItem: (key: string) => localStore.get(key) || null,
    setItem: (key: string, val: string) => localStore.set(key, val),
    removeItem: (key: string) => localStore.delete(key),
    clear: () => localStore.clear(),
  };

  beforeEach(() => {
    localStore.clear();
    (globalThis as any).localStorage = mockLocalStorage;
    (globalThis as any).indexedDB = createMockIndexedDB();
    (HouseholdStore as any).instance = undefined;
    store = HouseholdStore.getInstance();
  });

  it('generates and persists a stable local device id with tizen_ prefix', () => {
    const id1 = store.getLocalDeviceId();
    expect(id1).toMatch(/^tizen_[0-9a-f]{16}$/);

    const id2 = store.getLocalDeviceId();
    expect(id2).toBe(id1);
  });

  it('saves and retrieves household metadata', () => {
    expect(store.getHouseholdInfo()).toBeNull();

    const info = {
      household_id: 'buntu_hh_8c587a530f9f3a19',
      household_name: 'Salon',
      created_at: 1700000000000,
    };
    store.saveHouseholdInfo(info);

    const read = store.getHouseholdInfo();
    expect(read).toEqual(info);
  });

  it('encrypts household key with WebCrypto AES-GCM and decrypts it back', async () => {
    const testKeyHex = '0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20';

    expect(await store.getHouseholdKey()).toBeNull();

    await store.setHouseholdKey(testKeyHex);

    const decrypted = await store.getHouseholdKey();
    expect(decrypted).toBe(testKeyHex);
  });

  it('records paired device activity and enforces monotonic sequence counter', () => {
    store.recordDeviceActivity('phone_1', 'iPhone 15', 'mobile', 10);

    let devices = store.getPairedDevices();
    expect(devices.length).toBe(1);
    expect(devices[0].device_id).toBe('phone_1');
    expect(devices[0].device_name).toBe('iPhone 15');
    expect(devices[0].last_seq).toBe(10);
    expect(store.getLastSeenSeq('phone_1')).toBe(10);

    // Higher sequence updates
    store.recordDeviceActivity('phone_1', 'iPhone 15 Pro', 'mobile', 15);
    devices = store.getPairedDevices();
    expect(devices[0].device_name).toBe('iPhone 15 Pro');
    expect(devices[0].last_seq).toBe(15);
    expect(store.getLastSeenSeq('phone_1')).toBe(15);

    // Out of order lower sequence does not regress the barrier
    store.recordDeviceActivity('phone_1', 'iPhone 15 Pro', 'mobile', 12);
    expect(store.getLastSeenSeq('phone_1')).toBe(15);
  });

  it('clears household metadata, devices and encrypted key', async () => {
    store.saveHouseholdInfo({
      household_id: 'buntu_hh_test',
      household_name: 'Test',
      created_at: Date.now(),
    });
    await store.setHouseholdKey('0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20');
    store.recordDeviceActivity('dev1', 'MacBook', 'desktop', 1);

    await store.clearHousehold();

    expect(store.getHouseholdInfo()).toBeNull();
    expect(store.getPairedDevices()).toEqual([]);
    expect(await store.getHouseholdKey()).toBeNull();
  });
});
