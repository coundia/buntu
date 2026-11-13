import type { ItemRecord } from '../storage/Database';
import { detectChannelQuality } from '../utils/categoryMeta';

/** A film is 4K when its title or its category says so (« 4K », « UHD », « 2160p »). */
export function isUhdTitle(item: Pick<ItemRecord, 'name' | 'group_title'>): boolean {
  return detectChannelQuality(item.name) === '4K' || detectChannelQuality(item.group_title ?? '') === '4K';
}
