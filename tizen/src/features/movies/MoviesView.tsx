import { Component, createSignal, onMount, onCleanup, For, Show } from 'solid-js';
import { CndEngine } from '../../core/engine/CndEngine';
import { ItemRecord } from '../../core/storage/Database';
import { FocusableItem, spatialNav } from '../../ui/design/SpatialNav';
import { RemoteKeyHandler } from '../../core/input/RemoteKeyHandler';
import { announce } from '../../ui/design/a11y';

export interface MoviesViewProps {
  onSelectMovie: (movie: ItemRecord) => void;
}

export const MoviesView: Component<MoviesViewProps> = (props) => {
  const engine = CndEngine.getInstance();
  const PAGE_SIZE = 25; // 5 columns x 5 rows

  const [movies, setMovies] = createSignal<ItemRecord[]>([]);
  const [categories, setCategories] = createSignal<string[]>([]);
  const [selectedCat, setSelectedCat] = createSignal<string>('');
  const [currentPage, setCurrentPage] = createSignal(1);
  const [totalCount, setTotalCount] = createSignal(0);
  const [focusId] = spatialNav.getFocusSignal();

  const totalPages = () => Math.max(1, Math.ceil(totalCount() / PAGE_SIZE));

  let keyUnsub: (() => void) | null = null;

  onMount(async () => {
    const cats = await engine.getCategories('movie');
    setCategories(cats);
    if (cats.length > 0) {
      await loadMovies(cats[0], cats, 1);
    }

    keyUnsub = RemoteKeyHandler.getInstance().addListener((key) => {
      if (key === 'CHANNEL_UP' && currentPage() < totalPages()) {
        void loadMovies(selectedCat(), categories(), currentPage() + 1);
        return true;
      }
      if (key === 'CHANNEL_DOWN' && currentPage() > 1) {
        void loadMovies(selectedCat(), categories(), currentPage() - 1);
        return true;
      }
      return false;
    });
  });

  onCleanup(() => {
    if (keyUnsub) keyUnsub();
  });

  const loadMovies = async (category?: string, cats = categories(), page = 1) => {
    const isNewCategory = category !== selectedCat();
    const targetPage = isNewCategory ? 1 : page;
    setSelectedCat(category || '');
    setCurrentPage(targetPage);

    const offset = (targetPage - 1) * PAGE_SIZE;

    // Parallel execution: fetch page slice + instant count (< 15ms total)
    const [list, count] = await Promise.all([
      engine.getCatalog('movie', category, offset, PAGE_SIZE),
      engine.countCatalog('movie', category),
    ]);

    setMovies(list);
    setTotalCount(count);

    const pages = Math.max(1, Math.ceil(count / PAGE_SIZE));
    announce(`Films, catégorie ${category || 'toutes'}, page ${targetPage} sur ${pages}`);

    const grid: FocusableItem[][] = [];
    const visibleCats = cats.slice(0, 16);
    if (visibleCats.length > 0) {
      grid.push(
        visibleCats.map((cat, idx) => ({
          id: `movie-cat-${idx}`,
          onSelect: () => void loadMovies(cat, cats, 1),
        }))
      );
    }

    const COLS = 5;
    for (let i = 0; i < list.length; i += COLS) {
      const row = list.slice(i, i + COLS).map((m) => ({
        id: `movie-${m.id}`,
        onSelect: () => props.onSelectMovie(m),
      }));
      grid.push(row);
    }

    // Pagination row
    const paginationRow: FocusableItem[] = [];
    if (targetPage > 1) {
      paginationRow.push({
        id: 'btn-page-prev',
        onSelect: () => void loadMovies(category, cats, targetPage - 1),
      });
    }
    if (targetPage < pages) {
      paginationRow.push({
        id: 'btn-page-next',
        onSelect: () => void loadMovies(category, cats, targetPage + 1),
      });
    }
    if (paginationRow.length > 0) {
      grid.push(paginationRow);
    }

    spatialNav.setGrid(grid, list.length > 0 && visibleCats.length > 0 ? 1 : 0, 0);

    // If moving between pages, smoothly refocus on first movie card
    if (!isNewCategory && list.length > 0) {
      spatialNav.setFocusById(`movie-${list[0].id}`);
    }
  };

  return (
    <div class="tv-container" style={{ "overflow-y": "auto" }}>
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
                onClick={() => void loadMovies(cat, categories(), 1)}
              >
                {cat}
              </button>
            )}
          </For>
        </div>

        <div class="tv-live-badge" style={{ "margin-left": "16px", "flex-shrink": 0 }}>
          <span>{totalCount()} films</span>
        </div>
      </div>

      {/* 5-Column Pixel-Perfect Movie Poster Grid */}
      <div class="tv-poster-grid" role="list" aria-label="Catalogue des films">
        <For each={movies()}>
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

      {/* Pagination Footer Controls */}
      <Show when={totalPages() > 1}>
        <div class="tv-pagination-bar" role="navigation" aria-label="Pagination des films">
          <button
            id="btn-page-prev"
            role="button"
            tabindex="-1"
            aria-label="Aller à la page précédente"
            class={`tv-btn ${currentPage() <= 1 ? 'disabled' : ''} ${focusId() === 'btn-page-prev' ? 'focused' : ''}`}
            onClick={() => void loadMovies(selectedCat(), categories(), currentPage() - 1)}
          >
            ◀ Page précédente
          </button>

          <div class="tv-page-indicator" aria-live="polite">
            Page {currentPage()} sur {totalPages()} ({totalCount()} films)
          </div>

          <button
            id="btn-page-next"
            role="button"
            tabindex="-1"
            aria-label="Aller à la page suivante"
            class={`tv-btn ${currentPage() >= totalPages() ? 'disabled' : ''} ${focusId() === 'btn-page-next' ? 'focused' : ''}`}
            onClick={() => void loadMovies(selectedCat(), categories(), currentPage() + 1)}
          >
            Page suivante ▶
          </button>
        </div>
      </Show>
    </div>
  );
};
