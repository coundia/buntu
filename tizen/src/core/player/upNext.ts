/**
 * « À suivre » at the end of a film: whether the next film starts by itself, after how many seconds, and how many
 * films may follow one another without anybody pressing a key. Same defaults as macOS (automatic, 10 s) and the
 * same limit as Android (3 in a row, then « Toujours là ? »).
 */

export interface UpNextPrefs {
  auto: boolean;
  seconds: number;
}

export const COUNTDOWN_CHOICES = [5, 10, 15, 30];
export const DEFAULT_UP_NEXT: UpNextPrefs = { auto: true, seconds: 10 };
export const MAX_AUTO_CHAIN = 3;

const STORAGE_KEY = 'buntu.upnext';

export function getUpNextPrefs(): UpNextPrefs {
  try {
    const raw = JSON.parse(localStorage.getItem(STORAGE_KEY) ?? 'null');
    const seconds = COUNTDOWN_CHOICES.includes(raw?.seconds) ? raw.seconds : DEFAULT_UP_NEXT.seconds;
    return { auto: typeof raw?.auto === 'boolean' ? raw.auto : DEFAULT_UP_NEXT.auto, seconds };
  } catch {
    return { ...DEFAULT_UP_NEXT };
  }
}

export function setUpNextPrefs(partial: Partial<UpNextPrefs>): UpNextPrefs {
  const next = { ...getUpNextPrefs(), ...partial };
  if (!COUNTDOWN_CHOICES.includes(next.seconds)) next.seconds = DEFAULT_UP_NEXT.seconds;
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(next));
  } catch {
    /* storage unavailable: the choice lasts for this visit */
  }
  return next;
}

/** The next duration of the countdown in the list of choices (5 → 10 → 15 → 30 → 5). */
export function nextCountdownChoice(current: number): number {
  const i = COUNTDOWN_CHOICES.indexOf(current);
  return COUNTDOWN_CHOICES[(i + 1) % COUNTDOWN_CHOICES.length];
}

/** Films started by themselves in a row: the chain stops (« Toujours là ? ») when it reaches the limit. */
let autoChain = 0;
export const upNextChain = {
  count: () => autoChain,
  /** Somebody pressed a key or chose a film: the chain starts over. */
  reset: () => { autoChain = 0; },
  /** One more film started by itself. */
  advance: () => { autoChain += 1; },
  /** The limit is reached: the next film waits for a key press. */
  isStillWatchingDue: () => autoChain >= MAX_AUTO_CHAIN,
};
