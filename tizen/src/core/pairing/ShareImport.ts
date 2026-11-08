/**
 * Reads the sources a phone sent (PRD 39 / PRD 26: `cnd-source-share` document) and adds them.
 *
 * Preview first: what the TV shows to be confirmed shows the account name, its type and the HOST of
 * the server only, never a password or a complete address. Nothing is added before the user agrees.
 */
import { CndEngine } from '../engine/CndEngine';
import { Database, SourceRecord } from '../storage/Database';

export interface SharedSource {
  name: string;
  type: 'xtream' | 'm3u';
  server?: string;
  username?: string;
  password?: string;
  url?: string;
  epgUrl?: string;
}

export interface PreviewSource {
  name: string;
  type: 'xtream' | 'm3u';
  /** `host:port` of the server, nothing more. */
  host: string;
  hasPassword: boolean;
  duplicate: boolean;
}

export interface SharePreview {
  sources: PreviewSource[];
  /** Same order as `sources`: what will be added. */
  pending: SharedSource[];
}

const MAX_SOURCES = 20;
const MAX_TEXT = 300;

const clean = (v: unknown, max = MAX_TEXT): string =>
  typeof v === 'string' ? v.replace(/[\u0000-\u001f\u007f]/g, '').trim().slice(0, max) : '';

export function hostOf(address: string): string {
  try {
    const u = new URL(address);
    return u.host;
  } catch {
    return '';
  }
}

const normalizeServer = (s: string) => s.trim().toLowerCase().replace(/\/+$/, '');
const normalizeUrl = (s: string) => s.trim().toLowerCase().replace(/\/+$/, '');

export interface ParseShareOptions {
  /**
   * Check `doc.expires_at` against local `Date.now()`.
   * Defaults to `true` for standalone files/links; set to `false` inside a live QR pairing session
   * whose 5-minute freshness was already verified against the TV's own monotonic clock, avoiding
   * false expiry errors when the TV's wall clock differs from the phone's wall clock.
   */
  checkExpiry?: boolean;
}

export type ImportProgressCallback = (message: string, percent?: number) => void;

/** Throws a short French message when the document is not one we understand. */
export function parseShareDocument(json: string, options: ParseShareOptions = {}): SharedSource[] {
  let doc: any;
  try {
    doc = JSON.parse(json);
  } catch {
    throw new Error('Document de partage illisible');
  }
  if (doc?.format !== 'cnd-source-share' || doc?.version !== 1 || !Array.isArray(doc.sources)) {
    throw new Error('Ce n’est pas un partage de sources Buntu');
  }
  if (options.checkExpiry !== false && typeof doc.expires_at === 'number' && doc.expires_at * 1000 < Date.now()) {
    throw new Error('Ce partage a expiré');
  }
  const out: SharedSource[] = [];
  for (const raw of doc.sources.slice(0, MAX_SOURCES)) {
    const type = raw?.type === 'm3u' ? 'm3u' : raw?.type === 'xtream' ? 'xtream' : null;
    if (!type) continue;
    const name = clean(raw.name, 80) || 'Ma source';
    if (type === 'xtream') {
      const server = clean(raw.server);
      const username = clean(raw.username);
      if (!/^https?:\/\//i.test(server) || !username) continue;
      const password = typeof raw.password === 'string' ? raw.password.slice(0, 200) : undefined;
      out.push({ name, type, server, username, password: password || undefined, epgUrl: clean(raw.epg_url) || undefined });
    } else {
      const url = clean(raw.url, 2000);
      if (!/^https?:\/\//i.test(url)) continue;
      out.push({ name, type, url, epgUrl: clean(raw.epg_url) || undefined });
    }
  }
  if (out.length === 0) throw new Error('Aucun compte utilisable dans ce partage');
  return out;
}

export function isDuplicate(candidate: SharedSource, existing: SourceRecord[]): boolean {
  return existing.some((e) => {
    if (candidate.type === 'xtream') {
      return (
        e.source_type === 'xtream' &&
        normalizeServer(e.server ?? '') === normalizeServer(candidate.server ?? '') &&
        (e.username ?? '') === (candidate.username ?? '')
      );
    }
    return e.source_type === 'm3u' && normalizeUrl(e.url ?? '') === normalizeUrl(candidate.url ?? '');
  });
}

/** Finds the existing source record matching the candidate if it is a duplicate. */
export function findDuplicate(candidate: SharedSource, existing: SourceRecord[]): SourceRecord | undefined {
  return existing.find((e) => {
    if (candidate.type === 'xtream') {
      return (
        e.source_type === 'xtream' &&
        normalizeServer(e.server ?? '') === normalizeServer(candidate.server ?? '') &&
        (e.username ?? '') === (candidate.username ?? '')
      );
    }
    return e.source_type === 'm3u' && normalizeUrl(e.url ?? '') === normalizeUrl(candidate.url ?? '');
  });
}

export interface ApplyShareOptions {
  /** When true, existing duplicate accounts are deleted and replaced by the new ones. */
  replaceDuplicates?: boolean;
  /** Optional existing sources list (defaults to querying Database). */
  existingSources?: SourceRecord[];
}

/** What the confirmation shows. A duplicate is listed but not added again unless replaceDuplicates is set. */
export function previewShare(json: string, existing: SourceRecord[], options: ParseShareOptions = {}): SharePreview {
  const all = parseShareDocument(json, options);
  const sources: PreviewSource[] = [];
  const pending: SharedSource[] = [];
  for (const s of all) {
    const duplicate = isDuplicate(s, existing);
    sources.push({
      name: s.name,
      type: s.type,
      host: hostOf(s.type === 'xtream' ? s.server! : s.url!),
      hasPassword: s.type === 'xtream' && !!s.password,
      duplicate,
    });
    pending.push(s);
  }
  return { sources, pending };
}

/** Adds the sources and starts their synchronisation. Returns how many. */
export async function applyShare(
  preview: SharePreview,
  engine: CndEngine = CndEngine.getInstance(),
  onProgress?: ImportProgressCallback,
  options: ApplyShareOptions = {}
): Promise<number> {
  const existing = options.existingSources ?? (await Database.getInstance().getSources());
  let added = 0;
  const actionable = preview.sources
    .map((meta, i) => ({ meta, source: preview.pending[i] }))
    .filter(({ meta, source }) => (!meta.duplicate || options.replaceDuplicates) && (source.type !== 'xtream' || !!source.password));

  for (let idx = 0; idx < actionable.length; idx++) {
    const { meta, source: s } = actionable[idx];
    if (meta.duplicate && options.replaceDuplicates) {
      const dup = findDuplicate(s, existing);
      if (dup?.id) {
        await engine.deleteSource(dup.id);
      }
    }
    const prefix = actionable.length > 1 ? `[${idx + 1}/${actionable.length}] ` : '';
    const forwardProgress: ImportProgressCallback = (msg, pct) => {
      const overallPct =
        pct !== undefined
          ? Math.round(((idx + pct / 100) / actionable.length) * 100)
          : undefined;
      onProgress?.(`${prefix}${msg}`, overallPct);
    };
    // One source after the other: a one-connection subscription cannot download two playlists at once.
    if (s.type === 'xtream') {
      await engine.syncXtreamSource(s.name, s.server!, s.username!, s.password!, s.epgUrl, forwardProgress);
    } else {
      await engine.syncM3uSource(s.name, s.url!, forwardProgress);
    }
    added += 1;
  }
  return added;
}

export async function existingSources(): Promise<SourceRecord[]> {
  return Database.getInstance().getSources();
}
