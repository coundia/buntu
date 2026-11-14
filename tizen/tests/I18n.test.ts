import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { render } from 'solid-js/web';
import {
  appLanguage,
  DEFAULT_LANGUAGE,
  en,
  fr,
  LANGUAGE_STORAGE_KEY,
  setAppLanguage,
  t,
} from '../src/core/i18n';
import { HomeView } from '../src/features/home/HomeView';
import { SettingsView } from '../src/features/settings/SettingsView';
import { spatialNav } from '../src/ui/design/SpatialNav';
import { RemoteKeyHandler } from '../src/core/input/RemoteKeyHandler';
import { AiKeyStore } from '../src/core/ai/AiKeyStore';
import { WorkerBridge } from '../src/worker/worker-bridge';

describe('Tizen i18n (fr / en)', () => {
  let store: Record<string, string>;
  let dispose = () => {};
  const settle = async () => {
    for (let i = 0; i < 15; i++) await Promise.resolve();
  };

  beforeEach(() => {
    store = {};
    vi.stubGlobal('localStorage', {
      getItem: (k: string) => (k in store ? store[k] : null),
      setItem: (k: string, v: string) => {
        store[k] = v;
      },
      removeItem: (k: string) => {
        delete store[k];
      },
      clear: () => {
        for (const k of Object.keys(store)) delete store[k];
      },
    });
    setAppLanguage('fr');
  });

  afterEach(() => {
    dispose();
    dispose = () => {};
    document.body.innerHTML = '';
    spatialNav.setHeader([]);
    spatialNav.setGrid([]);
    RemoteKeyHandler.getInstance().destroy();
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
  });

  it('defaults to French (fr)', () => {
    expect(DEFAULT_LANGUAGE).toBe('fr');
    expect(appLanguage()).toBe('fr');
    expect(t('home.question')).toBe('Que voulez-vous regarder ?');
    expect(t('settings.title')).toBe('Réglages');
  });

  it('switches to English, persists under buntu_app_language, and interpolates params', () => {
    setAppLanguage('en');
    expect(appLanguage()).toBe('en');
    expect(localStorage.getItem(LANGUAGE_STORAGE_KEY)).toBe('en');
    expect(store['buntu_app_language']).toBe('en');
    expect(t('home.question')).toBe('What would you like to watch?');
    expect(t('settings.title')).toBe('Settings');
    expect(t('sources.countPlural', { count: 3 })).toBe('3 saved sources');

    setAppLanguage('fr');
    expect(appLanguage()).toBe('fr');
    expect(localStorage.getItem(LANGUAGE_STORAGE_KEY)).toBe('fr');
    expect(t('sources.countPlural', { count: 3 })).toBe('3 sources enregistrées');
  });

  it('has 100% key parity and non-empty values between fr.ts and en.ts', () => {
    const frKeys = Object.keys(fr).sort();
    const enKeys = Object.keys(en).sort();
    expect(frKeys).toEqual(enKeys);
    expect(frKeys.length).toBeGreaterThan(0);

    for (const key of frKeys) {
      const frVal = (fr as Record<string, string>)[key];
      const enVal = (en as Record<string, string>)[key];
      expect(typeof frVal).toBe('string');
      expect(typeof enVal).toBe('string');
      expect(frVal.trim().length).toBeGreaterThan(0);
      expect(enVal.trim().length).toBeGreaterThan(0);
    }
  });

  it('falls back to fr if a key is missing in the active dictionary', () => {
    const original = (en as Record<string, string>)['settings.title'];
    delete (en as Record<string, string>)['settings.title'];
    try {
      setAppLanguage('en');
      expect(t('settings.title')).toBe(fr['settings.title']);
    } finally {
      (en as Record<string, string>)['settings.title'] = original;
    }
  });

  it('exposes accessible language selector in SettingsView and updates UI reactively', async () => {
    vi.spyOn(AiKeyStore.getInstance(), 'getMaskedKey').mockResolvedValue(null);
    vi.spyOn(WorkerBridge.getInstance(), 'getVersion').mockResolvedValue('cnd-domain-wasm 0.1.0');
    RemoteKeyHandler.getInstance().init();
    (spatialNav as any).isInitialized = false;
    spatialNav.init();

    dispose = render(() => SettingsView({}), document.body);
    await settle();

    expect(document.body.textContent).toContain('Réglages');

    // Open System & Language panel
    const sysBtn = document.getElementById('settings-system') as HTMLButtonElement;
    expect(sysBtn).not.toBeNull();
    sysBtn.click();
    await settle();

    const btnFr = document.getElementById('btn-lang-fr') as HTMLButtonElement;
    const btnEn = document.getElementById('btn-lang-en') as HTMLButtonElement;
    expect(btnFr).not.toBeNull();
    expect(btnEn).not.toBeNull();
    expect(btnFr.getAttribute('aria-pressed')).toBe('true');
    expect(btnEn.getAttribute('aria-pressed')).toBe('false');

    // Select English via SpatialNav focus + click
    spatialNav.setFocusById('btn-lang-en');
    expect(btnEn.classList.contains('focused')).toBe(true);
    btnEn.click();
    await settle();

    expect(appLanguage()).toBe('en');
    expect(localStorage.getItem('buntu_app_language')).toBe('en');
    expect(btnEn.getAttribute('aria-pressed')).toBe('true');
    expect(document.body.textContent).toContain('Settings');
    expect(document.body.textContent).toContain('Visual Accessibility');

    // Switch back to French
    btnFr.click();
    await settle();
    expect(appLanguage()).toBe('fr');
    expect(document.body.textContent).toContain('Réglages');
    expect(document.body.textContent).toContain('Accessibilité visuelle');
  });

  it('updates HomeView reactively when language changes', async () => {
    RemoteKeyHandler.getInstance().init();
    (spatialNav as any).isInitialized = false;
    spatialNav.init();

    dispose = render(
      () =>
        HomeView({
          initialSection: 'live',
          onOpen: vi.fn(),
          onExit: vi.fn(),
        }),
      document.body
    );
    await settle();

    expect(document.body.textContent).toContain('Que voulez-vous regarder ?');
    expect(document.body.textContent).toContain('Réglages');

    setAppLanguage('en');
    await settle();

    expect(document.body.textContent).toContain('What would you like to watch?');
    expect(document.body.textContent).toContain('Settings');
    expect(document.body.textContent).toContain('Movies');
  });
});
