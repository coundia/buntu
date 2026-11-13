/** Device-only source settings, encrypted with a non-exportable WebCrypto key. Never exported. */
export interface SourceConnectionEdit {
  source_type: 'xtream' | 'm3u';
  server: string;
  username: string;
  password: string;
  url: string;
}

type CipherRecord = { iv: Uint8Array; ciphertext: ArrayBuffer };
export class LocalSourceVault {
  private static instance: LocalSourceVault;
  static getInstance(): LocalSourceVault { return this.instance || (this.instance = new LocalSourceVault()); }
  private database: Promise<IDBDatabase> | null = null;
  private key: Promise<CryptoKey> | null = null;
  private cache = new Map<string, SourceConnectionEdit>();

  private open(): Promise<IDBDatabase> {
    if (!this.database) this.database = new Promise((resolve, reject) => {
      const request = indexedDB.open('cnd_local_source_vault', 1);
      request.onupgradeneeded = () => { request.result.createObjectStore('vault'); };
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(new Error('Stockage local indisponible'));
    });
    return this.database;
  }
  private async read<T>(id: string): Promise<T | undefined> {
    const db = await this.open();
    return new Promise((resolve, reject) => {
      const request = db.transaction('vault', 'readonly').objectStore('vault').get(id);
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(new Error('Lecture locale impossible'));
    });
  }
  private async write(id: string, value?: unknown): Promise<void> {
    const db = await this.open();
    return new Promise((resolve, reject) => {
      const tx = db.transaction('vault', 'readwrite');
      const store = tx.objectStore('vault');
      if (value === undefined) store.delete(id); else store.put(value, id);
      tx.oncomplete = () => resolve();
      tx.onerror = tx.onabort = () => reject(new Error('Enregistrement local impossible'));
    });
  }
  private masterKey(): Promise<CryptoKey> {
    if (!this.key) this.key = (async () => {
      const previous = await this.read<CryptoKey>('master');
      if (previous) return previous;
      const key = await crypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
      await this.write('master', key);
      return key;
    })();
    return this.key;
  }
  async get(uuid: string): Promise<SourceConnectionEdit | null> {
    const cached = this.cache.get(uuid);
    if (cached) return { ...cached };
    const record = await this.read<CipherRecord>(`source:${uuid}`);
    if (!record) return null;
    const plaintext = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: new Uint8Array(record.iv), additionalData: new TextEncoder().encode(uuid) }, await this.masterKey(), record.ciphertext);
    const edit = JSON.parse(new TextDecoder().decode(plaintext)) as SourceConnectionEdit;
    this.cache.set(uuid, edit);
    return { ...edit };
  }
  async set(uuid: string, edit: SourceConnectionEdit): Promise<void> {
    const iv = crypto.getRandomValues(new Uint8Array(12));
    const ciphertext = await crypto.subtle.encrypt({ name: 'AES-GCM', iv, additionalData: new TextEncoder().encode(uuid) }, await this.masterKey(), new TextEncoder().encode(JSON.stringify(edit)));
    await this.write(`source:${uuid}`, { iv, ciphertext });
    this.cache.set(uuid, { ...edit });
  }
  async delete(uuid: string): Promise<void> {
    await this.write(`source:${uuid}`);
    this.cache.delete(uuid);
  }
}
