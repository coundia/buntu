/**
 * CND IPTV Tizen - Unified Engine Facade (PRD 38 § 2.2 & § 7)
 *
 * Single point of entry for the UI:
 * Coordinates Network (1-conn queue), Web Worker (wasm domain logic),
 * Storage (IndexedDB/wa-sqlite), and AVPlayerService.
 */

import { Database, ItemRecord, SourceRecord } from '../storage/Database';
import { HttpClient } from '../net/HttpClient';
import { AVPlayerService } from '../player/AVPlayerService';
import { WorkerBridge } from '../../worker/worker-bridge';

export interface ProfileState {
  id: number;
  name: string;
  isKids: boolean;
  avatar: string;
}

export class CndEngine {
  private static instance: CndEngine;
  private db = Database.getInstance();
  private net = HttpClient.getInstance();
  private player = AVPlayerService.getInstance();
  private worker = WorkerBridge.getInstance();

  private activeProfile: ProfileState = {
    id: 1,
    name: 'Défaut',
    isKids: false,
    avatar: 'tv',
  };
  private isAdultUnlocked = false;
  private currentPlayingItem: ItemRecord | null = null;

  public static getInstance(): CndEngine {
    if (!CndEngine.instance) {
      CndEngine.instance = new CndEngine();
    }
    return CndEngine.instance;
  }

  public async init(): Promise<void> {
    await this.db.init();
    this.worker.init();
    console.log('[CndEngine] Initialized');
  }

  public getActiveProfile(): ProfileState {
    return this.activeProfile;
  }

  public setProfile(profile: ProfileState) {
    this.activeProfile = profile;
    this.isAdultUnlocked = false;
  }

  public unlockAdult(pin: string): boolean {
    if (pin === '0000' || pin === '1234') {
      this.isAdultUnlocked = true;
      return true;
    }
    return false;
  }

  /**
   * Source Synchronization.
   */
  public async syncM3uSource(name: string, url: string, onProgress?: (msg: string) => void): Promise<number> {
    onProgress?.('Téléchargement de la liste M3U...');
    const resp = await this.net.get<string>(url, {}, 'text');

    onProgress?.('Analyse WebAssembly ultra-rapide...');
    const uuid = 'src_' + Date.now();
    const { header, items } = await this.worker.parseM3uChunk(resp.data, uuid);

    onProgress?.(`Enregistrement de ${items.length} éléments en base...`);
    const sourceId = await this.db.insertSource({
      uuid,
      name,
      source_type: 'm3u',
      url,
      epg_url: header.epg_url,
      item_count: items.length,
      last_sync_at: Date.now(),
    });

    const itemRecords: Omit<ItemRecord, 'id'>[] = items.map((it) => ({
      source_id: sourceId,
      stable_hash: it.stable_hash,
      kind: it.kind as any,
      name: it.name,
      name_clean: it.name_clean,
      year: it.year,
      group_title: it.group_title,
      tvg_id: it.tvg_id,
      tvg_name: it.tvg_name,
      logo_url: it.logo_url,
      chno: it.chno,
      country: it.country,
      language: it.language,
      catchup_type: it.catchup_type,
      catchup_days: it.catchup_days,
      stream_url: it.stream_url,
      container_ext: it.container_ext,
      is_favorite: 0,
      season_num: it.series_info?.season_num,
      episode_num: it.series_info?.episode_num,
      playback_position_ms: 0,
      duration_ms: 0,
      imdb_rating: it.imdb_rating,
      plot: it.plot,
    }));

    await this.db.insertItemsBatch(itemRecords);
    onProgress?.('Synchronisation terminée !');
    return items.length;
  }

  /**
   * Catalog Queries.
   */
  public async getCatalog(
    kind: 'live' | 'movie' | 'series',
    groupTitle?: string,
    offset = 0,
    limit = 60
  ): Promise<ItemRecord[]> {
    const items = await this.db.getItemsByKindAndGroup(kind, groupTitle, offset, limit);

    // Apply adult & kids filter
    const filtered: ItemRecord[] = [];
    for (const item of items) {
      if (this.activeProfile.isKids) {
        // Only youth categories in kids profile
        const isAdult = await this.worker.isAdultCategory(item.group_title || '');
        if (isAdult) continue;
      } else if (!this.isAdultUnlocked) {
        const isAdult = await this.worker.isAdultCategory(item.group_title || '');
        if (isAdult) continue;
      }
      filtered.push(item);
    }
    return filtered;
  }

  public async getCategories(kind: 'live' | 'movie' | 'series'): Promise<string[]> {
    const rawCategories = await this.db.getCategories(kind);
    const result: string[] = [];
    for (const cat of rawCategories) {
      const isAdult = await this.worker.isAdultCategory(cat);
      if (this.activeProfile.isKids && isAdult) continue;
      if (!this.isAdultUnlocked && isAdult) continue;
      result.push(cat);
    }
    return result;
  }

  public async getFavorites(): Promise<ItemRecord[]> {
    return this.db.getFavorites();
  }

  public async toggleFavorite(itemId: number): Promise<boolean> {
    return this.db.toggleFavorite(itemId);
  }

  /**
   * Playback.
   */
  public async play(item: ItemRecord): Promise<void> {
    this.currentPlayingItem = item;
    const isLive = item.kind === 'live';

    // 1-conn rule: resolve final address once to stay in the same supplier session
    let streamUrl = item.stream_url;
    if (!isLive) {
      try {
        streamUrl = await this.net.resolveFinalUrl(item.stream_url);
      } catch (err) {
        console.warn('Final URL resolution fallback to raw:', err);
      }
    }

    await this.player.open(streamUrl, isLive);
    this.player.play();
  }

  public getCurrentPlayingItem(): ItemRecord | null {
    return this.currentPlayingItem;
  }

  /**
   * Search.
   */
  public async search(rawQuery: string): Promise<any[]> {
    if (!rawQuery.trim()) return [];

    const parsedQuery = await this.worker.parseSearchQuery(rawQuery, Date.now() / 1000, new Date().getTimezoneOffset());
    const candidates = await this.db.getItemsByKindAndGroup('movie', undefined, 0, 100);
    const searchCandidates = candidates.map((c) => ({
      id: c.id,
      name: c.name,
      name_clean: c.name_clean,
      kind: c.kind,
      group_title: c.group_title,
      year: c.year,
      is_favorite: c.is_favorite === 1,
      logo_url: c.logo_url,
    }));

    return this.worker.rankSearch(parsedQuery, searchCandidates);
  }
}
