import { Component, createSignal, onMount, For } from 'solid-js';
import { CndEngine } from '../../core/engine/CndEngine';
import { ItemRecord } from '../../core/storage/Database';
import { spatialNav } from '../../ui/design/SpatialNav';

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
    await loadMovies(cats[0]);
  });

  const loadMovies = async (category?: string) => {
    setSelectedCat(category || '');
    const list = await engine.getCatalog('movie', category, 0, 60);
    setMovies(list);

    // Build 5-column grid for spatial navigation
    const COLS = 5;
    const grid = [];
    for (let i = 0; i < list.length; i += COLS) {
      const row = list.slice(i, i + COLS).map((m) => ({
        id: `movie-${m.id}`,
        onSelect: () => props.onSelectMovie(m),
      }));
      grid.push(row);
    }
    spatialNav.setGrid(grid);
  };

  return (
    <div class="tv-container">
      <div class="tv-header">
        <h2 style={{ "font-size": "32px", color: "var(--buntu-gold)" }}>Films & VOD</h2>
        <div style={{ display: "flex", gap: "12px", "overflow-x": "auto", "max-width": "1000px" }}>
          <For each={categories().slice(0, 8)}>
            {(cat) => (
              <button
                class={`tv-nav-item ${selectedCat() === cat ? 'active' : ''}`}
                onClick={() => loadMovies(cat)}
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
      }}>
        <For each={movies()}>
          {(movie) => (
            <div
              class={`tv-card tv-poster-card ${focusId() === `movie-${movie.id}` ? 'focused' : ''}`}
              onClick={() => props.onSelectMovie(movie)}
              style={{ width: "100%", height: "400px" }}
            >
              <div
                class="tv-poster-img"
                style={{
                  height: "320px",
                  "background-image": movie.logo_url ? `url(${movie.logo_url})` : 'none',
                  "background-size": "cover",
                  "background-position": "center",
                }}
              />
              <div class="tv-poster-title">{movie.name_clean || movie.name}</div>
              <div style={{
                display: "flex",
                "justify-content": "space-between",
                padding: "0 12px 8px 12px",
                "font-size": "14px",
                color: "var(--buntu-text-muted)"
              }}>
                <span>{movie.year || ''}</span>
                <span style={{ color: "var(--buntu-gold)" }}>
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

