/**
 * Remote Playback Coordinator for Samsung Tizen ("Lire sur...", PRD-42).
 *
 * Implements the two-phase handoff state machine, single-stream enforcement (release_stream),
 * playback control, and 1-second state broadcasts.
 */

import { Database, ItemRecord } from '../storage/Database';
import { HouseholdStore } from '../sync/HouseholdStore';
import { LocalSyncService } from '../sync/LocalSyncService';
import { AVPlayerService, PlayerState } from '../player/AVPlayerService';

export interface RemoteDevice {
  deviceId: string;
  deviceName: string;
  deviceType: string;
  canPlay: boolean;
  state: 'idle' | 'playing' | 'busy';
  lastSeenMs: number;
}

export type PlayRefuseReason =
  | 'unknown_content'
  | 'source_missing'
  | 'busy'
  | 'kids_restricted'
  | 'declined_by_user'
  | 'not_allowed'
  | 'app_not_ready'
  | 'rate_limited';

export interface PlaybackStateMsg {
  deviceId: string;
  contentKey?: string;
  title?: string;
  state: 'loading' | 'playing' | 'paused' | 'ended' | 'error';
  positionMs: number;
  durationMs: number;
  controls: string[];
}

export class RemotePlaybackCoordinator {
  private static instance: RemotePlaybackCoordinator;

  private store = HouseholdStore.getInstance();
  private localSync = LocalSyncService.getInstance();
  private db = Database.getInstance();
  private avplayer = AVPlayerService.getInstance();

  private activeReservation: {
    requestId: string;
    contentKey: string;
    sourceKey?: string;
    item: ItemRecord;
    timestamp: number;
  } | null = null;

  private currentPlayingSourceKey: string | null = null;
  private currentPlayingContentKey: string | null = null;
  private currentPlayingTitle: string | null = null;
  private stateBroadcastTimer: ReturnType<typeof setInterval> | null = null;

  public onRemoteLaunchNotice?: (title: string, senderName: string) => void;
  public onStreamStoppedByAnotherDevice?: (sourceKey: string) => void;

  public static getInstance(): RemotePlaybackCoordinator {
    if (!RemotePlaybackCoordinator.instance) {
      RemotePlaybackCoordinator.instance = new RemotePlaybackCoordinator();
    }
    return RemotePlaybackCoordinator.instance;
  }

  public init(): void {
    // Listen to incoming messages via LocalSyncService
    this.localSync.onGenericMessage((msg) => this.handleIncomingMessage(msg));
  }

  /** Current playing item tracking for single-stream rule and state emission */
  public setLocalPlaying(item: ItemRecord | null, sourceKey?: string | null): void {
    if (!item) {
      this.currentPlayingContentKey = null;
      this.currentPlayingSourceKey = null;
      this.currentPlayingTitle = null;
      this.stopStateBroadcast();
      return;
    }

    this.currentPlayingContentKey = item.stable_hash;
    this.currentPlayingSourceKey = sourceKey || (item as any).source_key || null;
    this.currentPlayingTitle = item.name;
    this.startStateBroadcast();
  }

  // --------------------------------------------------------------------------
  // Message Handling
  // --------------------------------------------------------------------------

  private async handleIncomingMessage(msg: any): Promise<void> {
    if (!msg || !msg.type) return;

    const localDeviceId = this.store.getLocalDeviceId();

    switch (msg.type) {
      case 'play_request': {
        if (msg.target_device_id && msg.target_device_id !== localDeviceId) {
          return;
        }
        await this.handlePlayRequest(msg);
        break;
      }

      case 'play_go': {
        await this.handlePlayGo(msg);
        break;
      }

      case 'playback_control': {
        if (msg.target_device_id && msg.target_device_id !== localDeviceId) {
          return;
        }
        this.handlePlaybackControl(msg);
        break;
      }

      case 'release_stream': {
        this.handleReleaseStream(msg.source_key);
        break;
      }

      case 'release_request': {
        if (msg.target_device_id && msg.target_device_id !== localDeviceId) {
          return;
        }
        await this.handleReleaseRequest(msg.request_id);
        break;
      }
    }
  }

  private async handlePlayRequest(msg: any): Promise<void> {
    const requestId = msg.request_id;
    const contentKey = msg.content_key;
    const sourceKey = msg.source_key;
    const positionMs = msg.position_ms || 0;

    // 1. Resolve item
    let item = await this.db.getItemByStableHash(contentKey);
    if (!item && msg.provider_ref && sourceKey) {
      // Reconstruct Xtream item
      const sources = await this.db.getSources();
      const match = sources.find((s) => (s as any).source_key === sourceKey || s.server);
      if (match && match.server && match.username && (match as any).password) {
        const streamUrl = `${match.server.replace(/\/$/, '')}/live/${match.username}/${(match as any).password}/${msg.provider_ref}.ts`;
        item = {
          id: 0,
          source_id: match.id,
          stable_hash: contentKey,
          kind: (msg.item_kind as any) || 'live',
          name: msg.title || `Canal ${msg.provider_ref}`,
          name_clean: msg.title || `Canal ${msg.provider_ref}`,
          stream_url: streamUrl,
          is_favorite: 0,
          playback_position_ms: 0,
          duration_ms: 0,
        };
      }
    }

    if (!item) {
      await this.sendRefused(requestId, 'unknown_content');
      return;
    }

    // 2. Reserve
    this.activeReservation = {
      requestId,
      contentKey,
      sourceKey,
      item,
      timestamp: Date.now(),
    };

    // 3. Reply PlayReady
    await this.localSync.sendMessage({
      type: 'play_ready',
      request_id: requestId,
    });
  }

  private async handlePlayGo(msg: any): Promise<void> {
    if (!this.activeReservation || this.activeReservation.requestId !== msg.request_id) {
      return;
    }

    const { item, sourceKey } = this.activeReservation;
    this.activeReservation = null;

    // Step 4: Broadcast release_stream so no other device streams this account (PRD-42 § 3.4)
    if (sourceKey) {
      await this.localSync.sendMessage({
        type: 'release_stream',
        source_key: sourceKey,
      });
    }

    // Launch player at position
    if (msg.position_ms > 0) {
      item.playback_position_ms = msg.position_ms;
    }

    this.setLocalPlaying(item, sourceKey);
    await this.avplayer.open(item.stream_url, item.kind === 'live');
    this.avplayer.play();
    if (msg.position_ms > 0) {
      this.avplayer.seekTo(msg.position_ms);
    }

    this.onRemoteLaunchNotice?.(item.name, 'un autre appareil');
  }

  private handlePlaybackControl(msg: any): void {
    const action = msg.action;
    const val = msg.value;

    switch (action) {
      case 'pause':
        this.avplayer.pause();
        break;
      case 'resume':
        this.avplayer.play();
        break;
      case 'seek_to':
        if (typeof val === 'number') this.avplayer.seekTo(val);
        break;
      case 'seek_by':
        if (typeof val === 'number') {
          const cur = this.avplayer.getCurrentTime();
          this.avplayer.seekTo(Math.max(0, cur + val));
        }
        break;
      case 'stop':
        this.avplayer.stop();
        this.setLocalPlaying(null);
        break;
    }
  }

  private handleReleaseStream(incomingSourceKey: string): void {
    if (!this.currentPlayingSourceKey || !incomingSourceKey) return;

    if (this.currentPlayingSourceKey.trim().toLowerCase() === incomingSourceKey.trim().toLowerCase()) {
      console.warn('[RemotePlayback] release_stream received for current account: stopping local playback');
      this.avplayer.stop();
      this.setLocalPlaying(null);
      this.onStreamStoppedByAnotherDevice?.(incomingSourceKey);
    }
  }

  private async handleReleaseRequest(requestId: string): Promise<void> {
    const pos = this.avplayer.getCurrentTime();
    const cKey = this.currentPlayingContentKey;

    this.avplayer.stop();
    this.setLocalPlaying(null);

    await this.localSync.sendMessage({
      type: 'release_done',
      request_id: requestId,
      content_key: cKey,
      position_ms: Math.max(0, pos),
    });
  }

  private async sendRefused(requestId: string, reason: PlayRefuseReason): Promise<void> {
    await this.localSync.sendMessage({
      type: 'play_refused',
      request_id: requestId,
      reason,
    });
  }

  // --------------------------------------------------------------------------
  // Periodic 1-second Playback State Broadcast (PRD-42 § 3.1)
  // --------------------------------------------------------------------------

  private startStateBroadcast(): void {
    this.stopStateBroadcast();
    this.stateBroadcastTimer = setInterval(() => {
      this.broadcastPlaybackState();
    }, 1000);
    this.broadcastPlaybackState();
  }

  private stopStateBroadcast(): void {
    if (this.stateBroadcastTimer) {
      clearInterval(this.stateBroadcastTimer);
      this.stateBroadcastTimer = null;
    }
  }

  private broadcastPlaybackState(): void {
    if (!this.currentPlayingContentKey) return;

    const state = this.avplayer.getState();
    const isPlaying = state === 'PLAYING';
    const isPaused = state === 'PAUSED';

    const wireState = isPlaying ? 'playing' : isPaused ? 'paused' : 'loading';

    void this.localSync.sendMessage({
      type: 'playback_state',
      device_id: this.store.getLocalDeviceId(),
      content_key: this.currentPlayingContentKey,
      title: this.currentPlayingTitle || undefined,
      state: wireState,
      position_ms: Math.max(0, this.avplayer.getCurrentTime()),
      duration_ms: Math.max(0, this.avplayer.getDuration()),
      controls: ['pause', 'resume', 'seek_to', 'seek_by', 'stop'],
    });
  }
}
