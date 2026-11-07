import { Component, createSignal, onMount, For, Show } from 'solid-js';
import { CndEngine } from '../../core/engine/CndEngine';
import { ItemRecord } from '../../core/storage/Database';
import { FocusableItem, spatialNav } from '../../ui/design/SpatialNav';
import { createInfiniteScroller } from '../../core/pagination/InfiniteScrollController';
import { TvSearchBar } from '../../ui/components/TvSearchBar';
import { announce } from '../../ui/design/a11y';

export interface SeriesViewProps {
  onSelectSeries: (series: ItemRecord) => void;
}

export const SeriesView: Component<SeriesViewProps> = (props) => {
  const engine = CndEngine.getInstance();
  const PAGE_SIZE = 25; // 5 columns x 5 rows

  const [categories, setCategories] = createSignal<string[]>([]);
  const [selectedCat, setSelectedCat] = createSignal<string>('');
  const [searchQuery, setSearchQuery] = createSignal<string>('');
  const [searchResults, setSearchResults] = createSignal<ItemRecord[]>([]);
  const [focusId] = spatialNav.getFocusSignal();

  const isSearchMode = () => searchQuery().trim().length > 0;
  const activeSeries = () => isSearchMode() ? searchResults() : scroller.items();

  const scroller = createInfiniteScroller<ItemRecord>({
    pageSize: PAGE_SIZE,
    threshold: 10,
    maxItems: 300,
    fetchBatch: async (offset, limit) => {
      const cat = selectedCat();
      const [list, count] = await Promise.all([
        engine.getCatalog('series', cat, offset, limit),
        engine.countCatalog('series', cat),
      ]);
      return { items: list, total: count };
    },
    onBatchLoaded: (list, total) => {
      if (!isSearchMode()) {
        announce(`Séries, ${list.length} séries affichées sur ${total}`);
        rebuildGrid(categories(), list, true);
      }
    },
  });

  onMount(async () => {
    const cats = await engine.getCategories('series');
    setCategories(cats);
    if (cats.length > 0) {
      setSelectedCat(cats[0]);
      await scroller.reset();
      rebuildGrid(cats, scroller.items(), false);
      if (scroller.items().length > 0) {
        spatialNav.setFocusById(`series-${scroller.items()[0].id}`);
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
    const results = await engine.searchCatalog(query, 'series', 60);
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
      { id: 'series-search-input', onSelect: () => focusInput('series-search-input') },
    ];
    if (searchQuery().trim()) {
      searchRow.push({ id: 'series-search-input-clear', onSelect: handleClearSearch });
    }
    grid.push(searchRow);

    // 5 Series cards per row
    const COLS = 5;
    for (let i = 0; i < results.length; i += COLS) {
      const row = results.slice(i, i + COLS).map((s) => ({
        id: `series-${s.id}`,
        onSelect: () => props.onSelectSeries(s),
      }));
      grid.push(row);
    }

    spatialNav.setGrid(grid, 0, 0, false);
  };

  const rebuildGrid = (cats: string[], list: ItemRecord[], preserveFocus = false) => {
    const grid: FocusableItem[][] = [];

    // Row 0: Search Bar
    const searchRow: FocusableItem[] = [
      { id: 'series-search-input', onSelect: () => focusInput('series-search-input') },
    ];
    if (searchQuery().trim()) {
      searchRow.push({ id: 'series-search-input-clear', onSelect: handleClearSearch });
    }
    grid.push(searchRow);

    // Row 1: Category Tabs
    const visibleCats = cats.slice(0, 16);
    if (visibleCats.length > 0) {
      grid.push(
        visibleCats.map((cat, idx) => ({
          id: `series-cat-${idx}`,
          onSelect: () => void handleSelectCategory(cat),
        }))
      );
    }

    // Subsequent Rows: 5 Series Cards per Row
    const COLS = 5;
    for (let i = 0; i < list.length; i += COLS) {
      const row = list.slice(i, i + COLS).map((s, colIdx) => {
        const itemIdx = i + colIdx;
        return {
          id: `series-${s.id}`,
          onFocus: () => void scroller.checkTrigger(itemIdx),
          onSelect: () => props.onSelectSeries(s),
        };
      });
      grid.push(row);
    }

    spatialNav.setGrid(grid, list.length > 0 && visibleCats.length > 0 ? 2 : 1, 0, preserveFocus);
  };

  const handleSelectCategory = async (cat: string) => {
    if (cat === selectedCat()) return;
    setSearchQuery('');
    setSearchResults([]);
    setSelectedCat(cat);
    await scroller.reset();
    rebuildGrid(categories(), scroller.items(), false);
    if (scroller.items().length > 0) {
      spatialNav.setFocusById(`series-${scroller.items()[0].id}`);
    }
  };

  const handleContainerScroll = (e: Event) => {
    if (isSearchMode()) return;
    const el = e.currentTarget as HTMLElement;
    if (el.scrollTop + el.clientHeight >= el.scrollHeight - 400) {
      void scroller.loadMore();
    }
  };

  return (
    <div
      class="tv-container"
      style={{ "overflow-y": "auto" }}
      onScroll={handleContainerScroll}
    >
      {/* Header with Title, In-Screen Search Bar & Counter */}
      <div class="tv-live-header">
        <h1 class="tv-live-title">
          <span>Séries TV</span>
        </h1>

        <TvSearchBar
          id="series-search-input"
          placeholder="🔍 Rechercher une série..."
          value={searchQuery()}
          onInput={handleSearch}
          onClear={handleClearSearch}
          focusId={focusId()}
        />

        {/* Category tabs (hidden in search mode to leave space) */}
        <Show when={!isSearchMode()}>
          <div class="tv-category-tabs" role="tablist" aria-label="Catégories de séries">
            <For each={categories().slice(0, 16)}>
              {(cat, idx) => (
                <button
                  id={`series-cat-${idx()}`}
                  role="tab"
                  tabindex="-1"
                  aria-selected={selectedCat() === cat}
                  aria-label={`Catégorie ${cat}`}
                  class={`tv-category-pill ${selectedCat() === cat ? 'active' : ''} ${focusId() === `series-cat-${idx()}` ? 'focused' : ''}`}
                  onClick={() => void handleSelectCategory(cat)}
                >
                  {cat}
                </button>
              )}
            </For>
          </div>
        </Show>

        <div class="tv-live-badge" style={{ "margin-left": "16px", "flex-shrink": 0 }}>
          <span>
            {isSearchMode()
              ? `${searchResults().length} résultats`
              : `${scroller.items().length} / ${scroller.total()} séries`}
          </span>
        </div>
      </div>

      {/* 5-Column Pixel-Perfect Series Poster Grid */}
      <div class="tv-poster-grid" role="list" aria-label="Catalogue des séries">
        <Show
          when={activeSeries().length > 0}
          fallback={
            <div style={{ width: "100%", padding: "48px 0", "text-align": "center", color: "var(--buntu-text-muted)", "font-size": "20px" }}>
              Aucune série ne correspond à "{searchQuery()}".
            </div>
          }
        >
          <For each={activeSeries()}>
            {(series) => {
              const title = series.name_clean || series.name;
              const is4k = title.toLowerCase().includes('4k') || title.toLowerCase().includes('uhd');
              return (
                <div class="tv-poster-cell">
                  <div
                    id={`series-${series.id}`}
                    role="button"
                    tabindex="-1"
                    aria-label={`Série ${title}, Saison ${series.season_num || 1}, Épisode ${series.episode_num || 1}`}
                    class={`tv-card tv-poster-card ${focusId() === `series-${series.id}` ? 'focused' : ''}`}
                    onClick={() => props.onSelectSeries(series)}
                  >
                    {/* Poster Art with Fallback */}
                    <div class="tv-poster-art">
                      <Show
                        when={series.logo_url}
                        fallback={
                          <div class="tv-poster-fallback">
                            <span class="tv-poster-fallback-icon">📺</span>
                            <span class="tv-poster-fallback-title">{title}</span>
                          </div>
                        }
                      >
                        <img
                          src={series.logo_url}
                          alt=""
                          loading="lazy"
                          onError={(e) => {
                            const target = e.currentTarget as HTMLElement;
                            target.style.display = 'none';
                            const parent = target.parentElement;
                            if (parent && !parent.querySelector('.tv-poster-fallback')) {
                              const fb = document.createElement('div');
                              fb.className = 'tv-poster-fallback';
                              fb.innerHTML = `<span class="tv-poster-fallback-icon">📺</span><span class="tv-poster-fallback-title">${title}</span>`;
                              parent.appendChild(fb);
                            }
                          }}
                        />
                      </Show>

                      {/* Quality / Season Badge */}
                      <Show when={is4k || series.season_num}>
                        <div class="tv-poster-badge">
                          {is4k ? '4K' : `S${series.season_num || 1}`}
                        </div>
                      </Show>
                    </div>

                    {/* Card Body */}
                    <div class="tv-poster-body">
                      <div class="tv-poster-title">{title}</div>
                      <div class="tv-poster-sub">
                        <span>Saison {series.season_num || 1}</span>
                        <span style={{ color: "var(--buntu-cyan)", "font-weight": "700" }}>
                          Ép. {series.episode_num || 1}
                        </span>
                      </div>
                    </div>
                  </div>
                </div>
              );
            }}
          </For>
        </Show>
      </div>

      {/* Infinite Scroll Loader & End Status (Only in standard mode) */}
      <Show when={!isSearchMode() && scroller.isLoading()}>
        <div class="tv-infinite-loader">
          <span class="tv-spinner-small" />
          <span>Chargement des séries suivantes...</span>
        </div>
      </Show>

      <Show when={!isSearchMode() && !scroller.hasMore() && scroller.items().length > 0}>
        <div class="tv-infinite-end">
          • Fin du catalogue ({scroller.total()} séries) •
        </div>
      </Show>
    </div>
  );
};
