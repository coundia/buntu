/**
 * CND IPTV Tizen - Unified Engine Facade (PRD 38 § 2.2 & § 7)
 *
 * Single point of entry for the UI:
 * Coordinates Network (1-conn queue), Web Worker (wasm domain logic),
 * Storage (IndexedDB/wa-sqlite), and AVPlayerService.
 */

import { Database, ItemRecord, SourceRecord, FAVORITES_CATEGORY } from '../storage/Database';
import { HttpClient } from '../net/HttpClient';
import { AVPlayerService } from '../player/AVPlayerService';
import { WorkerBridge } from '../../worker/worker-bridge';

import { cleanMediaTitle } from '../utils/titleCleaner';

export interface ProfileState {
  id: number;
  name: string;
  isKids: boolean;
  avatar: string;
}

export interface EpisodeItem {
  id: string;
  episode_num: number;
  season_num: number;
  title: string;
  container_ext: string;
  stream_url: string;
  duration?: string;
  plot?: string;
  cover?: string;
  rating?: number;
}

export interface SeasonInfo {
  season_num: number;
  name: string;
  overview?: string;
  episodes: EpisodeItem[];
}

export interface SeriesDetails {
  info: {
    title: string;
    plot?: string;
    cover?: string;
    backdrop?: string;
    genre?: string;
    rating?: number;
    year?: number;
    cast?: string;
    director?: string;
  };
  seasons: SeasonInfo[];
}

export type SyncProgressCallback = (msg: string, percent?: number) => void;

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
  private seriesDetailsCache = new Map<string, SeriesDetails>();

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
      const cleanName = cleanMediaTitle(rawName).clean;
      const catName = liveCats.get(String(s?.category_id ?? '')) || 'Direct';
      const archiveDays = Number(s?.tv_archive) > 0 ? Number(s?.tv_archive_duration) || undefined : undefined;
      itemRecords.push({
        source_id: sourceId,
        stable_hash: `live_${streamId}`,
        kind: 'live',
        name: rawName,
        name_clean: cleanName,
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
      const { clean, year } = cleanMediaTitle(rawName);
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
      const { clean, year } = cleanMediaTitle(rawName);
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

    this.categoriesMemCache.clear();
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
    this.categoriesMemCache.clear();
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
      if (groupTitle !== FAVORITES_CATEGORY && groupTitle !== 'Favoris') {
        const isAdult = await this.checkAdultCategory(groupTitle);
        if ((this.activeProfile.isKids || !this.isAdultUnlocked) && isAdult) {
          return [];
        }
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
      if (groupTitle !== FAVORITES_CATEGORY && groupTitle !== 'Favoris') {
        const isAdult = await this.checkAdultCategory(groupTitle);
        if ((this.activeProfile.isKids || !this.isAdultUnlocked) && isAdult) {
          return 0;
        }
      }
    }
    return this.db.countItemsByKindAndGroup(kind, groupTitle);
  }

  public async getCategories(kind: 'live' | 'movie' | 'series'): Promise<string[]> {
    const mem = this.categoriesMemCache.get(kind);
    if (mem && mem.length > 0) {
      if (mem[0] === FAVORITES_CATEGORY) {
        return mem;
      }
      const fixed = [FAVORITES_CATEGORY, ...mem.filter(c => c !== FAVORITES_CATEGORY && c !== 'Favoris')];
      this.categoriesMemCache.set(kind, fixed);
      return fixed;
    }

    const rawCategories = await this.db.getCategories(kind);
    const result: string[] = [FAVORITES_CATEGORY];
    for (const cat of rawCategories) {
      if (cat === FAVORITES_CATEGORY || cat === 'Favoris') continue;
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

  public async getFavoritesByKind(kind: 'live' | 'movie' | 'series', limit = 16): Promise<ItemRecord[]> {
    return this.db.getItemsByKindAndGroup(kind, FAVORITES_CATEGORY, 0, limit);
  }

  public async getCategoryCounts(kind: 'live' | 'movie' | 'series'): Promise<{ total: number; favCount: number; counts: Record<string, number> }> {
    return this.db.getCategoryCounts(kind);
  }

  public async getGlobalCounts(): Promise<{ live: number; movie: number; series: number; sources: number }> {
    const [live, movie, series, sources] = await Promise.all([
      this.db.countItemsByKindAndGroup('live'),
      this.db.countItemsByKindAndGroup('movie'),
      this.db.countItemsByKindAndGroup('series'),
      this.db.getSources().then((s) => s.length),
    ]);
    return { live, movie, series, sources };
  }

  public recordRecent(item: ItemRecord): void {
    const kindKey = item.kind === 'episode' ? 'series' : item.kind;
    const storageKey = `cnd_recent_${kindKey}`;
    try {
      const raw = localStorage.getItem(storageKey);
      const ids: number[] = raw ? JSON.parse(raw) : [];
      const next = [item.id, ...ids.filter((id) => id !== item.id)].slice(0, 16);
      localStorage.setItem(storageKey, JSON.stringify(next));
    } catch {}
  }

  public async getRecentItems(kind: 'live' | 'movie' | 'series', limit = 12): Promise<ItemRecord[]> {
    const storageKey = `cnd_recent_${kind}`;
    try {
      const raw = localStorage.getItem(storageKey);
      if (!raw) return [];
      const ids: number[] = JSON.parse(raw);
      if (!Array.isArray(ids) || ids.length === 0) return [];
      return this.db.getItemsByIds(ids.slice(0, limit));
    } catch {
      return [];
    }
  }

  public async toggleFavorite(itemId: number): Promise<boolean> {
    return this.db.toggleFavorite(itemId);
  }

  /**
   * Playback. Several calls may overlap (zapping in the Live TV list): only the last one opens its stream.
   * The same item already playing (mini player → full screen) is not reopened unless `force`.
   */
  public async play(item: ItemRecord, options: { force?: boolean } = {}): Promise<void> {
    this.recordRecent(item);
    const token = ++this.playToken;
    const isLive = item.kind === 'live';
    const alreadyPlaying =
      !options.force &&
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

  /** True when this very item is the one currently playing (not merely selected). */
  public isPlayingItem(item: ItemRecord): boolean {
    return this.currentPlayingItem?.id === item.id && this.player.isActive();
  }

  /** Stops the video and frees the provider's connection. */
  public stopPlayback() {
    this.playToken++;
    this.currentPlayingItem = null;
    this.player.stop();
  }

  /**
   * Fetches full series details, seasons, and episodes from Xtream Codes API or DB.
   */
  public async getSeriesDetails(item: ItemRecord): Promise<SeriesDetails> {
    const cacheKey = item.stream_url;
    if (this.seriesDetailsCache.has(cacheKey)) {
      return this.seriesDetailsCache.get(cacheKey)!;
    }

    if (item.stream_url.startsWith('xtream-series://')) {
      const raw = item.stream_url.slice('xtream-series://'.length);
      const [encBase, u, p, seriesId] = raw.split('|');
      const base = decodeURIComponent(encBase || '');
      const resp = await this.net.get<any>(
        `${base}/player_api.php?username=${u}&password=${p}&action=get_series_info&series_id=${encodeURIComponent(seriesId)}`,
        {},
        'json'
      );

      const d = resp.data || {};
      const episodesObj = d.episodes || {};
      const seasonsArr: SeasonInfo[] = [];

      // Season metadata if provided
      const metaSeasonsMap = new Map<number, any>();
      if (Array.isArray(d.seasons)) {
        for (const s of d.seasons) {
          const num = Number(s?.season_number);
          if (!isNaN(num)) metaSeasonsMap.set(num, s);
        }
      }

      const seasonKeys = Object.keys(episodesObj).sort((a, b) => Number(a) - Number(b));
      for (const sk of seasonKeys) {
        const sNum = Number(sk) || 1;
        const metaSeason = metaSeasonsMap.get(sNum);
        const rawEps = episodesObj[sk];
        const epList: EpisodeItem[] = (Array.isArray(rawEps) ? rawEps : []).map((ep: any, idx: number) => {
          const epId = String(ep?.id ?? '').trim();
          const ext = String(ep?.container_extension || 'mp4').replace(/^\.+/, '') || 'mp4';
          const epNum = Number(ep?.episode_num) || idx + 1;
          const epTitle = ep?.title ? String(ep.title).trim() : `Épisode ${epNum}`;
          const epInfo = ep?.info || {};
          const durationSec = Number(epInfo.duration_secs) || 0;
          const durationStr = epInfo.duration
            ? String(epInfo.duration)
            : durationSec > 0
            ? `${Math.round(durationSec / 60)} min`
            : undefined;

          return {
            id: epId,
            episode_num: epNum,
            season_num: sNum,
            title: cleanMediaTitle(epTitle).clean || epTitle,
            container_ext: ext,
            stream_url: `${base}/series/${u}/${p}/${epId}.${ext}`,
            duration: durationStr,
            plot: epInfo.plot ? String(epInfo.plot) : undefined,
            cover: epInfo.movie_image ? String(epInfo.movie_image) : undefined,
            rating: epInfo.rating ? Number(epInfo.rating) : undefined,
          };
        });

        if (epList.length > 0) {
          seasonsArr.push({
            season_num: sNum,
            name: metaSeason?.name || `Saison ${sNum}`,
            overview: metaSeason?.overview || undefined,
            episodes: epList,
          });
        }
      }

      const infoObj = d.info || {};
      const ratingRaw =
        infoObj.rating != null
          ? Number(infoObj.rating)
          : infoObj.rating_5based != null
          ? Number(infoObj.rating_5based) * 2
          : item.imdb_rating;

      const result: SeriesDetails = {
        info: {
          title: cleanMediaTitle(infoObj.name || item.name_clean || item.name).clean,
          plot: infoObj.plot || item.plot,
          cover: infoObj.cover || item.logo_url,
          backdrop:
            Array.isArray(infoObj.backdrop_path) && infoObj.backdrop_path.length > 0
              ? infoObj.backdrop_path[0]
              : undefined,
          genre: infoObj.genre || item.group_title,
          rating: typeof ratingRaw === 'number' && Number.isFinite(ratingRaw) && ratingRaw > 0 ? ratingRaw : undefined,
          year: infoObj.releaseDate
            ? parseInt(infoObj.releaseDate.slice(0, 4), 10) || item.year
            : item.year,
          cast: infoObj.cast || undefined,
          director: infoObj.director || undefined,
        },
        seasons: seasonsArr,
      };

      this.seriesDetailsCache.set(cacheKey, result);
      return result;
    }

    // Fallback for non-Xtream series
    const fallbackResult: SeriesDetails = {
      info: {
        title: cleanMediaTitle(item.name_clean || item.name).clean,
        plot: item.plot,
        cover: item.logo_url,
        genre: item.group_title,
        year: item.year,
        rating: item.imdb_rating,
      },
      seasons: [
        {
          season_num: item.season_num || 1,
          name: `Saison ${item.season_num || 1}`,
          episodes: [
            {
              id: String(item.id),
              episode_num: item.episode_num || 1,
              season_num: item.season_num || 1,
              title: cleanMediaTitle(item.name_clean || item.name).clean,
              container_ext: item.container_ext || 'mp4',
              stream_url: item.stream_url,
              plot: item.plot,
              cover: item.logo_url,
            },
          ],
        },
      ],
    };
    return fallbackResult;
  }

  private async resolveXtreamSeriesFirstEpisode(descriptor: string): Promise<string> {
    const dummyItem: ItemRecord = {
      id: 0,
      source_id: 0,
      stable_hash: '',
      kind: 'series',
      name: '',
      name_clean: '',
      stream_url: descriptor,
      is_favorite: 0,
      playback_position_ms: 0,
      duration_ms: 0,
    };
    const details = await this.getSeriesDetails(dummyItem);
    if (details.seasons.length > 0 && details.seasons[0].episodes.length > 0) {
      return details.seasons[0].episodes[0].stream_url;
    }
    throw new Error('Aucun épisode disponible pour cette série.');
  }

  public getCurrentPlayingItem(): ItemRecord | null {
    return this.currentPlayingItem;
  }

  /**
   * Fast In-Screen Catalog Search with optional kind filter.
   */
  public async searchCatalog(
    query: string,
    kind?: 'live' | 'movie' | 'series',
    limit = 60
  ): Promise<ItemRecord[]> {
    if (!query.trim()) return [];
    return this.db.searchItems(query, kind, limit);
  }

  /**
   * Search.
   */
  public async search(rawQuery: string, kind?: 'live' | 'movie' | 'series'): Promise<any[]> {
    if (!rawQuery.trim()) return [];

    const parsedQuery = await this.worker.parseSearchQuery(rawQuery, Date.now() / 1000, new Date().getTimezoneOffset());
    const candidates = await this.db.searchItems(rawQuery, kind, 80);
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

