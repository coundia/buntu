import { Component, createSignal, onMount, For } from 'solid-js';
import { CndEngine } from '../../core/engine/CndEngine';
import { ItemRecord } from '../../core/storage/Database';
import { FocusableItem, spatialNav } from '../../ui/design/SpatialNav';

export interface RecommendationsViewProps {
  onSelectItem: (item: ItemRecord) => void;
}

export const RecommendationsView: Component<RecommendationsViewProps> = (props) => {
  const engine = CndEngine.getInstance();
  const [movieRecs, setMovieRecs] = createSignal<ItemRecord[]>([]);
  const [seriesRecs, setSeriesRecs] = createSignal<ItemRecord[]>([]);
  const [focusId] = spatialNav.getFocusSignal();

  onMount(async () => {
    const movies = await engine.getCatalog('movie', undefined, 0, 10);
    const series = await engine.getCatalog('series', undefined, 0, 10);
    setMovieRecs(movies);
    setSeriesRecs(series);

    const grid: FocusableItem[][] = [];
    if (movies.length > 0) {
      grid.push(
        movies.map((m) => ({
          id: `reco-movie-${m.id}`,
          onSelect: () => props.onSelectItem(m),
        }))
      );
    }
    if (series.length > 0) {
      grid.push(
        series.map((s) => ({
          id: `reco-series-${s.id}`,
          onSelect: () => props.onSelectItem(s),
        }))
      );
    }
    spatialNav.setGrid(grid);
  });

  return (
    <div class="tv-container" style={{ "overflow-y": "auto" }}>
      <div class="tv-header">
        <h2 style={{ "font-size": "32px", color: "var(--buntu-gold)" }}>Recommandé Pour Vous</h2>
        <div style={{ color: "var(--buntu-text-muted)" }}>Basé sur vos préférences locales</div>
      </div>

      {/* Movies Shelf */}
      <div style={{ "margin-bottom": "36px" }}>
        <h3 style={{ "font-size": "24px", "margin-bottom": "16px", color: "var(--buntu-cyan)" }}>
          Films à découvrir
        </h3>
        <div class="tv-shelf" role="list" aria-label="Films à découvrir">
          <For each={movieRecs()}>
            {(movie) => (
              <div
                id={`reco-movie-${movie.id}`}
                role="button"
                tabindex="-1"
                aria-label={`Film ${movie.name_clean || movie.name}, ${movie.year || ''}`}
                class={`tv-card tv-poster-card ${focusId() === `reco-movie-${movie.id}` ? 'focused' : ''}`}
                onClick={() => props.onSelectItem(movie)}
                style={{ cursor: "pointer" }}
              >
                <div
                  class="tv-poster-img"
                  style={{
                    "background-image": movie.logo_url ? `url(${movie.logo_url})` : 'none',
                    "background-size": "cover",
                    "background-position": "center",
                    display: "flex",
                    "align-items": "center",
                    "justify-content": "center",
                    color: "var(--buntu-text-muted)",
                  }}
                >
                  {!movie.logo_url && <span style={{ "font-size": "36px" }}>🎬</span>}
                </div>
                <div class="tv-poster-title">{movie.name_clean || movie.name}</div>
              </div>
            )}
          </For>
        </div>
      </div>

      {/* Series Shelf */}
      <div>
        <h3 style={{ "font-size": "24px", "margin-bottom": "16px", color: "var(--buntu-gold)" }}>
          Séries recommandées
        </h3>
        <div class="tv-shelf" role="list" aria-label="Séries recommandées">
          <For each={seriesRecs()}>
            {(series) => (
              <div
                id={`reco-series-${series.id}`}
                role="button"
                tabindex="-1"
                aria-label={`Série ${series.name_clean || series.name}`}
                class={`tv-card tv-poster-card ${focusId() === `reco-series-${series.id}` ? 'focused' : ''}`}
                onClick={() => props.onSelectItem(series)}
                style={{ cursor: "pointer" }}
              >
                <div
                  class="tv-poster-img"
                  style={{
                    "background-image": series.logo_url ? `url(${series.logo_url})` : 'none',
                    "background-size": "cover",
                    "background-position": "center",
                    display: "flex",
                    "align-items": "center",
                    "justify-content": "center",
                    color: "var(--buntu-text-muted)",
                  }}
                >
                  {!series.logo_url && <span style={{ "font-size": "36px" }}>📺</span>}
                </div>
                <div class="tv-poster-title">{series.name_clean || series.name}</div>
              </div>
            )}
          </For>
        </div>
      </div>
    </div>
  );
};
