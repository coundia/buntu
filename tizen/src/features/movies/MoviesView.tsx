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
    const visibleCats = cats.slice(0, 8);
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
      <div class="tv-header">
        <h2 style={{ "font-size": "32px", color: "var(--buntu-gold)" }}>Films & VOD</h2>
        <div style={{ display: "flex", gap: "12px", "overflow-x": "auto", "max-width": "1000px" }} role="tablist" aria-label="Catégories de films">
          <For each={categories().slice(0, 8)}>
            {(cat, idx) => (
              <button
                id={`movie-cat-${idx()}`}
                role="tab"
                tabindex="-1"
                aria-selected={selectedCat() === cat}
                aria-label={`Catégorie ${cat}`}
                class={`tv-nav-item ${selectedCat() === cat ? 'active' : ''} ${focusId() === `movie-cat-${idx()}` ? 'focused' : ''}`}
                onClick={() => void loadMovies(cat, categories(), 1)}
              >
                {cat}
              </button>
            )}
          </For>
        </div>
      </div>

      <div style={{
        display: "grid",
        "grid-template-columns": "repeat(5, 1fr)",
        gap: "24px",
        padding: "16px 0",
      }} role="list" aria-label="Catalogue des films">
        <For each={movies()}>
          {(movie) => (
            <div
              id={`movie-${movie.id}`}
              role="button"
              tabindex="-1"
              aria-label={`Film ${movie.name_clean || movie.name}, ${movie.year || ''}, note ${movie.imdb_rating ? movie.imdb_rating.toFixed(1) + ' sur 10' : 'non noté'}`}
              class={`tv-card tv-poster-card ${focusId() === `movie-${movie.id}` ? 'focused' : ''}`}
              onClick={() => props.onSelectMovie(movie)}
              style={{ width: "100%", height: "400px", cursor: "pointer" }}
            >
              <div
                class="tv-poster-img"
                style={{
                  height: "320px",
                  "background-image": movie.logo_url ? `url(${movie.logo_url})` : 'none',
                  "background-size": "cover",
                  "background-position": "center",
                  display: "flex",
                  "align-items": "center",
                  "justify-content": "center",
                  color: "var(--buntu-text-muted)",
                }}
              >
                {!movie.logo_url && <span style={{ "font-size": "48px" }}>🎬</span>}
              </div>
              <div class="tv-poster-title">{movie.name_clean || movie.name}</div>
              <div style={{
                display: "flex",
                "justify-content": "space-between",
                padding: "0 12px 8px 12px",
                "font-size": "14px",
                color: "var(--buntu-text-muted)"
              }}>
                <span>{movie.year || ''}</span>
                <span style={{ color: "var(--buntu-gold)", "font-weight": "700" }}>
                  {movie.imdb_rating ? `★ ${movie.imdb_rating.toFixed(1)}` : ''}
                </span>
              </div>
            </div>
          )}
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
