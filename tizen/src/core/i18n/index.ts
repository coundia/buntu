import { createSignal } from 'solid-js';
import { fr, type TranslationKey } from './fr';
import { en } from './en';

export type AppLanguage = 'fr' | 'en';
export type { TranslationKey };
export type TranslationParams = Record<string, string | number>;

export const DEFAULT_LANGUAGE: AppLanguage = 'fr';
export const LANGUAGE_STORAGE_KEY = 'buntu_app_language';

function readStoredLanguage(): AppLanguage {
  try {
    if (typeof localStorage !== 'undefined') {
      const saved = localStorage.getItem(LANGUAGE_STORAGE_KEY);
      if (saved === 'fr' || saved === 'en') {
        return saved;
      }
    }
  } catch {
    // Ignore storage access errors in restricted environments.
  }
  return DEFAULT_LANGUAGE;
}

const [appLanguage, setAppLanguageSignal] = createSignal<AppLanguage>(readStoredLanguage());

export { appLanguage };

export function setAppLanguage(lang: AppLanguage): void {
  const next: AppLanguage = lang === 'en' ? 'en' : 'fr';
  setAppLanguageSignal(next);
  try {
    if (typeof localStorage !== 'undefined') {
      localStorage.setItem(LANGUAGE_STORAGE_KEY, next);
    }
  } catch {
    // Ignore storage write errors in restricted environments.
  }
}

export function t(key: TranslationKey, params?: TranslationParams): string {
  const lang = appLanguage();
  const dict: Record<string, string> = lang === 'en' ? en : fr;
  let text = dict[key];
  if (text === undefined) {
    text = fr[key];
  }
  if (text === undefined) {
    return String(key);
  }
  if (!params) {
    return text;
  }
  return text.replace(/\{(\w+)\}/g, (match, k: string) => {
    const val = params[k];
    return val !== undefined ? String(val) : match;
  });
}

export { fr, en };
