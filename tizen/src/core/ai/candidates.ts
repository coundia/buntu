/**
 * CND IPTV Tizen - Candidate Extraction for AI (PRD 40 § 3.2, § 5 & § 8)
 *
 * Gathers at most 40-60 candidates from IndexedDB, cleans names and attaches currently
 * airing programmes, ensuring NO credentials, stream URLs or server hosts are ever sent.
 */
import { Database, ItemRecord } from '../storage/Database';

export interface AiCandidate {
  id: number;
  name: string;
  group_title?: string;
  chno?: number;
  is_favorite: boolean;
  current_programme?: string;
  next_programme?: string;
}

const MAX_COMMAND_CANDIDATES = 40;
const MAX_RECO_CANDIDATES = 60;

function cleanString(s: unknown): string {
  if (typeof s !== 'string') return '';
  return s.replace(/[\u0000-\u001f\u007f]/g, '').trim();
}

/**
 * Gathers up to 40 live channel candidates from favorites, recent channels, and matching names.
 */
export async function gatherCommandCandidates(
  query: string,
  recentItemIds: number[] = []
): Promise<AiCandidate[]> {
  const db = Database.getInstance();
  await db.init();

  const candidatesMap = new Map<number, AiCandidate>();
  const addCandidate = (item: ItemRecord, programme?: string) => {
    if (candidatesMap.has(item.id)) return;
    if (candidatesMap.size >= MAX_COMMAND_CANDIDATES) return;
    candidatesMap.set(item.id, {
      id: item.id,
      name: cleanString(item.name_clean || item.name),
      group_title: item.group_title ? cleanString(item.group_title) : undefined,
      chno: item.chno,
      is_favorite: Boolean(item.is_favorite),
      current_programme: programme ? cleanString(programme) : undefined,
    });
  };

  // 1. Add recent channels
  for (const id of recentItemIds.slice(0, 10)) {
    const item = await db.getItemById(id);
    if (item && item.kind === 'live') {
      const epg = item.tvg_id ? (await db.getEpgNowNext(item.tvg_id, Date.now())).now : null;
      addCandidate(item, epg?.title);
    }
  }

  // 2. Add favorites
  const favorites = (await db.getFavorites()).filter((item) => item.kind === 'live');
  for (const item of favorites.slice(0, 15)) {
    const epg = item.tvg_id ? (await db.getEpgNowNext(item.tvg_id, Date.now())).now : null;
    addCandidate(item, epg?.title);
  }

  // 3. Match by search query tokens if space remains
  const words = query
    .toLowerCase()
    .replace(/[^\w\s]/g, '')
    .split(/\s+/)
    .filter((w) => w.length >= 2);

  if (words.length > 0 && candidatesMap.size < MAX_COMMAND_CANDIDATES) {
    // Search by channel name
    const matches = await db.searchItems(words[0], 'live', 30);
    for (const item of matches) {
      const epg = item.tvg_id ? (await db.getEpgNowNext(item.tvg_id, Date.now())).now : null;
      addCandidate(item, epg?.title);
    }
  }

  return Array.from(candidatesMap.values());
}

/**
 * Builds candidate payload for recommendation re-ranking (PRD 40 § 6.3).
 */
export function buildRecommendationCandidates(
  items: ItemRecord[],
  prefix: 'm' | 's' | 't' = 'm'
): { opaqueIds: string[]; candidates: any[]; idToItemMap: Map<string, ItemRecord> } {
  const bounded = items.slice(0, MAX_RECO_CANDIDATES);
  const opaqueIds: string[] = [];
  const candidates: any[] = [];
  const idToItemMap = new Map<string, ItemRecord>();

  bounded.forEach((item, index) => {
    const opaqueId = `${prefix}${index + 1}`;
    opaqueIds.push(opaqueId);
    idToItemMap.set(opaqueId, item);

    candidates.push({
      id: opaqueId,
      title: cleanString(item.name_clean || item.name),
      year: item.year,
      category: item.group_title ? cleanString(item.group_title) : '',
    });
  });

  return { opaqueIds, candidates, idToItemMap };
}
