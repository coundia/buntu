import { Component, createSignal, onMount, For } from 'solid-js';
import { CndEngine } from '../../core/engine/CndEngine';
import { ItemRecord } from '../../core/storage/Database';

export interface RecommendationsViewProps {
  onSelectItem: (item: ItemRecord) => void;
}

export const RecommendationsView: Component<RecommendationsViewProps> = (props) => {
  const engine = CndEngine.getInstance();
  const [movieRecs, setMovieRecs] = createSignal<ItemRecord[]>([]);
  const [seriesRecs, setSeriesRecs] = createSignal<ItemRecord[]>([]);

  onMount(async () => {
    const movies = await engine.getCatalog('movie', undefined, 0, 10);
    const series = await engine.getCatalog('series', undefined, 0, 10);
    setMovieRecs(movies);
    setSeriesRecs(series);
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
        <div class="tv-shelf">
          <For each={movieRecs()}>
            {(movie) => (
              <div
                class="tv-card tv-poster-card"
                onClick={() => props.onSelectItem(movie)}
                style={{ cursor: "pointer" }}
              >
                <div
                  class="tv-poster-img"
                  style={{
                    "background-image": movie.logo_url ? `url(${movie.logo_url})` : 'none',
                    "background-size": "cover",
                  }}
                />
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
        <div class="tv-shelf">
          <For each={seriesRecs()}>
            {(series) => (
              <div
                class="tv-card tv-poster-card"
                onClick={() => props.onSelectItem(series)}
                style={{ cursor: "pointer" }}
              >
                <div
                  class="tv-poster-img"
                  style={{
                    "background-image": series.logo_url ? `url(${series.logo_url})` : 'none',
                    "background-size": "cover",
                  }}
                />
                <div class="tv-poster-title">{series.name_clean || series.name}</div>
              </div>
            )}
          </For>
        </div>
      </div>
    </div>
  );
};

