import type { ItemRecord } from '../../core/storage/Database';
import { cleanMediaTitle } from '../../core/utils/titleCleaner';
import { formatDuration, percentOf } from '../../core/utils/timeFormat';

export interface ResumeInfo {
  /** « Film », « Série », « Épisode S02E05 » or « En direct ». */
  kind: string;
  title: string;
  /** What OK does: « Reprendre à 42:10 · 35 % », « Retourner sur la chaîne », « Ouvrir la série ». */
  action: string;
  /** 0..100 for a film or an episode that was started, otherwise `undefined`. */
  percent?: number;
}

const pad2 = (n: number) => String(n).padStart(2, '0');

/** What the home says about the last thing watched. Text only: no picture, no network. */
export function describeResume(item: ItemRecord): ResumeInfo {
  const title = (item.name_clean && item.name_clean !== item.name ? item.name_clean : cleanMediaTitle(item.name).clean) || item.name;
  if (item.kind === 'live') {
    return { kind: 'En direct', title, action: 'Retourner sur cette chaîne' };
  }
  if (item.kind === 'series') {
    return { kind: 'Série', title, action: 'Ouvrir la série' };
  }
  const kind = item.kind === 'episode'
    ? `Épisode${item.season_num ? ` S${pad2(item.season_num)}E${pad2(item.episode_num ?? 0)}` : ''}`
    : 'Film';
  const started = item.playback_position_ms > 0;
  const percent = started && item.duration_ms > 0 ? percentOf(item.playback_position_ms, item.duration_ms) : undefined;
  const action = started
    ? `Reprendre à ${formatDuration(item.playback_position_ms)}${percent !== undefined ? ` · ${percent} %` : ''}`
    : 'Reprendre la lecture';
  return { kind, title, action, percent };
}
