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

export type SyncProgressCallback = (msg: string, percent?: number) => void;

function cleanYearFromTitle(rawName: string): { clean: string; year?: number } {
  const m = rawName.match(/[\(\[\s]((?:19|20)\d{2})[\)\]]?\s*$/);
  if (m) {
    const yr = parseInt(m[1], 10);
    const stripped = rawName.slice(0, m.index).replace(/[-–—\s]+$/, '').trim();
    return { clean: stripped || rawName.trim(), year: yr };
  }
  return { clean: rawName.trim() };
}

export class CndEngine {
  private static instance: CndEngine;
  private db = Database.getInstance();
  private net = HttpClient.getInstance();
  private player = AVPlayerService.getInstance();
  private worker = WorkerBridge.getInstance();
  private adultCategoryCache = new Map<string, boolean>();

  private activeProfile: ProfileState = {
    id: 1,
    name: 'Défaut',
    isKids: false,
    avatar: 'tv',
  };
  private isAdultUnlocked = false;
  private currentPlayingItem: ItemRecord | null = null;
  private playToken = 0;
  private categoriesMemCache = new Map<string, string[]>();

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
    this.categoriesMemCache.clear();
  }

  public unlockAdult(pin: string): boolean {
    if (pin === '0000' || pin === '1234') {
      this.isAdultUnlocked = true;
      this.categoriesMemCache.clear();
      return true;
    }
    return false;
  }

  /**
   * Source Synchronization.
   */
  public async syncM3uSource(name: string, url: string, onProgress?: SyncProgressCallback): Promise<number> {
    return this.syncPlaylist({ name, url, sourceType: 'm3u' }, onProgress);
  }

  /**
   * Synchronises an Xtream Codes account via the fast JSON API (`/player_api.php`) sequentially
   * (strictly 1 connection at a time), falling back to `/get.php` M3U only if the JSON API is absent.
   */
  public async syncXtreamSource(
    name: string,
    server: string,
    username: string,
    password: string,
    epgUrl?: string,
    onProgress?: SyncProgressCallback
  ): Promise<number> {
    const base = server.trim().replace(/\/+$/, '');
    const u = encodeURIComponent(username.trim());
    const p = encodeURIComponent(password);
    const apiBase = `${base}/player_api.php?username=${u}&password=${p}`;

    onProgress?.('Vérification du compte Xtream…', 5);
    let authData: any = null;
    try {
      const authResp = await this.net.get<any>(apiBase, {}, 'json');
      authData = authResp.data;
    } catch (err: any) {
      const msg = String(err?.message || '');
      if (msg.includes('401') || msg.includes('403') || msg.includes('Identifiants')) {
        throw err;
      }
      // Provider may only expose M3U `/get.php`
      const fallbackUrl = `${base}/get.php?username=${u}&password=${p}&type=m3u_plus&output=ts`;
      return this.syncPlaylist(
        { name, url: fallbackUrl, sourceType: 'xtream', server: base, username: username.trim(), password, epgUrl },
        onProgress
      );
    }

    const userInfo = authData?.user_info;
    if (userInfo && (userInfo.auth === 0 || userInfo.auth === '0' || String(userInfo.status || '').toLowerCase() === 'expired')) {
      throw new Error('Identifiants Xtream invalides ou abonnement expiré.');
    }

    const fetchCategoryMap = async (action: string): Promise<Map<string, string>> => {
      const map = new Map<string, string>();
      try {
        const res = await this.net.get<any[]>(`${apiBase}&action=${action}`, {}, 'json');
        if (Array.isArray(res.data)) {
          for (const c of res.data) {
            if (c?.category_id != null && c?.category_name) {
              map.set(String(c.category_id), String(c.category_name).trim());
            }
          }
        }
      } catch {
        /* non-fatal if categories endpoint is empty */
      }
      return map;
    };

    const fetchList = async (action: string): Promise<any[]> => {
      try {
        const res = await this.net.get<any[]>(`${apiBase}&action=${action}`, {}, 'json');
        return Array.isArray(res.data) ? res.data : [];
      } catch {
        return [];
      }
    };

    onProgress?.('Téléchargement des chaînes en direct…', 18);
    const liveCats = await fetchCategoryMap('get_live_categories');
    const liveStreams = await fetchList('get_live_streams');

    onProgress?.(`Téléchargement des films VOD (${liveStreams.length} chaînes reçues)…`, 42);
    const vodCats = await fetchCategoryMap('get_vod_categories');
    const vodStreams = await fetchList('get_vod_streams');

    onProgress?.(`Téléchargement des séries (${vodStreams.length} films reçus)…`, 64);
    const seriesCats = await fetchCategoryMap('get_series_categories');
    const seriesEntries = await fetchList('get_series');

    const totalCount = liveStreams.length + vodStreams.length + seriesEntries.length;
    if (totalCount === 0) {
      // Fallback to /get.php in case JSON lists were disabled on panel
      const fallbackUrl = `${base}/get.php?username=${u}&password=${p}&type=m3u_plus&output=ts`;
      return this.syncPlaylist(
        { name, url: fallbackUrl, sourceType: 'xtream', server: base, username: username.trim(), password, epgUrl },
        onProgress
      );
    }

    onProgress?.(`Préparation de ${totalCount} contenus…`, 76);
    const uuid = 'src_' + Date.now();
    const resolvedEpgUrl = epgUrl || `${base}/xmltv.php?username=${u}&password=${p}`;
    const expDate = userInfo?.exp_date ? Number(userInfo.exp_date) || undefined : undefined;
    const maxConnections = userInfo?.max_connections ? Number(userInfo.max_connections) || undefined : undefined;
    const activeCons = userInfo?.active_cons != null ? Number(userInfo.active_cons) || 0 : undefined;

    const sourceId = await this.db.insertSource({
      uuid,
      name,
      source_type: 'xtream',
      server: base,
      username: username.trim(),
      password,
      epg_url: resolvedEpgUrl,
      exp_date: expDate,
      max_connections: maxConnections,
      active_cons: activeCons,
      item_count: totalCount,
      last_sync_at: Date.now(),
    });

    const itemRecords: Omit<ItemRecord, 'id'>[] = [];

    for (let i = 0; i < liveStreams.length; i++) {
      const s = liveStreams[i];
      const streamId = String(s?.stream_id ?? '').trim();
      if (!streamId) continue;
      const rawName = String(s?.name || `Chaîne ${i + 1}`).trim();
      const catName = liveCats.get(String(s?.category_id ?? '')) || 'Direct';
      const archiveDays = Number(s?.tv_archive) > 0 ? Number(s?.tv_archive_duration) || undefined : undefined;
      itemRecords.push({
        source_id: sourceId,
        stable_hash: `live_${streamId}`,
        kind: 'live',
        name: rawName,
        name_clean: rawName,
        group_title: catName,
        tvg_id: s?.epg_channel_id ? String(s.epg_channel_id) : undefined,
        tvg_name: rawName,
        logo_url: s?.stream_icon ? String(s.stream_icon) : undefined,
        chno: s?.num ? Number(s.num) || undefined : i + 1,
        catchup_type: archiveDays ? 'xtream' : undefined,
        catchup_days: archiveDays,
        stream_url: `${base}/live/${u}/${p}/${streamId}.ts`,
        container_ext: 'ts',
        is_favorite: 0,
        playback_position_ms: 0,
        duration_ms: 0,
      });
    }

    for (let i = 0; i < vodStreams.length; i++) {
      const s = vodStreams[i];
      const streamId = String(s?.stream_id ?? '').trim();
      if (!streamId) continue;
      const rawName = String(s?.name || `Film ${i + 1}`).trim();
      const { clean, year } = cleanYearFromTitle(rawName);
      const catName = vodCats.get(String(s?.category_id ?? '')) || 'Films';
      const ext = String(s?.container_extension || 'mp4').replace(/^\.+/, '') || 'mp4';
      const ratingRaw = s?.rating != null ? Number(s.rating) : s?.rating_5based != null ? Number(s.rating_5based) * 2 : NaN;
      itemRecords.push({
        source_id: sourceId,
        stable_hash: `vod_${streamId}`,
        kind: 'movie',
        name: rawName,
        name_clean: clean,
        year,
        group_title: catName,
        logo_url: s?.stream_icon ? String(s.stream_icon) : undefined,
        stream_url: `${base}/movie/${u}/${p}/${streamId}.${ext}`,
        container_ext: ext,
        is_favorite: 0,
        playback_position_ms: 0,
        duration_ms: 0,
        imdb_rating: Number.isFinite(ratingRaw) && ratingRaw > 0 ? ratingRaw : undefined,
      });
    }

    for (let i = 0; i < seriesEntries.length; i++) {
      const s = seriesEntries[i];
      const seriesId = String(s?.series_id ?? '').trim();
      if (!seriesId) continue;
      const rawName = String(s?.name || `Série ${i + 1}`).trim();
      const { clean, year } = cleanYearFromTitle(rawName);
      const catName = seriesCats.get(String(s?.category_id ?? '')) || 'Séries';
      const ratingRaw = s?.rating != null ? Number(s.rating) : s?.rating_5based != null ? Number(s.rating_5based) * 2 : NaN;
      itemRecords.push({
        source_id: sourceId,
        stable_hash: `series_${seriesId}`,
        kind: 'series',
        name: rawName,
        name_clean: clean,
        year,
        group_title: catName,
        logo_url: s?.cover ? String(s.cover) : undefined,
        stream_url: `xtream-series://${encodeURIComponent(base)}|${u}|${p}|${seriesId}`,
        is_favorite: 0,
        season_num: 1,
        episode_num: 1,
        playback_position_ms: 0,
        duration_ms: 0,
        imdb_rating: Number.isFinite(ratingRaw) && ratingRaw > 0 ? ratingRaw : undefined,
        plot: s?.plot ? String(s.plot) : undefined,
      });
    }

    await this.db.insertItemsBatch(itemRecords, (saved, total) => {
      const pct = 80 + Math.round((saved / Math.max(1, total)) * 20);
      onProgress?.(`Enregistrement sur la TV : ${saved} / ${total} contenus…`, pct);
    });

    onProgress?.(`${itemRecords.length} contenus importés avec succès !`, 100);
    return itemRecords.length;
  }

  private async syncPlaylist(
    src: { name: string; url: string; sourceType: 'm3u' | 'xtream'; server?: string; username?: string; password?: string; epgUrl?: string },
    onProgress?: SyncProgressCallback
  ): Promise<number> {
    const { name, url } = src;
    onProgress?.('Téléchargement de la liste M3U…', 12);
    const resp = await this.net.get<string>(url, {}, 'text');

    if (!resp.data || typeof resp.data !== 'string' || resp.data.trim().length === 0) {
      throw new Error('La liste reçue du fournisseur IPTV est vide.');
    }

    onProgress?.('Analyse WebAssembly des chaînes et films…', 45);
    const uuid = 'src_' + Date.now();
    const { header, items } = await this.worker.parseM3uChunk(resp.data, uuid);

    if (!Array.isArray(items) || items.length === 0) {
      throw new Error('Aucune chaîne ou vidéo trouvée dans cette playlist.');
    }

    onProgress?.(`Enregistrement de ${items.length} contenus…`, 75);
    const sourceId = await this.db.insertSource({
      uuid,
      name,
      source_type: src.sourceType,
      url: src.sourceType === 'xtream' ? undefined : url,
      server: src.server,
      username: src.username,
      password: src.password,
      epg_url: src.epgUrl || header.epg_url,
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

    await this.db.insertItemsBatch(itemRecords, (saved, total) => {
      const pct = 78 + Math.round((saved / Math.max(1, total)) * 22);
      onProgress?.(`Enregistrement sur la TV : ${saved} / ${total} contenus…`, pct);
    });
    onProgress?.(`${items.length} contenus importés avec succès !`, 100);
    return items.length;
  }

  private async checkAdultCategory(group: string): Promise<boolean> {
    if (!group) return false;
    const cached = this.adultCategoryCache.get(group);
    if (cached !== undefined) return cached;
    const isAdult = await this.worker.isAdultCategory(group);
    this.adultCategoryCache.set(group, isAdult);
    return isAdult;
  }

  /**
   * Catalog Queries with fast single-category bypass and pagination.
   */
  public async getCatalog(
    kind: 'live' | 'movie' | 'series',
    groupTitle?: string,
    offset = 0,
    limit = 30
  ): Promise<ItemRecord[]> {
    if (groupTitle) {
      const isAdult = await this.checkAdultCategory(groupTitle);
      if ((this.activeProfile.isKids || !this.isAdultUnlocked) && isAdult) {
        return [];
      }
      return this.db.getItemsByKindAndGroup(kind, groupTitle, offset, limit);
    }

    const items = await this.db.getItemsByKindAndGroup(kind, undefined, offset, limit);
    const filtered: ItemRecord[] = [];
    for (const item of items) {
      if (this.activeProfile.isKids || !this.isAdultUnlocked) {
        const isAdult = await this.checkAdultCategory(item.group_title || '');
        if (isAdult) continue;
      }
      filtered.push(item);
    }
    return filtered;
  }

  public async countCatalog(
    kind: 'live' | 'movie' | 'series',
    groupTitle?: string
  ): Promise<number> {
    if (groupTitle) {
      const isAdult = await this.checkAdultCategory(groupTitle);
      if ((this.activeProfile.isKids || !this.isAdultUnlocked) && isAdult) {
        return 0;
      }
    }
    return this.db.countItemsByKindAndGroup(kind, groupTitle);
  }

  public async getCategories(kind: 'live' | 'movie' | 'series'): Promise<string[]> {
    const mem = this.categoriesMemCache.get(kind);
    if (mem && mem.length > 0) {
      return mem;
    }

    const rawCategories = await this.db.getCategories(kind);
    const result: string[] = [];
    for (const cat of rawCategories) {
      const isAdult = await this.checkAdultCategory(cat);
      if ((this.activeProfile.isKids || !this.isAdultUnlocked) && isAdult) continue;
      result.push(cat);
    }
    this.categoriesMemCache.set(kind, result);
    return result;
  }

  public async getFavorites(): Promise<ItemRecord[]> {
    return this.db.getFavorites();
  }

  public async toggleFavorite(itemId: number): Promise<boolean> {
    return this.db.toggleFavorite(itemId);
  }

  /**
   * Playback. Several calls may overlap (zapping in the Live TV list): only the last one opens its stream.
   * The same live channel already playing (preview → full screen) is not reopened unless `force`.
   */
  public async play(item: ItemRecord, options: { force?: boolean } = {}): Promise<void> {
    const token = ++this.playToken;
    const isLive = item.kind === 'live';
    const alreadyPlaying =
      !options.force &&
      isLive &&
      this.currentPlayingItem?.id === item.id &&
      this.player.isActive();
    this.currentPlayingItem = item;
    if (alreadyPlaying) return;

    let streamUrl = item.stream_url;
    if (streamUrl.startsWith('xtream-series://')) {
      streamUrl = await this.resolveXtreamSeriesFirstEpisode(streamUrl);
    }

    // 1-conn rule: resolve final address once to stay in the same supplier session
    if (!isLive) {
      try {
        streamUrl = await this.net.resolveFinalUrl(streamUrl);
      } catch (err) {
        console.warn('Final URL resolution fallback to raw:', err);
      }
    }
    if (token !== this.playToken) return; // the user already chose something else

    await this.player.open(streamUrl, isLive);
    if (token !== this.playToken) return;
    this.player.play();
  }

  /** Stops the video and frees the provider's connection. */
  public stopPlayback() {
    this.playToken++;
    this.currentPlayingItem = null;
    this.player.stop();
  }

  private async resolveXtreamSeriesFirstEpisode(descriptor: string): Promise<string> {
    const raw = descriptor.slice('xtream-series://'.length);
    const [encBase, u, p, seriesId] = raw.split('|');
    const base = decodeURIComponent(encBase || '');
    const resp = await this.net.get<any>(
      `${base}/player_api.php?username=${u}&password=${p}&action=get_series_info&series_id=${encodeURIComponent(seriesId)}`,
      {},
      'json'
    );
    const episodesObj = resp.data?.episodes;
    if (episodesObj && typeof episodesObj === 'object') {
      const seasonKeys = Object.keys(episodesObj).sort((a, b) => Number(a) - Number(b));
      for (const sk of seasonKeys) {
        const list = episodesObj[sk];
        if (Array.isArray(list) && list.length > 0) {
          const ep = list[0];
          const epId = String(ep?.id ?? '').trim();
          const ext = String(ep?.container_extension || 'mp4').replace(/^\.+/, '') || 'mp4';
          if (epId) {
            return `${base}/series/${u}/${p}/${epId}.${ext}`;
          }
        }
      }
    }
    throw new Error('Aucun épisode disponible pour cette série.');
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

