import { Component, createSignal, onMount, For, Show } from 'solid-js';
import { CndEngine } from '../../core/engine/CndEngine';
import { ItemRecord } from '../../core/storage/Database';
import { FocusableItem, spatialNav } from '../../ui/design/SpatialNav';
import { createInfiniteScroller } from '../../core/pagination/InfiniteScrollController';
import { announce } from '../../ui/design/a11y';

export interface MoviesViewProps {
  onSelectMovie: (movie: ItemRecord) => void;
}

export const MoviesView: Component<MoviesViewProps> = (props) => {
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
        engine.getCatalog('movie', cat, offset, limit),
        engine.countCatalog('movie', cat),
      ]);
      return { items: list, total: count };
    },
    onBatchLoaded: (list, total) => {
      announce(`Films, ${list.length} films affichés sur ${total}`);
      rebuildGrid(categories(), list, true);
    },
  });

  onMount(async () => {
    const cats = await engine.getCategories('movie');
    setCategories(cats);
    if (cats.length > 0) {
      setSelectedCat(cats[0]);
      await scroller.reset();
      rebuildGrid(cats, scroller.items(), false);
      if (scroller.items().length > 0) {
        spatialNav.setFocusById(`movie-${scroller.items()[0].id}`);
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
          id: `movie-cat-${idx}`,
          onSelect: () => void handleSelectCategory(cat),
        }))
      );
    }

    // Subsequent Rows: 5 Movie Cards per Row
    const COLS = 5;
    for (let i = 0; i < list.length; i += COLS) {
      const row = list.slice(i, i + COLS).map((m, colIdx) => {
        const itemIdx = i + colIdx;
        return {
          id: `movie-${m.id}`,
          onFocus: () => void scroller.checkTrigger(itemIdx),
          onSelect: () => props.onSelectMovie(m),
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
      spatialNav.setFocusById(`movie-${scroller.items()[0].id}`);
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
          <span>Films & VOD</span>
        </h1>

        <div class="tv-category-tabs" role="tablist" aria-label="Catégories de films">
          <For each={categories().slice(0, 16)}>
            {(cat, idx) => (
              <button
                id={`movie-cat-${idx()}`}
                role="tab"
                tabindex="-1"
                aria-selected={selectedCat() === cat}
                aria-label={`Catégorie ${cat}`}
                class={`tv-category-pill ${selectedCat() === cat ? 'active' : ''} ${focusId() === `movie-cat-${idx()}` ? 'focused' : ''}`}
                onClick={() => void handleSelectCategory(cat)}
              >
                {cat}
              </button>
            )}
          </For>
        </div>

        <div class="tv-live-badge" style={{ "margin-left": "16px", "flex-shrink": 0 }}>
          <span>{scroller.items().length} / {scroller.total()} films</span>
        </div>
      </div>

      {/* 5-Column Pixel-Perfect Movie Poster Grid */}
      <div class="tv-poster-grid" role="list" aria-label="Catalogue des films">
        <For each={scroller.items()}>
          {(movie) => {
            const title = movie.name_clean || movie.name;
            const is4k = title.toLowerCase().includes('4k') || title.toLowerCase().includes('uhd');
            return (
              <div class="tv-poster-cell">
                <div
                  id={`movie-${movie.id}`}
                  role="button"
                  tabindex="-1"
                  aria-label={`Film ${title}, ${movie.year || ''}, note ${movie.imdb_rating ? movie.imdb_rating.toFixed(1) + ' sur 10' : 'non noté'}`}
                  class={`tv-card tv-poster-card ${focusId() === `movie-${movie.id}` ? 'focused' : ''}`}
                  onClick={() => props.onSelectMovie(movie)}
                >
                  {/* Poster Image Container with Fallback */}
                  <div class="tv-poster-art">
                    <Show
                      when={movie.logo_url}
                      fallback={
                        <div class="tv-poster-fallback">
                          <span class="tv-poster-fallback-icon">🎬</span>
                          <span class="tv-poster-fallback-title">{title}</span>
                        </div>
                      }
                    >
                      <img
                        src={movie.logo_url}
                        alt=""
                        loading="lazy"
                        onError={(e) => {
                          const target = e.currentTarget as HTMLElement;
                          target.style.display = 'none';
                          const parent = target.parentElement;
                          if (parent && !parent.querySelector('.tv-poster-fallback')) {
                            const fb = document.createElement('div');
                            fb.className = 'tv-poster-fallback';
                            fb.innerHTML = `<span class="tv-poster-fallback-icon">🎬</span><span class="tv-poster-fallback-title">${title}</span>`;
                            parent.appendChild(fb);
                          }
                        }}
                      />
                    </Show>

                    {/* Quality / Year Badge */}
                    <Show when={is4k || movie.year}>
                      <div class="tv-poster-badge">
                        {is4k ? '4K UHD' : movie.year}
                      </div>
                    </Show>
                  </div>

                  {/* Card Body Info */}
                  <div class="tv-poster-body">
                    <div class="tv-poster-title">{title}</div>
                    <div class="tv-poster-sub">
                      <span>{movie.year || 'Film'}</span>
                      <Show when={movie.imdb_rating}>
                        <span style={{ color: "var(--buntu-gold)", "font-weight": "800" }}>
                          ★ {movie.imdb_rating!.toFixed(1)}
                        </span>
                      </Show>
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
          <span>Chargement des films suivants...</span>
        </div>
      </Show>

      <Show when={!scroller.hasMore() && scroller.items().length > 0}>
        <div class="tv-infinite-end">
          • Fin du catalogue ({scroller.total()} films) •
        </div>
      </Show>
    </div>
  );
};
