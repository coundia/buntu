import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { render } from 'solid-js/web';

const settings = vi.hoisted(() => ({ provider: 'local_only' as string }));
vi.mock('../src/core/ai/AiSettings', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../src/core/ai/AiSettings')>();
  return { ...actual, getAiSettings: () => ({ ...actual.getAiSettings(), provider: settings.provider }) };
});

import { SearchView } from '../src/features/search/SearchView';
import { CndEngine } from '../src/core/engine/CndEngine';
import { spatialNav } from '../src/ui/design/SpatialNav';
import { RemoteKeyHandler } from '../src/core/input/RemoteKeyHandler';
import { setSearchMode } from '../src/core/search/searchMode';

const settle = async () => { for (let i = 0; i < 30; i++) await Promise.resolve(); await new Promise((r) => setTimeout(r, 160)); };
const click = (id: string) => (document.getElementById(id) as HTMLButtonElement).click();
let dispose = () => {};
let search: any;
let ai: any;

beforeEach(() => {
  RemoteKeyHandler.getInstance().init();
  (spatialNav as any).isInitialized = false;
  spatialNav.init();
  spatialNav.setHeader([]);
  const engine = CndEngine.getInstance();
  search = vi.spyOn(engine, 'search').mockResolvedValue([]);
  ai = vi.spyOn(engine, 'understandSearchWithAi').mockResolvedValue({ ok: true, understanding: { reply: 'ok', title_guesses: [] } } as any);
});
afterEach(() => { void setSearchMode('local'); dispose(); document.body.innerHTML = ''; RemoteKeyHandler.getInstance().destroy(); vi.restoreAllMocks(); settings.provider = 'local_only'; });

const mount = async () => { dispose = render(() => SearchView({ onSelectResult: vi.fn() }), document.body); await settle(); };
const isActive = (id: string) => document.getElementById(id)!.getAttribute('aria-checked') === 'true';

describe('Search mode: local or AI', () => {
  it('starts local, offers both modes, and refuses IA while the assistant is not set up', async () => {
    await mount();
    expect(document.getElementById('search-mode-local')).not.toBeNull();
    expect(document.getElementById('search-mode-ai')).not.toBeNull();
    expect(document.getElementById('key-✨ ASSISTANT IA')).toBeNull();
    click('search-mode-ai');
    await settle();
    expect(isActive('search-mode-local')).toBe(true);
    expect(document.body.textContent).toContain('Réglages > Assistant');
  });

  it('the two modes are reachable with the remote, in the filters row', async () => {
    await mount();
    spatialNav.setFocusById('search-tab-series');
    window.dispatchEvent(new KeyboardEvent('keydown', { keyCode: 39 }));
    expect(spatialNav.getCurrentFocusId()).toBe('search-mode-local');
    window.dispatchEvent(new KeyboardEvent('keydown', { keyCode: 39 }));
    expect(spatialNav.getCurrentFocusId()).toBe('search-mode-ai');
  });

  it('Local mode: Rechercher looks in the catalogue only', async () => {
    settings.provider = 'gemini';
    await mount();
    click('key-A');
    click('key-RECHERCHER');
    await settle();
    expect(search).toHaveBeenCalled();
    expect(ai).not.toHaveBeenCalled();
  });

  it('IA mode: Rechercher shows local results and also asks the assistant', async () => {
    settings.provider = 'gemini';
    await mount();
    click('search-mode-ai');
    await settle();
    expect(isActive('search-mode-ai')).toBe(true);
    click('key-A');
    click('key-RECHERCHER');
    await settle();
    expect(search).toHaveBeenCalled();
    expect(ai).toHaveBeenCalledTimes(1);
  });
});
