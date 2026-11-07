import { Component, createSignal, onMount, For, Show } from 'solid-js';
import { CndEngine } from '../../core/engine/CndEngine';
import { ItemRecord } from '../../core/storage/Database';
import { FocusableItem, spatialNav } from '../../ui/design/SpatialNav';
import { createInfiniteScroller } from '../../core/pagination/InfiniteScrollController';
import { TvSearchBar } from '../../ui/components/TvSearchBar';
import { announce } from '../../ui/design/a11y';

export interface LiveViewProps {
  onPlayChannel: (channel: ItemRecord) => void;
  onAddSource?: () => void;
}

export const LiveView: Component<LiveViewProps> = (props) => {
  const engine = CndEngine.getInstance();
  const PAGE_SIZE = 40;

  const [categories, setCategories] = createSignal<string[]>([]);
  const [selectedCategory, setSelectedCategory] = createSignal<string>('');
  const [searchQuery, setSearchQuery] = createSignal<string>('');
  const [searchResults, setSearchResults] = createSignal<ItemRecord[]>([]);
  const [focusId] = spatialNav.getFocusSignal();

  const isSearchMode = () => searchQuery().trim().length > 0;
  const activeChannels = () => isSearchMode() ? searchResults() : scroller.items();

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
        rebuildGrid(categories(), list, true);
      }
    },
  });

  onMount(async () => {
    const cats = await engine.getCategories('live');
    setCategories(cats);
    if (cats.length > 0) {
      setSelectedCategory(cats[0]);
      await scroller.reset();
      rebuildGrid(cats, scroller.items(), false);
      if (scroller.items().length > 0) {
        spatialNav.setFocusById(`channel-${scroller.items()[0].id}`);
      }
    } else {
      rebuildGrid([], [], false);
    }
  });

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
    announce(`${results.length} résultats pour la recherche ${query}`);
    rebuildSearchGrid(results);
  };

  const handleClearSearch = () => {
    setSearchQuery('');
    setSearchResults([]);
    rebuildGrid(categories(), scroller.items(), false);
  };

  const rebuildSearchGrid = (results: ItemRecord[]) => {
    const grid: FocusableItem[][] = [];

    // Search bar row
    const searchRow: FocusableItem[] = [
      { id: 'live-search-input', onSelect: () => focusInput('live-search-input') },
    ];
    if (searchQuery().trim()) {
      searchRow.push({ id: 'live-search-input-clear', onSelect: handleClearSearch });
    }
    grid.push(searchRow);

    // Results rows
    for (const ch of results) {
      grid.push([
        {
          id: `channel-${ch.id}`,
          onSelect: () => props.onPlayChannel(ch),
        },
      ]);
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
              rebuildGrid(cats, scroller.items(), false);
              if (scroller.items().length > 0) {
                spatialNav.setFocusById(`channel-${scroller.items()[0].id}`);
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
          onFocus: () => void scroller.checkTrigger(i),
          onSelect: () => props.onPlayChannel(ch),
        });
      } else if (list.length > 0) {
        // Padded row when categories > channels
        const lastCh = list[list.length - 1];
        row.push({
          id: `channel-${lastCh.id}`,
          onSelect: () => props.onPlayChannel(lastCh),
        });
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
    rebuildGrid(categories(), scroller.items(), false);
    if (scroller.items().length > 0) {
      spatialNav.setFocusById(`channel-${scroller.items()[0].id}`);
    }
  };

  const handleChannelsScroll = (e: Event) => {
    if (isSearchMode()) return;
    const el = e.currentTarget as HTMLElement;
    if (el.scrollTop + el.clientHeight >= el.scrollHeight - 300) {
      void scroller.loadMore();
    }
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
        <div class="tv-live-layout">
          {/* Categories Sidebar (Hidden in search mode to give full width to results) */}
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

          {/* Channels List with Infinite Scroll or Search Results */}
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
                {(ch) => (
                  <div
                    id={`channel-${ch.id}`}
                    role="button"
                    tabindex="-1"
                    aria-label={`Chaîne numéro ${ch.chno || ''} : ${ch.name}, catégorie ${ch.group_title || 'Général'}. Appuyez sur OK pour regarder en plein écran.`}
                    class={`tv-channel-row ${focusId() === `channel-${ch.id}` ? 'focused' : ''}`}
                    onClick={() => props.onPlayChannel(ch)}
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
                      <div class="tv-channel-name">{ch.name}</div>
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
                )}
              </For>
            </Show>

            {/* Infinite Scroll Loader & End Status (Only in standard mode) */}
            <Show when={!isSearchMode() && scroller.isLoading()}>
              <div class="tv-infinite-loader">
                <span class="tv-spinner-small" />
                <span>Chargement des chaînes suivantes...</span>
              </div>
            </Show>

            <Show when={!isSearchMode() && !scroller.hasMore() && scroller.items().length > 0}>
              <div class="tv-infinite-end">
                • Fin de la catégorie ({scroller.total()} chaînes) •
              </div>
            </Show>
          </div>
        </div>
      </Show>
    </div>
  );
};
