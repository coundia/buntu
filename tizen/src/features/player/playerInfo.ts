/**
 * Live facts shown by the full-screen player over the picture: the clock, what the TV decodes,
 * the TV program (now / next) for a channel, and the favorite flag. Kept apart from the view so
 * the view only has to display them.
 */

import { createSignal, createEffect, on, onCleanup, Accessor } from 'solid-js';
import type { EpgProgramRecord, ItemRecord } from '../../core/storage/Database';
import type { StreamSummary } from '../../core/player/streamInfo';
import { formatClock } from '../../core/utils/timeFormat';

export interface PlayerInfoDeps {
  player: { getStreamSummary(): StreamSummary | null };
  db: { getEpgUpcoming(tvgId: string, nowTs: number, count?: number): Promise<EpgProgramRecord[]> };
  engine: { toggleFavorite(itemId: number): Promise<boolean> };
}

export interface PlayerInfo {
  /** Unix time in seconds, refreshed every 15 s (drives clocks, progress bars and remaining times). */
  nowTs: Accessor<number>;
  clock: () => string;
  /** What the TV decodes for the running stream; null until it is known. */
  stream: Accessor<StreamSummary | null>;
  /** Programs of the current channel that have not ended, current one first (empty for films). */
  epg: Accessor<EpgProgramRecord[]>;
  isFavorite: Accessor<boolean>;
  toggleFavorite: () => Promise<boolean>;
}

const TICK_MS = 15000;
const STREAM_POLL_MS = 1500;

export function createPlayerInfo(getItem: () => ItemRecord, deps: PlayerInfoDeps): PlayerInfo {
  const [nowTs, setNowTs] = createSignal(Math.floor(Date.now() / 1000));
  const [stream, setStream] = createSignal<StreamSummary | null>(null);
  const [epg, setEpg] = createSignal<EpgProgramRecord[]>([]);
  const [isFavorite, setIsFavorite] = createSignal(getItem().is_favorite === 1);

  const tick = setInterval(() => setNowTs(Math.floor(Date.now() / 1000)), TICK_MS);
  const poll = setInterval(() => {
    const summary = deps.player.getStreamSummary();
    if (summary) setStream(summary);
  }, STREAM_POLL_MS);
  onCleanup(() => {
    clearInterval(tick);
    clearInterval(poll);
  });

  // Another channel (zapping) or film: forget the previous facts.
  createEffect(
    on(
      () => getItem().id,
      () => {
        setStream(null);
        setIsFavorite(getItem().is_favorite === 1);
      }
    )
  );

  // The program guide of the channel, re-read every tick so the "now" program moves on by itself.
  createEffect(() => {
    const item = getItem();
    const now = nowTs();
    if (item.kind !== 'live' || !item.tvg_id) {
      setEpg([]);
      return;
    }
    const id = item.id;
    deps.db
      .getEpgUpcoming(item.tvg_id, now, 4)
      .then((programs) => {
        if (getItem().id === id) setEpg(programs);
      })
      .catch(() => {
        if (getItem().id === id) setEpg([]);
      });
  });

  const toggleFavorite = async () => {
    const item = getItem();
    const next = await deps.engine.toggleFavorite(item.id);
    item.is_favorite = next ? 1 : 0;
    setIsFavorite(next);
    return next;
  };

  return { nowTs, clock: () => formatClock(nowTs()), stream, epg, isFavorite, toggleFavorite };
}
