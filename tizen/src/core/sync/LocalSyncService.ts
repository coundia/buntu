/**
 * CND IPTV Tizen - Local Network Household Synchronization Service (PRD 41 § 6 & § 8)
 *
 * Implements:
 * 1. Samsung MSF Channel client (ws://<tv_host>:8001/api/v2/channels/buntu.sync.<household_id>).
 * 2. End-to-end encrypted message exchanges using AES-256-GCM and the 256-bit HouseholdKey.
 * 3. Bidirectional delta synchronization (favorites, watch progress, recents, last channel).
 * 4. Remote playback ("Regarder sur la TV") with single-connection enforcement.
 * 5. Remote navigation keys and text typing.
 */

import { WorkerBridge } from '../../worker/worker-bridge';
import { Database, ItemRecord } from '../storage/Database';
import { HouseholdStore } from './HouseholdStore';
import { AVPlayerService } from '../player/AVPlayerService';

export interface RemotePlayEvent {
  content_key: string;
  position_ms: number;
  title?: string;
  source_key?: string;
}

export type SyncStatusListener = (status: {
  connected: boolean;
  householdName?: string;
  pairedDeviceCount: number;
  lastSyncTime?: number;
}) => void;

export class LocalSyncService {
  private static instance: LocalSyncService;
  private ws: WebSocket | null = null;
  private store = HouseholdStore.getInstance();
  private bridge = WorkerBridge.getInstance();
  private db = Database.getInstance();

  private isRunning = false;
  private isConnected = false;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private periodicSyncTimer: ReturnType<typeof setInterval> | null = null;
  private heartbeatTimer: ReturnType<typeof setInterval> | null = null;
  private seenPeersOnConnection = new Set<string>();
  private localSeq = 1;
  private lastSyncHlc = '';

  private playRemoteListeners: ((e: RemotePlayEvent) => void)[] = [];
  private remoteKeyListeners: ((key: string) => void)[] = [];
  private remoteTextListeners: ((text: string) => void)[] = [];
  private genericMessageListeners: ((msg: any, senderId: string) => void)[] = [];
  private statusListeners: SyncStatusListener[] = [];

  public static getInstance(): LocalSyncService {
    if (!LocalSyncService.instance) {
      LocalSyncService.instance = new LocalSyncService();
    }
    return LocalSyncService.instance;
  }

  public onGenericMessage(fn: (msg: any, senderId: string) => void): () => void {
    this.genericMessageListeners.push(fn);
    return () => {
      this.genericMessageListeners = this.genericMessageListeners.filter((l) => l !== fn);
    };
  }

  public onPlayRemote(fn: (e: RemotePlayEvent) => void): () => void {
    this.playRemoteListeners.push(fn);
    return () => {
      this.playRemoteListeners = this.playRemoteListeners.filter((l) => l !== fn);
    };
  }

  public onRemoteKey(fn: (key: string) => void): () => void {
    this.remoteKeyListeners.push(fn);
    return () => {
      this.remoteKeyListeners = this.remoteKeyListeners.filter((l) => l !== fn);
    };
  }

  public onRemoteText(fn: (text: string) => void): () => void {
    this.remoteTextListeners.push(fn);
    return () => {
      this.remoteTextListeners = this.remoteTextListeners.filter((l) => l !== fn);
    };
  }

  public onStatusChange(fn: SyncStatusListener): () => void {
    this.statusListeners.push(fn);
    this.notifyStatus();
    return () => {
      this.statusListeners = this.statusListeners.filter((l) => l !== fn);
    };
  }

  private notifyStatus() {
    const info = this.store.getHouseholdInfo();
    const devices = this.store.getPairedDevices();
    for (const fn of this.statusListeners) {
      fn({
        connected: this.isConnected,
        householdName: info?.household_name,
        pairedDeviceCount: devices.length,
        lastSyncTime: Date.now(),
      });
    }
  }

  public async start(): Promise<void> {
    if (this.isRunning) return;
    this.isRunning = true;

    const info = this.store.getHouseholdInfo();
    const key = await this.store.getHouseholdKey();
    if (!info || !key) {
      return;
    }

    this.connectWs(info.household_id);

    // Periodic sync every 60 seconds
    this.periodicSyncTimer = setInterval(() => {
      void this.triggerSync();
    }, 60_000);

    // Initial sync
    setTimeout(() => {
      void this.triggerSync();
    }, 1_000);
  }

  public stop(): void {
    this.isRunning = false;
    this.isConnected = false;
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    if (this.periodicSyncTimer) clearInterval(this.periodicSyncTimer);
    if (this.heartbeatTimer) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = null;
    }
    this.seenPeersOnConnection.clear();
    if (this.ws) {
      this.ws.close();
      this.ws = null;
    }
    this.notifyStatus();
  }

  private startHeartbeat(): void {
    if (this.heartbeatTimer) clearInterval(this.heartbeatTimer);
    this.heartbeatTimer = setInterval(() => {
      if (this.isConnected) {
        this.broadcastDeviceAnnounce();
      }
    }, 30_000);
  }

  private connectWs(householdId: string): void {
    if (!this.isRunning) return;

    // Connect to local Samsung channel service (default port 8001)
    const host = typeof window !== 'undefined' && window.location.hostname ? window.location.hostname : '127.0.0.1';
    const channelName = `buntu.sync.${householdId}`;
    const url = `ws://${host}:8001/api/v2/channels/${channelName}`;

    try {
      this.ws = new WebSocket(url);

      this.ws.onopen = () => {
        this.isConnected = true;
        this.seenPeersOnConnection.clear();
        this.notifyStatus();
        this.broadcastDeviceAnnounce();
        this.startHeartbeat();
      };

      this.ws.onmessage = (event) => {
        void this.handleIncomingMessage(event.data);
      };

      this.ws.onclose = () => {
        this.isConnected = false;
        if (this.heartbeatTimer) {
          clearInterval(this.heartbeatTimer);
          this.heartbeatTimer = null;
        }
        this.seenPeersOnConnection.clear();
        this.notifyStatus();
        if (this.isRunning) {
          this.reconnectTimer = setTimeout(() => this.connectWs(householdId), 5_000);
        }
      };

      this.ws.onerror = () => {
        this.isConnected = false;
        this.notifyStatus();
      };
    } catch {
      this.isConnected = false;
      this.notifyStatus();
      if (this.isRunning) {
        this.reconnectTimer = setTimeout(() => this.connectWs(householdId), 5_000);
      }
    }
  }

  /**
   * Anti-replay counter, strictly increasing ACROSS app restarts.
   * It used to restart at 1 on every launch, so after the first restart the phones (which remember
   * the last sequence seen from this TV) rejected every message as a replay.
   */
  private nextSequence(): number {
    let last = 0;
    try {
      last = parseInt(localStorage.getItem('cnd_sync_seq') || '0', 10) || 0;
    } catch {
      // storage unavailable: fall back to the clock below
    }
    const seq = Math.max(last + 1, Date.now());
    try {
      localStorage.setItem('cnd_sync_seq', String(seq));
    } catch {
      // ignore
    }
    this.localSeq = seq;
    return seq;
  }

  public async sendMessage(message: any): Promise<void> {
    const key = await this.store.getHouseholdKey();
    if (!key) return;

    const nonce = new Uint8Array(12);
    crypto.getRandomValues(nonce);
    const nonceHex = Array.from(nonce).map((b) => b.toString(16).padStart(2, '0')).join('');

    const seq = this.nextSequence();
    const senderId = this.store.getLocalDeviceId();

    const envelope = await this.bridge.post('SYNC_SEAL_ENVELOPE', {
      householdKeyHex: key,
      senderId,
      sequence: seq,
      nonceHex,
      message,
    });

    if (this.ws && this.ws.readyState === WebSocket.OPEN) {
      this.ws.send(
        JSON.stringify({
          method: 'ms.channel.emit',
          params: { event: 'buntu-sync-envelope', to: 'broadcast', data: envelope },
        })
      );
    }
  }

  private async handleIncomingMessage(raw: string): Promise<void> {
    try {
      const parsed = typeof raw === 'string' ? JSON.parse(raw) : raw;
      if (parsed.event === 'ms.channel.connect') {
        return;
      }

      let envelope = parsed.data;
      if (typeof envelope === 'string') {
        try {
          envelope = JSON.parse(envelope);
        } catch {
          // not JSON string
        }
      }
      if (!envelope || !envelope.sender_device_id) {
        envelope = parsed;
      }
      if (!envelope || !envelope.sender_device_id || !envelope.ciphertext_hex) {
        return;
      }

      // Ignore our own broadcast reflections
      if (envelope.sender_device_id === this.store.getLocalDeviceId()) {
        return;
      }

      const key = await this.store.getHouseholdKey();
      if (!key) return;

      const lastSeq = this.store.getLastSeenSeq(envelope.sender_device_id);
      const message = await this.bridge.post('SYNC_OPEN_ENVELOPE', {
        householdKeyHex: key,
        envelope,
        lastSeenSequence: lastSeq,
      });

      this.store.recordDeviceActivity(
        envelope.sender_device_id,
        envelope.sender_device_id,
        'mobile',
        envelope.sequence
      );

      this.dispatchSyncMessage(message, envelope.sender_device_id);
    } catch (e) {
      // Replay rejected, decryption failure, or ping message
    }
  }

  private dispatchSyncMessage(message: any, senderId: string): void {
    if (!message || !message.type) return;

    for (const fn of this.genericMessageListeners) {
      fn(message, senderId);
    }

    switch (message.type) {
      case 'sync_delta':
        void this.applyIncomingDelta(message);
        break;

      case 'play_remote':
        for (const fn of this.playRemoteListeners) {
          fn({
            content_key: message.content_key,
            position_ms: message.position_ms,
            title: message.title,
            source_key: message.source_key,
          });
        }
        break;

      case 'remote_key':
        for (const fn of this.remoteKeyListeners) {
          fn(message.key);
        }
        break;

      case 'remote_text':
        for (const fn of this.remoteTextListeners) {
          fn(message.text);
        }
        break;

      case 'device_announce':
        this.store.recordDeviceActivity(
          senderId,
          message.device_name,
          message.device_type,
          0
        );
        this.notifyStatus();
        if (!this.seenPeersOnConnection.has(senderId)) {
          this.seenPeersOnConnection.add(senderId);
          this.broadcastDeviceAnnounce();
        }
        break;
    }
  }

  private broadcastDeviceAnnounce(): void {
    const isPlaying = AVPlayerService.getInstance().isActive();
    void this.sendMessage({
      type: 'device_announce',
      device_id: this.store.getLocalDeviceId(),
      device_name: this.store.getLocalDeviceName(),
      device_type: 'tv',
      app_version: '1.0.0',
      can_play: true,
      capabilities: ['play', 'remote_control'],
      state: isPlaying ? 'playing' : 'idle',
    });
  }

  /**
   * Triggers export and broadcast of local state changes to the household.
   */
  public async triggerSync(): Promise<void> {
    const key = await this.store.getHouseholdKey();
    if (!key) return;

    // Only the CHANGES since the last export are sent. Re-sending every favorite with a fresh
    // timestamp each minute (the previous behaviour) made a favorite removed on another device
    // come back, because the TV's copy always looked newer than the removal.
    const profile = LocalSyncService.PROFILE_UUID;
    const favorites = await this.db.getFavorites();
    const current = new Set(favorites.map((f) => f.stable_hash));
    const previous = this.loadFavoriteSnapshot();

    const node = this.store.getLocalDeviceId();
    const now = Date.now();
    const hlc = `${now}.0.${node}`;

    const added = favorites.filter((f) => !previous.has(f.stable_hash));
    const removed = Array.from(previous).filter((k) => !current.has(k));
    if (added.length === 0 && removed.length === 0) return;

    await this.sendMessage({
      type: 'sync_delta',
      to_hlc: hlc,
      sources: [],
      profiles: [],
      progress: [],
      recents: [],
      favorites: added.map((f) => ({
        profile_uuid: profile,
        content_key: f.stable_hash,
        item_kind: f.kind,
        hlc,
      })),
      tombstones: removed.map((k) => ({
        kind: 'favorite',
        key: `${profile}:${k}`,
        hlc,
      })),
    });
    this.lastSyncHlc = hlc;
    this.saveFavoriteSnapshot(current);
  }

  private static readonly PROFILE_UUID = '00000000-0000-0000-0000-000000000001';
  private static readonly FAV_SNAPSHOT_KEY = 'cnd_sync_fav_keys';

  private loadFavoriteSnapshot(): Set<string> {
    try {
      const raw = localStorage.getItem(LocalSyncService.FAV_SNAPSHOT_KEY);
      return new Set<string>(raw ? JSON.parse(raw) : []);
    } catch {
      return new Set<string>();
    }
  }

  private saveFavoriteSnapshot(keys: Set<string>): void {
    try {
      localStorage.setItem(LocalSyncService.FAV_SNAPSHOT_KEY, JSON.stringify(Array.from(keys)));
    } catch {
      // ignore
    }
  }

  /**
   * Broadcasts watch progress during playback (called every 15s or at pause/stop).
   */
  public async broadcastProgress(
    contentKey: string,
    positionMs: number,
    durationMs: number,
    completed: boolean
  ): Promise<void> {
    const node = this.store.getLocalDeviceId();
    const now = Date.now();
    await this.sendMessage({
      type: 'sync_delta',
      to_hlc: `${now}.0.${node}`,
      progress: [
        {
          profile_uuid: '00000000-0000-0000-0000-000000000001',
          content_key: contentKey,
          item_kind: 'movie',
          position_ms: positionMs,
          duration_ms: durationMs,
          completed,
          hlc: `${now}.0.${node}`,
        },
      ],
      sources: [],
      profiles: [],
      favorites: [],
      recents: [],
      tombstones: [],
    });
  }

  /**
   * Applies an incoming SyncDelta from a remote household device.
   */
  public async applyIncomingDelta(delta: any): Promise<void> {
    if (!delta) return;

    const snapshot = this.loadFavoriteSnapshot();
    let snapshotChanged = false;

    // Favorites added elsewhere
    if (Array.isArray(delta.favorites)) {
      for (const fav of delta.favorites) {
        if (!fav.content_key) continue;
        const item = await this.db.getItemByStableHash(fav.content_key);
        if (item && item.is_favorite !== 1) {
          await this.db.toggleFavorite(item.id);
        }
        // Known to this device now: it must not be re-exported as one of its own changes.
        if (item) {
          snapshot.add(item.stable_hash);
          snapshotChanged = true;
        }
      }
    }

    // Favorites removed elsewhere (tombstones were ignored before: removals never arrived)
    if (Array.isArray(delta.tombstones)) {
      for (const t of delta.tombstones) {
        if (!t || t.kind !== 'favorite' || typeof t.key !== 'string') continue;
        const contentKey = t.key.indexOf(':') >= 0 ? t.key.slice(t.key.indexOf(':') + 1) : t.key;
        const item = await this.db.getItemByStableHash(contentKey);
        if (item && item.is_favorite === 1) {
          await this.db.toggleFavorite(item.id);
        }
        if (item) {
          snapshot.delete(item.stable_hash);
          snapshotChanged = true;
        }
      }
    }
    if (snapshotChanged) this.saveFavoriteSnapshot(snapshot);

    // Watch progress (the previous code called a `put` method that does not exist: nothing was saved)
    if (Array.isArray(delta.progress)) {
      for (const prg of delta.progress) {
        if (!prg.content_key) continue;
        const item = await this.db.getItemByStableHash(prg.content_key);
        if (item) {
          await this.db.updateWatchProgress(item.id, prg.position_ms || 0, prg.duration_ms || item.duration_ms || 0);
        }
      }
    }

    this.notifyStatus();
  }
}
