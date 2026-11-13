import type { ItemRecord } from '../storage/Database';

/**
 * Features of a channel for the shared recommendation scoring (`cnd-domain` `recommend::scoring`, WebAssembly):
 * « channel:<name without quality tags> » and « group:<category> », the names the other platforms use
 * (`cnd-core` `live_features`). Only the scoring rule is shared; features are read from the TV's catalogue.
 */
const clean = (s: string) => s.split(/\s+/).filter(Boolean).join(' ').toLowerCase();

const QUALITY_TAGS = /\b(uhd|fhd|hd|sd|4k|hevc|h265|h264|50fps|60fps)\b/g;

/** « TF1 HD » and « TF1 FHD » are the same channel for taste purposes. */
export function channelFamily(nameClean: string): string {
  return clean(nameClean.replace(/\[[^\]]*\]|\([^)]*\)/g, ' ').toLowerCase().replace(QUALITY_TAGS, ' ').replace(/[|:_-]+/g, ' '));
}

export function liveFeatures(channel: ItemRecord): string[] {
  const out: string[] = [];
  const family = channelFamily(channel.name_clean || channel.name);
  if (family) out.push(`channel:${family}`);
  const group = clean(channel.group_title ?? '');
  if (group) out.push(`group:${group}`);
  return out;
}

/**
 * The taste of the viewer from the channels watched lately (most recent first, each counting a bit less) and the
 * favourites (a stronger signal); weights are scaled so the strongest is 1, as `Taste::finish` does.
 */
export function liveTaste(recents: ItemRecord[], favorites: ItemRecord[]): { weights: Record<string, number>; samples: number } {
  const weights: Record<string, number> = {};
  let samples = 0;
  const add = (channel: ItemRecord, weight: number) => {
    const features = liveFeatures(channel);
    if (features.length === 0) return;
    samples += 1;
    for (const f of features) weights[f] = (weights[f] ?? 0) + weight;
  };
  recents.forEach((channel, index) => add(channel, Math.max(0.2, 1 - index * 0.1)));
  favorites.forEach((channel) => add(channel, 1.2));
  const max = Math.max(0, ...Object.values(weights));
  if (max > 0) for (const key of Object.keys(weights)) weights[key] /= max;
  return { weights, samples };
}

export function toLiveCandidate(channel: ItemRecord) {
  return {
    id: channel.id,
    name: channel.name,
    name_clean: channel.name_clean,
    kind: channel.kind,
    group_title: channel.group_title ?? null,
    year: null,
    imdb_rating: null,
    features: liveFeatures(channel),
  };
}

/**
 * The best scored channels, one per channel family (the HD and SD copies of a channel are one proposal), without
 * the ones already known to the viewer (`excluded` families and ids) and without the ones marked out of service.
 */
export function pickRecommendedChannels(
  scored: { item: { id: number }; score: number }[],
  byId: Map<number, ItemRecord>,
  excludedIds: Set<number>,
  excludedFamilies: Set<string>,
  limit: number
): ItemRecord[] {
  const seen = new Set(excludedFamilies);
  const out: ItemRecord[] = [];
  for (const entry of scored) {
    const channel = byId.get(entry.item.id);
    if (!channel || excludedIds.has(channel.id) || channel.is_broken === 1 || entry.score <= 0) continue;
    const family = channelFamily(channel.name_clean || channel.name);
    if (family && seen.has(family)) continue;
    if (family) seen.add(family);
    out.push(channel);
    if (out.length >= limit) break;
  }
  return out;
}
