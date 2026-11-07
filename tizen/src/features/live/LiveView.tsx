import { Component, createSignal, onMount, onCleanup, For, Show } from 'solid-js';
import { CndEngine } from '../../core/engine/CndEngine';
import { Database, EpgProgramRecord, ItemRecord } from '../../core/storage/Database';
import { AVPlayerService } from '../../core/player/AVPlayerService';
import { FocusableItem, spatialNav } from '../../ui/design/SpatialNav';
import { createInfiniteScroller } from '../../core/pagination/InfiniteScrollController';
import { TvSearchBar } from '../../ui/components/TvSearchBar';
import { cleanMediaTitle } from '../../core/utils/titleCleaner';
import { announce } from '../../ui/design/a11y';

export interface LiveViewProps {
  onPlayChannel: (channel: ItemRecord) => void;
  onAddSource?: () => void;
}

export const LiveView: Component<LiveViewProps> = (props) => {
  const engine = CndEngine.getInstance();
  const db = Database.getInstance();
  const player = AVPlayerService.getInstance();
  const PAGE_SIZE = 40;

  const [categories, setCategories] = createSignal<string[]>([]);
  const [selectedCategory, setSelectedCategory] = createSignal<string>('');
  const [searchQuery, setSearchQuery] = createSignal<string>('');
  const [searchResults, setSearchResults] = createSignal<ItemRecord[]>([]);
  const [previewChannel, setPreviewChannel] = createSignal<ItemRecord | null>(null);
  const [currentEpg, setCurrentEpg] = createSignal<{ now?: EpgProgramRecord; next?: EpgProgramRecord } | null>(null);
  const [isFav, setIsFav] = createSignal(false);
  const [focusId] = spatialNav.getFocusSignal();

  const isSearchMode = () => searchQuery().trim().length > 0;
  const activeChannels = () => (isSearchMode() ? searchResults() : scroller.items());

  const activePreviewChannel = (): ItemRecord | null => {
    return previewChannel() || (activeChannels().length > 0 ? activeChannels()[0] : null);
  };

  const previewTitle = () => {
    const ch = activePreviewChannel();
    if (!ch) return 'Direct TV';
    return ch.name_clean && ch.name_clean !== ch.name ? ch.name_clean : cleanMediaTitle(ch.name).clean;
  };

  const scroller = createInfiniteScroller<ItemRecord>({
    pageSize: PAGE_SIZE,
    threshold: 8,
    maxItems: 300,
    fetchBatch: async (offset, limit) => {
      const cat = selectedCategory();
      const [list, count] = await Promise.all([
        engine.getCatalog('live', cat, offset, limit),
        engine.countCatalog('live', cat),
      ]);
      return { items: list, total: count };
    },
    onBatchLoaded: (list, total) => {
      if (!isSearchMode()) {
        announce(`Direct, ${list.length} chaînes affichées sur ${total}`);
        if (!previewChannel() && list.length > 0) {
          void updatePreview(list[0]);
        }
        rebuildGrid(categories(), list, true);
      }
    },
  });

  onMount(async () => {
    // 1. Configure AVPlay display area for the mini player window on Samsung TV
    player.setDisplayArea({ x: 1084, y: 192, width: 756, height: 425 });
    document.querySelector('.app-root')?.classList.add('preview-mode');

    // 2. Load categories & initial channels
    const cats = await engine.getCategories('live');
    setCategories(cats);
    if (cats.length > 0) {
      setSelectedCategory(cats[0]);
      await scroller.reset();
      const items = scroller.items();
      if (items.length > 0) {
        await updatePreview(items[0]);
        rebuildGrid(cats, items, false);
        spatialNav.setFocusById(`channel-${items[0].id}`);
      } else {
        rebuildGrid(cats, [], false);
      }
    } else {
      rebuildGrid([], [], false);
    }
  });

  onCleanup(() => {
    document.querySelector('.app-root')?.classList.remove('preview-mode');
  });

  const updatePreview = async (ch: ItemRecord) => {
    setPreviewChannel(ch);
    setIsFav(ch.is_favorite === 1);
    if (ch.tvg_id) {
      try {
        const epg = await db.getEpgNowNext(ch.tvg_id, Math.floor(Date.now() / 1000));
        setCurrentEpg(epg);
      } catch {
        setCurrentEpg(null);
      }
    } else {
      setCurrentEpg(null);
    }
  };

  const focusInput = (id: string) => {
    const el = document.getElementById(id);
    if (el) (el as HTMLInputElement).focus();
  };

  const handleSearch = async (query: string) => {
    setSearchQuery(query);
    if (!query.trim()) {
      setSearchResults([]);
      rebuildGrid(categories(), scroller.items(), false);
      return;
    }
    const results = await engine.searchCatalog(query, 'live', 80);
    setSearchResults(results);
    if (results.length > 0) {
      void updatePreview(results[0]);
    }
    announce(`${results.length} résultats pour la recherche ${query}`);
    rebuildSearchGrid(results);
  };

  const handleClearSearch = () => {
    setSearchQuery('');
    setSearchResults([]);
    rebuildGrid(categories(), scroller.items(), false);
  };

  const handleToggleFav = async () => {
    const current = activePreviewChannel();
    if (!current) return;
    const next = await engine.toggleFavorite(current.id);
    setIsFav(next);
    announce(next ? 'Chaîne ajoutée aux favoris' : 'Chaîne retirée des favoris');
  };

  const handleFullscreen = () => {
    const ch = activePreviewChannel();
    if (ch) {
      props.onPlayChannel(ch);
    }
  };

  const handleChannelSelect = (ch: ItemRecord) => {
    if (previewChannel()?.id === ch.id) {
      // Second click or Enter while already previewing -> open fullscreen
      props.onPlayChannel(ch);
    } else {
      // First click -> preview in mini player
      void updatePreview(ch);
    }
  };

  const rebuildSearchGrid = (results: ItemRecord[]) => {
    const grid: FocusableItem[][] = [];

    // Row 0: Search bar
    const searchRow: FocusableItem[] = [
      { id: 'live-search-input', onSelect: () => focusInput('live-search-input') },
    ];
    if (searchQuery().trim()) {
      searchRow.push({ id: 'live-search-input-clear', onSelect: handleClearSearch });
    }
    grid.push(searchRow);

    // Results rows
    for (let i = 0; i < results.length; i++) {
      const ch = results[i];
      const row: FocusableItem[] = [
        {
          id: `channel-${ch.id}`,
          onFocus: () => void updatePreview(ch),
          onSelect: () => handleChannelSelect(ch),
        },
      ];

      // Side buttons for mini player
      if (i === 0) {
        row.push({ id: 'btn-mini-fullscreen', onSelect: handleFullscreen });
      } else if (i === 1) {
        row.push({ id: 'btn-mini-play', onSelect: handleFullscreen });
      } else if (i === 2) {
        row.push({ id: 'btn-mini-fav', onSelect: () => void handleToggleFav() });
      }

      grid.push(row);
    }

    spatialNav.setGrid(grid, 0, 0, false);
  };

  const rebuildGrid = (cats: string[], list: ItemRecord[], preserveFocus = false) => {
    if (cats.length === 0 && list.length === 0) {
      if (props.onAddSource) {
        spatialNav.setGrid([[{ id: 'btn-live-add-source', onSelect: () => props.onAddSource?.() }]]);
      } else {
        spatialNav.setGrid([]);
      }
      return;
    }

    const grid: FocusableItem[][] = [];

    // Row 0: Search Bar
    const searchRow: FocusableItem[] = [
      { id: 'live-search-input', onSelect: () => focusInput('live-search-input') },
    ];
    if (searchQuery().trim()) {
      searchRow.push({ id: 'live-search-input-clear', onSelect: handleClearSearch });
    }
    grid.push(searchRow);

    const maxRows = Math.max(cats.length, list.length);

    for (let i = 0; i < maxRows; i++) {
      const row: FocusableItem[] = [];

      // Column 0: Categories (padded to bottom if list.length > cats.length)
      if (cats.length > 0) {
        const catIdx = Math.min(i, cats.length - 1);
        const cat = cats[catIdx];
        row.push({
          id: `cat-${catIdx}`,
          onSelect: async () => {
            if (cat !== selectedCategory()) {
              setSelectedCategory(cat);
              await scroller.reset();
              const items = scroller.items();
              if (items.length > 0) {
                void updatePreview(items[0]);
              }
              rebuildGrid(cats, items, false);
              if (items.length > 0) {
                spatialNav.setFocusById(`channel-${items[0].id}`);
              }
            }
          },
        });
      }

      // Column 1: Live Channels
      if (i < list.length) {
        const ch = list[i];
        row.push({
          id: `channel-${ch.id}`,
          onFocus: () => {
            void scroller.checkTrigger(i);
            void updatePreview(ch);
          },
          onSelect: () => handleChannelSelect(ch),
        });
      } else if (list.length > 0) {
        const lastCh = list[list.length - 1];
        row.push({
          id: `channel-${lastCh.id}`,
          onSelect: () => handleChannelSelect(lastCh),
        });
      }

      // Column 2: Mini Player Action buttons on top rows
      if (i === 0) {
        row.push({ id: 'btn-mini-fullscreen', onSelect: handleFullscreen });
      } else if (i === 1) {
        row.push({ id: 'btn-mini-play', onSelect: handleFullscreen });
      } else if (i === 2) {
        row.push({ id: 'btn-mini-fav', onSelect: () => void handleToggleFav() });
      }

      if (row.length > 0) {
        grid.push(row);
      }
    }

    spatialNav.setGrid(grid, list.length > 0 ? 1 : 0, cats.length > 0 ? 1 : 0, preserveFocus);
  };

  const handleSelectCategory = async (cat: string) => {
    if (cat === selectedCategory()) return;
    setSearchQuery('');
    setSearchResults([]);
    setSelectedCategory(cat);
    await scroller.reset();
    const items = scroller.items();
    if (items.length > 0) {
      void updatePreview(items[0]);
    }
    rebuildGrid(categories(), items, false);
    if (items.length > 0) {
      spatialNav.setFocusById(`channel-${items[0].id}`);
    }
  };

  const handleChannelsScroll = (e: Event) => {
    if (isSearchMode()) return;
    const el = e.currentTarget as HTMLElement;
    if (el.scrollTop + el.clientHeight >= el.scrollHeight - 300) {
      void scroller.loadMore();
    }
  };

  const progressPercent = () => {
    const epg = currentEpg();
    if (!epg?.now?.start_ts || !epg?.now?.end_ts) return 0;
    const start = epg.now.start_ts;
    const end = epg.now.end_ts;
    const now = Math.floor(Date.now() / 1000);
    if (now < start) return 0;
    if (now >= end) return 100;
    return Math.round(((now - start) / (end - start)) * 100);
  };

  const formatTimeRange = (start?: number, end?: number) => {
    if (!start || !end) return '';
    const sDate = new Date(start * 1000);
    const eDate = new Date(end * 1000);
    const sStr = sDate.toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit' });
    const eStr = eDate.toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit' });
    return `${sStr} - ${eStr}`;
  };

  return (
    <div class="tv-container">
      {/* Header with Title, In-Screen Search Bar & Counter */}
      <div class="tv-live-header">
        <h1 class="tv-live-title">
          <span>Direct TV</span>
        </h1>

        <TvSearchBar
          id="live-search-input"
          placeholder="🔍 Rechercher une chaîne ou numéro..."
          value={searchQuery()}
          onInput={handleSearch}
          onClear={handleClearSearch}
          focusId={focusId()}
        />

        <div class="tv-live-badge">
          <span>
            {isSearchMode()
              ? `${searchResults().length} résultats`
              : `${scroller.items().length} / ${scroller.total()} chaînes`}
          </span>
        </div>
      </div>

      <Show
        when={activeChannels().length > 0 || categories().length > 0 || isSearchMode()}
        fallback={
          <div style={{ flex: 1, display: "flex", "flex-direction": "column", "align-items": "center", "justify-content": "center", padding: "40px" }}>
            <p style={{ "font-size": "24px", color: "var(--buntu-text-muted)", "margin-bottom": "24px" }}>
              Aucune chaîne en direct disponible. Ajoutez un abonnement IPTV pour commencer.
            </p>
            <Show when={props.onAddSource}>
              <button
                class={`tv-btn ${focusId() === 'btn-live-add-source' ? 'focused' : ''}`}
                onClick={() => props.onAddSource?.()}
              >
                + Ajouter une source IPTV
              </button>
            </Show>
          </div>
        }
      >
        <div class={`tv-live-layout ${isSearchMode() ? 'search-active' : ''}`}>
          {/* Column 1: Categories Sidebar (Hidden in search mode) */}
          <Show when={!isSearchMode()}>
            <div class="tv-live-sidebar" role="tablist" aria-label="Catégories de chaînes">
              <For each={categories()}>
                {(cat, idx) => (
                  <div
                    id={`cat-${idx()}`}
                    role="tab"
                    tabindex="-1"
                    aria-selected={selectedCategory() === cat}
                    aria-label={`Catégorie ${cat}`}
                    class={`tv-category-item ${selectedCategory() === cat ? 'active' : ''} ${focusId() === `cat-${idx()}` ? 'focused' : ''}`}
                    onClick={() => void handleSelectCategory(cat)}
                  >
                    {cat}
                  </div>
                )}
              </For>
            </div>
          </Show>

          {/* Column 2: Channels List with Infinite Scroll */}
          <div
            class="tv-live-channels"
            role="list"
            aria-label="Liste des chaînes en direct"
            onScroll={handleChannelsScroll}
          >
            <Show
              when={activeChannels().length > 0}
              fallback={
                <div style={{ padding: "48px 0", "text-align": "center", color: "var(--buntu-text-muted)", "font-size": "20px" }}>
                  Aucune chaîne ne correspond à "{searchQuery()}".
                </div>
              }
            >
              <For each={activeChannels()}>
                {(ch) => {
                  const chName = ch.name_clean && ch.name_clean !== ch.name
                    ? ch.name_clean
                    : cleanMediaTitle(ch.name).clean;
                  const isSelected = () => activePreviewChannel()?.id === ch.id;
                  return (
                    <div
                      id={`channel-${ch.id}`}
                      role="button"
                      tabindex="-1"
                      aria-label={`Chaîne numéro ${ch.chno || ''} : ${chName}, catégorie ${ch.group_title || 'Général'}.`}
                      class={`tv-channel-row ${focusId() === `channel-${ch.id}` ? 'focused' : ''} ${isSelected() ? 'active' : ''}`}
                      onClick={() => handleChannelSelect(ch)}
                    >
                      {/* Channel Number Badge */}
                      <div class="tv-channel-num">
                        {ch.chno || '•'}
                      </div>

                      {/* Channel Logo / Fallback */}
                      <div class="tv-channel-logo">
                        <Show
                          when={ch.logo_url}
                          fallback={<span class="tv-channel-logo-fallback">📺</span>}
                        >
                          <img
                            src={ch.logo_url}
                            alt=""
                            loading="lazy"
                            referrerpolicy="no-referrer"
                            crossOrigin="anonymous"
                            onError={(e) => {
                              const target = e.currentTarget as HTMLElement;
                              target.style.display = 'none';
                              if (target.parentElement) {
                                const fallback = document.createElement('span');
                                fallback.className = 'tv-channel-logo-fallback';
                                fallback.textContent = '📺';
                                target.parentElement.appendChild(fallback);
                              }
                            }}
                          />
                        </Show>
                      </div>

                      {/* Channel Name & Category Subtitle */}
                      <div class="tv-channel-info">
                        <div class="tv-channel-name">{chName}</div>
                        <div class="tv-channel-meta">
                          {ch.group_title || 'Général'}
                        </div>
                      </div>

                      {/* Channel Badges & Action Pill */}
                      <div class="tv-channel-actions">
                        <Show when={ch.catchup_days}>
                          <div class="tv-channel-catchup">
                            Replay {ch.catchup_days}j
                          </div>
                        </Show>

                        <Show when={focusId() === `channel-${ch.id}`}>
                          <div class="tv-watch-pill">
                            <span>▶</span>
                            <span>REGARDER</span>
                          </div>
                        </Show>
                      </div>
                    </div>
                  );
                }}
              </For>
            </Show>

            {/* Infinite Scroll Loader & End Status */}
            <Show when={!isSearchMode() && scroller.isLoading()}>
              <div class="tv-infinite-loader">
                <span class="tv-spinner-small" />
                <span>Chargement des chaînes...</span>
              </div>
            </Show>

            <Show when={!isSearchMode() && !scroller.hasMore() && scroller.items().length > 0}>
              <div class="tv-infinite-end">
                • Fin de la catégorie ({scroller.total()} chaînes) •
              </div>
            </Show>
          </div>

          {/* Column 3: Mini Player Preview on the Right */}
          <div class="tv-live-preview" role="region" aria-label="Aperçu et mini lecteur de la chaîne">
            <div class="tv-mini-player-card">
              {/* 16:9 Video Viewport */}
              <div id="tv-mini-viewport" class="tv-live-preview-viewport">
                {/* Real TV hardware AVPlay cutout / Web Mock */}
                <Show
                  when={!(window as any).webapis?.avplay}
                  fallback={
                    <div class="tv-mini-tv-overlay">
                      <div class="tv-mini-live-tag">
                        <span class="tv-live-pulse-dot" />
                        <span>DIRECT</span>
                      </div>
                      <div class="tv-mini-hd-badge">1080p FHD</div>
                    </div>
                  }
                >
                  {/* Browser / Mock Preview Mode */}
                  <div class="tv-mini-mock-screen">
                    <div class="tv-mini-live-tag">
                      <span class="tv-live-pulse-dot" />
                      <span>DIRECT</span>
                    </div>
                    <div class="tv-mini-hd-badge">1080p FHD</div>

                    {/* Centered Channel Icon / Art */}
                    <div class="tv-mini-mock-art">
                      <Show
                        when={activePreviewChannel()?.logo_url}
                        fallback={<span style={{ "font-size": "48px" }}>📺</span>}
                      >
                        <img
                          src={activePreviewChannel()!.logo_url}
                          alt=""
                          referrerpolicy="no-referrer"
                          crossOrigin="anonymous"
                          style={{ "max-width": "80px", "max-height": "80px", "object-fit": "contain" }}
                        />
                      </Show>
                    </div>

                    {/* Equalizer Soundwave Animation */}
                    <div class="tv-mini-equalizer">
                      <span class="eq-bar eq-1" />
                      <span class="eq-bar eq-2" />
                      <span class="eq-bar eq-3" />
                      <span class="eq-bar eq-4" />
                      <span class="eq-bar eq-5" />
                    </div>

                    <div class="tv-mini-mock-title">
                      {previewTitle()}
                    </div>
                  </div>
                </Show>

                {/* Quick Play / Fullscreen overlay button */}
                <button
                  id="btn-mini-fullscreen"
                  role="button"
                  tabindex="-1"
                  aria-label={`Regarder ${previewTitle()} en plein écran`}
                  class={`tv-mini-fs-btn ${focusId() === 'btn-mini-fullscreen' ? 'focused' : ''}`}
                  onClick={handleFullscreen}
                >
                  <span>⛶</span>
                  <span>Plein écran (OK)</span>
                </button>
              </div>

              {/* Channel Info Row */}
              <div class="tv-mini-channel-row">
                <div class="tv-channel-num" style={{ "font-size": "17px", "min-width": "58px", height: "38px" }}>
                  {activePreviewChannel()?.chno || '•'}
                </div>
                <div class="tv-mini-logo-box">
                  <Show
                    when={activePreviewChannel()?.logo_url}
                    fallback={<span style={{ "font-size": "24px" }}>📺</span>}
                  >
                    <img
                      src={activePreviewChannel()!.logo_url}
                      alt=""
                      referrerpolicy="no-referrer"
                      crossOrigin="anonymous"
                    />
                  </Show>
                </div>
                <div class="tv-mini-name-col">
                  <div class="tv-mini-channel-name">{previewTitle()}</div>
                  <div class="tv-mini-channel-cat">
                    {activePreviewChannel()?.group_title || selectedCategory() || 'Direct TV'}
                  </div>
                </div>
                <Show when={activePreviewChannel()?.catchup_days}>
                  <div class="tv-channel-catchup" style={{ "margin-left": "auto" }}>
                    Replay {activePreviewChannel()!.catchup_days}j
                  </div>
                </Show>
              </div>

              {/* EPG Widget */}
              <div class="tv-mini-epg-box">
                <div class="tv-mini-epg-header">
                  <span class="tv-mini-now-tag">EN CE MOMENT</span>
                  <span class="tv-mini-epg-time">
                    {formatTimeRange(currentEpg()?.now?.start_ts, currentEpg()?.now?.end_ts)}
                  </span>
                </div>
                <div class="tv-mini-epg-title">
                  {currentEpg()?.now?.title || 'Programme en cours de diffusion'}
                </div>

                {/* Progress Bar */}
                <div class="tv-mini-epg-bar">
                  <div
                    class="tv-mini-epg-fill"
                    style={{ width: `${progressPercent()}%` }}
                  />
                </div>

                <div class="tv-mini-epg-next">
                  <span class="tv-mini-next-label">À SUIVRE :</span>
                  <span class="tv-mini-next-title">
                    {currentEpg()?.next?.title || 'Programme suivant'}
                  </span>
                </div>
              </div>

              {/* Action Bar */}
              <div class="tv-mini-actions-row">
                <button
                  id="btn-mini-play"
                  role="button"
                  tabindex="-1"
                  aria-label={`Lancer ${previewTitle()}`}
                  class={`tv-btn tv-mini-action-btn ${focusId() === 'btn-mini-play' ? 'focused' : ''}`}
                  onClick={handleFullscreen}
                >
                  ▶ Regarder
                </button>

                <button
                  id="btn-mini-fav"
                  role="button"
                  tabindex="-1"
                  aria-label="Basculer favori"
                  class={`tv-btn tv-mini-action-btn ${focusId() === 'btn-mini-fav' ? 'focused' : ''}`}
                  onClick={() => void handleToggleFav()}
                >
                  {isFav() ? '★ Favori' : '☆ Favori'}
                </button>
              </div>
            </div>
          </div>
        </div>
      </Show>
    </div>
  );
};
