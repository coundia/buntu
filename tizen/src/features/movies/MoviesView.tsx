import { Component, createSignal, onMount, For, Show } from 'solid-js';
import { CndEngine } from '../../core/engine/CndEngine';
import { ItemRecord } from '../../core/storage/Database';
import { FocusableItem, spatialNav } from '../../ui/design/SpatialNav';
import { createInfiniteScroller } from '../../core/pagination/InfiniteScrollController';
import { TvSearchBar } from '../../ui/components/TvSearchBar';
import { announce } from '../../ui/design/a11y';

export interface MoviesViewProps {
  onSelectMovie: (movie: ItemRecord) => void;
}

export const MoviesView: Component<MoviesViewProps> = (props) => {
  const engine = CndEngine.getInstance();
  const PAGE_SIZE = 25; // 5 columns x 5 rows

  const [categories, setCategories] = createSignal<string[]>([]);
  const [selectedCat, setSelectedCat] = createSignal<string>('');
  const [searchQuery, setSearchQuery] = createSignal<string>('');
  const [searchResults, setSearchResults] = createSignal<ItemRecord[]>([]);
  const [focusId] = spatialNav.getFocusSignal();

  const isSearchMode = () => searchQuery().trim().length > 0;
  const activeMovies = () => isSearchMode() ? searchResults() : scroller.items();

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
      if (!isSearchMode()) {
        announce(`Films, ${list.length} films affichés sur ${total}`);
        rebuildGrid(categories(), list, true);
      }
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
    const results = await engine.searchCatalog(query, 'movie', 60);
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
      { id: 'movie-search-input', onSelect: () => focusInput('movie-search-input') },
    ];
    if (searchQuery().trim()) {
      searchRow.push({ id: 'movie-search-input-clear', onSelect: handleClearSearch });
    }
    grid.push(searchRow);

    // 5 Movie cards per row
    const COLS = 5;
    for (let i = 0; i < results.length; i += COLS) {
      const row = results.slice(i, i + COLS).map((m) => ({
        id: `movie-${m.id}`,
        onSelect: () => props.onSelectMovie(m),
      }));
      grid.push(row);
    }

    spatialNav.setGrid(grid, 0, 0, false);
  };

  const rebuildGrid = (cats: string[], list: ItemRecord[], preserveFocus = false) => {
    const grid: FocusableItem[][] = [];

    // Row 0: Search Bar
    const searchRow: FocusableItem[] = [
      { id: 'movie-search-input', onSelect: () => focusInput('movie-search-input') },
    ];
    if (searchQuery().trim()) {
      searchRow.push({ id: 'movie-search-input-clear', onSelect: handleClearSearch });
    }
    grid.push(searchRow);

    // Row 1: Category Tabs
    const visibleCats = cats.slice(0, 16);
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
      spatialNav.setFocusById(`movie-${scroller.items()[0].id}`);
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
          <span>Films & VOD</span>
        </h1>

        <TvSearchBar
          id="movie-search-input"
          placeholder="🔍 Rechercher un film..."
          value={searchQuery()}
          onInput={handleSearch}
          onClear={handleClearSearch}
          focusId={focusId()}
        />

        {/* Category tabs (hidden in search mode to leave space) */}
        <Show when={!isSearchMode()}>
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
        </Show>

        <div class="tv-live-badge" style={{ "margin-left": "16px", "flex-shrink": 0 }}>
          <span>
            {isSearchMode()
              ? `${searchResults().length} résultats`
              : `${scroller.items().length} / ${scroller.total()} films`}
          </span>
        </div>
      </div>

      {/* 5-Column Pixel-Perfect Movie Poster Grid */}
      <div class="tv-poster-grid" role="list" aria-label="Catalogue des films">
        <Show
          when={activeMovies().length > 0}
          fallback={
            <div style={{ width: "100%", padding: "48px 0", "text-align": "center", color: "var(--buntu-text-muted)", "font-size": "20px" }}>
              Aucun film ne correspond à "{searchQuery()}".
            </div>
          }
        >
          <For each={activeMovies()}>
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
        </Show>
      </div>

      {/* Infinite Scroll Loader & End Status (Only in standard mode) */}
      <Show when={!isSearchMode() && scroller.isLoading()}>
        <div class="tv-infinite-loader">
          <span class="tv-spinner-small" />
          <span>Chargement des films suivants...</span>
        </div>
      </Show>

      <Show when={!isSearchMode() && !scroller.hasMore() && scroller.items().length > 0}>
        <div class="tv-infinite-end">
          • Fin du catalogue ({scroller.total()} films) •
        </div>
      </Show>
    </div>
  );
};
