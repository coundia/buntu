import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { render } from 'solid-js/web';
import {
  getSubtitlePrefs,
  nextSubtitleColor,
  nextSubtitleSize,
  setSubtitlePrefs,
  subtitleBoxStyle,
  subtitleColorLabel,
  subtitleSizeLabel,
} from '../src/core/player/subtitlePrefs';
import { describeSourceExpiry } from '../src/features/sources/sourceExpiry';
import { AssistantModal } from '../src/features/assistant/AssistantModal';
import { SearchView } from '../src/features/search/SearchView';
import { CndEngine } from '../src/core/engine/CndEngine';
import { LocalSyncService } from '../src/core/sync/LocalSyncService';
import { RemoteKeyHandler } from '../src/core/input/RemoteKeyHandler';
import { spatialNav } from '../src/ui/design/SpatialNav';

describe('Tizen nice-to-have features', () => {
  beforeEach(() => {
    const store: Record<string, string> = {};
    vi.stubGlobal('localStorage', {
      getItem: (k: string) => store[k] ?? null,
      setItem: (k: string, v: string) => { store[k] = v; },
      removeItem: (k: string) => { delete store[k]; },
      clear: () => { for (const k of Object.keys(store)) delete store[k]; },
    });
  });

  it('persists and cycles subtitle appearance preferences and computes styles', () => {
    expect(getSubtitlePrefs()).toEqual({ size: 'medium', color: 'white', opaqueBox: true });

    localStorage.setItem('buntu.player.subtitles', '{invalid');
    expect(getSubtitlePrefs()).toEqual({ size: 'medium', color: 'white', opaqueBox: true });

    const updated = setSubtitlePrefs({ size: 'large', color: 'yellow', opaqueBox: false });
    expect(updated).toEqual({ size: 'large', color: 'yellow', opaqueBox: false });
    expect(getSubtitlePrefs()).toEqual({ size: 'large', color: 'yellow', opaqueBox: false });

    expect(subtitleBoxStyle(updated)).toEqual({
      'font-size': '40px',
      color: '#FFE066',
      background: 'transparent',
      'text-shadow': '0 2px 6px #000000, 0 0 2px #000000',
    });

    expect(nextSubtitleSize('small')).toBe('medium');
    expect(nextSubtitleSize('medium')).toBe('large');
    expect(nextSubtitleSize('large')).toBe('small');
    expect(nextSubtitleColor('white')).toBe('yellow');
    expect(nextSubtitleColor('yellow')).toBe('cyan');
    expect(nextSubtitleColor('cyan')).toBe('white');

    expect(subtitleSizeLabel('small')).toBe('Petit');
    expect(subtitleSizeLabel('large')).toBe('Grand');
    expect(subtitleColorLabel('cyan')).toBe('Cyan');
  });

  it('wires Skip Intro (+85s), Audio-Only curtain, and custom subtitle styles in PlayerView', () => {
    const player = readFileSync(resolve(import.meta.dirname, '../src/features/player/PlayerView.tsx'), 'utf8');
    expect(player).toContain("id: 'btn-osd-skip-intro'");
    expect(player).toContain('seekDelta(85000)');
    expect(player).toContain('id="btn-osd-skip-intro"');

    expect(player).toContain("id: 'btn-osd-audio-only'");
    expect(player).toContain('id="btn-osd-audio-only"');
    expect(player).toContain('id="audio-only-curtain"');

    expect(player).toContain('subtitleBoxStyle(getSubtitlePrefs())');
  });

  it('wires subtitle customization controls in SettingsView and Xtream info in SourcesView', () => {
    const settings = readFileSync(resolve(import.meta.dirname, '../src/features/settings/SettingsView.tsx'), 'utf8');
    expect(settings).toContain('id="btn-sub-size"');
    expect(settings).toContain('id="btn-sub-color"');
    expect(settings).toContain('id="btn-sub-bg"');
    expect(settings).toContain("{ id: 'btn-sub-size', onSelect: cycleSubSize }");
    expect(settings).toContain("{ id: 'btn-sub-color', onSelect: cycleSubColor }");
    expect(settings).toContain("{ id: 'btn-sub-bg', onSelect: toggleSubOpaque }");

    const sources = readFileSync(resolve(import.meta.dirname, '../src/features/sources/SourcesView.tsx'), 'utf8');
    expect(sources).toContain('source.exp_date');
    expect(sources).toContain('source.max_connections');

    const css = readFileSync(resolve(import.meta.dirname, '../src/ui/design/theme.css'), 'utf8');
    expect(css).toContain('.tv-audio-only-curtain');
    expect(css).toContain('.buntu-home-expirations');
    expect(css).toContain('.buntu-home-expiry-pill');
  });

  it('formats source expiration status and renders it in HomeView', () => {
    const nowSec = 1_700_000_000;
    expect(describeSourceExpiry({ exp_date: undefined }, nowSec)).toBeNull();
    expect(describeSourceExpiry({ exp_date: nowSec - 3600 }, nowSec)?.status).toBe('expired');
    expect(describeSourceExpiry({ exp_date: nowSec + 3 * 86400 }, nowSec)?.status).toBe('soon');
    expect(describeSourceExpiry({ exp_date: nowSec + 30 * 86400 }, nowSec)?.status).toBe('ok');

    const home = readFileSync(resolve(import.meta.dirname, '../src/features/home/HomeView.tsx'), 'utf8');
    expect(home).toContain('describeSourceExpiry');
    expect(home).toContain('buntu-home-expirations');
    expect(home).toContain('buntu-home-expiry-pill');
    expect(home).toContain('Sans date d’expiration');
  });

  it('wires Samsung IME <input> and RemoteText integration in AssistantModal, App, and SearchView', () => {
    const assistant = readFileSync(resolve(import.meta.dirname, '../src/features/assistant/AssistantModal.tsx'), 'utf8');
    expect(assistant).toContain('initialPhrase?: string');
    expect(assistant).toContain('id="assistant-ime-input"');
    expect(assistant).toContain('id="btn-assistant-submit"');
    expect(assistant).toContain("{ id: 'assistant-ime-input', onSelect: () => inputRef?.focus() }");
    expect(assistant).toContain('e.keyCode === 13 || e.keyCode === 65376');
    expect(assistant).toContain("background: 'var(--buntu-midnight)'");
    expect(assistant).toContain('LocalSyncService.getInstance().onRemoteText');
    expect(assistant).toContain('props.initialPhrase');

    const app = readFileSync(resolve(import.meta.dirname, '../src/app/App.tsx'), 'utf8');
    expect(app).toContain('assistantInitialPhrase');
    expect(app).toContain('setAssistantInitialPhrase');
    expect(app).toContain('if (showAssistantModal()) return;');
    expect(app).toContain('LocalSyncService.getInstance().onRemoteText');
    expect(app).toContain('initialPhrase={assistantInitialPhrase()}');

    const search = readFileSync(resolve(import.meta.dirname, '../src/features/search/SearchView.tsx'), 'utf8');
    expect(search).toContain('id="search-ime-input"');
    expect(search).toContain("{ id: 'search-ime-input', onSelect: () => searchInputRef?.focus() }");
    expect(search).toContain('e.keyCode === 13 || e.keyCode === 65376');
    expect(search).toContain('searchInputRef?.blur()');
  });
});

describe('Samsung IME <input> and Phone-to-TV RemoteText behavior', () => {
  let dispose = () => {};
  const settle = async () => { for (let i = 0; i < 20; i++) await Promise.resolve(); };

  beforeEach(() => {
    const store: Record<string, string> = {};
    vi.stubGlobal('localStorage', {
      getItem: (k: string) => store[k] ?? null,
      setItem: (k: string, v: string) => { store[k] = v; },
      removeItem: (k: string) => { delete store[k]; },
      clear: () => { for (const k of Object.keys(store)) delete store[k]; },
    });
    RemoteKeyHandler.getInstance().init();
    (spatialNav as any).isInitialized = false;
    spatialNav.init();
    spatialNav.setHeader([]);
  });

  afterEach(() => {
    dispose();
    document.body.innerHTML = '';
    RemoteKeyHandler.getInstance().destroy();
    spatialNav.setGrid([]);
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
  });

  it('executes initialPhrase, handles Samsung IME input/Enter/65376, and listens to RemoteText in AssistantModal', async () => {
    const resolveAi = vi.spyOn(CndEngine.getInstance(), 'resolveAiCommand').mockResolvedValue({ reply: 'OK' } as any);
    let remoteCb: ((text: string) => void) | null = null;
    const unsub = vi.fn();
    vi.spyOn(LocalSyncService.getInstance(), 'onRemoteText').mockImplementation((fn) => {
      remoteCb = fn;
      return unsub;
    });

    dispose = render(
      () => AssistantModal({ onClose: vi.fn(), initialPhrase: 'Mets France 2' }),
      document.body
    );
    await settle();

    expect(resolveAi).toHaveBeenCalledWith('Mets France 2');

    // Navigate to #assistant-ime-input and select with OK -> focuses DOM input for Samsung IME
    spatialNav.setFocusById('assistant-ime-input');
    const input = document.getElementById('assistant-ime-input') as HTMLInputElement;
    expect(input).not.toBeNull();
    expect(input.classList.contains('focused')).toBe(true);

    window.dispatchEvent(new KeyboardEvent('keydown', { keyCode: 13, key: 'Enter', bubbles: true }));
    expect(document.activeElement).toBe(input);

    // Typing and pressing Samsung IME Done (65376) executes and blurs
    input.value = 'Un film comme Inception';
    input.dispatchEvent(new Event('input', { bubbles: true }));
    input.dispatchEvent(new KeyboardEvent('keydown', { keyCode: 65376, bubbles: true }));
    await settle();

    expect(resolveAi).toHaveBeenCalledWith('Un film comme Inception');
    expect(document.activeElement).not.toBe(input);

    // Re-focus and press Enter (13) to submit via input onKeyDown
    input.focus();
    input.value = 'Chaîne suivante';
    input.dispatchEvent(new Event('input', { bubbles: true }));
    input.dispatchEvent(new KeyboardEvent('keydown', { keyCode: 13, key: 'Enter', bubbles: true }));
    await settle();

    expect(resolveAi).toHaveBeenCalledWith('Chaîne suivante');
    expect(document.activeElement).not.toBe(input);

    // Submit button also executes
    input.value = 'TF1';
    input.dispatchEvent(new Event('input', { bubbles: true }));
    (document.getElementById('btn-assistant-submit') as HTMLButtonElement).click();
    await settle();
    expect(resolveAi).toHaveBeenCalledWith('TF1');

    // RemoteText callback executes while modal is open and unsubscribes on cleanup
    expect(remoteCb).not.toBeNull();
    remoteCb!('France 3');
    await settle();
    expect(resolveAi).toHaveBeenCalledWith('France 3');

    dispose();
    dispose = () => {};
    expect(unsub).toHaveBeenCalledTimes(1);
  });

  it('wires #search-ime-input between filter tabs and virtual keyboard in SearchView', async () => {
    const searchSpy = vi.spyOn(CndEngine.getInstance(), 'search').mockResolvedValue([]);

    dispose = render(() => SearchView({ onSelectResult: vi.fn() }), document.body);
    await settle();

    const searchInput = document.getElementById('search-ime-input') as HTMLInputElement;
    expect(searchInput).not.toBeNull();
    expect(searchInput.tagName).toBe('INPUT');

    // Positioned between tabRow and kbRows in SpatialNav grid
    spatialNav.setFocusById('search-tab-all');
    window.dispatchEvent(new KeyboardEvent('keydown', { keyCode: 40, key: 'ArrowDown', bubbles: true }));
    expect(spatialNav.getCurrentFocusId()).toBe('search-ime-input');
    window.dispatchEvent(new KeyboardEvent('keydown', { keyCode: 40, key: 'ArrowDown', bubbles: true }));
    expect(spatialNav.getCurrentFocusId()).toBe('key-A');

    // Selecting search-ime-input focuses DOM input; input & Samsung IME Done (65376) run local search
    spatialNav.setFocusById('search-ime-input');
    window.dispatchEvent(new KeyboardEvent('keydown', { keyCode: 13, key: 'Enter', bubbles: true }));
    expect(document.activeElement).toBe(searchInput);

    searchInput.value = 'Gladiator';
    searchInput.dispatchEvent(new Event('input', { bubbles: true }));
    await settle();
    expect(searchSpy).toHaveBeenCalledWith('Gladiator', undefined);

    searchInput.dispatchEvent(new KeyboardEvent('keydown', { keyCode: 65376, bubbles: true }));
    await settle();
    expect(document.activeElement).not.toBe(searchInput);
    expect(searchSpy).toHaveBeenCalledTimes(2);
  });

  it('filters remote_text by target_device_id in LocalSyncService while preserving broadcast', () => {
    const sync = LocalSyncService.getInstance();
    vi.spyOn((sync as any).store, 'getLocalDeviceId').mockReturnValue('tv-living-room');

    const received: string[] = [];
    const unsub = sync.onRemoteText((text) => received.push(text));

    try {
      // Broadcast (absent or empty target_device_id) -> accepted
      (sync as any).dispatchSyncMessage({ type: 'remote_text', text: 'France 2' }, 'phone-1');
      (sync as any).dispatchSyncMessage({ type: 'remote_text', text: 'Arte', target_device_id: '' }, 'phone-1');

      // Targeted to another TV -> ignored
      (sync as any).dispatchSyncMessage(
        { type: 'remote_text', text: 'M6', target_device_id: 'tv-bedroom' },
        'phone-1'
      );

      // Targeted to this TV -> accepted
      (sync as any).dispatchSyncMessage(
        { type: 'remote_text', text: 'TF1', target_device_id: 'tv-living-room' },
        'phone-1'
      );

      expect(received).toEqual(['France 2', 'Arte', 'TF1']);
    } finally {
      unsub();
    }
  });

  it('exposes APP_VERSION, APP_BUILD and APP_VERSION_LABEL constants', async () => {
    const { APP_VERSION, APP_BUILD, APP_VERSION_LABEL } = await import('../src/core/appInfo');
    expect(APP_VERSION).toBe('1.0.0');
    expect(APP_BUILD).toBe('1');
    expect(APP_VERSION_LABEL).toBe('1.0.0 (build 1)');
  });
});
