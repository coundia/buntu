export type TextSizePreset = 'standard' | 'large' | 'xlarge';

export interface AccessibilityPrefs {
  highContrast: boolean;
  textSize: TextSizePreset;
}

const STORAGE_KEY = 'buntu.ui.accessibility';
const TEXT_SIZE_ORDER: TextSizePreset[] = ['standard', 'large', 'xlarge'];

const DEFAULT_PREFS: AccessibilityPrefs = {
  highContrast: false,
  textSize: 'standard',
};

function isValidTextSize(value: unknown): value is TextSizePreset {
  return value === 'standard' || value === 'large' || value === 'xlarge';
}

/**
 * Reads persisted TV accessibility preferences from localStorage.
 */
export function getAccessibilityPrefs(): AccessibilityPrefs {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) return { ...DEFAULT_PREFS };
    const parsed = JSON.parse(raw) as Partial<AccessibilityPrefs> | null;
    return {
      highContrast: parsed?.highContrast === true,
      textSize: isValidTextSize(parsed?.textSize) ? parsed.textSize : 'standard',
    };
  } catch {
    return { ...DEFAULT_PREFS };
  }
}

/**
 * Updates, persists, and applies TV accessibility preferences.
 */
export function setAccessibilityPrefs(patch: Partial<AccessibilityPrefs>): AccessibilityPrefs {
  const current = getAccessibilityPrefs();
  const next: AccessibilityPrefs = {
    highContrast: typeof patch.highContrast === 'boolean' ? patch.highContrast : current.highContrast,
    textSize: isValidTextSize(patch.textSize) ? patch.textSize : current.textSize,
  };
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(next));
  } catch {
    // Ignore storage quota/unavailable errors on restricted TVs
  }
  applyAccessibilityPrefs(next);
  return next;
}

/**
 * Cycles through available text size presets: standard -> large -> xlarge -> standard.
 */
export function nextTextSizePreset(current: TextSizePreset): TextSizePreset {
  const idx = TEXT_SIZE_ORDER.indexOf(current);
  return TEXT_SIZE_ORDER[(idx + 1) % TEXT_SIZE_ORDER.length];
}

/**
 * Returns the localized French label for a text size preset.
 */
export function textSizeLabel(size: TextSizePreset): string {
  if (size === 'large') return 'Grand (115 %)';
  if (size === 'xlarge') return 'Très grand (130 %)';
  return 'Standard (100 %)';
}

/**
 * Applies high-contrast and text-size attributes to the root document element.
 */
export function applyAccessibilityPrefs(
  prefs: AccessibilityPrefs,
  root: HTMLElement | null = typeof document !== 'undefined' ? document.documentElement : null
): void {
  if (!root) return;
  if (prefs.highContrast) {
    root.setAttribute('data-high-contrast', 'true');
  } else {
    root.removeAttribute('data-high-contrast');
  }
  root.setAttribute('data-text-size', prefs.textSize);
}
