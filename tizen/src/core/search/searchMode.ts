import { createSignal } from 'solid-js';
import { AiProviderType, getAiSettings, hasUserConsent, saveAiSettings } from '../ai/AiSettings';
import { AiKeyStore } from '../ai/AiKeyStore';
import type { CndEngine } from '../engine/CndEngine';
import type { ItemRecord } from '../storage/Database';

/**
 * Which search engine the TV uses: « local » (the catalogue only) or « ai » (the catalogue, then the assistant).
 * One choice for every screen (Live, Films, Séries, Recherche), kept between visits.
 */
export type SearchMode = 'local' | 'ai';

const STORAGE_KEY = 'buntu.search.mode';

/**
 * The provider the assistant will use, or `null` when none is configured. A provider is configured when it is
 * selected, or when a key is saved for it (a key received from the household does not select the provider).
 */
export async function configuredProvider(): Promise<AiProviderType | null> {
  const selected = getAiSettings().provider;
  if (selected !== 'local_only') return selected;
  for (const provider of ['gemini', 'anthropic', 'openai_compatible'] as AiProviderType[]) {
    try {
      if (await AiKeyStore.getInstance().hasApiKey(provider)) return provider;
    } catch {
      /* vault unavailable: treated as no key */
    }
  }
  return null;
}

const load = (): SearchMode => {
  try {
    return localStorage.getItem(STORAGE_KEY) === 'ai' ? 'ai' : 'local';
  } catch {
    return 'local';
  }
};

const [mode, setModeSignal] = createSignal<SearchMode>(load());

/** Reactive: read it in a view to show the current engine. */
export const searchMode = mode;

export interface ModeChange {
  mode: SearchMode;
  /** Short sentence to show or announce. */
  message: string;
}

/**
 * Sets the engine. « ai » needs a configured assistant: a selected provider, or a saved key (its provider is then
 * selected). Consent for remote calls stays in the assistant settings: when it is missing the message says so.
 */
export async function setSearchMode(next: SearchMode): Promise<ModeChange> {
  if (next === 'ai') {
    const provider = await configuredProvider();
    if (!provider) {
      setModeSignal('local');
      return { mode: 'local', message: 'Aucune clé d’assistant : Réglages > Assistant. La recherche reste locale.' };
    }
    if (getAiSettings().provider === 'local_only') saveAiSettings({ provider, model: '', baseUrl: '' });
    setModeSignal('ai');
    persist('ai');
    return {
      mode: 'ai',
      message: hasUserConsent(provider)
        ? 'Recherche IA : le catalogue, puis l’assistant.'
        : 'Recherche IA activée, mais le consentement manque : Réglages > Assistant.',
    };
  }
  setModeSignal('local');
  persist('local');
  return { mode: 'local', message: 'Recherche locale : catalogue uniquement.' };
}

function persist(next: SearchMode): void {
  try {
    localStorage.setItem(STORAGE_KEY, next);
  } catch {
    /* storage unavailable: the choice lasts for this visit */
  }
}

export function toggleSearchMode(): Promise<ModeChange> {
  return setSearchMode(mode() === 'ai' ? 'local' : 'ai');
}

/** The icon + word shown on the button next to a search field. */
export function searchModeLabel(m: SearchMode): string {
  return m === 'ai' ? '✨ IA' : '⌕ Local';
}

/** Items the assistant suggests for a sentence (it guesses titles; each guess is looked up in the catalogue). */
export async function aiSuggestions(
  engine: Pick<CndEngine, 'understandSearchWithAi' | 'searchCatalog'>,
  query: string,
  kind: 'live' | 'movie' | 'series'
): Promise<ItemRecord[]> {
  const understanding = await engine.understandSearchWithAi(query);
  if (!understanding.ok || !understanding.understanding) return [];
  const guesses = understanding.understanding.title_guesses;
  if (!Array.isArray(guesses)) return [];
  const seen = new Set<number>();
  const found: ItemRecord[] = [];
  for (const guess of guesses.slice(0, 15)) {
    const hits = await engine.searchCatalog(guess.title, kind, 3);
    for (const hit of hits) {
      if (!seen.has(hit.id)) {
        seen.add(hit.id);
        found.push(hit);
      }
    }
  }
  return found;
}

/** The assistant's suggestions first, then the local results that are not already among them. */
export function mergeSuggestions(local: ItemRecord[], suggested: ItemRecord[]): ItemRecord[] {
  const ids = new Set(suggested.map((i) => i.id));
  return [...suggested, ...local.filter((i) => !ids.has(i.id))];
}
