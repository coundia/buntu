import { Component, createSignal, onMount, onCleanup, For, Show } from 'solid-js';
import { CndEngine } from '../../core/engine/CndEngine';
import { Database, EpgProgramRecord, ItemRecord } from '../../core/storage/Database';
import { AVPlayerService } from '../../core/player/AVPlayerService';
import { FocusableItem, spatialNav } from '../../ui/design/SpatialNav';
import { createInfiniteScroller } from '../../core/pagination/InfiniteScrollController';
import { TvSearchBar } from '../../ui/components/TvSearchBar';
import { cleanMediaTitle } from '../../core/utils/titleCleaner';
import { getCategoryMeta, formatViewCount } from '../../core/utils/categoryMeta';
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
    player.setDisplayArea({ x: 918, y: 84, width: 880, height: 495 });
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
        spatialNav.setFocusById('cat-0');
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
    if (selectedCategory().includes('Favoris')) {
      await scroller.reset();
      const items = scroller.items();
      if (items.length > 0) {
        void updatePreview(items[0]);
      } else {
        setPreviewChannel(null);
      }
      rebuildGrid(categories(), items, false);
    }
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

  const formatTimestamp = (ts?: number, fallback = '00:00:00') => {
    if (!ts) return fallback;
    const d = new Date(ts * 1000);
    const h = String(d.getHours()).padStart(2, '0');
    const m = String(d.getMinutes()).padStart(2, '0');
    const s = String(d.getSeconds()).padStart(2, '0');
    return `${h}:${m}:${s}`;
  };

  return (
    <div style={{ width: "100%", height: "100%", overflow: "hidden" }}>
      <Show
        when={activeChannels().length > 0 || categories().length > 0 || isSearchMode()}
        fallback={
          <div style={{ flex: 1, display: "flex", "flex-direction": "column", "align-items": "center", "justify-content": "center", height: "100%", padding: "40px" }}>
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
        <div class="tv-minimal-3col">
          {/* Column 1: Categories Sidebar */}
          <div class="tv-min-col-categories" role="tablist" aria-label="Catégories de chaînes">
            <h1 class="tv-min-col-title">
              <span>Live TV's</span>
            </h1>

            <div style={{ "margin-bottom": "14px" }}>
              <TvSearchBar
                id="live-search-input"
                placeholder="Rechercher chaîne..."
                value={searchQuery()}
                onInput={handleSearch}
                onClear={handleClearSearch}
                focusId={focusId()}
              />
            </div>

            <div class="tv-min-cat-list">
              <For each={categories()}>
                {(cat, idx) => {
                  const meta = getCategoryMeta(cat);
                  const isSelected = () => selectedCategory() === cat;
                  return (
                    <div
                      id={`cat-${idx()}`}
                      role="tab"
                      tabindex="-1"
                      aria-selected={isSelected()}
                      aria-label={`Catégorie ${cat}`}
                      class={`tv-min-cat-item ${isSelected() ? 'active' : ''} ${focusId() === `cat-${idx()}` ? 'focused' : ''}`}
                      onClick={() => void handleSelectCategory(cat)}
                    >
                      <div class="tv-min-cat-badge">{meta.icon}</div>
                      <div class="tv-min-cat-info">
                        <div class="tv-min-cat-name">{cat}</div>
                        <div class="tv-min-cat-count">
                          {isSelected() ? `${scroller.total()} Chaînes` : 'Chaînes'}
                        </div>
                      </div>
                    </div>
                  );
                }}
              </For>
            </div>
          </div>

          {/* Column 2: Cards List with Infinite Scroll */}
          <div
            class="tv-min-col-cards"
            role="list"
            aria-label="Liste des chaînes"
            onScroll={handleChannelsScroll}
          >
            <div class="tv-min-cards-scroll">
              <Show
                when={activeChannels().length > 0}
                fallback={
                  <div style={{ padding: "48px 20px", "text-align": "center", color: "var(--buntu-text-muted)", "font-size": "18px" }}>
                    {isSearchMode()
                      ? `Aucune chaîne ne correspond à "${searchQuery()}".`
                      : selectedCategory().includes('Favoris')
                      ? 'Aucune chaîne dans vos favoris. Appuyez sur ☆ Favori pour ajouter vos chaînes préférées !'
                      : 'Aucune chaîne dans cette catégorie.'}
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
                        aria-label={`Chaîne ${chName}`}
                        class={`tv-min-media-card ${focusId() === `channel-${ch.id}` ? 'focused' : ''} ${isSelected() ? 'active' : ''}`}
                        onClick={() => handleChannelSelect(ch)}
                      >
                        <div class="tv-min-card-thumb">
                          <Show
                            when={ch.logo_url}
                            fallback={<span style={{ "font-size": "32px" }}>📺</span>}
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
                                  target.parentElement.innerHTML = '<span style="font-size:32px;">📺</span>';
                                }
                              }}
                            />
                          </Show>
                        </div>

                        <div class="tv-min-card-meta">
                          <div class="tv-min-card-title">{chName}</div>
                          <div class="tv-min-card-views">{formatViewCount(ch.id)}</div>
                          <div class="tv-min-card-tags">
                            <span class="tv-min-tag">HD</span>
                            <Show when={ch.tvg_id}><span class="tv-min-tag">EPG</span></Show>
                            <Show when={ch.catchup_days}><span class="tv-min-tag">REPLAY</span></Show>
                          </div>
                        </div>

                        <Show when={ch.is_favorite === 1}>
                          <div class="tv-min-card-fav">★</div>
                        </Show>
                      </div>
                    );
                  }}
                </For>
              </Show>

              {/* Infinite Scroll Loader */}
              <Show when={!isSearchMode() && scroller.isLoading()}>
                <div style={{ "text-align": "center", padding: "16px", color: "var(--buntu-text-muted)" }}>
                  Chargement...
                </div>
              </Show>
            </div>
          </div>

          {/* Column 3: Hero Panel (16:9 Viewport + Now Playing + Synopsis + Timeline + Actions) */}
          <div class="tv-min-col-hero" role="region" aria-label="Aperçu et mini lecteur">
            <div id="tv-mini-viewport" class="tv-min-hero-viewport">
              {/* Hardware AVPlay or Web Mock */}
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
                <div class="tv-mini-mock-screen">
                  <div class="tv-mini-live-tag">
                    <span class="tv-live-pulse-dot" />
                    <span>DIRECT</span>
                  </div>
                  <div class="tv-mini-hd-badge">1080p FHD</div>

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

                  <div class="tv-mini-equalizer">
                    <span class="eq-bar eq-1" />
                    <span class="eq-bar eq-2" />
                    <span class="eq-bar eq-3" />
                    <span class="eq-bar eq-4" />
                    <span class="eq-bar eq-5" />
                  </div>

                  <div class="tv-mini-mock-title">{previewTitle()}</div>
                </div>
              </Show>
            </div>

            {/* Now Playing Metadata Section */}
            <div class="tv-min-hero-info">
              <div class="tv-min-now-label">NOW PLAYING...</div>
              <h2 class="tv-min-hero-title">
                {currentEpg()?.now?.title || previewTitle()}
              </h2>
              <p class="tv-min-hero-desc">
                {currentEpg()?.now?.desc || (activePreviewChannel()?.group_title ? `Diffusion en continu dans le bouquet ${activePreviewChannel()!.group_title}. Flux haute définition optimisé Smart TV.` : 'Programme en cours de diffusion.')}
              </p>

              {/* Progress Bar Timeline */}
              <div class="tv-min-hero-progress">
                <span class="tv-min-time">
                  {formatTimestamp(currentEpg()?.now?.start_ts, '01:52:37')}
                </span>
                <div class="tv-min-track">
                  <div class="tv-min-fill" style={{ width: `${Math.max(5, progressPercent())}%` }}>
                    <div class="tv-min-knob" />
                  </div>
                </div>
                <span class="tv-min-time">
                  {formatTimestamp(currentEpg()?.now?.end_ts, '02:10:46')}
                </span>
              </div>

              {/* Hero Action Buttons */}
              <div class="tv-min-hero-actions">
                <button
                  id="btn-mini-play"
                  role="button"
                  tabindex="-1"
                  aria-label={`Lancer ${previewTitle()}`}
                  class={`tv-min-btn-play ${focusId() === 'btn-mini-play' ? 'focused' : ''}`}
                  onClick={handleFullscreen}
                >
                  ▶ Regarder
                </button>

                <button
                  id="btn-mini-fav"
                  role="button"
                  tabindex="-1"
                  aria-label="Basculer favori"
                  class={`tv-min-btn-secondary ${focusId() === 'btn-mini-fav' ? 'focused' : ''}`}
                  onClick={() => void handleToggleFav()}
                >
                  {isFav() ? '★ Retirer Favori' : '☆ Favori'}
                </button>

                <button
                  id="btn-mini-fullscreen"
                  role="button"
                  tabindex="-1"
                  aria-label="Plein écran"
                  class={`tv-min-btn-secondary ${focusId() === 'btn-mini-fullscreen' ? 'focused' : ''}`}
                  onClick={handleFullscreen}
                >
                  ⛶ Plein écran
                </button>
              </div>
            </div>
          </div>
        </div>
      </Show>
    </div>
  );
};
