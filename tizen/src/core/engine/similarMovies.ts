import type { ItemRecord } from '../storage/Database';
import { cleanMediaTitle } from '../utils/titleCleaner';

/**
 * Features of a film for the shared recommendation scoring (`cnd-domain` `recommend::scoring`, run in WebAssembly).
 * Same names as the engine of the other platforms (`cnd-core` `movie_features`): « group:… », « decade:… »,
 * and « genre:… » / « director:… » / « actor:… » when the provider gave them. Only the scoring rule is shared;
 * the features are read from what the TV has in its catalogue.
 */
const clean = (s: string) => s.split(/\s+/).filter(Boolean).join(' ').toLowerCase();
const list = (s: string | undefined, max: number) =>
  (s ?? '').split(',').map(clean).filter((v) => v && v !== 'n/a').slice(0, max);

export interface FilmFacts {
  genre?: string;
  director?: string;
  cast?: string;
}

export function movieFeatures(item: ItemRecord, facts?: FilmFacts | null): string[] {
  const out: string[] = [];
  out.push(...list(facts?.genre, 4).map((v) => `genre:${v}`));
  out.push(...list(facts?.director, 2).map((v) => `director:${v}`));
  out.push(...list(facts?.cast, 3).map((v) => `actor:${v}`));
  const year = item.year || cleanMediaTitle(item.name).year;
  if (year && year >= 1900 && year < 2100) out.push(`decade:${Math.floor(year / 10) * 10}`);
  const group = clean(item.group_title ?? '');
  if (group) out.push(`group:${group}`);
  return out;
}

/** The taste « what resembles this film »: each of its features counts the same. */
export function tasteOf(features: string[]): { weights: Record<string, number>; samples: number } {
  const weights: Record<string, number> = {};
  for (const feature of features) weights[feature] = 1;
  return { weights, samples: features.length > 0 ? 1 : 0 };
}

export function toCandidate(item: ItemRecord) {
  return {
    id: item.id,
    name: item.name,
    name_clean: item.name_clean,
    kind: item.kind,
    group_title: item.group_title ?? null,
    year: item.year ?? null,
    imdb_rating: item.imdb_rating ?? null,
    features: movieFeatures(item),
  };
}

/** `true` for a film practically finished: not worth proposing as « next ». */
export function isFinished(item: ItemRecord): boolean {
  return item.duration_ms > 0 && item.playback_position_ms / item.duration_ms >= 0.95;
}

/** The scored items back to catalogue records, best first, without the film being watched. */
export function pickSimilar(
  scored: { item: { id: number }; score: number }[],
  byId: Map<number, ItemRecord>,
  currentId: number,
  limit: number
): ItemRecord[] {
  const out: ItemRecord[] = [];
  for (const entry of scored) {
    const item = byId.get(entry.item.id);
    if (!item || item.id === currentId || isFinished(item)) continue;
    out.push(item);
    if (out.length >= limit) break;
  }
  return out;
}
