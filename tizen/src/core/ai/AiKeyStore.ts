import { AiProviderType, getAiSettings } from './AiSettings';
/**
 * CND IPTV Tizen - Secure AI API Key Storage (PRD 40 § 4.3)
 *
 * Implements:
 * 1. AES-GCM (256-bit) encryption using WebCrypto (crypto.subtle).
 * 2. Non-exportable master key stored in an isolated IndexedDB database (`cnd_ai_vault`).
 * 3. Encrypted ciphertext + IV stored in IndexedDB.
 * 4. Zero plaintext keys in localStorage, console logs, or network payloads.
 */

const DB_NAME = 'cnd_ai_vault';
const DB_VERSION = 1;
const STORE_NAME = 'keys';
const MASTER_KEY_ID = 'master_key';
const API_KEY_RECORD_ID = 'encrypted_api_key';

/** What the vault can hold a key for: an AI provider, or the OMDb film-facts service. */
export type KeySlot = AiProviderType | 'omdb';

interface EncryptedPayload {
  iv: Uint8Array;
  ciphertext: ArrayBuffer;
}

export class AiKeyStore {
  private static instance: AiKeyStore;
  private db: IDBDatabase | null = null;
  private cachedKey: CryptoKey | null = null;

  public static getInstance(): AiKeyStore {
    if (!AiKeyStore.instance) {
      AiKeyStore.instance = new AiKeyStore();
    }
    return AiKeyStore.instance;
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
        reject(new Error(`Failed to open AI vault: ${event.target.error}`));
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

    // Generate non-exportable 256-bit AES-GCM key
    const newKey = await crypto.subtle.generateKey(
      {
        name: 'AES-GCM',
        length: 256,
      },
      false, // non-exportable
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

  public async setApiKey(apiKey: string, provider: KeySlot = getAiSettings().provider): Promise<void> {
    const trimmed = apiKey.trim();
    if (!trimmed) {
      await this.deleteApiKey(provider);
      return;
    }

    const masterKey = await this.getMasterKey();
    const iv = crypto.getRandomValues(new Uint8Array(12));
    const encoded = new TextEncoder().encode(trimmed);

    const ciphertext = await crypto.subtle.encrypt(
      {
        name: 'AES-GCM',
        iv,
      },
      masterKey,
      encoded
    );

    const payload: EncryptedPayload = { iv, ciphertext };
    const db = await this.openDb();

    await new Promise<void>((resolve, reject) => {
      const tx = db.transaction(STORE_NAME, 'readwrite');
      const store = tx.objectStore(STORE_NAME);
      const req = store.put(payload, `${API_KEY_RECORD_ID}_${provider}`);
      req.onsuccess = () => resolve();
      req.onerror = () => reject(req.error);
    });
  }

  public async getApiKey(provider: KeySlot = getAiSettings().provider): Promise<string | null> {
    const db = await this.openDb();
    let record = await new Promise<EncryptedPayload | undefined>((resolve, reject) => {
      const tx = db.transaction(STORE_NAME, 'readonly');
      const store = tx.objectStore(STORE_NAME);
      const req = store.get(`${API_KEY_RECORD_ID}_${provider}`);
      req.onsuccess = () => resolve(req.result);
      req.onerror = () => reject(req.error);
    });

    // Migrate the old single slot only for the provider selected by that old app.
    if (!record && provider === getAiSettings().provider) {
      record = await new Promise<EncryptedPayload | undefined>((resolve, reject) => {
        const tx = db.transaction(STORE_NAME, 'readwrite');
        const store = tx.objectStore(STORE_NAME);
        const request = store.get(API_KEY_RECORD_ID);
        request.onsuccess = () => {
          const legacy = request.result;
          if (legacy) {
            store.put(legacy, `${API_KEY_RECORD_ID}_${provider}`);
            store.delete(API_KEY_RECORD_ID);
          }
          tx.oncomplete = () => resolve(legacy);
        };
        tx.onerror = () => reject(new Error('Migration du coffre IA impossible'));
      });
    }

    if (!record || !record.iv || !record.ciphertext) {
      return null;
    }

    try {
      const masterKey = await this.getMasterKey();
      const decrypted = await crypto.subtle.decrypt(
        {
          name: 'AES-GCM',
          iv: record.iv as BufferSource,
        },
        masterKey,
        record.ciphertext
      );

      return new TextDecoder().decode(decrypted);
    } catch {
      return null;
    }
  }

  public async deleteApiKey(provider: KeySlot = getAiSettings().provider): Promise<void> {
    const db = await this.openDb();
    await new Promise<void>((resolve, reject) => {
      const tx = db.transaction(STORE_NAME, 'readwrite');
      const store = tx.objectStore(STORE_NAME);
      const req = store.delete(`${API_KEY_RECORD_ID}_${provider}`);
      if (provider === getAiSettings().provider) store.delete(API_KEY_RECORD_ID);
      req.onsuccess = () => resolve();
      req.onerror = () => reject(req.error);
    });
  }

  public async hasApiKey(provider: KeySlot = getAiSettings().provider): Promise<boolean> {
    const key = await this.getApiKey(provider);
    return Boolean(key && key.length > 0);
  }

  public async getMaskedKey(provider: KeySlot = getAiSettings().provider): Promise<string | null> {
    const key = await this.getApiKey(provider);
    if (!key) return null;
    if (key.length <= 4) return '••••';
    const last4 = key.slice(-4);
    return `••••••••${last4}`;
  }
}
