export type SubtitleSize = 'small' | 'medium' | 'large';
export type SubtitleColor = 'white' | 'yellow' | 'cyan';

export interface SubtitlePrefs {
  size: SubtitleSize;
  color: SubtitleColor;
  opaqueBox: boolean;
}

const STORAGE_KEY = 'buntu.player.subtitles';
const SIZE_ORDER: SubtitleSize[] = ['small', 'medium', 'large'];
const COLOR_ORDER: SubtitleColor[] = ['white', 'yellow', 'cyan'];

const DEFAULT_PREFS: SubtitlePrefs = {
  size: 'medium',
  color: 'white',
  opaqueBox: true,
};

function isValidSize(v: unknown): v is SubtitleSize {
  return v === 'small' || v === 'medium' || v === 'large';
}

function isValidColor(v: unknown): v is SubtitleColor {
  return v === 'white' || v === 'yellow' || v === 'cyan';
}

/**
 * Reads persisted subtitle appearance preferences from localStorage.
 */
export function getSubtitlePrefs(): SubtitlePrefs {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) return { ...DEFAULT_PREFS };
    const parsed = JSON.parse(raw) as Partial<SubtitlePrefs> | null;
    return {
      size: isValidSize(parsed?.size) ? parsed.size : DEFAULT_PREFS.size,
      color: isValidColor(parsed?.color) ? parsed.color : DEFAULT_PREFS.color,
      opaqueBox: typeof parsed?.opaqueBox === 'boolean' ? parsed.opaqueBox : DEFAULT_PREFS.opaqueBox,
    };
  } catch {
    return { ...DEFAULT_PREFS };
  }
}

/**
 * Updates and persists subtitle appearance preferences.
 */
export function setSubtitlePrefs(patch: Partial<SubtitlePrefs>): SubtitlePrefs {
  const current = getSubtitlePrefs();
  const next: SubtitlePrefs = {
    size: isValidSize(patch.size) ? patch.size : current.size,
    color: isValidColor(patch.color) ? patch.color : current.color,
    opaqueBox: typeof patch.opaqueBox === 'boolean' ? patch.opaqueBox : current.opaqueBox,
  };
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(next));
  } catch {
    // Ignore storage errors on restricted TVs
  }
  return next;
}

export function nextSubtitleSize(current: SubtitleSize): SubtitleSize {
  return SIZE_ORDER[(SIZE_ORDER.indexOf(current) + 1) % SIZE_ORDER.length];
}

export function nextSubtitleColor(current: SubtitleColor): SubtitleColor {
  return COLOR_ORDER[(COLOR_ORDER.indexOf(current) + 1) % COLOR_ORDER.length];
}

export function subtitleSizeLabel(size: SubtitleSize): string {
  if (size === 'small') return 'Petit';
  if (size === 'large') return 'Grand';
  return 'Moyen';
}

export function subtitleColorLabel(color: SubtitleColor): string {
  if (color === 'yellow') return 'Jaune';
  if (color === 'cyan') return 'Cyan';
  return 'Blanc';
}

/**
 * Returns inline CSS properties for `.tv-subtitle-box` matching the user's preferences.
 */
export function subtitleBoxStyle(prefs: SubtitlePrefs): Record<string, string> {
  const fontSize = prefs.size === 'small' ? '24px' : prefs.size === 'large' ? '40px' : '32px';
  const color = prefs.color === 'yellow' ? '#FFE066' : prefs.color === 'cyan' ? '#4DE8FF' : '#FFFFFF';
  return {
    'font-size': fontSize,
    color,
    background: prefs.opaqueBox ? '#000000' : 'transparent',
    'text-shadow': prefs.opaqueBox ? 'none' : '0 2px 6px #000000, 0 0 2px #000000',
  };
}
