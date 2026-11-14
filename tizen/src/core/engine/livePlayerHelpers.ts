import type { EpgProgramRecord, ItemRecord } from '../storage/Database';
import { detectChannelQuality } from '../utils/categoryMeta';
import { channelFamily } from './liveRecommendations';

const QUALITY_RANK: Record<string, number> = {
  '4K': 4,
  FHD: 3,
  HD: 2,
};

function qualityScore(name: string): number {
  const q = detectChannelQuality(name);
  return q ? (QUALITY_RANK[q] ?? 1) : 1;
}

function normalizedTvgId(tvgId?: string): string {
  return (tvgId ?? '').trim().toLowerCase();
}

function normalizedFamily(item: Pick<ItemRecord, 'name' | 'name_clean'>): string {
  return channelFamily(item.name_clean || item.name);
}

/** True when two live items represent alternate streams (mirrors) of the same TV channel. */
export function isSameLiveChannel(
  a: Pick<ItemRecord, 'name' | 'name_clean' | 'tvg_id'>,
  b: Pick<ItemRecord, 'name' | 'name_clean' | 'tvg_id'>
): boolean {
  const tvgA = normalizedTvgId(a.tvg_id);
  const tvgB = normalizedTvgId(b.tvg_id);
  if (tvgA && tvgB && tvgA === tvgB) return true;
  const famA = normalizedFamily(a);
  const famB = normalizedFamily(b);
  return Boolean(famA && famB && famA === famB);
}

/**
 * Ranks healthy alternative live streams (`is_broken !== 1`) matching `target` by `tvg_id` or cleaned family name.
 * Ordered: 4K > FHD > HD > SD, same source before external source, then alphabetical name.
 */
export function rankLiveMirrors(target: ItemRecord, candidates: ItemRecord[]): ItemRecord[] {
  if (target.kind !== 'live') return [];
  const matches = candidates.filter(
    (c) => c.kind === 'live' && c.id !== target.id && c.is_broken !== 1 && isSameLiveChannel(target, c)
  );
  return matches.sort((a, b) => {
    const qa = qualityScore(a.name);
    const qb = qualityScore(b.name);
    if (qb !== qa) return qb - qa;
    const sa = a.source_id === target.source_id ? 1 : 0;
    const sb = b.source_id === target.source_id ? 1 : 0;
    if (sb !== sa) return sb - sa;
    return (a.name_clean || a.name).localeCompare(b.name_clean || b.name);
  });
}

/** Resolves channel by explicit `chno` first (preferring working streams), then 1-based list order fallback. */
export function findChannelByNumber(channels: ItemRecord[], chno: number): ItemRecord | null {
  if (!Number.isInteger(chno) || chno <= 0 || channels.length === 0) return null;
  const exactMatches = channels.filter((ch) => ch.kind === 'live' && ch.chno === chno);
  if (exactMatches.length > 0) {
    return exactMatches.find((ch) => ch.is_broken !== 1) ?? exactMatches[0];
  }
  const hasExplicitNumbers = channels.some((ch) => (ch.chno ?? 0) > 0);
  if (!hasExplicitNumbers && chno <= channels.length) {
    return channels[chno - 1] ?? null;
  }
  return null;
}

function appendQuery(streamUrl: string, query: string): string {
  const clean = query.replace(/^[?&]+/, '');
  return streamUrl.includes('?') ? `${streamUrl}&${clean}` : `${streamUrl}?${clean}`;
}

function pad2(n: number): string {
  return String(Math.floor(n)).padStart(2, '0');
}

function tryBuildXtreamTimeshiftUrl(streamUrl: string, startTs: number, endTs: number): string | null {
  const match = streamUrl.match(/^(https?:\/\/[^/?#]+)(\/[^?#]*)?$/i);
  if (!match) return null;
  const origin = match[1];
  const segments = (match[2] ?? '').split('/').filter(Boolean);
  let user = '';
  let pass = '';
  let streamFile = '';
  if (segments.length === 4 && segments[0] === 'live') {
    [, user, pass, streamFile] = segments;
  } else if (
    segments.length === 3 &&
    segments[0] !== 'movie' &&
    segments[0] !== 'series' &&
    segments[0] !== 'timeshift' &&
    segments[0] !== 'player_api.php'
  ) {
    [user, pass, streamFile] = segments;
  } else {
    return null;
  }
  const d = new Date(startTs * 1000);
  const timeStr = `${d.getUTCFullYear()}-${pad2(d.getUTCMonth() + 1)}-${pad2(d.getUTCDate())}:${pad2(d.getUTCHours())}-${pad2(d.getUTCMinutes())}`;
  const durationSecs = Math.max(60, endTs - startTs);
  const durationMin = Math.max(1, Math.ceil(durationSecs / 60));
  return `${origin}/timeshift/${user}/${pass}/${durationMin}/${timeStr}/${streamFile}`;
}

/** Builds a Start-Over / catchup URL aligned with `cnd-core::iptv::catchup::build_catchup_url`. */
export function buildLiveCatchupUrl(
  item: Pick<ItemRecord, 'stream_url' | 'catchup_type' | 'catchup_days'>,
  program: Pick<EpgProgramRecord, 'start_ts' | 'end_ts'>,
  nowTs: number
): string | null {
  const cType = (item.catchup_type ?? '').trim().toLowerCase();
  const hasDays = (item.catchup_days ?? 0) > 0;
  const typeDisabled = cType === 'false' || cType === 'no';
  if (typeDisabled || (!hasDays && !cType)) return null;
  if (program.start_ts > nowTs) return null;

  const retentionDays = Math.max(1, item.catchup_days ?? 7);
  if (nowTs - program.start_ts > retentionDays * 86400) return null;

  const streamUrl = item.stream_url.trim();
  if (!streamUrl) return null;

  const xtreamUrl = tryBuildXtreamTimeshiftUrl(streamUrl, program.start_ts, program.end_ts);
  if (xtreamUrl) return xtreamUrl;

  if (cType === 'flussonic' || cType === 'fs') {
    if (streamUrl.endsWith('/index.m3u8')) {
      return `${streamUrl.slice(0, -'/index.m3u8'.length)}/timeshift_abs-${program.start_ts}.m3u8`;
    }
    if (streamUrl.endsWith('/mono.m3u8')) {
      return `${streamUrl.slice(0, -'/mono.m3u8'.length)}/timeshift_abs-${program.start_ts}.m3u8`;
    }
    const idx = streamUrl.lastIndexOf('.m3u8');
    if (idx !== -1) {
      return `${streamUrl.slice(0, idx)}/timeshift_abs-${program.start_ts}.m3u8`;
    }
    return appendQuery(streamUrl, `timeshift_abs=${program.start_ts}`);
  }

  if (cType === 'shift') {
    const offset = Math.max(0, nowTs - program.start_ts);
    return appendQuery(streamUrl, `timeshift=${offset}`);
  }

  return appendQuery(streamUrl, `utc=${program.start_ts}&lutc=${nowTs}`);
}

/**
 * Coalesces rapid Ch+/Ch- keypresses (anti HTTP 429): `currentTarget()` tracks each step
 * synchronously for UI feedback, while `onCommit` fires only after `delayMs` of calm.
 */
export function createZapDebouncer<T>(delayMs: number, onCommit: (target: T) => void) {
  let timer: ReturnType<typeof setTimeout> | null = null;
  let target: T | null = null;

  return {
    schedule(nextTarget: T) {
      target = nextTarget;
      if (timer) clearTimeout(timer);
      timer = setTimeout(() => {
        timer = null;
        const resolved = target;
        target = null;
        if (resolved !== null) onCommit(resolved);
      }, delayMs);
    },
    cancel() {
      if (timer) clearTimeout(timer);
      timer = null;
      target = null;
    },
    currentTarget(): T | null {
      return target;
    },
  };
}
