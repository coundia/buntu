import { Component, createSignal, onMount, For, Show } from 'solid-js';
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

    // Asynchronous progressive AI re-ranking (PRD 40 § 6.3)
    void (async () => {
      try {
        const refinedMovies = await engine.refineRecommendationsWithAi('movie', movies);
        if (refinedMovies && refinedMovies.length > 0) {
          setMovieRecs(refinedMovies);
        }
      } catch {}

      try {
        const refinedSeries = await engine.refineRecommendationsWithAi('series', series);
        if (refinedSeries && refinedSeries.length > 0) {
          setSeriesRecs(refinedSeries);
        }
      } catch {}
    })();

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
    <div
      style={{
        width: "100%",
        height: "100%",
        padding: "24px 40px",
        "box-sizing": "border-box",
        overflow: "hidden",
        display: "flex",
        "flex-direction": "column"
      }}
    >
      {/* Header */}
      <div class="tv-live-header">
        <h1 class="tv-live-title">
          <span>Recommandé Pour Vous</span>
        </h1>
        <div class="tv-live-badge">
          <span>IA & Préférences locales</span>
        </div>
      </div>

      {/* Movies Shelf */}
      <div style={{ "margin-bottom": "36px" }}>
        <h2 style={{ "font-size": "24px", "font-weight": "800", "margin-bottom": "16px", color: "var(--buntu-gold)" }}>
          Films à découvrir
        </h2>
        <div
          class="tv-shelf"
          role="list"
          aria-label="Films à découvrir"
          style={{ display: "flex", "overflow-x": "auto", padding: "8px 0 20px 0" }}
        >
          <For each={movieRecs()}>
            {(movie) => {
              const title = movie.name_clean || movie.name;
              return (
                <div style={{ width: "220px", "margin-right": "18px", "flex-shrink": 0 }}>
                  <div
                    id={`reco-movie-${movie.id}`}
                    role="button"
                    tabindex="-1"
                    aria-label={`Film ${title}, ${movie.year || ''}`}
                    class={`tv-card tv-poster-card ${focusId() === `reco-movie-${movie.id}` ? 'focused' : ''}`}
                    onClick={() => props.onSelectItem(movie)}
                    style={{ height: "340px" }}
                  >
                    <div class="tv-poster-art" style={{ height: "250px" }}>
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
                    </div>
                    <div class="tv-poster-body">
                      <div class="tv-poster-title">{title}</div>
                      <Show when={(movie as any).aiReason}>
                        <div style={{ color: "var(--buntu-gold)", "font-size": "13px", "margin-top": "2px", "white-space": "nowrap", overflow: "hidden", "text-overflow": "ellipsis" }}>
                          ✨ {(movie as any).aiReason}
                        </div>
                      </Show>
                      <div class="tv-poster-sub">
                        <span>{movie.year || 'Film'}</span>
                        <Show when={movie.imdb_rating}>
                          <span style={{ color: "var(--buntu-gold)", "font-weight": "700" }}>
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
      </div>

      {/* Series Shelf */}
      <div style={{ "margin-bottom": "36px" }}>
        <h2 style={{ "font-size": "24px", "font-weight": "800", "margin-bottom": "16px", color: "var(--buntu-cyan)" }}>
          Séries recommandées
        </h2>
        <div
          class="tv-shelf"
          role="list"
          aria-label="Séries recommandées"
          style={{ display: "flex", "overflow-x": "auto", padding: "8px 0 20px 0" }}
        >
          <For each={seriesRecs()}>
            {(series) => {
              const title = series.name_clean || series.name;
              return (
                <div style={{ width: "220px", "margin-right": "18px", "flex-shrink": 0 }}>
                  <div
                    id={`reco-series-${series.id}`}
                    role="button"
                    tabindex="-1"
                    aria-label={`Série ${title}`}
                    class={`tv-card tv-poster-card ${focusId() === `reco-series-${series.id}` ? 'focused' : ''}`}
                    onClick={() => props.onSelectItem(series)}
                    style={{ height: "340px" }}
                  >
                    <div class="tv-poster-art" style={{ height: "250px" }}>
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
                    </div>
                    <div class="tv-poster-body">
                      <div class="tv-poster-title">{title}</div>
                      <Show when={(series as any).aiReason}>
                        <div style={{ color: "var(--buntu-gold)", "font-size": "13px", "margin-top": "2px", "white-space": "nowrap", overflow: "hidden", "text-overflow": "ellipsis" }}>
                          ✨ {(series as any).aiReason}
                        </div>
                      </Show>
                      <div class="tv-poster-sub">
                        <span>Série TV</span>
                        <span style={{ color: "var(--buntu-cyan)", "font-weight": "700" }}>
                          S{series.season_num || 1}
                        </span>
                      </div>
                    </div>
                  </div>
                </div>
              );
            }}
          </For>
        </div>
      </div>
    </div>
  );
};
