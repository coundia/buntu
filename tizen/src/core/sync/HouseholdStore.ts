/**
 * CND IPTV Tizen - Secure Household Key & Device Registry (PRD 41 § 5)
 *
 * Implements:
 * 1. WebCrypto AES-GCM (256-bit) encrypted storage of the household key in IndexedDB (`cnd_household_vault`).
 * 2. Device identity (local device_id, device_name, device_type).
 * 3. Registered household devices tracking and sequence barrier anti-replay.
 * 4. Zero plaintext keys in localStorage, logs or network traffic.
 */

import { WorkerBridge } from '../../worker/worker-bridge';

const DB_NAME = 'cnd_household_vault';
const DB_VERSION = 1;
const STORE_NAME = 'vault';
const MASTER_KEY_ID = 'master_key';
const HOUSEHOLD_KEY_RECORD_ID = 'encrypted_household_key';
const SETTINGS_KEY = 'cnd_household_info';

export interface HouseholdInfo {
    household_id: string;
    household_name: string;
    created_at: number;
}

export interface PairedDevice {
    device_id: string;
    device_name: string;
    device_type: 'tv' | 'mobile' | 'desktop';
    last_seen: number;
    last_seq: number;
}

interface EncryptedPayload {
    iv: Uint8Array;
    ciphertext: ArrayBuffer;
}

export class HouseholdStore {
    private static instance: HouseholdStore;
    private db: IDBDatabase | null = null;
    private cachedKey: CryptoKey | null = null;
    private deviceId: string | null = null;

    public static getInstance(): HouseholdStore {
        if (!HouseholdStore.instance) {
            HouseholdStore.instance = new HouseholdStore();
        }
        return HouseholdStore.instance;
    }

    private async openDb(): Promise<IDBDatabase> {
        if (this.db) return this.db;

        return new Promise<IDBDatabase>((resolve, reject) => {
            const request = indexedDB.open(DB_NAME, DB_VERSION);

            request.onupgradeneeded = (event: any) => {
                const db = event.target.result as IDBDatabase;
                if (!db.objectStoreNames.contains(STORE_NAME)) {
                    db.createObjectStore(STORE_NAME);
                }
            };

            request.onsuccess = (event: any) => {
                this.db = event.target.result;
                resolve(this.db!);
            };

            request.onerror = (event: any) => {
                reject(new Error(`Failed to open household vault: ${event.target.error}`));
            };
        });
    }

    private async getMasterKey(): Promise<CryptoKey> {
        if (this.cachedKey) return this.cachedKey;

        const db = await this.openDb();
        const existing = await new Promise<CryptoKey | undefined>((resolve, reject) => {
            const tx = db.transaction(STORE_NAME, 'readonly');
            const store = tx.objectStore(STORE_NAME);
            const req = store.get(MASTER_KEY_ID);
            req.onsuccess = () => resolve(req.result);
            req.onerror = () => reject(req.error);
        });

        if (existing) {
            this.cachedKey = existing;
            return existing;
        }

        const newKey = await crypto.subtle.generateKey(
            { name: 'AES-GCM', length: 256 },
            false,
            ['encrypt', 'decrypt']
        );

        await new Promise<void>((resolve, reject) => {
            const tx = db.transaction(STORE_NAME, 'readwrite');
            const store = tx.objectStore(STORE_NAME);
            const req = store.put(newKey, MASTER_KEY_ID);
            req.onsuccess = () => resolve();
            req.onerror = () => reject(req.error);
        });

        this.cachedKey = newKey;
        return newKey;
    }

    public getLocalDeviceId(): string {
        if (this.deviceId) return this.deviceId;
        let id = localStorage.getItem('cnd_device_id');
        if (!id) {
            const arr = new Uint8Array(8);
            crypto.getRandomValues(arr);
            id = `tizen_${Array.from(arr).map(b => b.toString(16).padStart(2, '0')).join('')}`;
            localStorage.setItem('cnd_device_id', id);
        }
        this.deviceId = id;
        return id;
    }

    public getLocalDeviceName(): string {
        return localStorage.getItem('cnd_device_name') || 'Samsung TV';
    }

    public setLocalDeviceName(name: string): void {
        localStorage.setItem('cnd_device_name', name.trim());
    }

    public getHouseholdInfo(): HouseholdInfo | null {
        try {
            const raw = localStorage.getItem(SETTINGS_KEY);
            return raw ? JSON.parse(raw) : null;
        } catch {
            return null;
        }
    }

    public saveHouseholdInfo(info: HouseholdInfo): void {
        localStorage.setItem(SETTINGS_KEY, JSON.stringify(info));
    }

    public async getHouseholdKey(): Promise<string | null> {
        const db = await this.openDb();
        const record = await new Promise<EncryptedPayload | undefined>((resolve, reject) => {
            const tx = db.transaction(STORE_NAME, 'readonly');
            const store = tx.objectStore(STORE_NAME);
            const req = store.get(HOUSEHOLD_KEY_RECORD_ID);
            req.onsuccess = () => resolve(req.result);
            req.onerror = () => reject(req.error);
        });

        if (!record || !record.iv || !record.ciphertext) {
            return null;
        }

        try {
            const masterKey = await this.getMasterKey();
            const decrypted = await crypto.subtle.decrypt(
                { name: 'AES-GCM', iv: record.iv as BufferSource },
                masterKey,
                record.ciphertext
            );
            return new TextDecoder().decode(decrypted);
        } catch {
            return null;
        }
    }

    public async setHouseholdKey(keyHex: string): Promise<void> {
        const trimmed = keyHex.trim();
        if (!trimmed) {
            await this.clearHousehold();
            return;
        }

        const masterKey = await this.getMasterKey();
        const iv = crypto.getRandomValues(new Uint8Array(12));
        const encoded = new TextEncoder().encode(trimmed);

        const ciphertext = await crypto.subtle.encrypt(
            { name: 'AES-GCM', iv },
            masterKey,
            encoded
        );

        const payload: EncryptedPayload = { iv, ciphertext };
        const db = await this.openDb();

        await new Promise<void>((resolve, reject) => {
            const tx = db.transaction(STORE_NAME, 'readwrite');
            const store = tx.objectStore(STORE_NAME);
            const req = store.put(payload, HOUSEHOLD_KEY_RECORD_ID);
            req.onsuccess = () => resolve();
            req.onerror = () => reject(req.error);
        });
    }

    public async joinHousehold(invite: string, name = 'Salon'): Promise<HouseholdInfo> {
        const result = await WorkerBridge.getInstance().post('SYNC_HOUSEHOLD_JOIN', { invite });
        await this.setHouseholdKey(result.household_key);
        const info = { household_id: result.household_id, household_name: name.trim() || 'Salon', created_at: Date.now() };
        this.saveHouseholdInfo(info);
        return info;
    }

    public async createHousehold(name = 'Maison'): Promise<HouseholdInfo> {
        const entropy = new Uint8Array(32);
        crypto.getRandomValues(entropy);
        const entropyHex = Array.from(entropy).map(b => b.toString(16).padStart(2, '0')).join('');

        const bridge = WorkerBridge.getInstance();
        const res = await bridge.post('SYNC_CREATE_HOUSEHOLD', { entropyHex });

        await this.setHouseholdKey(res.household_key);

        const info: HouseholdInfo = {
            household_id: res.household_id,
            household_name: name,
            created_at: Date.now(),
        };
        this.saveHouseholdInfo(info);
        return info;
    }

    public async clearHousehold(): Promise<void> {
        localStorage.removeItem(SETTINGS_KEY);
        localStorage.removeItem('cnd_paired_devices');
        const db = await this.openDb();
        await new Promise<void>((resolve, reject) => {
            const tx = db.transaction(STORE_NAME, 'readwrite');
            const store = tx.objectStore(STORE_NAME);
            const req = store.delete(HOUSEHOLD_KEY_RECORD_ID);
            req.onsuccess = () => resolve();
            req.onerror = () => reject(req.error);
        });
    }

    public getPairedDevices(): PairedDevice[] {
        try {
            const raw = localStorage.getItem('cnd_paired_devices');
            return raw ? JSON.parse(raw) : [];
        } catch {
            return [];
        }
    }

    public recordDeviceActivity(deviceId: string, deviceName: string, deviceType: 'tv' | 'mobile' | 'desktop', seq: number): void {
        const devices = this.getPairedDevices();
        const existing = devices.find(d => d.device_id === deviceId);
        if (existing) {
            // A bare envelope (seq only) records the sender as 'mobile'; an announce brings the real type.
            if (seq === 0 || deviceName !== deviceId) {
                existing.device_name = deviceName;
                existing.device_type = deviceType;
            }
            existing.last_seen = Date.now();
            existing.last_seq = Math.max(existing.last_seq, seq);
        } else {
            devices.push({
                device_id: deviceId,
                device_name: deviceName,
                device_type: deviceType,
                last_seen: Date.now(),
                last_seq: seq,
            });
        }
        localStorage.setItem('cnd_paired_devices', JSON.stringify(devices));
    }

    public getLastSeenSeq(deviceId: string): number {
        const devices = this.getPairedDevices();
        const existing = devices.find(d => d.device_id === deviceId);
        return existing ? existing.last_seq : 0;
    }
}

