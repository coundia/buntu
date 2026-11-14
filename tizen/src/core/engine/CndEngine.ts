import { LocalSourceVault, SourceConnectionEdit } from '../storage/LocalSourceVault';
/**
 * CND IPTV Tizen - Unified Engine Facade (PRD 38 § 2.2 & § 7)
 *
 * Single point of entry for the UI:
 * Coordinates Network (1-conn queue), Web Worker (wasm domain logic),
 * Storage (IndexedDB/wa-sqlite), and AVPlayerService.
 */

import { neighbourInList, zapContext } from '../navigation/ZapContext';
import { Database, EpgProgramRecord, ItemRecord, SourceRecord, FAVORITES_CATEGORY, RECENT_CATEGORY, RECENT_LIMIT } from '../storage/Database';
import { HttpClient } from '../net/HttpClient';
import { AVPlayerService } from '../player/AVPlayerService';
import { WorkerBridge } from '../../worker/worker-bridge';
import { findSameAccount } from '../sync/AccountIdentity';
import { AiClient, AiTaskResult } from '../ai/AiClient';
import { gatherCommandCandidates, buildRecommendationCandidates } from '../ai/candidates';

import { cleanMediaTitle } from '../utils/titleCleaner';
import { AiKeyStore } from '../ai/AiKeyStore';
import { isUhdTitle } from '../player/uhd';
import { movieFeatures, pickSimilar, tasteOf, toCandidate } from './similarMovies';
import { channelFamily, liveTaste, pickRecommendedChannels, toLiveCandidate } from './liveRecommendations';
import { buildLiveCatchupUrl, findChannelByNumber, isSameLiveChannel, rankLiveMirrors } from './livePlayerHelpers';

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
  duration_ms?: number;
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

/** What the provider says about a film (Xtream `get_vod_info`); every field is optional. */
export interface MovieInfo {
  plot?: string;
  genre?: string;
  cast?: string;
  director?: string;
  releaseDate?: string;
  rating?: number;
  durationMs?: number;
  country?: string;
  /** Age rating when the provider gives one. */
  age?: string;
}

export type SyncProgressCallback = (msg: string, percent?: number) => void;

const LAST_WATCHED_KEY = 'cnd_last_watched';
/** A channel that played and then went silent is marked out of service only after this long without recovering. */
const LIVE_SILENCE_BEFORE_BROKEN_MS = 90_000;
/** A film's position is saved this often while it plays, and when it stops. */
const PROGRESS_SAVE_MS = 10_000;
/** Under this the film starts from the beginning. */
const RESUME_MIN_MS = 15_000;

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
  private healthUnsubscribe: (() => void) | null = null;
  private categoriesMemCache = new Map<string, string[]>();
  private seriesDetailsCache = new Map<string, SeriesDetails>();
  private movieInfoCache = new Map<string, MovieInfo | null>();

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

  public getDatabase(): Database {
    return this.db;
  }

  public async updateLocalSource(sourceId: number, draft: SourceConnectionEdit): Promise<void> {
    const source = (await this.db.getSharedSources()).find((s) => s.id === sourceId);
    if (!source) throw new Error('Source introuvable');
    const edit = await this.worker.post<SourceConnectionEdit>('SOURCE_EDIT_VALIDATE', { edit: { ...draft, source_type: source.source_type } });
    if (this.currentPlayingItem?.source_id === sourceId) this.stopPlayback();
    await LocalSourceVault.getInstance().set(source.uuid, edit);
    await this.db.updateSource({ ...source, local_override: true });
    this.categoriesMemCache.clear();
    this.seriesDetailsCache.clear();
    this.movieInfoCache.clear();
    if (source.source_type === 'm3u') await this.syncM3uSource(source.name, edit.url);
  }

  private async localItem(item: ItemRecord): Promise<ItemRecord> {
    const source = (await this.db.getSharedSources()).find((s) => s.id === item.source_id);
    if (!source?.local_override) return item;
    const edit = await LocalSourceVault.getInstance().get(source.uuid);
    if (!edit) throw new Error('Coordonnées locales indisponibles');
    const locator = await this.worker.post<string>('SOURCE_EDIT_REWRITE', { locator: item.stream_url, edit });
    return { ...item, stream_url: locator };
  }

  public async deleteSource(sourceId: number): Promise<void> {
    const source = (await this.db.getSharedSources()).find((s) => s.id === sourceId);
    await this.db.deleteSource(sourceId);
    if (source?.local_override) await LocalSourceVault.getInstance().delete(source.uuid);
    this.categoriesMemCache.clear();
  }

  /**
   * Source Synchronization.
   */
  /**
   * Saves an account, never twice: an account already here (same uuid, or same identity computed in Rust:
   * added from another device, re-synchronised, typed again) is updated and keeps its uuid and its name.
   */
  private async saveSource(source: Omit<SourceRecord, 'id'>): Promise<number> {
    const same = await findSameAccount(source, await this.db.getSources())
      || await findSameAccount(source, await this.db.getSharedSources());
    if (same?.local_override) {
      const original = (await this.db.getSharedSources()).find((s) => s.id === same.id);
      if (!original) throw new Error('Source introuvable');
      await this.db.updateSource({ ...original, item_count: source.item_count, last_sync_at: source.last_sync_at });
      return original.id;
    }
    if (!same) return this.db.upsertSource(source);
    return this.db.upsertSource({ ...source, id: same.id, uuid: same.uuid, name: same.name || source.name });
  }

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

    const sourceId = await this.saveSource({
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
    const sourceId = await this.saveSource({
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

  /** Whether the active profile may play `item` (Kids profile or adult content locked). */
  public async isItemAllowedForActiveProfile(item: ItemRecord): Promise<boolean> {
    if (!this.activeProfile.isKids && this.isAdultUnlocked) return true;
    return !(await this.checkAdultCategory(item.group_title || ''));
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
    return this.db.withProgress(await this.getCatalogRaw(kind, groupTitle, offset, limit));
  }

  private async getCatalogRaw(
    kind: 'live' | 'movie' | 'series',
    groupTitle?: string,
    offset = 0,
    limit = 30
  ): Promise<ItemRecord[]> {
    if (groupTitle === RECENT_CATEGORY) {
      const recents = await this.visibleRecents(kind);
      return recents.slice(offset, offset + limit);
    }
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
    if (groupTitle === RECENT_CATEGORY) {
      return (await this.visibleRecents(kind)).length;
    }
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
    return this.db.withProgress(await this.db.getItemsByKindAndGroup(kind, FAVORITES_CATEGORY, 0, limit));
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
    // An item rebuilt for a playback sent from another device is not a database row (negative id).
    if (!(item.id > 0)) return;
    const kindKey = item.kind === 'episode' ? 'series' : item.kind;
    const storageKey = `cnd_recent_${kindKey}`;
    try {
      const raw = localStorage.getItem(storageKey);
      const ids: number[] = raw ? JSON.parse(raw) : [];
      const next = [item.id, ...ids.filter((id) => id !== item.id)].slice(0, RECENT_LIMIT);
      localStorage.setItem(storageKey, JSON.stringify(next));
      // The home offers to resume the last thing watched, whatever its kind: remember which and when.
      localStorage.setItem(LAST_WATCHED_KEY, JSON.stringify({ id: item.id, at: Date.now() }));
    } catch {}
  }

  /**
   * Channels to suggest in Live TV: those of the categories (and of the kind) the viewer watches or has in favourites,
   * scored by the shared rule of `cnd-domain` (WebAssembly). Empty while there is nothing to learn from (no recent
   * channel, no favourite). Local data only: nothing is sent anywhere, no stream is opened.
   */
  public async getRecommendedChannels(limit = 6): Promise<ItemRecord[]> {
    try {
      const [recents, favorites] = await Promise.all([this.visibleRecents('live'), this.getFavoritesByKind('live', 20)]);
      const taste = liveTaste(recents, favorites);
      if (taste.samples === 0) return [];

      const groups: string[] = [];
      for (const channel of [...favorites, ...recents]) {
        if (channel.group_title && !groups.includes(channel.group_title)) groups.push(channel.group_title);
      }
      const pool = new Map<number, ItemRecord>();
      for (const group of groups.slice(0, 4)) {
        (await this.getCatalog('live', group, 0, 80)).forEach((c) => c.kind === 'live' && pool.set(c.id, c));
      }
      if (pool.size < 30) (await this.getCatalog('live', undefined, 0, 60)).forEach((c) => c.kind === 'live' && pool.set(c.id, c));
      if (pool.size === 0) return [];

      const known = [...recents, ...favorites];
      const scored = await this.worker.scoreRecommendations(taste, [...pool.values()].map(toLiveCandidate));
      return pickRecommendedChannels(
        scored as { item: { id: number }; score: number }[],
        pool,
        new Set(known.map((c) => c.id)),
        new Set(known.map((c) => channelFamily(c.name_clean || c.name))),
        limit
      );
    } catch {
      return [];
    }
  }

  /**
   * Films that resemble this one, for the « À suivre » shelf of the player: those of its category first, closest
   * decade next, the better rated before the others. The scoring is the shared rule of `cnd-domain` (WebAssembly).
   * Empty when nothing is similar. Never opens a stream.
   */
  public async getSimilarMovies(item: ItemRecord, limit = 8): Promise<ItemRecord[]> {
    if (item.kind !== 'movie') return [];
    try {
      const pool = new Map<number, ItemRecord>();
      const add = (items: ItemRecord[]) => items.forEach((i) => i.kind === 'movie' && !pool.has(i.id) && pool.set(i.id, i));
      if (item.group_title) add(await this.getCatalog('movie', item.group_title, 0, 150));
      if (pool.size < 40) add(await this.getCatalog('movie', undefined, 0, 100));
      pool.delete(item.id);
      if (pool.size === 0) return [];

      const info = await this.getMovieInfo(item).catch(() => null);
      const taste = tasteOf(movieFeatures(item, info));
      const scored = await this.worker.scoreRecommendations(taste, [...pool.values()].map(toCandidate));
      return pickSimilar(scored as { item: { id: number }; score: number }[], pool, item.id, limit);
    } catch {
      return [];
    }
  }

  /**
   * The last film, episode, series or channel watched, ready to resume from the home. `null` when there is none, when
   * the profile may not see it (adult category) or when it is practically finished (95 % or more). Local data only.
   */
  public async getLastWatched(): Promise<ItemRecord | null> {
    try {
      const raw = localStorage.getItem(LAST_WATCHED_KEY);
      const id = raw ? Number(JSON.parse(raw)?.id) : NaN;
      if (!Number.isFinite(id) || id <= 0) return null;
      const [item] = await this.db.withProgress(await this.db.getItemsByIds([id]));
      if (!item) return null;
      if ((this.activeProfile.isKids || !this.isAdultUnlocked) && (await this.checkAdultCategory(item.group_title || ''))) {
        return null;
      }
      if ((item.kind === 'movie' || item.kind === 'episode') && item.duration_ms > 0
        && item.playback_position_ms / item.duration_ms >= 0.95) {
        return null;
      }
      return item;
    } catch {
      return null;
    }
  }

  /** The recently watched items of this kind, without the adult ones when the profile may not see them. */
  private async visibleRecents(kind: 'live' | 'movie' | 'series'): Promise<ItemRecord[]> {
    // Watching an episode records the episode: the series list only shows series.
    const recents = (await this.getRecentItems(kind, RECENT_LIMIT)).filter(
      (item) => kind !== 'series' || item.kind !== 'episode'
    );
    if (!this.activeProfile.isKids && this.isAdultUnlocked) return recents;
    const visible: ItemRecord[] = [];
    for (const item of recents) {
      if (!(await this.checkAdultCategory(item.group_title || ''))) visible.push(item);
    }
    return visible;
  }

  /**
   * The channel to switch to with Ch+ / Ch-: the next (or previous) one in the list the viewer came
   * from. `category` is '' for all channels, FAVORITES_CATEGORY, RECENT_CATEGORY or a provider category.
   * Wraps around at the ends; null when there is nowhere to go.
   */
  public async getAdjacentItem(
    current: ItemRecord,
    category: string,
    direction: 'next' | 'prev'
  ): Promise<ItemRecord | null> {
    const kind = current.kind === 'episode' ? 'series' : current.kind;
    const step = direction === 'next' ? 1 : -1;

    if (category === RECENT_CATEGORY) {
      if (!zapContext.frozen) zapContext.frozen = await this.visibleRecents(kind);
      return (neighbourInList(zapContext.frozen as ItemRecord[], current.id, step) as ItemRecord | undefined) ?? null;
    }
    if (category === FAVORITES_CATEGORY) {
      const favorites = await this.db.getItemsByKindAndGroup(kind, FAVORITES_CATEGORY, 0, 5000);
      return neighbourInList(favorites, current.id, step) ?? null;
    }

    const mustHideAdult = this.activeProfile.isKids || !this.isAdultUnlocked;
    let fromId = current.id;
    for (let attempt = 0; attempt < 60; attempt += 1) {
      const candidate = await this.db.getNeighbourItem(kind, category || undefined, fromId, direction);
      if (!candidate || candidate.id === current.id) return null;
      if (mustHideAdult && (await this.checkAdultCategory(candidate.group_title || ''))) {
        fromId = candidate.id; // skip channels of an adult category
        continue;
      }
      return candidate;
    }
    return null;
  }

  public async getRecentItems(kind: 'live' | 'movie' | 'series', limit = 12): Promise<ItemRecord[]> {
    const storageKey = `cnd_recent_${kind}`;
    try {
      const raw = localStorage.getItem(storageKey);
      if (!raw) return [];
      const ids: number[] = JSON.parse(raw);
      if (!Array.isArray(ids) || ids.length === 0) return [];
      return this.db.withProgress(await this.db.getItemsByIds(ids.slice(0, limit)));
    } catch {
      return [];
    }
  }

  public async toggleFavorite(itemId: number): Promise<boolean> {
    return this.db.toggleFavorite(itemId);
  }

  public async setBroken(itemId: number, broken = true): Promise<boolean> {
    return this.db.setBroken(itemId, broken);
  }

  /** Live channel recall state: previous distinct channel (not overwritten by mirror failover). */
  public getPreviousLiveItem(): ItemRecord | null {
    return this.previousLiveItem;
  }

  /** Resolves a Live channel by numeric `chno` (exact `chno` first, category then global, or positional fallback). */
  public async getChannelByNumber(chno: number, category = ''): Promise<ItemRecord | null> {
    if (!Number.isInteger(chno) || chno <= 0) return null;
    if (category === RECENT_CATEGORY) {
      const list = (zapContext.frozen as ItemRecord[] | null) ?? (await this.visibleRecents('live'));
      return findChannelByNumber(list, chno);
    }

    const mustHideAdult = this.activeProfile.isKids || !this.isAdultUnlocked;
    const isVisible = async (cand: ItemRecord) =>
      cand.kind === 'live' && (!mustHideAdult || !(await this.checkAdultCategory(cand.group_title || '')));

    // Bounded search on chno stringified avoids pulling huge catalogs into RAM for exact matches.
    const hits = await this.db.searchItems(String(chno), 'live', 80);
    const exactInCat: ItemRecord[] = [];
    const exactGlobal: ItemRecord[] = [];
    for (const h of hits) {
      if (h.chno !== chno || !(await isVisible(h))) continue;
      if (category && category !== FAVORITES_CATEGORY && h.group_title === category) exactInCat.push(h);
      exactGlobal.push(h);
    }
    if (exactInCat.length > 0) return findChannelByNumber(exactInCat, chno);
    if (!category || category === FAVORITES_CATEGORY) {
      if (category === FAVORITES_CATEGORY) {
        const favs = await this.getCatalog('live', FAVORITES_CATEGORY, 0, 500);
        const favHit = findChannelByNumber(favs, chno);
        if (favHit) return favHit;
      }
      if (exactGlobal.length > 0) return findChannelByNumber(exactGlobal, chno);
    }
    if (exactGlobal.length > 0) return findChannelByNumber(exactGlobal, chno);

    // Positional fallback inside current category when explicit chno are missing.
    if (chno <= 500) {
      const scoped = await this.getCatalog('live', category || undefined, 0, Math.max(chno, 50));
      return findChannelByNumber(scoped, chno);
    }
    return null;
  }

  /** Healthy alternative streams for the current channel (4K > FHD > HD > SD, same source first). */
  public async findMirrors(item: ItemRecord): Promise<ItemRecord[]> {
    if (item.kind !== 'live') return [];
    const pool = new Map<number, ItemRecord>();
    const familyToken = channelFamily(item.name_clean || item.name).split(' ').find((w) => w.length >= 2) ?? '';
    if (familyToken) {
      for (const hit of await this.db.searchItems(familyToken, 'live', 80)) {
        pool.set(hit.id, hit);
      }
    }
    if (item.group_title) {
      for (const ch of await this.getCatalog('live', item.group_title, 0, 120)) {
        pool.set(ch.id, ch);
      }
    }
    const mustHideAdult = this.activeProfile.isKids || !this.isAdultUnlocked;
    const visible: ItemRecord[] = [];
    for (const cand of pool.values()) {
      if (mustHideAdult && (await this.checkAdultCategory(cand.group_title || ''))) continue;
      visible.push(cand);
    }
    return rankLiveMirrors(item, visible);
  }

  /** Builds a Start-Over / catchup URL for an active program when replay is supported. */
  public buildCatchupUrl(item: ItemRecord, program: Pick<EpgProgramRecord, 'start_ts' | 'end_ts'>, nowTs = Math.floor(Date.now() / 1000)): string | null {
    return buildLiveCatchupUrl(item, program, nowTs);
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
    if (isLive && item.id > 0) {
      if (
        this.lastLiveItem &&
        this.lastLiveItem.id !== item.id &&
        !isSameLiveChannel(this.lastLiveItem, item)
      ) {
        this.previousLiveItem = this.lastLiveItem;
      }
      this.lastLiveItem = item;
    }
    this.currentPlayingItem = item;
    if (alreadyPlaying) return;
    this.healthUnsubscribe?.();
    this.healthUnsubscribe = null;

    let streamUrl = (await this.localItem(item)).stream_url;
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

    if (isLive) {
      if (this.livePlayedItemId !== item.id) this.livePlayedItemId = null;
      let broken: boolean | undefined;
      const mark = (next: boolean) => {
        if (broken === next) return;
        broken = next;
        item.is_broken = next ? 1 : 0;
        if (this.currentPlayingItem?.id === item.id) this.currentPlayingItem.is_broken = item.is_broken;
        void this.db.setBroken(item.id, next).catch(() => {
          console.warn('État de la chaîne non enregistré.');
        });
      };
      this.healthUnsubscribe = this.player.onStreamHealth((state) => {
        if (token !== this.playToken) return;
        if (state === 'playing') {
          this.livePlayedItemId = item.id;
          this.clearBrokenTimer();
          mark(false);
          return;
        }
        // A channel that never connected is out of service at once. A channel that was playing and then stopped
        // answering is most likely a server cut: it is only marked out of service when the silence lasts.
        if (this.livePlayedItemId !== item.id) {
          mark(true);
        } else if (!this.brokenTimer) {
          this.brokenTimer = setTimeout(() => {
            this.brokenTimer = null;
            if (token === this.playToken) mark(true);
          }, LIVE_SILENCE_BEFORE_BROKEN_MS);
        }
      });
    }
    const resumeAt = await this.resumePosition(item);
    // A 4K film is much heavier to stream: the player keeps more video ready (see bufferPolicy).
    await this.player.open(streamUrl, isLive, { uhd: !isLive && isUhdTitle(item) });
    if (token !== this.playToken) return;
    if (resumeAt > 0) {
      this.player.seekTo(resumeAt);
      this.resumedItemId = item.id;
    }
    this.player.play();
    this.startProgressSaver();
  }

  private livePlayedItemId: number | null = null;
  private brokenTimer: ReturnType<typeof setTimeout> | null = null;
  private lastLiveItem: ItemRecord | null = null;
  private previousLiveItem: ItemRecord | null = null;

  private clearBrokenTimer() {
    if (this.brokenTimer) clearTimeout(this.brokenTimer);
    this.brokenTimer = null;
  }

  private progressTimer: ReturnType<typeof setInterval> | null = null;
  private resumedItemId: number | null = null;

  /** `true` once when `play` already moved this item to its saved position (the player must not seek again). */
  public takeResumed(itemId: number): boolean {
    const resumed = this.resumedItemId === itemId;
    if (resumed) this.resumedItemId = null;
    return resumed;
  }

  /** Saves where the film or episode that plays has got to (nothing for a channel or a stream that has not started). */
  public async saveProgress(): Promise<void> {
    const item = this.currentPlayingItem;
    if (!item || item.kind === 'live' || !(item.id > 0) || !this.player.isActive()) return;
    const position = this.player.getCurrentTime();
    const duration = this.player.getDuration();
    if (!(position > 0) || !(duration > 0)) return;
    item.playback_position_ms = position;
    if (!(item.duration_ms > 0)) item.duration_ms = duration;
    try {
      await this.db.updateWatchProgress(item.id, position, duration);
    } catch {
      /* a position not saved is not worth an error on screen */
    }
  }

  private stopProgressSaver() {
    if (this.progressTimer) clearInterval(this.progressTimer);
    this.progressTimer = null;
  }

  private startProgressSaver() {
    this.stopProgressSaver();
    this.progressTimer = setInterval(() => void this.saveProgress(), PROGRESS_SAVE_MS);
  }

  /** Where to start a film or episode: the position given with the item, else the one saved here; never the last 5 %. */
  private async resumePosition(item: ItemRecord): Promise<number> {
    if (item.kind === 'live') return 0;
    let position = item.playback_position_ms > 0 ? item.playback_position_ms : 0;
    let duration = item.duration_ms > 0 ? item.duration_ms : 0;
    if (!(position > 0) && item.id > 0) {
      const saved = await this.db.getWatchProgress(item.id).catch(() => null);
      position = saved?.position_ms ?? 0;
      if (!(duration > 0)) duration = saved?.duration_ms ?? 0;
    }
    if (position < RESUME_MIN_MS) return 0;
    if (duration > 0 && position / duration >= 0.95) return 0;
    return position;
  }

  /** True when this very item is the one currently playing (not merely selected). */
  public isPlayingItem(item: ItemRecord): boolean {
    return this.currentPlayingItem?.id === item.id && this.player.isActive();
  }

  /** Stops the video and frees the provider's connection. */
  public stopPlayback() {
    this.clearBrokenTimer();
    this.livePlayedItemId = null;
    void this.saveProgress();
    this.stopProgressSaver();
    this.healthUnsubscribe?.();
    this.healthUnsubscribe = null;
    this.playToken++;
    this.currentPlayingItem = null;
    this.player.stop();
  }

  /**
   * The facts known about a film: what the provider says (Xtream `get_vod_info`), completed by OMDb when the
   * household shared its OMDb key with this TV. `null` when nothing is known: callers show only what exists.
   * Short API calls, cached; they never open a stream.
   */
  public async getMovieInfo(item: ItemRecord): Promise<MovieInfo | null> {
    if (item.kind !== 'movie') return null;
    item = await this.localItem(item);
    const cacheKey = item.stream_url;
    if (this.movieInfoCache.has(cacheKey)) return this.movieInfoCache.get(cacheKey) ?? null;

    const provider = await this.providerMovieInfo(item);
    const missing = !provider.info || !provider.info.plot || !provider.info.genre || !provider.info.cast
      || !provider.info.director || !provider.info.rating || !provider.info.releaseDate || !provider.info.durationMs;
    let omdb: MovieInfo | null = null;
    let omdbFailed = false;
    if (missing) {
      const result = await this.omdbMovieInfo(item);
      omdb = result.info;
      omdbFailed = result.failed;
    }
    const merged = this.mergeMovieInfo(provider.info, omdb);
    // A failed call is not remembered: the service may answer next time.
    if (!provider.failed && !omdbFailed) this.movieInfoCache.set(cacheKey, merged);
    return merged;
  }

  /** The provider's values win; OMDb only fills what is missing. */
  private mergeMovieInfo(primary: MovieInfo | null, fallback: MovieInfo | null): MovieInfo | null {
    if (!primary && !fallback) return null;
    const out: MovieInfo = { ...(fallback ?? {}) };
    for (const [key, value] of Object.entries(primary ?? {})) {
      if (value !== undefined) (out as any)[key] = value;
    }
    return Object.values(out).some((v) => v !== undefined) ? out : null;
  }

  private async providerMovieInfo(item: ItemRecord): Promise<{ info: MovieInfo | null; failed: boolean }> {
    const match = /^(https?:\/\/.+?)\/movie\/([^/]+)\/([^/]+)\/(\d+)\.[A-Za-z0-9]+(?:\?.*)?$/.exec(item.stream_url);
    if (!match) return { info: null, failed: false };
    const [, base, u, p, vodId] = match;
    try {
      const resp = await this.net.get<any>(
        `${base}/player_api.php?username=${u}&password=${p}&action=get_vod_info&vod_id=${encodeURIComponent(vodId)}`,
        {},
        'json'
      );
      const info = resp?.data?.info ?? {};
      const text = (v: unknown): string | undefined => {
        const t = typeof v === 'string' ? v.trim() : '';
        return t && t !== 'N/A' ? t : undefined;
      };
      const ratingRaw = Number(info.rating ?? info.rating_5based * 2);
      const seconds = Number(info.duration_secs);
      const result: MovieInfo = {
        plot: text(info.plot) ?? text(info.description),
        genre: text(info.genre),
        cast: text(info.cast) ?? text(info.actors),
        director: text(info.director),
        releaseDate: text(info.releasedate) ?? text(info.release_date),
        rating: Number.isFinite(ratingRaw) && ratingRaw > 0 ? ratingRaw : undefined,
        durationMs: Number.isFinite(seconds) && seconds > 0 ? seconds * 1000 : undefined,
        country: text(info.country),
        age: text(info.age) ?? text(info.mpaa_rating),
      };
      return { info: Object.values(result).some((v) => v !== undefined) ? result : null, failed: false };
    } catch {
      return { info: null, failed: true };
    }
  }

  /** Film facts from OMDb, by title and year, with the key the household shared. Nothing without a key. */
  private async omdbMovieInfo(item: ItemRecord): Promise<{ info: MovieInfo | null; failed: boolean }> {
    let key: string | null = null;
    try {
      key = await AiKeyStore.getInstance().getApiKey('omdb');
    } catch {
      key = null;
    }
    if (!key) return { info: null, failed: false };
    const parsed = cleanMediaTitle(item.name);
    const title = (item.name_clean && item.name_clean !== item.name ? item.name_clean : parsed.clean).trim();
    if (!title) return { info: null, failed: false };
    const year = item.year || parsed.year;
    try {
      const resp = await this.net.get<any>(
        `https://www.omdbapi.com/?apikey=${encodeURIComponent(key)}&t=${encodeURIComponent(title)}${year ? `&y=${year}` : ''}&type=movie&plot=short`,
        {},
        'json'
      );
      const d = resp?.data;
      if (!d || d.Response !== 'True') return { info: null, failed: false };
      const text = (v: unknown): string | undefined => {
        const t = typeof v === 'string' ? v.trim() : '';
        return t && t !== 'N/A' ? t : undefined;
      };
      const rating = Number(d.imdbRating);
      const minutes = parseInt(String(d.Runtime ?? ''), 10);
      const info: MovieInfo = {
        plot: text(d.Plot),
        genre: text(d.Genre),
        cast: text(d.Actors),
        director: text(d.Director),
        releaseDate: text(d.Released),
        rating: Number.isFinite(rating) && rating > 0 ? rating : undefined,
        durationMs: Number.isFinite(minutes) && minutes > 0 ? minutes * 60000 : undefined,
        country: text(d.Country),
        age: text(d.Rated),
      };
      return { info: Object.values(info).some((v) => v !== undefined) ? info : null, failed: false };
    } catch {
      return { info: null, failed: true };
    }
  }

  /**
   * Fetches full series details, seasons, and episodes from Xtream Codes API or DB.
   */
  public async getSeriesDetails(item: ItemRecord): Promise<SeriesDetails> {
    item = await this.localItem(item);
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
            duration_ms: durationSec > 0 ? durationSec * 1000 : undefined,
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
    return this.db.withProgress(await this.db.searchItems(query, kind, limit));
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

  /**
   * Resolves a voice or text command locally or with AI assistant (PRD 40 § 6.2).
   */
  public async resolveAiCommand(command: string): Promise<AiTaskResult & { resolvedItem?: ItemRecord }> {
    const aiClient = AiClient.getInstance();
    const recents = await this.visibleRecents('live');
    const recentIds = recents.map((i: ItemRecord) => i.id);
    const candidates = await gatherCommandCandidates(command, recentIds);

    // 1. Try local resolution first (< 50ms)
    const local = await aiClient.resolveLocal(command, candidates, {
      playing_stable_hash: this.currentPlayingItem?.stable_hash,
      locale: 'fr-FR',
    });

    if (local.action) {
      let resolvedItem: ItemRecord | undefined;
      const itemId = local.action.play_channel?.item_id || (local.action.play ? local.action.play.item_id : undefined);
      if (typeof itemId === 'number') {
        resolvedItem = (await this.db.getItemById(itemId)) || undefined;
      }
      return {
        ok: true,
        action: local.action,
        reply: resolvedItem ? `${resolvedItem.name}` : undefined,
        resolvedItem,
      };
    }

    // 2. Fall back to configured AI provider
    const aiRes = await aiClient.executeTask(
      'command',
      {
        locale: 'fr-FR',
        command,
        playing: this.currentPlayingItem?.name,
        candidates,
      },
      { isKidsProfile: this.activeProfile.isKids }
    );

    let resolvedItem: ItemRecord | undefined;
    const itemId = aiRes.action?.play_channel?.item_id || (aiRes.action?.play ? aiRes.action.play.item_id : undefined);
    if (typeof itemId === 'number') {
      resolvedItem = (await this.db.getItemById(itemId)) || undefined;
    }

    return {
      ...aiRes,
      resolvedItem,
    };
  }

  /**
   * Understands a universal search request with AI (PRD 40 § 6.1).
   */
  public async understandSearchWithAi(query: string): Promise<AiTaskResult> {
    const aiClient = AiClient.getInstance();
    return aiClient.executeTask(
      'understand_search',
      {
        locale: 'fr-FR',
        command: query,
        now_local: new Date().toISOString().slice(0, 16).replace('T', ' '),
        catalog_has: ['live', 'movie', 'series'],
        only: [],
      },
      { isKidsProfile: this.activeProfile.isKids }
    );
  }

  /**
   * Re-ranks recommendations shelf using AI (PRD 40 § 6.3).
   */
  public async refineRecommendationsWithAi(
    kind: 'movie' | 'series' | 'live',
    items: ItemRecord[]
  ): Promise<ItemRecord[]> {
    if (items.length < 3 || this.activeProfile.isKids) {
      return items;
    }

    const prefix = kind === 'movie' ? 'm' : kind === 'series' ? 's' : 't';
    const { candidates, idToItemMap } = buildRecommendationCandidates(items, prefix);
    const aiClient = AiClient.getInstance();

    const res = await aiClient.executeTask(
      'recommend',
      {
        locale: 'fr-FR',
        kind,
        taste: '',
        recent: [],
        candidates,
        now_local: new Date().toISOString().slice(0, 16).replace('T', ' '),
      },
      { isKidsProfile: this.activeProfile.isKids }
    );

    if (!res.ok || !res.recommendations?.picks || res.recommendations.picks.length === 0) {
      return items;
    }

    const reordered: ItemRecord[] = [];
    const seen = new Set<number>();

    for (const pick of res.recommendations.picks) {
      const item = idToItemMap.get(pick.id);
      if (item && !seen.has(item.id)) {
        seen.add(item.id);
        const copy = { ...item };
        if (pick.reason) {
          (copy as any).aiReason = pick.reason;
        }
        reordered.push(copy);
      }
    }

    for (const item of items) {
      if (!seen.has(item.id)) {
        reordered.push(item);
      }
    }

    return reordered;
  }
}

