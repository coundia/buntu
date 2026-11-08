import { Component, createEffect, createSignal, onMount, onCleanup, Switch, Match, Show } from 'solid-js';
import { CndEngine } from '../core/engine/CndEngine';
import { AVPlayerService } from '../core/player/AVPlayerService';
import { RemoteKey, RemoteKeyHandler } from '../core/input/RemoteKeyHandler';
import { Database, ItemRecord } from '../core/storage/Database';
import { spatialNav } from '../ui/design/SpatialNav';
import { PlatformService } from '../core/platform/PlatformService';
import { announce } from '../ui/design/a11y';
import { formatBuntuCount } from '../core/utils/categoryMeta';

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
import { AssistantModal } from '../features/assistant/AssistantModal';
import { NavigationHistory, NavEntry } from '../core/navigation/NavigationHistory';
import { screenState } from '../core/navigation/ScreenState';
import { zapContext } from '../core/navigation/ZapContext';
import { LocalSyncService } from '../core/sync/LocalSyncService';
import { RemotePlaybackCoordinator } from '../core/remote/RemotePlayback';

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
  // Screens query the database: they must not mount before the engine has opened it.
  const [engineReady, setEngineReady] = createSignal(false);
  const history = new NavigationHistory<ItemRecord>();
  const [selectedItem, setSelectedItem] = createSignal<ItemRecord | null>(null);
  const [hasSources, setHasSources] = createSignal(true);
  const [showExitDialog, setShowExitDialog] = createSignal(false);
  const [showAssistantModal, setShowAssistantModal] = createSignal(false);
  const [sidebarCollapsed, setSidebarCollapsed] = createSignal(false);
  const [globalCounts, setGlobalCounts] = createSignal({ live: 0, movie: 0, series: 0, sources: 0 });
  const [focusId] = spatialNav.getFocusSignal();

  let keyUnsub: (() => void) | null = null;
  let unsubRemotePlay: (() => void) | null = null;
  let unsubRemoteKey: (() => void) | null = null;
  let unsubRemoteText: (() => void) | null = null;

  const IPTV_NAV_ITEMS: { route: ScreenRoute; label: string; icon: string; countKey?: 'live' | 'movie' | 'series' }[] = [
    { route: 'live', label: 'Live TV', icon: '📺', countKey: 'live' },
    { route: 'guide', label: 'Guide TV', icon: '📅' },
    { route: 'movies', label: 'Films', icon: '🎬', countKey: 'movie' },
    { route: 'series', label: 'Séries', icon: '🍿', countKey: 'series' },
    { route: 'recommendations', label: 'Pour vous', icon: '✨' },
    { route: 'search', label: 'Recherche', icon: '🔍' },
  ];

  const SYSTEM_NAV_ITEMS: { route: ScreenRoute; label: string; icon: string; countKey?: 'sources' }[] = [
    { route: 'sources', label: 'Sources', icon: '📡', countKey: 'sources' },
    { route: 'profiles', label: 'Profils', icon: '👤' },
    { route: 'settings', label: 'Réglages', icon: '⚙️' },
  ];

  const ALL_NAV_ITEMS = [...IPTV_NAV_ITEMS, ...SYSTEM_NAV_ITEMS];

  const refreshGlobalCounts = async () => {
    try {
      const c = await engine.getGlobalCounts();
      setGlobalCounts(c);
    } catch {}
  };

  const openExitDialog = () => {
    setShowExitDialog(true);
    announce("Voulez-vous quitter l'application Buntu ?");
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

  // Keep Left Buntu Sidebar registered with SpatialNav (vertical orientation) whenever visible
  createEffect(() => {
    const route = currentRoute();
    if (route === 'player' || showExitDialog()) {
      spatialNav.setHeader([]);
      return;
    }
    void refreshGlobalCounts();
    const activeIdx = Math.max(0, ALL_NAV_ITEMS.findIndex((n) => n.route === route));
    const headerItems = [
      ...ALL_NAV_ITEMS.map((nav) => ({
        id: `nav-${nav.route}`,
        onSelect: () => navigateTo(nav.route),
      })),
      {
        id: 'nav-exit',
        onSelect: openExitDialog,
      },
    ];
    spatialNav.setHeader(headerItems, activeIdx, 'vertical');
  });

  onMount(async () => {
    // Initialize remote control & spatial navigation immediately (before any async work)
    RemoteKeyHandler.getInstance().init();
    spatialNav.init();
    keyUnsub = RemoteKeyHandler.getInstance().addListener(handleGlobalKey);
    document.addEventListener('visibilitychange', handleVisibilityChange);

    try {
      await engine.init();
      const storedSources = await Database.getInstance().getSources();
      await refreshGlobalCounts();
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
    } finally {
      setEngineReady(true);
    }

    // Start local household continuity sync (PRD-41 & PRD-42)
    void LocalSyncService.getInstance().start();
    const remote = RemotePlaybackCoordinator.getInstance();
    remote.init();
    // "Lire sur…" (PRD-42): the playback goes through the app's own path (full screen player).
    remote.onPlayItem = async (item) => {
      await handlePlayItem(item);
    };
    remote.onZap = (direction) => {
      void zapChannel(direction);
    };

    // Deprecated PRD-41 `play_remote`: same checks as a negotiated request (profile, busy, access).
    unsubRemotePlay = LocalSyncService.getInstance().onPlayRemote(async (event) => {
      await remote.playLegacyRequest(event);
    });

    unsubRemoteKey = LocalSyncService.getInstance().onRemoteKey((keyName) => {
      const keyMap: Record<string, RemoteKey> = {
        up: 'UP',
        down: 'DOWN',
        left: 'LEFT',
        right: 'RIGHT',
        select: 'ENTER',
        enter: 'ENTER',
        ok: 'ENTER',
        back: 'BACK',
        play: 'PLAY',
        pause: 'PAUSE',
        play_pause: 'PLAY_PAUSE',
        channel_up: 'CHANNEL_UP',
        channel_down: 'CHANNEL_DOWN',
        red: 'RED',
        green: 'GREEN',
        yellow: 'YELLOW',
        blue: 'BLUE',
      };
      const mapped = keyMap[keyName.toLowerCase()];
      if (mapped) {
        handleGlobalKey(mapped);
      }
    });

    unsubRemoteText = LocalSyncService.getInstance().onRemoteText((text) => {
      const active = document.activeElement;
      if (active && (active instanceof HTMLInputElement || active instanceof HTMLTextAreaElement)) {
        active.value = text;
        active.dispatchEvent(new Event('input', { bubbles: true }));
        active.dispatchEvent(new Event('change', { bubbles: true }));
      }
    });
  });

  onCleanup(() => {
    if (keyUnsub) keyUnsub();
    if (unsubRemotePlay) unsubRemotePlay();
    if (unsubRemoteKey) unsubRemoteKey();
    if (unsubRemoteText) unsubRemoteText();
    LocalSyncService.getInstance().stop();
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

  const here = (): NavEntry<ItemRecord> => ({ route: currentRoute(), item: selectedItem() });

  /** Opens a screen and remembers the current one so BACK can return to it. */
  const navigateTo = (route: ScreenRoute, opts: { reset?: boolean } = {}) => {
    if (currentRoute() === 'player' && route !== 'player') {
      engine.stopPlayback();
    }
    screenState.disarm();
    zapContext.category = ''; // only opening the player from a Live TV list keeps a zapping list
    zapContext.frozen = null;
    if (opts.reset) {
      history.reset();
      screenState.clear();
    } else {
      history.enter(here(), { route, item: route === 'details' ? selectedItem() : null });
    }
    setCurrentRoute(route);
  };

  /** BACK: returns to the screen displayed before. False when there is nothing to go back to. */
  const goBack = (): boolean => {
    const previous = history.back();
    if (!previous) return false;
    if (currentRoute() === 'player') {
      engine.stopPlayback();
    }
    if (previous.item) setSelectedItem(previous.item);
    screenState.arm(previous.route);
    setCurrentRoute(previous.route as ScreenRoute);
    return true;
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
      if (showAssistantModal()) {
        setShowAssistantModal(false);
        return true;
      }
      if (showExitDialog()) {
        closeExitDialog();
        return true;
      }
      if (currentRoute() === 'player') {
        return false;
      }
      if (currentRoute() !== 'onboarding') {
        if (goBack()) {
          return true;
        }
        if (currentRoute() !== 'live') {
          navigateTo('live', { reset: true });
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
    // Zapping from one channel to the next keeps the screen that opened the player.
    if (currentRoute() !== 'player') {
      screenState.disarm();
      history.enter(here(), { route: 'player', item });
    }
    setSelectedItem(item);
    setCurrentRoute('player');
    RemotePlaybackCoordinator.getInstance().setLocalPlaying(item);
    // What already plays in a mini player (live channel or film) keeps running, not reopened.
    await engine.play(item, { force: item.kind !== 'live' && !engine.isPlayingItem(item) });
  };

  /** Ch+ / Ch- in the player: the neighbour of the current channel in the list it was opened from. */
  const zapChannel = async (direction: 'next' | 'prev') => {
    const current = selectedItem();
    if (!current || current.kind !== 'live') return;
    const target = await engine.getAdjacentItem(current, zapContext.category, direction);
    if (target) await handlePlayItem(target);
  };

  const handleNextChannel = () => zapChannel('next');
  const handlePrevChannel = () => zapChannel('prev');

  const handleSelectDetails = (item: ItemRecord) => {
    setSelectedItem(item);
    navigateTo('details');
  };

  return (
    <div
      class={`app-root ${currentRoute() === 'player' ? 'video-mode' : ''}`}
    >
      {/* Left Buntu Navigation Sidebar (hidden in full-screen player) */}
      {currentRoute() !== 'player' && (
        <aside
          class={`buntu-sidebar ${sidebarCollapsed() ? 'collapsed' : ''}`}
          role="navigation"
          aria-label="Menu principal Buntu"
        >
          <div class="buntu-brand-header">
            <div class="buntu-brand-identity">
              <img
                src="./icon.png"
                alt="Buntu"
                class="buntu-brand-logo"
                onError={(e) => {
                  (e.currentTarget as HTMLImageElement).style.display = 'none';
                }}
              />
              <span class="buntu-brand-text">Buntu</span>
            </div>
            <button
              type="button"
              tabindex="-1"
              class="buntu-cat-home-btn"
              title={sidebarCollapsed() ? 'Déplier le menu' : 'Replier le menu'}
              onClick={() => setSidebarCollapsed((v) => !v)}
            >
              ◧
            </button>
          </div>

          <nav class="buntu-nav-scroll" role="tablist" aria-label="Sections IPTV">
            <div class="buntu-nav-group-label">IPTV</div>
            {IPTV_NAV_ITEMS.map((nav) => {
              const countVal = () => (nav.countKey ? globalCounts()[nav.countKey] : 0);
              return (
                <button
                  id={`nav-${nav.route}`}
                  role="tab"
                  tabindex="-1"
                  aria-selected={currentRoute() === nav.route}
                  aria-label={nav.label}
                  class={`buntu-nav-btn ${currentRoute() === nav.route ? 'active' : ''} ${focusId() === `nav-${nav.route}` ? 'focused' : ''}`}
                  onClick={() => navigateTo(nav.route)}
                >
                  <span class="buntu-nav-icon">{nav.icon}</span>
                  <span class="buntu-nav-label">{nav.label}</span>
                  <Show when={countVal() > 0}>
                    <span class="buntu-nav-count">{formatBuntuCount(countVal())}</span>
                  </Show>
                </button>
              );
            })}

            <div class="buntu-nav-group-label">Gestion</div>
            {SYSTEM_NAV_ITEMS.map((nav) => {
              const countVal = () => (nav.countKey ? globalCounts()[nav.countKey] : 0);
              return (
                <button
                  id={`nav-${nav.route}`}
                  role="tab"
                  tabindex="-1"
                  aria-selected={currentRoute() === nav.route}
                  aria-label={nav.label}
                  class={`buntu-nav-btn ${currentRoute() === nav.route ? 'active' : ''} ${focusId() === `nav-${nav.route}` ? 'focused' : ''}`}
                  onClick={() => navigateTo(nav.route)}
                >
                  <span class="buntu-nav-icon">{nav.icon}</span>
                  <span class="buntu-nav-label">{nav.label}</span>
                  <Show when={countVal() > 0}>
                    <span class="buntu-nav-count">{formatBuntuCount(countVal())}</span>
                  </Show>
                </button>
              );
            })}
          </nav>

          <div class="buntu-sidebar-footer">
            <button
              id="nav-exit"
              role="button"
              tabindex="-1"
              aria-label="Quitter l'application"
              class={`buntu-nav-btn exit-btn ${focusId() === 'nav-exit' ? 'focused' : ''}`}
              onClick={openExitDialog}
            >
              <span class="buntu-nav-icon">⏻</span>
              <span class="buntu-nav-label">Quitter</span>
            </button>
          </div>
        </aside>
      )}

      {/* Main Content Router */}
      <main class="tv-screen-content" role="main">
        <Show
          when={engineReady()}
          fallback={
            <div class="tv-loader-card" style={{ margin: 'auto', 'max-width': '520px' }}>
              <div class="tv-spinner-small" />
              <span>Chargement…</span>
            </div>
          }
        >
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
                navigateTo('live', { reset: true });
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
              onBack={() => { if (!goBack()) navigateTo('series'); }}
            />
          </Match>

          <Match when={currentRoute() === 'details' && selectedItem()}>
            <DetailsView
              item={selectedItem()!}
              onPlay={handlePlayItem}
              onBack={() => { if (!goBack()) navigateTo('movies'); }}
            />
          </Match>

          <Match when={currentRoute() === 'player' && selectedItem()}>
            <PlayerView
              item={selectedItem()!}
              onExit={() => { if (!goBack()) navigateTo('live', { reset: true }); }}
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
              onBack={() => { if (!goBack()) navigateTo('live', { reset: true }); }}
              onAddNew={() => navigateTo('onboarding')}
            />
          </Match>

          <Match when={currentRoute() === 'profiles'}>
            <ProfilesView onProfileChanged={() => navigateTo('live', { reset: true })} />
          </Match>

          <Match when={currentRoute() === 'settings'}>
            <SettingsView onRequestExit={openExitDialog} />
          </Match>
        </Switch>
        </Show>
      </main>

      {/* Exit Confirmation Modal */}
      <Show when={showExitDialog()}>
        <div class="tv-modal-overlay" role="dialog" aria-modal="true" aria-labelledby="exit-modal-title">
          <div class="tv-modal-card">
            <div style={{ "font-size": "56px", color: "var(--buntu-danger)" }}>⏻</div>
            <h2 id="exit-modal-title" style={{ "font-size": "36px", "font-weight": "800", color: "var(--buntu-gold)", margin: 0 }}>
              Quitter Buntu
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

      {/* Assistant Modal */}
      <Show when={showAssistantModal()}>
        <AssistantModal
          onClose={() => setShowAssistantModal(false)}
          onPlayItem={(item) => {
            setShowAssistantModal(false);
            handlePlayItem(item);
          }}
          onSearchQuery={() => {
            setShowAssistantModal(false);
            navigateTo('search');
          }}
        />
      </Show>
    </div>
  );
};
