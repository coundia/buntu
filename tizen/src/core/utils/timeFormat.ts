/** Small time formatting helpers for the panels (French, 24 h). */

/** 5 025 000 ms → "1:23:45"; 725 000 → "12:05". */
export function formatDuration(ms: number): string {
  const total = Math.max(0, Math.floor(ms / 1000));
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  const two = (n: number) => String(n).padStart(2, '0');
  return h > 0 ? `${h}:${two(m)}:${two(s)}` : `${m}:${two(s)}`;
}

/** 5 520 000 ms → "1 h 32", 2 700 000 → "45 min". */
export function formatRuntime(ms: number): string {
  const minutes = Math.round(ms / 60000);
  if (minutes <= 0) return '';
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  if (h === 0) return `${m} min`;
  return `${h} h ${String(m).padStart(2, '0')}`;
}

/** A unix timestamp (seconds) as "21:05". */
export function formatClock(ts: number): string {
  const d = new Date(ts * 1000);
  return `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
}

/** Progress 0..100 of `position` inside `duration` (0 when the duration is unknown). */
export function percentOf(position: number, duration: number): number {
  if (!(duration > 0)) return 0;
  return Math.min(100, Math.max(0, Math.round((position / duration) * 100)));
}
