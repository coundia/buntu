import { Component, createSignal, onMount, For } from 'solid-js';
import { CndEngine } from '../../core/engine/CndEngine';
import { ItemRecord } from '../../core/storage/Database';
import { FocusableItem, spatialNav } from '../../ui/design/SpatialNav';

export interface MoviesViewProps {
  onSelectMovie: (movie: ItemRecord) => void;
}

export const MoviesView: Component<MoviesViewProps> = (props) => {
  const engine = CndEngine.getInstance();
  const [movies, setMovies] = createSignal<ItemRecord[]>([]);
  const [categories, setCategories] = createSignal<string[]>([]);
  const [selectedCat, setSelectedCat] = createSignal<string>('');
  const [focusId] = spatialNav.getFocusSignal();

  onMount(async () => {
    const cats = await engine.getCategories('movie');
    setCategories(cats);
    await loadMovies(cats[0], cats);
  });

  const loadMovies = async (category?: string, cats = categories()) => {
    setSelectedCat(category || '');
    const list = await engine.getCatalog('movie', category, 0, 60);
    setMovies(list);

    const grid: FocusableItem[][] = [];
    const visibleCats = cats.slice(0, 8);
    if (visibleCats.length > 0) {
      grid.push(
        visibleCats.map((cat, idx) => ({
          id: `movie-cat-${idx}`,
          onSelect: () => void loadMovies(cat, cats),
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
    spatialNav.setGrid(grid, list.length > 0 && visibleCats.length > 0 ? 1 : 0, 0);
  };

  return (
    <div class="tv-container">
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
                onClick={() => void loadMovies(cat)}
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
        "overflow-y": "auto",
        padding: "16px 0",
        flex: 1
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
    </div>
  );
};
