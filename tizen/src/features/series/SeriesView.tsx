import { Component, createSignal, onMount, For, Show } from 'solid-js';
import { CndEngine } from '../../core/engine/CndEngine';
import { ItemRecord } from '../../core/storage/Database';
import { FocusableItem, spatialNav } from '../../ui/design/SpatialNav';
import { createInfiniteScroller } from '../../core/pagination/InfiniteScrollController';
import { announce } from '../../ui/design/a11y';

export interface SeriesViewProps {
  onSelectSeries: (series: ItemRecord) => void;
}

export const SeriesView: Component<SeriesViewProps> = (props) => {
  const engine = CndEngine.getInstance();
  const PAGE_SIZE = 25; // 5 columns x 5 rows

  const [categories, setCategories] = createSignal<string[]>([]);
  const [selectedCat, setSelectedCat] = createSignal<string>('');
  const [focusId] = spatialNav.getFocusSignal();

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
      announce(`Séries, ${list.length} séries affichées sur ${total}`);
      rebuildGrid(categories(), list, true);
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

  const rebuildGrid = (cats: string[], list: ItemRecord[], preserveFocus = false) => {
    const grid: FocusableItem[][] = [];
    const visibleCats = cats.slice(0, 16);

    // Row 0: Category Tabs
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

    spatialNav.setGrid(grid, list.length > 0 && visibleCats.length > 0 ? 1 : 0, 0, preserveFocus);
  };

  const handleSelectCategory = async (cat: string) => {
    if (cat === selectedCat()) return;
    setSelectedCat(cat);
    await scroller.reset();
    rebuildGrid(categories(), scroller.items(), false);
    if (scroller.items().length > 0) {
      spatialNav.setFocusById(`series-${scroller.items()[0].id}`);
    }
  };

  const handleContainerScroll = (e: Event) => {
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
      {/* Header with Title & Horizontal Category Tabs */}
      <div class="tv-live-header">
        <h1 class="tv-live-title">
          <span>Séries TV</span>
        </h1>

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

        <div class="tv-live-badge" style={{ "margin-left": "16px", "flex-shrink": 0 }}>
          <span>{scroller.items().length} / {scroller.total()} séries</span>
        </div>
      </div>

      {/* 5-Column Pixel-Perfect Series Poster Grid */}
      <div class="tv-poster-grid" role="list" aria-label="Catalogue des séries">
        <For each={scroller.items()}>
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
      </div>

      {/* Infinite Scroll Loader & End Status */}
      <Show when={scroller.isLoading()}>
        <div class="tv-infinite-loader">
          <span class="tv-spinner-small" />
          <span>Chargement des séries suivantes...</span>
        </div>
      </Show>

      <Show when={!scroller.hasMore() && scroller.items().length > 0}>
        <div class="tv-infinite-end">
          • Fin du catalogue ({scroller.total()} séries) •
        </div>
      </Show>
    </div>
  );
};
