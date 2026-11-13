import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { createComponent } from 'solid-js';
import { render } from 'solid-js/web';
import { App } from '../src/app/App';
import { spatialNav } from '../src/ui/design/SpatialNav';
import { readFileSync } from 'node:fs';

const state = vi.hoisted(() => ({
  init: vi.fn(async () => {}), getSources: vi.fn(async () => [{ id: 1 }]),
  counts: vi.fn(), mounts: vi.fn(),
}));
vi.mock('../src/core/engine/CndEngine', () => ({ CndEngine: { getInstance: () => ({
  init: state.init, getGlobalCounts: state.counts, stopPlayback: vi.fn(),
}) } }));
vi.mock('../src/core/storage/Database', () => ({ Database: { getInstance: () => ({ getSources: state.getSources }) } }));
vi.mock('../src/core/player/AVPlayerService', () => ({ AVPlayerService: { getInstance: () => ({}) } }));
vi.mock('../src/core/sync/LocalSyncService', () => ({ LocalSyncService: { getInstance: () => ({
  start: vi.fn(), stop: vi.fn(), onPlayRemote: () => vi.fn(), onRemoteKey: () => vi.fn(), onRemoteText: () => vi.fn(),
}) } }));
vi.mock('../src/core/remote/RemotePlayback', () => ({ RemotePlaybackCoordinator: { getInstance: () => ({ init: vi.fn() }) } }));
vi.mock('../src/features/live/LiveView', () => ({ LiveView: () => { state.mounts('live'); return 'Catalogue Live'; } }));
vi.mock('../src/features/movies/MoviesView', () => ({ MoviesView: () => { state.mounts('movies'); return 'Catalogue Films'; } }));
vi.mock('../src/features/series/SeriesView', () => ({ SeriesView: () => { state.mounts('series'); return 'Catalogue Séries'; } }));
vi.mock('../src/features/guide/GuideView', () => ({ GuideView: () => 'Guide' }));
vi.mock('../src/features/details/DetailsView', () => ({ DetailsView: () => 'Details' }));
vi.mock('../src/features/series/SeriesDetailsView', () => ({ SeriesDetailsView: () => 'Series details' }));
vi.mock('../src/features/player/PlayerView', () => ({ PlayerView: () => 'Player' }));
vi.mock('../src/features/search/SearchView', () => ({ SearchView: () => 'Search' }));
vi.mock('../src/features/recommendations/RecommendationsView', () => ({ RecommendationsView: () => 'Recommendations' }));
vi.mock('../src/features/sources/SourcesView', () => ({ SourcesView: () => 'Sources' }));
vi.mock('../src/features/profiles/ProfilesView', () => ({ ProfilesView: () => 'Profiles' }));
vi.mock('../src/features/settings/SettingsView', () => ({ SettingsView: () => 'Settings' }));
vi.mock('../src/features/onboarding/OnboardingView', () => ({ OnboardingView: (props: { onComplete: () => void }) => {
  const button = document.createElement('button');
  button.id = 'finish-onboarding'; button.onclick = props.onComplete;
  return button;
} }));
vi.mock('../src/features/assistant/AssistantModal', () => ({ AssistantModal: () => 'Assistant' }));

let dispose = () => {};
const settle = async () => { for (let i = 0; i < 20; i++) await Promise.resolve(); };
const click = (id: string) => (document.getElementById(id) as HTMLButtonElement).click();
const key = (keyCode: number) => window.dispatchEvent(new KeyboardEvent('keydown', { keyCode, bubbles: true }));
beforeEach(() => {
  vi.clearAllMocks(); state.init.mockResolvedValue(); state.getSources.mockResolvedValue([{ id: 1 }]);
  vi.spyOn(window, 'focus').mockImplementation(() => {});
});
afterEach(() => {
  dispose();
  if (spatialNav.isModalOpen()) spatialNav.closeModal();
  spatialNav.setHeader([]); spatialNav.setGrid([]);
  document.body.innerHTML = ''; vi.restoreAllMocks();
});
const mount = () => { dispose = render(() => createComponent(App, {}), document.body); };

describe('Tizen lightweight home', () => {
  it('keeps the selection visible on a Samsung browser without focus-visible support', async () => {
    // Older Chromium discards the entire rule when any selector is unsupported.
    const css = readFileSync('src/ui/design/theme.css', 'utf8');
    const style = document.createElement('style');
    style.textContent = css.replace(/\/\*[\s\S]*?\*\//g, '')
      .replace(/[^{}]*:focus-visible[^{}]*\{[^{}]*\}/g, '');
    document.body.appendChild(style);
    mount(); await settle();
    expect(getComputedStyle(document.getElementById('home-live')!).boxShadow).toContain('0px 0px 0px 3px');
    expect(getComputedStyle(document.getElementById('home-live')!).transition).toBe('none');
    key(39);
    expect(document.getElementById('home-movies')!.classList.contains('focused')).toBe(true);
    expect(getComputedStyle(document.getElementById('home-movies')!).boxShadow).toContain('0px 0px 0px 3px');
    key(40);
    expect(getComputedStyle(document.getElementById('home-devices')!).backgroundColor).toBe('rgb(36, 45, 62)');
    key(38); key(37); key(13); await settle();
    expect(state.mounts.mock.calls).toEqual([['live']]);
  });

  it('waits for initialization and starts without a catalogue or global counts', async () => {
    let ready!: () => void;
    state.init.mockImplementationOnce(() => new Promise<void>((resolve) => { ready = resolve; }));
    mount();
    expect(document.getElementById('home-live')).toBeNull();
    expect(state.getSources).not.toHaveBeenCalled();
    ready(); await settle();
    expect(document.querySelectorAll('.buntu-home-card')).toHaveLength(3);
    expect(document.querySelector('.buntu-sidebar')).toBeNull();
    expect(state.mounts).not.toHaveBeenCalled(); expect(state.counts).not.toHaveBeenCalled();
    expect(spatialNav.getCurrentFocusId()).toBe('home-live');
  });

  it.each(['live', 'movies', 'series'])('mounts only %s and BACK restores its home card', async (section) => {
    const headers = vi.spyOn(spatialNav, 'setHeader');
    mount(); await settle(); click(`home-${section}`); await settle();
    expect(state.mounts.mock.calls).toEqual([[section]]);
    expect(document.querySelector('.buntu-home')).toBeNull();
    expect(document.querySelector('.buntu-sidebar')).toBeNull();
    expect(document.getElementById('nav-live')).toBeNull();
    expect(headers).toHaveBeenLastCalledWith([]);
    key(10009); await settle();
    expect(document.querySelector('.buntu-home')).not.toBeNull();
    expect(spatialNav.getCurrentFocusId()).toBe(`home-${section}`);
    expect(state.mounts).toHaveBeenCalledTimes(1);
  });

  it('navigates secondary actions with the remote and confirms exit only from home', async () => {
    mount(); await settle(); key(39); key(39);
    expect(spatialNav.getCurrentFocusId()).toBe('home-series');
    key(40); expect(spatialNav.getCurrentFocusId()).toBe('home-settings');
    key(13); await settle(); expect(document.body.textContent).toContain('Settings');
    expect(document.querySelector('.buntu-sidebar')).toBeNull();
    key(10009); await settle(); expect(document.querySelector('.buntu-home')).not.toBeNull();
    key(10009); await settle(); expect(document.querySelector('[role="dialog"]')).not.toBeNull();
    expect(spatialNav.getCurrentFocusId()).toBe('btn-exit-cancel');
    key(10009); await settle(); expect(document.querySelector('[role="dialog"]')).toBeNull();
    expect(state.mounts).not.toHaveBeenCalled();
  });

  it.each(['sources', 'devices', 'settings'])('opens %s without the large sidebar and returns home', async (route) => {
    mount(); await settle(); click(`home-${route}`); await settle();
    expect(document.querySelector('.buntu-sidebar')).toBeNull();
    expect(document.getElementById('nav-live')).toBeNull();
    expect(state.mounts).not.toHaveBeenCalled();
    key(10009); await settle();
    expect(document.querySelector('.buntu-home')).not.toBeNull();
  });

  it('finishes onboarding at home without opening Live', async () => {
    state.getSources.mockResolvedValueOnce([]);
    mount(); await settle(); click('finish-onboarding'); await settle();
    expect(document.querySelector('.buntu-home')).not.toBeNull();
    expect(state.mounts).not.toHaveBeenCalled();
  });
});
