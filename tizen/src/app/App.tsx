import { Component, createEffect, createSignal, onMount, onCleanup, Switch, Match } from 'solid-js';
import { CndEngine } from '../core/engine/CndEngine';
import { AVPlayerService } from '../core/player/AVPlayerService';
import { RemoteKey, RemoteKeyHandler } from '../core/input/RemoteKeyHandler';
import { ItemRecord } from '../core/storage/Database';
import { spatialNav } from '../ui/design/SpatialNav';

import { LiveView } from '../features/live/LiveView';
import { GuideView } from '../features/guide/GuideView';
import { MoviesView } from '../features/movies/MoviesView';
import { SeriesView } from '../features/series/SeriesView';
import { DetailsView } from '../features/details/DetailsView';
import { PlayerView } from '../features/player/PlayerView';
import { SearchView } from '../features/search/SearchView';
import { RecommendationsView } from '../features/recommendations/RecommendationsView';
import { SourcesView } from '../features/sources/SourcesView';
import { ProfilesView } from '../features/profiles/ProfilesView';
import { SettingsView } from '../features/settings/SettingsView';
import { OnboardingView } from '../features/onboarding/OnboardingView';

export type ScreenRoute =
  | 'onboarding'
  | 'live'
  | 'guide'
  | 'movies'
  | 'series'
  | 'details'
  | 'player'
  | 'search'
  | 'recommendations'
  | 'sources'
  | 'profiles'
  | 'settings';

export const App: Component = () => {
  const engine = CndEngine.getInstance();
  const player = AVPlayerService.getInstance();
  const [currentRoute, setCurrentRoute] = createSignal<ScreenRoute>('live');
  const [selectedItem, setSelectedItem] = createSignal<ItemRecord | null>(null);
  const [hasSources, setHasSources] = createSignal(true);
  const [focusId] = spatialNav.getFocusSignal();

  let keyUnsub: (() => void) | null = null;

  const NAV_ITEMS: { route: ScreenRoute; label: string }[] = [
    { route: 'live', label: 'Direct' },
    { route: 'guide', label: 'Guide' },
    { route: 'movies', label: 'Films' },
    { route: 'series', label: 'Séries' },
    { route: 'recommendations', label: 'Pour vous' },
    { route: 'search', label: 'Recherche' },
    { route: 'sources', label: 'Sources' },
    { route: 'profiles', label: 'Profils' },
    { route: 'settings', label: 'Paramètres' },
  ];

  // Keep Top Navigation Bar registered with SpatialNav whenever visible
  createEffect(() => {
    const route = currentRoute();
    if (route === 'player') {
      spatialNav.setHeader([]);
      return;
    }
    const activeIdx = Math.max(0, NAV_ITEMS.findIndex((n) => n.route === route));
    spatialNav.setHeader(
      NAV_ITEMS.map((nav) => ({
        id: `nav-${nav.route}`,
        onSelect: () => setCurrentRoute(nav.route),
      })),
      activeIdx,
    );
  });

  onMount(async () => {
    // Initialize remote control & spatial navigation immediately (before any async work)
    RemoteKeyHandler.getInstance().init();
    spatialNav.init();
    keyUnsub = RemoteKeyHandler.getInstance().addListener(handleGlobalKey);
    document.addEventListener('visibilitychange', handleVisibilityChange);

    try {
      await engine.init();
      const sources = await engine.getCatalog('live', undefined, 0, 1);
      if (sources.length === 0) {
        setHasSources(false);
        setCurrentRoute('onboarding');
      }
    } catch (err) {
      console.warn('[App] Engine init fallback to onboarding:', err);
      setHasSources(false);
      setCurrentRoute('onboarding');
    }
  });

  onCleanup(() => {
    if (keyUnsub) keyUnsub();
    document.removeEventListener('visibilitychange', handleVisibilityChange);
  });

  const handleVisibilityChange = () => {
    if (document.hidden) {
      console.log('[TV Lifecycle] Application hidden -> suspending AVPlay');
      player.suspend();
    } else {
      console.log('[TV Lifecycle] Application visible -> restoring AVPlay');
      player.restore();
    }
  };

  const handleGlobalKey = (key: RemoteKey): boolean => {
    // Red -> Live TV
    if (key === 'RED') {
      setCurrentRoute('live');
      return true;
    }
    // Green -> EPG Guide
    if (key === 'GREEN') {
      setCurrentRoute('guide');
      return true;
    }
    // Yellow -> Search
    if (key === 'YELLOW') {
      setCurrentRoute('search');
      return true;
    }
    // Blue -> Settings
    if (key === 'BLUE') {
      setCurrentRoute('settings');
      return true;
    }

    if (key === 'BACK' && currentRoute() !== 'player' && currentRoute() !== 'onboarding') {
      if (currentRoute() !== 'live') {
        setCurrentRoute('live');
        return true;
      }
      if (!hasSources()) {
        setCurrentRoute('onboarding');
        return true;
      }
    }

    return false;
  };

  const handlePlayItem = async (item: ItemRecord) => {
    setSelectedItem(item);
    setCurrentRoute('player');
    await engine.play(item);
  };

  const handleSelectDetails = (item: ItemRecord) => {
    setSelectedItem(item);
    setCurrentRoute('details');
  };

  return (
    <div style={{ width: "1920px", height: "1080px", position: "relative" }}>
      {/* Top TV Navigation Bar (hidden in player) */}
      {currentRoute() !== 'player' && (
        <div style={{
          position: "absolute",
          top: "48px",
          left: "80px",
          right: "80px",
          height: "64px",
          display: "flex",
          "align-items": "center",
          "justify-content": "space-between",
          "z-index": 40
        }}>
          <div style={{
            "font-size": "32px",
            "font-weight": "800",
            color: "var(--buntu-gold)",
            "letter-spacing": "2px"
          }}>
            CND IPTV
          </div>

          <div style={{ display: "flex", gap: "12px" }}>
            {NAV_ITEMS.map((nav) => (
              <button
                class={`tv-nav-item ${currentRoute() === nav.route ? 'active' : ''} ${focusId() === `nav-${nav.route}` ? 'focused' : ''}`}
                onClick={() => setCurrentRoute(nav.route)}
              >
                {nav.label}
              </button>
            ))}
          </div>
        </div>
      )}

      {/* Main Content Router */}
      <div style={{ "padding-top": currentRoute() !== 'player' ? "120px" : "0", width: "100%", height: "100%" }}>
        <Switch>
          <Match when={currentRoute() === 'onboarding'}>
            <OnboardingView
              onComplete={() => setCurrentRoute('live')}
              onAddM3u={(url) => {
                engine.syncM3uSource('Ma Source', url);
                setHasSources(true);
                setCurrentRoute('live');
              }}
            />
          </Match>

          <Match when={currentRoute() === 'live'}>
            <LiveView
              onPlayChannel={handlePlayItem}
              onAddSource={() => setCurrentRoute('onboarding')}
            />
          </Match>

          <Match when={currentRoute() === 'guide'}>
            <GuideView onPlayChannel={handlePlayItem} />
          </Match>

          <Match when={currentRoute() === 'movies'}>
            <MoviesView onSelectMovie={handleSelectDetails} />
          </Match>

          <Match when={currentRoute() === 'series'}>
            <SeriesView onSelectSeries={handleSelectDetails} />
          </Match>

          <Match when={currentRoute() === 'details' && selectedItem()}>
            <DetailsView
              item={selectedItem()!}
              onPlay={handlePlayItem}
              onBack={() => setCurrentRoute('movies')}
            />
          </Match>

          <Match when={currentRoute() === 'player' && selectedItem()}>
            <PlayerView
              item={selectedItem()!}
              onExit={() => setCurrentRoute('live')}
            />
          </Match>

          <Match when={currentRoute() === 'search'}>
            <SearchView onSelectResult={handleSelectDetails} />
          </Match>

          <Match when={currentRoute() === 'recommendations'}>
            <RecommendationsView onSelectItem={handleSelectDetails} />
          </Match>

          <Match when={currentRoute() === 'sources'}>
            <SourcesView
              onBack={() => setCurrentRoute('live')}
              onAddNew={() => setCurrentRoute('onboarding')}
            />
          </Match>

          <Match when={currentRoute() === 'profiles'}>
            <ProfilesView onProfileChanged={() => setCurrentRoute('live')} />
          </Match>

          <Match when={currentRoute() === 'settings'}>
            <SettingsView />
          </Match>
        </Switch>
      </div>
    </div>
  );
};
