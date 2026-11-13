import { afterEach, describe, expect, it, vi } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const settings = vi.hoisted(() => ({ provider: 'local_only' as string }));
vi.mock('../src/core/ai/AiSettings', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../src/core/ai/AiSettings')>();
  return { ...actual, getAiSettings: () => ({ ...actual.getAiSettings(), provider: settings.provider }) };
});

import { AiKeyStore } from '../src/core/ai/AiKeyStore';
import * as aiSettings from '../src/core/ai/AiSettings';
import { aiSuggestions, mergeSuggestions, searchMode, searchModeLabel, setSearchMode, toggleSearchMode } from '../src/core/search/searchMode';

const item = (id: number) => ({ id, name: `n${id}` }) as any;

afterEach(async () => { await setSearchMode('local'); settings.provider = 'local_only'; vi.restoreAllMocks(); });

describe('Search engine choice (local / IA)', () => {
  it('stays local while no assistant is configured (no provider, no key), and says why', async () => {
    vi.spyOn(AiKeyStore.getInstance(), 'hasApiKey').mockResolvedValue(false);
    const change = await toggleSearchMode();
    expect(change.mode).toBe('local');
    expect(searchMode()).toBe('local');
    expect(change.message).toContain('Réglages > Assistant');
  });

  it('toggles between local and IA once a provider is selected, with an icon for each', async () => {
    settings.provider = 'gemini';
    expect((await toggleSearchMode()).mode).toBe('ai');
    expect(searchMode()).toBe('ai');
    expect(searchModeLabel('ai')).toContain('IA');
    expect((await toggleSearchMode()).mode).toBe('local');
    expect(searchModeLabel('local')).toContain('Local');
  });

  it('a key saved (e.g. received from the household) is enough: IA can be chosen and its provider is selected', async () => {
    const has = vi.spyOn(AiKeyStore.getInstance(), 'hasApiKey').mockImplementation(async (p: any) => p === 'anthropic');
    const save = vi.spyOn(aiSettings, 'saveAiSettings');
    const change = await toggleSearchMode();
    expect(change.mode).toBe('ai');
    expect(searchMode()).toBe('ai');
    expect(has).toHaveBeenCalled();
    expect(save).toHaveBeenCalledWith({ provider: 'anthropic', model: '', baseUrl: '' });
    // Without consent the switch works but says where to grant it.
    expect(change.message).toContain('consentement');
  });

  it('puts the assistant suggestions first, without duplicates', () => {
    expect(mergeSuggestions([item(1), item(2), item(3)], [item(3), item(9)]).map((i) => i.id)).toEqual([3, 9, 1, 2]);
  });

  it('looks each title the assistant guessed up in the catalogue', async () => {
    const engine = {
      understandSearchWithAi: vi.fn().mockResolvedValue({ ok: true, understanding: { title_guesses: [{ title: 'A' }, { title: 'B' }] } }),
      searchCatalog: vi.fn(async (t: string) => (t === 'A' ? [item(1), item(2)] : [item(2), item(3)])),
    };
    const found = await aiSuggestions(engine as any, 'un film de braquage', 'movie');
    expect(found.map((i) => i.id)).toEqual([1, 2, 3]);
    expect(engine.searchCatalog).toHaveBeenCalledWith('A', 'movie', 3);
  });

  it('gives nothing when the assistant is unavailable', async () => {
    const engine = { understandSearchWithAi: vi.fn().mockResolvedValue({ ok: false, error: 'x' }), searchCatalog: vi.fn() };
    expect(await aiSuggestions(engine as any, 'q', 'live')).toEqual([]);
    expect(engine.searchCatalog).not.toHaveBeenCalled();
  });

  it('the button sits after the search field, and is reachable, in Live, Films and Séries', () => {
    for (const [p, id] of [['live/LiveView', 'live'], ['movies/MoviesView', 'mv'], ['series/SeriesView', 's']]) {
      const text = readFileSync(resolve(__dirname, '..', `src/features/${p}.tsx`), 'utf8');
      expect(text, p).toContain(`id="${id}-search-mode"`);
      expect(text, p).toContain(`{ id: '${id}-search-mode', onSelect: switchSearchEngine }`);
      expect(text.indexOf(`id="${id}-search-input"`), p).toBeLessThan(text.indexOf(`id="${id}-search-mode"`));
      expect(text, p).toContain('scheduleAiRefine(query)');
    }
  });
});
