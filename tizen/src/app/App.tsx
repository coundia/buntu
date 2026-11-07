import { Component, createEffect, createSignal, onMount, onCleanup, Switch, Match, Show } from 'solid-js';
import { CndEngine } from '../core/engine/CndEngine';
import { AVPlayerService } from '../core/player/AVPlayerService';
import { RemoteKey, RemoteKeyHandler } from '../core/input/RemoteKeyHandler';
import { Database, ItemRecord } from '../core/storage/Database';
import { spatialNav } from '../ui/design/SpatialNav';
import { PlatformService } from '../core/platform/PlatformService';
import { announce } from '../ui/design/a11y';

import { LiveView } from '../features/live/LiveView';
import { GuideView } from '../features/guide/GuideView';
import { MoviesView } from '../features/movies/MoviesView';
import { SeriesView } from '../features/series/SeriesView';
import { DetailsView } from '../features/details/DetailsView';
import { SeriesDetailsView } from '../features/series/SeriesDetailsView';
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
  const [previousRoute, setPreviousRoute] = createSignal<ScreenRoute>('live');
  const [selectedItem, setSelectedItem] = createSignal<ItemRecord | null>(null);
  const [hasSources, setHasSources] = createSignal(true);
  const [showExitDialog, setShowExitDialog] = createSignal(false);
  const [focusId] = spatialNav.getFocusSignal();
  const [clock, setClock] = createSignal('');

  let keyUnsub: (() => void) | null = null;

  const NAV_ITEMS: { route: ScreenRoute; label: string; icon: string }[] = [
    { route: 'live', label: 'Direct', icon: '📺' },
    { route: 'movies', label: 'Films', icon: '🎬' },
    { route: 'series', label: 'Séries', icon: '🍿' },
    { route: 'guide', label: 'Guide', icon: '📅' },
    { route: 'recommendations', label: 'Pour vous', icon: '✨' },
    { route: 'search', label: 'Recherche', icon: '🔍' },
    { route: 'sources', label: 'Sources', icon: '📡' },
    { route: 'profiles', label: 'Profils', icon: '👤' },
    { route: 'settings', label: 'Paramètres', icon: '⚙️' },
  ];

  const openExitDialog = () => {
    setShowExitDialog(true);
    announce("Voulez-vous quitter l'application CND IPTV ?");
    spatialNav.openModal([
      [
        {
          id: 'btn-exit-confirm',
          onSelect: confirmExit,
        },
        {
          id: 'btn-exit-cancel',
          onSelect: closeExitDialog,
        },
      ],
    ], 0, 0);
  };

  const closeExitDialog = () => {
    setShowExitDialog(false);
    spatialNav.closeModal();
    announce("Annulation. Retour à l'application.");
  };

  const confirmExit = () => {
    announce("Fermeture de l'application.");
    PlatformService.exitApp();
  };

  // Keep Top Navigation Bar registered with SpatialNav whenever visible
  createEffect(() => {
    const route = currentRoute();
    if (route === 'player' || showExitDialog()) {
      spatialNav.setHeader([]);
      return;
    }
    const activeIdx = Math.max(0, NAV_ITEMS.findIndex((n) => n.route === route));
    const headerItems = [
      ...NAV_ITEMS.map((nav) => ({
        id: `nav-${nav.route}`,
        onSelect: () => navigateTo(nav.route),
      })),
      {
        id: 'nav-exit',
        onSelect: openExitDialog,
      },
    ];
    spatialNav.setHeader(headerItems, activeIdx);
  });

  let clockTimer: any = null;

  onMount(async () => {
    // Clock updater for top right status bar
    const updateClock = () => {
      const now = new Date();
      const h = String(now.getHours()).padStart(2, '0');
      const m = String(now.getMinutes()).padStart(2, '0');
      setClock(`${h}:${m}`);
    };
    updateClock();
    clockTimer = setInterval(updateClock, 10000);

    // Initialize remote control & spatial navigation immediately (before any async work)
    RemoteKeyHandler.getInstance().init();
    spatialNav.init();
    keyUnsub = RemoteKeyHandler.getInstance().addListener(handleGlobalKey);
    document.addEventListener('visibilitychange', handleVisibilityChange);

    try {
      await engine.init();
      const storedSources = await Database.getInstance().getSources();
      if (storedSources.length === 0) {
        setHasSources(false);
        setCurrentRoute('onboarding');
      } else {
        setHasSources(true);
      }
    } catch (err) {
      console.warn('[App] Engine init fallback to onboarding:', err);
      setHasSources(false);
      setCurrentRoute('onboarding');
    }
  });

  onCleanup(() => {
    if (clockTimer) clearInterval(clockTimer);
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

  const navigateTo = (route: ScreenRoute) => {
    if (currentRoute() === 'player' && route !== 'player') {
      engine.stopPlayback();
    }
    if (route !== currentRoute()) {
      setPreviousRoute(currentRoute());
    }
    setCurrentRoute(route);
  };

  const handleGlobalKey = (key: RemoteKey): boolean => {
    // Red -> Live TV
    if (key === 'RED') {
      navigateTo('live');
      return true;
    }
    // Green -> EPG Guide
    if (key === 'GREEN') {
      navigateTo('guide');
      return true;
    }
    // Yellow -> Search
    if (key === 'YELLOW') {
      navigateTo('search');
      return true;
    }
    // Blue -> Settings
    if (key === 'BLUE') {
      navigateTo('settings');
      return true;
    }

    if (key === 'BACK') {
      if (showExitDialog()) {
        closeExitDialog();
        return true;
      }
      if (currentRoute() === 'player') {
        return false;
      }
      if (currentRoute() !== 'onboarding') {
        if (currentRoute() !== 'live') {
          navigateTo('live');
          return true;
        }
        if (!hasSources()) {
          navigateTo('onboarding');
          return true;
        }
        // When on home screen 'live', pressing BACK asks to exit
        openExitDialog();
        return true;
      }
    }

    return false;
  };

  const handlePlayItem = async (item: ItemRecord) => {
    setSelectedItem(item);
    setCurrentRoute('player');
    await engine.play(item, { force: true });
  };

  const handleNextChannel = async () => {
    const current = selectedItem();
    if (!current || current.kind !== 'live') return;
    const channels = await engine.getCatalog('live', undefined, 0, 200);
    const idx = channels.findIndex((c) => c.id === current.id);
    if (idx !== -1 && channels.length > 1) {
      const next = channels[(idx + 1) % channels.length];
      await handlePlayItem(next);
    }
  };

  const handlePrevChannel = async () => {
    const current = selectedItem();
    if (!current || current.kind !== 'live') return;
    const channels = await engine.getCatalog('live', undefined, 0, 200);
    const idx = channels.findIndex((c) => c.id === current.id);
    if (idx !== -1 && channels.length > 1) {
      const prev = channels[(idx - 1 + channels.length) % channels.length];
      await handlePlayItem(prev);
    }
  };

  const handleSelectDetails = (item: ItemRecord) => {
    setSelectedItem(item);
    navigateTo('details');
  };

  return (
    <div
      class={`app-root ${currentRoute() === 'player' ? 'video-mode' : ''}`}
      style={{ width: "1920px", height: "1080px", position: "relative" }}
    >
      {/* Left Vertical Navigation Rail & Top Status Bar (hidden in player) */}
      {currentRoute() !== 'player' && (
        <>
          <aside class="tv-nav-rail" role="navigation" aria-label="Menu principal">
            <div class="tv-rail-top">
              <button
                id="nav-back"
                role="button"
                tabindex="-1"
                aria-label="Retour"
                class={`tv-rail-btn ${focusId() === 'nav-back' ? 'focused' : ''}`}
                onClick={() => {
                  if (currentRoute() !== 'live') navigateTo('live');
                }}
              >
                ‹
              </button>
            </div>

            <nav class="tv-rail-mid" role="tablist" aria-label="Sections">
              {NAV_ITEMS.map((nav) => (
                <button
                  id={`nav-${nav.route}`}
                  role="tab"
                  tabindex="-1"
                  aria-selected={currentRoute() === nav.route}
                  aria-label={nav.label}
                  class={`tv-rail-btn ${currentRoute() === nav.route ? 'active' : ''} ${focusId() === `nav-${nav.route}` ? 'focused' : ''}`}
                  onClick={() => navigateTo(nav.route)}
                >
                  {nav.icon}
                </button>
              ))}
            </nav>

            <div class="tv-rail-bottom">
              <button
                id="nav-exit"
                role="button"
                tabindex="-1"
                aria-label="Quitter l'application"
                class={`tv-rail-btn tv-rail-exit ${focusId() === 'nav-exit' ? 'focused' : ''}`}
                onClick={openExitDialog}
              >
                ⏻
              </button>
            </div>
          </aside>

          {/* Top Right Status Bar (Clock, Weather, Search, Avatar) */}
          <div class="tv-top-status-bar" role="region" aria-label="Statut système">
            <div class="tv-status-clock">{clock()}</div>
            <div class="tv-status-weather">⛅ 24°</div>
            <button
              id="btn-status-search"
              role="button"
              tabindex="-1"
              aria-label="Recherche rapide"
              class={`tv-status-btn ${focusId() === 'btn-status-search' ? 'focused' : ''}`}
              onClick={() => navigateTo('search')}
            >
              🔍
            </button>
            <div
              class="tv-status-avatar"
              aria-label="Profil utilisateur"
            >
              👤
            </div>
          </div>
        </>
      )}

      {/* Main Content Router */}
      <main class="tv-screen-content" role="main">
        <Switch>
          <Match when={currentRoute() === 'onboarding'}>
            <OnboardingView
              onComplete={() => {
                setHasSources(true);
                navigateTo('live');
              }}
              onAddM3u={async (url) => {
                await engine.syncM3uSource('Ma Source', url);
                setHasSources(true);
                navigateTo('live');
              }}
            />
          </Match>

          <Match when={currentRoute() === 'live'}>
            <LiveView
              onPlayChannel={handlePlayItem}
              onAddSource={() => navigateTo('onboarding')}
            />
          </Match>

          <Match when={currentRoute() === 'guide'}>
            <GuideView onPlayChannel={handlePlayItem} />
          </Match>

          <Match when={currentRoute() === 'movies'}>
            <MoviesView
              onSelectMovie={handleSelectDetails}
              onPlayMovie={handlePlayItem}
            />
          </Match>

          <Match when={currentRoute() === 'series'}>
            <SeriesView onSelectSeries={handleSelectDetails} />
          </Match>

          <Match when={currentRoute() === 'details' && selectedItem()?.kind === 'series'}>
            <SeriesDetailsView
              item={selectedItem()!}
              onPlay={handlePlayItem}
              onBack={() => navigateTo('series')}
            />
          </Match>

          <Match when={currentRoute() === 'details' && selectedItem()}>
            <DetailsView
              item={selectedItem()!}
              onPlay={handlePlayItem}
              onBack={() => navigateTo(previousRoute() === 'details' ? 'movies' : previousRoute())}
            />
          </Match>

          <Match when={currentRoute() === 'player' && selectedItem()}>
            <PlayerView
              item={selectedItem()!}
              onExit={() => navigateTo('live')}
              onNextChannel={handleNextChannel}
              onPrevChannel={handlePrevChannel}
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
              onBack={() => navigateTo('live')}
              onAddNew={() => navigateTo('onboarding')}
            />
          </Match>

          <Match when={currentRoute() === 'profiles'}>
            <ProfilesView onProfileChanged={() => navigateTo('live')} />
          </Match>

          <Match when={currentRoute() === 'settings'}>
            <SettingsView onRequestExit={openExitDialog} />
          </Match>
        </Switch>
      </main>

      {/* Exit Confirmation Modal */}
      <Show when={showExitDialog()}>
        <div class="tv-modal-overlay" role="dialog" aria-modal="true" aria-labelledby="exit-modal-title">
          <div class="tv-modal-card">
            <div style={{ "font-size": "56px", color: "var(--buntu-danger)" }}>⏻</div>
            <h2 id="exit-modal-title" style={{ "font-size": "36px", "font-weight": "800", color: "var(--buntu-gold)", margin: 0 }}>
              Quitter CND IPTV
            </h2>
            <p style={{ "font-size": "22px", color: "var(--buntu-text-muted)", margin: 0, "max-width": "500px" }}>
              Voulez-vous vraiment fermer l'application et retourner au téléviseur ?
            </p>
            <div style={{ display: "flex", gap: "24px", "margin-top": "16px" }}>
              <button
                id="btn-exit-confirm"
                role="button"
                tabindex="-1"
                aria-label="Confirmer pour fermer et quitter l'application"
                class={`tv-btn tv-btn-danger ${focusId() === 'btn-exit-confirm' ? 'focused' : ''}`}
                onClick={confirmExit}
              >
                ⏻ Oui, quitter
              </button>
              <button
                id="btn-exit-cancel"
                role="button"
                tabindex="-1"
                aria-label="Annuler et continuer d'utiliser l'application"
                class={`tv-btn ${focusId() === 'btn-exit-cancel' ? 'focused' : ''}`}
                onClick={closeExitDialog}
              >
                Annuler
              </button>
            </div>
          </div>
        </div>
      </Show>
    </div>
  );
};
