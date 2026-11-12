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
import { CndEngine } from '../engine/CndEngine';
import { hostOf } from '../pairing/ShareImport';

export interface RemotePlayEvent {
  content_key: string;
  position_ms: number;
  title?: string;
  source_key?: string;
}

export interface SyncLogEntry {
  id: string;
  time: string;
  text: string;
  warning?: boolean;
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

  private syncLogs: SyncLogEntry[] = [];
  private logListeners: ((logs: SyncLogEntry[]) => void)[] = [];

  private playRemoteListeners: ((e: RemotePlayEvent) => void)[] = [];
  private remoteKeyListeners: ((key: string) => void)[] = [];
  private remoteTextListeners: ((text: string) => void)[] = [];
  private genericMessageListeners: ((msg: any, senderId: string) => void)[] = [];
  private statusListeners: SyncStatusListener[] = [];

  public static getInstance(): LocalSyncService {
    if (!LocalSyncService.instance) {
      LocalSyncService.instance = new LocalSyncService();
      if (typeof window !== 'undefined') {
        (window as any).__cndSyncService = LocalSyncService.instance;
      }
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

  public log(text: string, warning = false): void {
    const d = new Date();
    const time = d.toLocaleTimeString();
    const entry: SyncLogEntry = {
      id: `${Date.now()}_${Math.random().toString(36).slice(2, 7)}`,
      time,
      text,
      warning,
    };
    this.syncLogs.unshift(entry);
    if (this.syncLogs.length > 50) this.syncLogs.pop();
    if (warning) {
      console.warn(`[LocalSyncService] ${text}`);
    } else {
      console.log(`[LocalSyncService] ${text}`);
    }
    for (const fn of this.logListeners) {
      fn(this.getLogs());
    }
  }

  public getLogs(): SyncLogEntry[] {
    return [...this.syncLogs];
  }

  public onLogChange(fn: (logs: SyncLogEntry[]) => void): () => void {
    this.logListeners.push(fn);
    fn(this.getLogs());
    return () => {
      this.logListeners = this.logListeners.filter((l) => l !== fn);
    };
  }

  public peerName(deviceId: string): string {
    const devices = this.store.getPairedDevices();
    const found = devices.find((d) => d.device_id === deviceId);
    return found?.device_name || (deviceId.length > 12 ? deviceId.slice(0, 12) + '…' : deviceId);
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
    this.log(`Connexion au canal de synchronisation local (${host}:8001)…`);

    try {
      this.ws = new WebSocket(url);

      this.ws.onopen = () => {
        this.isConnected = true;
        this.seenPeersOnConnection.clear();
        this.log('Canal de synchronisation ouvert : TV connectée au foyer.');
        this.notifyStatus();
        this.broadcastDeviceAnnounce();
        void this.requestFullSync();
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
        this.log('Canal de synchronisation fermé : nouvel essai dans 5 s.', true);
        this.notifyStatus();
        if (this.isRunning) {
          this.reconnectTimer = setTimeout(() => this.connectWs(householdId), 5_000);
        }
      };

      this.ws.onerror = () => {
        this.isConnected = false;
        this.log('Erreur réseau sur le canal de synchronisation.', true);
        this.notifyStatus();
      };
    } catch (e: any) {
      this.isConnected = false;
      this.log(`Impossible d'ouvrir le canal de synchronisation : ${e?.message || e}`, true);
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
        this.log('Relais Samsung MSF : canal actif.');
        return;
      }
      if (parsed.event === 'ms.channel.clientConnect') {
        this.log('Un appareil du foyer s’est connecté au canal.');
        return;
      }
      if (parsed.event === 'ms.channel.clientDisconnect') {
        this.log('Un appareil du foyer s’est déconnecté du canal.');
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
      if (!key) {
        this.log('Enveloppe reçue mais clé de foyer introuvable.', true);
        return;
      }

      const lastSeq = this.store.getLastSeenSeq(envelope.sender_device_id);
      let message: any;
      try {
        message = await this.bridge.post('SYNC_OPEN_ENVELOPE', {
          householdKeyHex: key,
          envelope,
          lastSeenSequence: lastSeq,
        });
      } catch (openErr: any) {
        const sender = this.peerName(envelope.sender_device_id);
        this.log(`Message rejeté de ${sender} (seq ${envelope.sequence}): ${openErr?.message || openErr}`, true);
        return;
      }

      this.store.recordDeviceActivity(
        envelope.sender_device_id,
        envelope.sender_device_id,
        'mobile',
        envelope.sequence
      );

      const sender = this.peerName(envelope.sender_device_id);
      this.log(`Message « ${message?.type || 'inconnu'} » reçu de ${sender}.`);
      this.dispatchSyncMessage(message, envelope.sender_device_id);
    } catch (e: any) {
      this.log(`Erreur message entrant : ${e?.message || e}`, true);
    }
  }

  private dispatchSyncMessage(message: any, senderId: string): void {
    if (!message || !message.type) return;

    for (const fn of this.genericMessageListeners) {
      fn(message, senderId);
    }

    switch (message.type) {
      case 'household_data_delta':
        void this.applyHouseholdDataDelta(message.delta, senderId);
        break;

      case 'sync_request':
        this.log(`${this.peerName(senderId)} demande les données du foyer.`);
        void this.sendHouseholdDataDelta();
        break;

      case 'sync_delta':
        void this.applyIncomingDelta(message, senderId);
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
        this.log(`Appareil en ligne : ${message.device_name} (${message.device_type || 'appareil'}).`);
        if (!this.seenPeersOnConnection.has(senderId)) {
          this.seenPeersOnConnection.add(senderId);
          this.broadcastDeviceAnnounce();
        }
        break;
    }
  }

  private broadcastDeviceAnnounce(): void {
    const isPlaying = AVPlayerService.getInstance().isActive();
    this.log(`Diffusion de la présence TV (« ${this.store.getLocalDeviceName()} »)…`);
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
   * Asks all household members on the channel to send their full state.
   */
  public async requestFullSync(): Promise<void> {
    this.log('Demande de synchronisation envoyée au foyer (sync_request)…');
    await this.sendMessage({
      type: 'sync_request',
    });
  }

  /**
   * Sends the TV's full data (sources and favorites) formatted as `household_data_delta`.
   */
  public async sendHouseholdDataDelta(): Promise<void> {
    const key = await this.store.getHouseholdKey();
    if (!key) return;

    const favorites = await this.db.getFavorites();
    const sources = await this.db.getSources();
    const profile = LocalSyncService.PROFILE_UUID;
    const now = Date.now();

    const favDtos = favorites.map((f) => ({
      stable_hash: f.stable_hash,
      item_kind: f.kind,
      created_at: now,
      profile_uuid: profile,
    }));

    const sourceDtos = sources.map((s) => ({
      uuid: s.uuid,
      name: s.name,
      source_type: s.source_type,
      server: s.server,
      username: s.username,
      password: s.password,
      url: s.url,
      epg_url: s.epg_url,
      updated_at: s.last_sync_at || now,
    }));

    this.log(`Envoi des données du foyer : ${sourceDtos.length} compte(s), ${favDtos.length} favori(s)…`);
    await this.sendMessage({
      type: 'household_data_delta',
      delta: {
        sources: sourceDtos,
        profiles: [],
        favorites: favDtos,
        watch_history: [],
        tombstones: [],
      },
    });
  }

  /**
   * Triggers export and broadcast of local state changes to the household.
   */
  public async triggerSync(): Promise<void> {
    const key = await this.store.getHouseholdKey();
    if (!key) return;

    const profile = LocalSyncService.PROFILE_UUID;
    const favorites = await this.db.getFavorites();
    const current = new Set(favorites.map((f) => f.stable_hash));
    const previous = this.loadFavoriteSnapshot();

    const added = favorites.filter((f) => !previous.has(f.stable_hash));
    const removed = Array.from(previous).filter((k) => !current.has(k));

    if (added.length === 0 && removed.length === 0) {
      this.log('Synchronisation locale : aucun nouveau favori ni suppression à envoyer.');
      return;
    }

    const now = Date.now();
    this.log(`Diffusion des changements locaux : +${added.length} favori(s), -${removed.length} supprimé(s).`);

    // Standard cross-platform format recognized by Apple & Android
    await this.sendMessage({
      type: 'household_data_delta',
      delta: {
        sources: [],
        profiles: [],
        favorites: added.map((f) => ({
          stable_hash: f.stable_hash,
          item_kind: f.kind,
          created_at: now,
          profile_uuid: profile,
        })),
        watch_history: [],
        tombstones: removed.map((k) => ({
          kind: 'favorite',
          key: k,
          deleted_at: now,
        })),
      },
    });

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
    const now = Date.now();
    await this.sendMessage({
      type: 'household_data_delta',
      delta: {
        sources: [],
        profiles: [],
        favorites: [],
        watch_history: [
          {
            stable_hash: contentKey,
            position_ms: positionMs,
            duration_ms: durationMs,
            completed,
            last_watched_at: now,
            profile_uuid: LocalSyncService.PROFILE_UUID,
          },
        ],
        tombstones: [],
      },
    });
  }

  /**
   * Applies an incoming household_data_delta from a remote household device (Apple, Android or another TV).
   */
  public async applyHouseholdDataDelta(delta: any, senderId?: string): Promise<void> {
    if (!delta) {
      if (senderId) this.log(`Delta vide reçu de ${this.peerName(senderId)}.`, true);
      return;
    }

    const fromWho = senderId ? ` de ${this.peerName(senderId)}` : '';
    let appliedFavs = 0;
    let removedFavs = 0;
    let appliedProgress = 0;

    let appliedSources = 0;
    // 1. Sources / IPTV accounts FIRST: what the user waits for. Favorites and progress come after,
    //    and must never keep the accounts from arriving.
    const sources = Array.isArray(delta.sources) ? delta.sources : [];

    this.log(
      `Données reçues${fromWho} : ${sources.length} compte(s), ` +
      `${Array.isArray(delta.favorites) ? delta.favorites.length : 0} favori(s), ` +
      `${Array.isArray(delta.watch_history) ? delta.watch_history.length : 0} reprise(s).`
    );

    if (sources.length > 0) {
      try {
      const existing = await this.db.getSources();
      for (const src of sources) {
        if (!src) continue;
        const srcType = String(src.source_type || 'xtream').toLowerCase() as 'xtream' | 'm3u';
        const srcName = String(src.name || 'Compte IPTV').trim();
        const server = (src.server || src.url || '').trim();
        const url = (src.url || src.server || '').trim();
        const username = src.username ? String(src.username).trim() : undefined;
        const password = src.password ? String(src.password) : undefined;
        const host = hostOf(server || url || '') || 'local';

        this.log(
          `Compte récupéré du foyer : « ${srcName} » (${srcType.toUpperCase()}, serveur: ${host}, ` +
          `identifiant: ${username ? 'fourni' : 'aucun'}, mot de passe: ${password ? 'fourni' : 'absent'}).`
        );

        const match = existing.find(
          (e) =>
            (src.uuid && e.uuid === src.uuid) ||
            (e.source_type === srcType && (e.server === server || e.url === url) && (!username || e.username === username))
        );

        if (match) {
          if (!match.password && password) {
            await this.db.upsertSource({ ...match, password });
            this.log(`Mot de passe mis à jour pour le compte « ${srcName} ».`);
            this.notifyStatus();
          } else {
            this.log(`Compte « ${srcName} » déjà enregistré sur la TV.`);
          }
          continue;
        }

        try {
          // 1. Immediately register the source in the TV database so it is visible in SourcesView
          const newUuid = src.uuid || `src_${Date.now()}_${Math.random().toString(36).slice(2, 7)}`;
          await this.db.upsertSource({
            uuid: newUuid,
            name: srcName,
            source_type: srcType,
            server: server || undefined,
            url: url || undefined,
            username: username,
            password: password,
            epg_url: src.epg_url || undefined,
            item_count: src.item_count || 0,
            last_sync_at: Date.now(),
          });
          appliedSources++;
          this.log(`Compte « ${srcName} » enregistré dans les sources de la TV.`);
          this.notifyStatus();

          // 2. Background download of catalog/channels
          if (srcType === 'xtream') {
            if (server && username && password) {
              this.log(`Téléchargement des chaînes et VOD pour « ${srcName} »…`);
              void CndEngine.getInstance()
                .syncXtreamSource(srcName, server, username, password, src.epg_url)
                .then((count) => {
                  this.log(`Chaînes de « ${srcName} » prêtes (${count} flux indexés).`);
                  this.notifyStatus();
                })
                .catch((e: any) => {
                  this.log(`Erreur téléchargement flux « ${srcName} » : ${e?.message || e}`, true);
                });
            } else if (!password) {
              this.log(`Compte Xtream « ${srcName} » enregistré, mais le mot de passe est manquant pour le direct.`, true);
            }
          } else if (srcType === 'm3u') {
            if (url) {
              this.log(`Téléchargement de la playlist « ${srcName} »…`);
              void CndEngine.getInstance()
                .syncM3uSource(srcName, url)
                .then((count) => {
                  this.log(`Playlist « ${srcName} » prête (${count} flux indexés).`);
                  this.notifyStatus();
                })
                .catch((e: any) => {
                  this.log(`Erreur téléchargement playlist « ${srcName} » : ${e?.message || e}`, true);
                });
            }
          }
        } catch (e: any) {
          this.log(`Échec enregistrement compte « ${srcName} » : ${e?.message || e}`, true);
        }
      }
      } catch (e: any) {
        this.log(`Erreur pendant l'import des comptes${fromWho} : ${e?.message || e}`, true);
      }
    }

    // 2. Favorites, removals and progress: index lookups only, and an error here is logged, not lost.
    try {

      const snapshot = this.loadFavoriteSnapshot();
      let snapshotChanged = false;

      // 1. Favorites
      const favorites = Array.isArray(delta.favorites) ? delta.favorites : [];
      for (const fav of favorites) {
        const hash = fav.stable_hash || fav.content_key;
        if (!hash) continue;
        const item = await this.db.getItemByStableHashIndexed(hash);
        if (item && item.is_favorite !== 1) {
          await this.db.toggleFavorite(item.id);
          appliedFavs++;
        }
        if (item) {
          snapshot.add(item.stable_hash);
          snapshotChanged = true;
        }
      }

      // 2. Tombstones (removals)
      const tombstones = Array.isArray(delta.tombstones) ? delta.tombstones : [];
      for (const t of tombstones) {
        if (!t || t.kind !== 'favorite' || typeof t.key !== 'string') continue;
        const contentKey = t.key.indexOf(':') >= 0 ? t.key.slice(t.key.indexOf(':') + 1) : t.key;
        const item = await this.db.getItemByStableHashIndexed(contentKey);
        if (item && item.is_favorite === 1) {
          await this.db.toggleFavorite(item.id);
          removedFavs++;
        }
        if (item) {
          snapshot.delete(item.stable_hash);
          snapshotChanged = true;
        }
      }
      if (snapshotChanged) this.saveFavoriteSnapshot(snapshot);

      // 3. Watch history / progress
      const history = Array.isArray(delta.watch_history)
        ? delta.watch_history
        : Array.isArray(delta.progress)
        ? delta.progress
        : [];
      for (const prg of history) {
        const hash = prg.stable_hash || prg.content_key;
        if (!hash) continue;
        const item = await this.db.getItemByStableHashIndexed(hash);
        if (item) {
          const pos = prg.position_ms || 0;
          const dur = prg.duration_ms || item.duration_ms || 0;
          await this.db.updateWatchProgress(item.id, pos, dur);
          appliedProgress++;
        }
      }
    } catch (e: any) {
      this.log(`Erreur pendant l'import des favoris et reprises${fromWho} : ${e?.message || e}`, true);
    }

    this.log(
      `Synchronisation appliquée${fromWho} : ${appliedFavs} favori(s), ${removedFavs} supprimé(s), ` +
      `${appliedProgress} reprise(s), ${appliedSources} compte(s) ajouté(s).`
    );
    this.notifyStatus();
  }

  /**
   * Applies an incoming SyncDelta (legacy HLC format or alternative client).
   */
  public async applyIncomingDelta(delta: any, senderId?: string): Promise<void> {
    return this.applyHouseholdDataDelta(delta, senderId);
  }
}
