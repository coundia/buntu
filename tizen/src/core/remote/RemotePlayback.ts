/**
 * Remote Playback Coordinator for Samsung Tizen ("Lire sur...", PRD-42).
 *
 * Two-phase handoff (target side), single-stream rule (release_stream), remote control and state reports.
 *
 * Safe by default: a request is refused unless this TV is free, the content exists here and belongs to
 * the announced account, the active profile (Kids) allows it and the access policy allows it. A running
 * playback is never replaced without the user's answer (`onPrompt`); with no prompt handler it is refused.
 *
 * The rules mirror `cnd-domain::remote::handoff` (Rust), whose state machine is not exported to WebAssembly
 * yet: keep both in line with the Rust tests.
 */

import { Database, ItemRecord, SourceRecord } from '../storage/Database';
import { HouseholdStore } from '../sync/HouseholdStore';
import { LocalSyncService, RemotePlayEvent } from '../sync/LocalSyncService';
import { AVPlayerService } from '../player/AVPlayerService';
import { CndEngine } from '../engine/CndEngine';
import { WorkerBridge } from '../../worker/worker-bridge';

export type PlayRefuseReason =
  | 'unknown_content'
  | 'source_missing'
  | 'busy'
  | 'kids_restricted'
  | 'declined_by_user'
  | 'not_allowed'
  | 'app_not_ready'
  | 'rate_limited';

export type RemoteAccessPolicy = 'open' | 'always_ask' | 'disabled';

const RESERVATION_TTL_MS = 10_000;
const MIN_REQUEST_INTERVAL_MS = 2_000;
/** The player needs a moment to open: do not take "not active yet" for "stopped". */
const START_GRACE_MS = 10_000;

interface Reservation {
  requestId: string;
  item: ItemRecord;
  sourceKey: string | null;
  senderId: string;
  reservedAt: number;
}

export class RemotePlaybackCoordinator {
  private static instance: RemotePlaybackCoordinator;

  private store = HouseholdStore.getInstance();
  private localSync = LocalSyncService.getInstance();
  private db = Database.getInstance();
  private avplayer = AVPlayerService.getInstance();
  private bridge = WorkerBridge.getInstance();

  private reservation: Reservation | null = null;
  private lastRequestAt = new Map<string, number>();
  private sourceKeyCache = new Map<number, string>();

  private playingContentKey: string | null = null;
  private playingSourceKey: string | null = null;
  private playingTitle: string | null = null;
  private playingSince = 0;
  /** Device that started the playback remotely: the only one that receives the 1 s state reports. */
  private stateSubscriberId: string | null = null;
  private stateTimer: ReturnType<typeof setInterval> | null = null;
  private unsubscribe: (() => void) | null = null;

  /** Who may start a playback on this TV (PRD-42 § 5.3). */
  public accessPolicy: RemoteAccessPolicy = 'open';

  /** Opens the item in the app (full screen player), resuming at `item.playback_position_ms`. */
  public onPlayItem?: (item: ItemRecord, positionMs: number) => Promise<void>;
  /** Ch+/Ch- asked from a phone. */
  public onZap?: (direction: 'next' | 'prev') => void;
  /** Asks the person in front of the TV. Without it, anything that needs an answer is refused. */
  public onPrompt?: (title: string | undefined, senderName: string, answer: (accepted: boolean) => void) => void;
  public onRemoteLaunchNotice?: (title: string, senderName: string) => void;
  public onStreamStoppedByAnotherDevice?: (sourceKey: string) => void;

  public static getInstance(): RemotePlaybackCoordinator {
    if (!RemotePlaybackCoordinator.instance) {
      RemotePlaybackCoordinator.instance = new RemotePlaybackCoordinator();
    }
    return RemotePlaybackCoordinator.instance;
  }

  public init(): void {
    if (this.unsubscribe) return;
    this.unsubscribe = this.localSync.onGenericMessage((msg, senderId) => {
      void this.handleIncomingMessage(msg, senderId);
    });
    // Detects that the playback ended or was stopped from the TV itself.
    setInterval(() => this.checkStillPlaying(), 1000);
  }

  /** The app started playing `item` (any way: remote or not). */
  public setLocalPlaying(item: ItemRecord | null): void {
    if (!item) {
      this.clearPlaying(true);
      return;
    }
    this.playingContentKey = item.stable_hash;
    this.playingTitle = item.name;
    this.playingSourceKey = null;
    this.playingSince = Date.now();
    void this.sourceKeyOf(item).then((k) => {
      if (this.playingContentKey === item.stable_hash) this.playingSourceKey = k;
    });
    if (this.stateSubscriberId) this.startStateTimer();
  }

  /** Deprecated PRD-41 `play_remote` (no negotiation): same safety checks, never replaces a playback. */
  public async playLegacyRequest(event: RemotePlayEvent, senderName = 'Un appareil du foyer'): Promise<void> {
    if (this.accessPolicy !== 'open' || this.isPlayingHere()) return;
    const item = await this.resolveItem(event.content_key, event.source_key ?? null);
    if (!item || !(await this.isAllowedForProfile(item))) return;
    await this.startPlayback(item, event.position_ms || 0, senderName);
  }

  // --------------------------------------------------------------------------
  // Incoming messages
  // --------------------------------------------------------------------------

  private async handleIncomingMessage(msg: any, senderId: string): Promise<void> {
    if (!msg || !msg.type) return;
    const localId = this.store.getLocalDeviceId();
    const forMe = msg.target_device_id === localId;

    switch (msg.type) {
      case 'play_request':
        if (forMe) await this.handlePlayRequest(msg, senderId);
        break;
      case 'play_go':
        await this.handlePlayGo(msg);
        break;
      case 'playback_control':
        if (forMe) this.handlePlaybackControl(msg);
        break;
      case 'release_stream':
        this.handleReleaseStream(msg.source_key);
        break;
      case 'release_request':
        if (forMe) await this.handleReleaseRequest(msg.request_id);
        break;
    }
  }

  private async handlePlayRequest(msg: any, senderId: string): Promise<void> {
    const requestId: string = msg.request_id;
    if (!requestId) return;
    const now = Date.now();

    // Rate limit: 1 request every 2 s per sender (PRD-42 § 5.2)
    const last = this.lastRequestAt.get(senderId) || 0;
    if (now - last < MIN_REQUEST_INTERVAL_MS) {
      await this.refuse(requestId, 'rate_limited');
      return;
    }
    this.lastRequestAt.set(senderId, now);

    if (this.accessPolicy === 'disabled') {
      await this.refuse(requestId, 'not_allowed');
      return;
    }

    // Another handoff is waiting for its play_go: do not steal it.
    if (this.reservation && this.reservation.requestId !== requestId && now - this.reservation.reservedAt <= RESERVATION_TTL_MS) {
      await this.refuse(requestId, 'busy');
      return;
    }

    const sourceKey: string | null = msg.source_key || null;
    const item = await this.resolveItem(
      msg.content_key,
      sourceKey,
      msg.provider_ref,
      msg.item_kind,
      msg.title,
      msg.container_ext
    );
    if (!item) {
      await this.refuse(requestId, 'unknown_content');
      return;
    }

    if (!(await this.isAllowedForProfile(item))) {
      await this.refuse(requestId, 'kids_restricted');
      return;
    }

    const playingHere = this.isPlayingHere();
    const senderName = this.store.getPairedDevices().find((d) => d.device_id === senderId)?.device_name || 'Un appareil du foyer';

    if (this.accessPolicy === 'always_ask') {
      if (!this.onPrompt) {
        await this.refuse(requestId, playingHere ? 'busy' : 'not_allowed');
        return;
      }
      this.onPrompt(msg.title, senderName, (accepted) => {
        if (accepted) void this.reserve(requestId, item, sourceKey, senderId);
        else void this.refuse(requestId, 'declined_by_user');
      });
      return;
    }

    // Default policy is 'open': replacement without confirmation in the household (PRD-45 § 1.1 & § 3.3)
    await this.reserve(requestId, item, sourceKey, senderId);
  }

  private async reserve(requestId: string, item: ItemRecord, sourceKey: string | null, senderId: string): Promise<void> {
    this.reservation = { requestId, item, sourceKey, senderId, reservedAt: Date.now() };
    await this.localSync.sendMessage({ type: 'play_ready', request_id: requestId });
  }

  private async handlePlayGo(msg: any): Promise<void> {
    const held = this.reservation;
    if (!held || held.requestId !== msg.request_id) return;
    this.reservation = null;
    if (Date.now() - held.reservedAt > RESERVATION_TTL_MS) return; // the origin had given up

    // Stop current stream if active (PRD-45 § 3.3)
    this.stopHere();

    // Everybody else stops streaming THIS account (PRD-42 § 3.4): the incoming key, not the previous one.
    const sourceKey = held.sourceKey || (await this.sourceKeyOf(held.item));
    if (sourceKey) {
      await this.localSync.sendMessage({ type: 'release_stream', source_key: sourceKey });
    }

    this.stateSubscriberId = held.senderId;
    const senderName = this.store.getPairedDevices().find((d) => d.device_id === held.senderId)?.device_name || 'un autre appareil';
    await this.startPlayback(held.item, typeof msg.position_ms === 'number' ? msg.position_ms : 0, senderName);
  }

  private async startPlayback(item: ItemRecord, positionMs: number, senderName: string): Promise<void> {
    if (!this.onPlayItem) return;
    if (positionMs > 0) item.playback_position_ms = positionMs;
    // Goes through the app's own path (full screen player, history, progress): opening AVPlay directly
    // left the screen without a player view, hence no picture.
    await this.onPlayItem(item, positionMs);
    this.onRemoteLaunchNotice?.(item.name, senderName);
  }

  private handlePlaybackControl(msg: any): void {
    const val = msg.value;
    switch (msg.action) {
      case 'pause':
        this.avplayer.pause();
        break;
      case 'resume':
        this.avplayer.play();
        break;
      case 'seek_to':
        if (typeof val === 'number') this.avplayer.seekTo(Math.max(0, val));
        break;
      case 'seek_by':
        if (typeof val === 'number') this.avplayer.seekTo(Math.max(0, this.avplayer.getCurrentTime() + val));
        break;
      case 'channel_up':
        this.onZap?.('next');
        break;
      case 'channel_down':
        this.onZap?.('prev');
        break;
      case 'stop':
        this.stopHere();
        break;
    }
  }

  private handleReleaseStream(incomingSourceKey: string): void {
    if (!this.playingSourceKey || !incomingSourceKey) return;
    if (this.playingSourceKey.trim().toLowerCase() === incomingSourceKey.trim().toLowerCase()) {
      this.stopHere();
      this.onStreamStoppedByAnotherDevice?.(incomingSourceKey);
    }
  }

  private async handleReleaseRequest(requestId: string): Promise<void> {
    if (!requestId) return;
    // Measured position first, then stop.
    const position = Math.max(0, this.avplayer.getCurrentTime());
    const contentKey = this.playingContentKey;
    this.stopHere();
    await this.localSync.sendMessage({
      type: 'release_done',
      request_id: requestId,
      content_key: contentKey,
      position_ms: position,
    });
  }

  private stopHere(): void {
    CndEngine.getInstance().stopPlayback();
    this.clearPlaying(true);
  }

  private async refuse(requestId: string, reason: PlayRefuseReason): Promise<void> {
    await this.localSync.sendMessage({ type: 'play_refused', request_id: requestId, reason });
  }

  // --------------------------------------------------------------------------
  // Content resolution & profile rules
  // --------------------------------------------------------------------------

  /**
   * Finds the requested item on this TV. The `content_key` of an Apple or Android device is ITS item hash
   * (`blake3(<account uuid>:xtream_live:<id>)`), never the TV's: the TV finds it by the provider's stream
   * id (`provider_ref`) in the account named by `source_key`, like `cnd-core::item_by_content_key` does.
   *
   * The TV stores an Xtream item as `<source id>_live_<id>` / `<source id>_vod_<id>`
   * (`Database.insertItemsBatch`), so the lookup is made per account, by index. When the catalog does not
   * hold it (episodes are never stored, playlist read through `get.php`, catalog still downloading), the
   * Xtream address is rebuilt from the account (PRD-42 § 6.2, rule in Rust). The full scan of 65 000 items
   * took longer than the 5 s the origin waits: it is kept for M3U accounts only, limited to that account.
   */
  private async resolveItem(
    contentKey: string,
    sourceKey: string | null,
    providerRef?: string | null,
    itemKind?: string | null,
    title?: string | null,
    containerExt?: string | null
  ): Promise<ItemRecord | null> {
    if (!contentKey && !providerRef) return null;
    let item = contentKey ? await this.db.getItemByStableHashIndexed(contentKey) : null;

    const ref = typeof providerRef === 'string' ? providerRef.trim() : '';
    if (!item && ref && /^[A-Za-z0-9_-]{1,40}$/.test(ref)) {
      const kind = RemotePlaybackCoordinator.normalizeKind(itemKind);
      const prefixes = kind === 'live' ? ['live_'] : kind === 'movie' ? ['vod_'] : kind === 'episode' ? [] : ['live_', 'vod_'];
      const accounts = await this.accountsFor(sourceKey);

      for (const account of accounts) {
        for (const prefix of prefixes) {
          item = await this.db.getItemByStableHashIndexed(`${account.id}_${prefix}${ref}`);
          if (item) break;
        }
        if (item) break;
      }
      // Catalogs saved before the `<source id>_` prefix.
      if (!item) {
        for (const prefix of prefixes) {
          item = await this.db.getItemByStableHashIndexed(prefix + ref);
          if (item) break;
        }
      }
      if (!item) item = await this.rebuildXtreamItem(accounts, !!sourceKey, kind, ref, title, containerExt);
      if (!item) {
        for (const account of accounts) {
          if (account.source_type !== 'm3u') continue;
          item = await this.db.findItemByStreamRef(account.id, ref, kind === 'unknown' ? null : kind);
          if (item) break;
        }
      }
    }
    // Old senders without `provider_ref` (legacy `live_<id>` suffix keys): the slow scan, as before.
    if (!item && contentKey && !ref) item = await this.db.getItemByStableHash(contentKey);
    if (!item) return null;
    // `getItemByStableHash` also accepts suffix matches (legacy `live_<id>` keys): when the origin names the
    // account, make sure the item really belongs to it, or the wrong content could play.
    if (sourceKey) {
      const itemSource = await this.sourceKeyOf(item);
      if (itemSource && itemSource.toLowerCase() !== sourceKey.trim().toLowerCase()) return null;
    }
    return item;
  }

  private static normalizeKind(itemKind?: string | null): 'live' | 'movie' | 'episode' | 'unknown' {
    const kind = String(itemKind || '').trim().toLowerCase();
    if (kind === 'live') return 'live';
    if (kind === 'movie' || kind === 'vod') return 'movie';
    if (kind === 'episode') return 'episode';
    return 'unknown';
  }

  /** Accounts of this TV named by `source_key`; every account when the origin did not name one. */
  private async accountsFor(sourceKey: string | null): Promise<SourceRecord[]> {
    let sources: SourceRecord[] = [];
    try {
      sources = await this.db.getSources();
    } catch {
      return [];
    }
    const wanted = (sourceKey || '').trim().toLowerCase();
    if (!wanted) return sources;
    const matching: SourceRecord[] = [];
    for (const source of sources) {
      const key = await this.sourceKeyOfSource(source);
      if (key && key.toLowerCase() === wanted) matching.push(source);
    }
    return matching;
  }

  /**
   * The item is not in this TV's catalog: an Xtream account is enough to play it, its address follows a
   * fixed pattern (`cnd-domain::remote::resolve::reconstruct_xtream_url`). It needs the account named by
   * the origin, or a single Xtream account here: never a guess among several (the same id exists in each).
   */
  private async rebuildXtreamItem(
    accounts: SourceRecord[],
    accountNamed: boolean,
    kind: 'live' | 'movie' | 'episode' | 'unknown',
    ref: string,
    title?: string | null,
    containerExt?: string | null
  ): Promise<ItemRecord | null> {
    if (kind === 'unknown') return null;
    const xtream = accounts.filter((a) => a.source_type === 'xtream' && a.server && a.username && a.password);
    // Several records of the SAME named account (added twice) are equivalent; unnamed, it must be unique.
    if (xtream.length === 0 || (!accountNamed && xtream.length > 1)) return null;
    const account = xtream[0];
    const ext = typeof containerExt === 'string' && /^[A-Za-z0-9]{1,8}$/.test(containerExt.trim()) ? containerExt.trim() : null;
    let url = '';
    try {
      url = await this.bridge.post<string>('REMOTE_RECONSTRUCT_XTREAM_URL', {
        server: account.server,
        username: account.username,
        password: account.password,
        kind,
        providerRef: ref,
        containerExt: ext,
      });
    } catch {
      return null;
    }
    if (typeof url !== 'string' || !url) return null;
    const name = (typeof title === 'string' && title.trim()) || (kind === 'live' ? 'Chaîne' : 'Vidéo');
    const extOfUrl = url.slice(url.lastIndexOf('.') + 1);
    // Not a database row: a negative id that never matches one, the same for the same stream (zapping and
    // "already playing" compare ids), and never written to the recents (`CndEngine.recordRecent`).
    const numeric = /^[0-9]{1,15}$/.test(ref) ? Number(ref) : 0;
    return {
      id: numeric > 0 ? -numeric : -1 - Math.floor(Math.random() * 1e9),
      source_id: account.id,
      stable_hash: `${account.id}_${kind === 'live' ? 'live' : kind === 'movie' ? 'vod' : 'episode'}_${ref}`,
      kind,
      name,
      name_clean: name,
      stream_url: url,
      container_ext: extOfUrl,
      is_favorite: 0,
      playback_position_ms: 0,
      duration_ms: 0,
    };
  }

  private async isAllowedForProfile(item: ItemRecord): Promise<boolean> {
    const engine = CndEngine.getInstance();
    // A rebuilt item (negative id) has no category to check: never on a Kids profile.
    if (item.id < 0 && engine.getActiveProfile().isKids) return false;
    return engine.isItemAllowedForActiveProfile(item);
  }

  private async sourceKeyOf(item: ItemRecord): Promise<string | null> {
    const cached = this.sourceKeyCache.get(item.source_id);
    if (cached) return cached;
    try {
      const sources = await this.db.getSources();
      const source = sources.find((s) => s.id === item.source_id);
      return source ? await this.sourceKeyOfSource(source) : null;
    } catch {
      return null;
    }
  }

  /** `source_key` of an account (PRD-41 identity, computed in Rust), cached by account id. */
  private async sourceKeyOfSource(source: SourceRecord): Promise<string | null> {
    if (source.local_override) {
      const original = (await this.db.getSharedSources()).find((s) => s.id === source.id);
      if (original) source = original;
    }
    const cached = this.sourceKeyCache.get(source.id);
    if (cached) return cached;
    try {
      const isXtream = source.source_type === 'xtream';
      const key = await this.bridge.post<string>('COMPUTE_SOURCE_KEY', {
        sourceType: source.source_type,
        serverOrUrl: isXtream ? source.server || '' : source.url || '',
        username: source.username || '',
      });
      if (typeof key === 'string' && key) {
        this.sourceKeyCache.set(source.id, key);
        return key;
      }
    } catch {
      // unknown account key: the single-stream rule then cannot match, nothing else breaks
    }
    return null;
  }

  // --------------------------------------------------------------------------
  // State reports (1 s) to the device that started the playback
  // --------------------------------------------------------------------------

  private isPlayingHere(): boolean {
    return this.avplayer.isActive();
  }

  private checkStillPlaying(): void {
    if (!this.playingContentKey) return;
    if (Date.now() - this.playingSince < START_GRACE_MS) return;
    if (!this.avplayer.isActive()) this.clearPlaying(true);
  }

  private clearPlaying(report: boolean): void {
    const subscriber = this.stateSubscriberId;
    const key = this.playingContentKey;
    const title = this.playingTitle;
    this.playingContentKey = null;
    this.playingSourceKey = null;
    this.playingTitle = null;
    this.stopStateTimer();
    this.stateSubscriberId = null;
    // Tell the controller it is over: it would otherwise show a dead remote forever.
    if (report && subscriber && key) {
      void this.localSync.sendMessage({
        type: 'playback_state',
        device_id: this.store.getLocalDeviceId(),
        content_key: key,
        title: title || undefined,
        state: 'ended',
        position_ms: 0,
        duration_ms: 0,
        controls: [],
      });
    }
  }

  private startStateTimer(): void {
    this.stopStateTimer();
    this.stateTimer = setInterval(() => this.reportState(), 1000);
    this.reportState();
  }

  private stopStateTimer(): void {
    if (this.stateTimer) {
      clearInterval(this.stateTimer);
      this.stateTimer = null;
    }
  }

  private reportState(): void {
    if (!this.playingContentKey || !this.stateSubscriberId) return;
    const st = this.avplayer.getState();
    const wire = st === 'PLAYING' ? 'playing' : st === 'PAUSED' ? 'paused' : 'loading';
    void this.localSync.sendMessage({
      type: 'playback_state',
      device_id: this.store.getLocalDeviceId(),
      content_key: this.playingContentKey,
      title: this.playingTitle || undefined,
      state: wire,
      position_ms: Math.max(0, this.avplayer.getCurrentTime()),
      duration_ms: Math.max(0, this.avplayer.getDuration()),
      controls: ['pause', 'resume', 'seek_to', 'seek_by', 'stop', 'channel_up', 'channel_down'],
    });
  }
}
