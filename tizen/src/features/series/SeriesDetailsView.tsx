import { Component, createSignal, onMount, For, Show } from 'solid-js';
import { CndEngine, EpisodeItem, SeasonInfo, SeriesDetails } from '../../core/engine/CndEngine';
import { ItemRecord } from '../../core/storage/Database';
import { FocusableItem, spatialNav } from '../../ui/design/SpatialNav';
import { cleanMediaTitle } from '../../core/utils/titleCleaner';
import { announce } from '../../ui/design/a11y';

export interface SeriesDetailsViewProps {
  item: ItemRecord;
  onPlay: (item: ItemRecord) => void;
  onBack: () => void;
}

export const SeriesDetailsView: Component<SeriesDetailsViewProps> = (props) => {
  const engine = CndEngine.getInstance();
  const [loading, setLoading] = createSignal(true);
  const [details, setDetails] = createSignal<SeriesDetails | null>(null);
  const [selectedSeasonNum, setSelectedSeasonNum] = createSignal<number>(1);
  const [isFav, setIsFav] = createSignal(props.item.is_favorite === 1);
  const [focusId] = spatialNav.getFocusSignal();

  const title = () => {
    const raw = details()?.info.title || props.item.name_clean || props.item.name;
    return cleanMediaTitle(raw).clean;
  };

  const currentSeason = (): SeasonInfo | undefined => {
    const d = details();
    if (!d || d.seasons.length === 0) return undefined;
    return d.seasons.find((s) => s.season_num === selectedSeasonNum()) || d.seasons[0];
  };

  const totalEpisodesCount = () => {
    const d = details();
    if (!d) return 0;
    return d.seasons.reduce((acc, s) => acc + s.episodes.length, 0);
  };

  const rebuildGrid = (d: SeriesDetails, activeSeasonNum: number, preserveFocus = false) => {
    const grid: FocusableItem[][] = [];

    // Row 0: Action buttons
    const actionsRow: FocusableItem[] = [
      {
        id: 'btn-series-play-first',
        onSelect: () => handlePlayFirst(),
      },
      {
        id: 'btn-series-fav',
        onSelect: async () => {
          const next = await engine.toggleFavorite(props.item.id);
          setIsFav(next);
        },
      },
      {
        id: 'btn-series-back',
        onSelect: () => props.onBack(),
      },
    ];
    grid.push(actionsRow);

    // Row 1: Season tabs (horizontal pills)
    if (d.seasons.length > 0) {
      const seasonRow = d.seasons.map((s) => ({
        id: `season-tab-${s.season_num}`,
        onSelect: () => handleSelectSeason(s.season_num),
      }));
      grid.push(seasonRow);
    }

    // Rows 2+: Episodes list of the active season
    const activeSeason = d.seasons.find((s) => s.season_num === activeSeasonNum) || d.seasons[0];
    if (activeSeason) {
      for (const ep of activeSeason.episodes) {
        grid.push([
          {
            id: `episode-${ep.id}`,
            onSelect: () => handlePlayEpisode(ep),
          },
        ]);
      }
    }

    spatialNav.setGrid(grid, 0, 0, preserveFocus);
  };

  onMount(async () => {
    try {
      setLoading(true);
      const res = await engine.getSeriesDetails(props.item);
      setDetails(res);
      const initialSeason = res.seasons.length > 0 ? res.seasons[0].season_num : 1;
      setSelectedSeasonNum(initialSeason);
      rebuildGrid(res, initialSeason, false);
      announce(`Série ${title()}, ${res.seasons.length} saisons disponibles.`);
    } catch (err) {
      console.error('[SeriesDetailsView] Error fetching series details:', err);
    } finally {
      setLoading(false);
    }
  });

  const handleSelectSeason = (seasonNum: number) => {
    if (seasonNum === selectedSeasonNum()) return;
    setSelectedSeasonNum(seasonNum);
    const d = details();
    if (d) {
      rebuildGrid(d, seasonNum, false);
      const season = d.seasons.find((s) => s.season_num === seasonNum);
      if (season && season.episodes.length > 0) {
        spatialNav.setFocusById(`episode-${season.episodes[0].id}`);
        announce(`${season.name}, ${season.episodes.length} épisodes.`);
      }
    }
  };

  const handlePlayEpisode = (ep: EpisodeItem) => {
    const sNum = currentSeason()?.season_num || ep.season_num || 1;
    const epItem: ItemRecord = {
      ...props.item,
      id: Number(ep.id) || props.item.id,
      name: `${title()} - S${sNum}E${ep.episode_num} ${ep.title}`,
      name_clean: `${title()} - S${sNum}E${ep.episode_num} ${ep.title}`,
      stream_url: ep.stream_url,
      container_ext: ep.container_ext,
      season_num: sNum,
      episode_num: ep.episode_num,
      plot: ep.plot || props.item.plot,
      logo_url: ep.cover || props.item.logo_url,
    };
    props.onPlay(epItem);
  };

  const handlePlayFirst = () => {
    const season = currentSeason();
    if (season && season.episodes.length > 0) {
      handlePlayEpisode(season.episodes[0]);
    } else {
      props.onPlay(props.item);
    }
  };

  return (
    <div class="tv-series-container" role="region" aria-label={`Détails de la série ${title()}`}>
      {/* Top Header Card */}
      <div class="tv-series-header-card">
        {/* Left: Series Cover Poster */}
        <div class="tv-series-poster-box">
          <Show
            when={details()?.info.cover || props.item.logo_url}
            fallback={
              <div class="tv-poster-fallback" style={{ height: "100%", "justify-content": "center" }}>
                <span style={{ "font-size": "56px", opacity: "0.6" }}>📺</span>
                <span class="tv-poster-fallback-title">{title()}</span>
              </div>
            }
          >
            <img
              src={details()?.info.cover || props.item.logo_url}
              alt=""
              referrerpolicy="no-referrer"
              crossOrigin="anonymous"
              onError={(e) => {
                const target = e.currentTarget as HTMLElement;
                target.style.display = 'none';
                const parent = target.parentElement;
                if (parent && !parent.querySelector('.tv-poster-fallback')) {
                  const fb = document.createElement('div');
                  fb.className = 'tv-poster-fallback';
                  fb.style.height = '100%';
                  fb.style.justifyContent = 'center';
                  fb.innerHTML = `<span style="font-size: 56px; opacity: 0.6">📺</span><span class="tv-poster-fallback-title">${title()}</span>`;
                  parent.appendChild(fb);
                }
              }}
            />
          </Show>
        </div>

        {/* Right: Series Meta, Synopsis & Action Toolbar */}
        <div class="tv-series-info-box">
          <h1 class="tv-series-title">{title()}</h1>

          <div class="tv-details-meta-bar">
            <Show when={details()?.info.rating || props.item.imdb_rating}>
              <span class="tv-details-badge" style={{ color: "var(--buntu-gold)" }}>
                ★ {(details()?.info.rating || props.item.imdb_rating)!.toFixed(1)} / 10
              </span>
            </Show>

            <span class="tv-details-badge" style={{ color: "var(--buntu-text-muted)" }}>
              {details()?.info.year || props.item.year || '2024'}
            </span>

            <span class="tv-details-badge" style={{ color: "var(--buntu-cyan)" }}>
              {details()?.info.genre || props.item.group_title || 'Série TV'}
            </span>

            <Show when={details()?.seasons.length}>
              <span class="tv-details-pill">
                {details()!.seasons.length} {details()!.seasons.length > 1 ? 'Saisons' : 'Saison'}
              </span>
            </Show>

            <Show when={totalEpisodesCount() > 0}>
              <span class="tv-details-pill">
                {totalEpisodesCount()} Épisodes
              </span>
            </Show>
          </div>

          <p class="tv-series-synopsis">
            {details()?.info.plot || props.item.plot || "Aucun synopsis disponible pour cette série. Choisissez un épisode ci-dessous pour lancer la lecture avec décodage matériel AVPlay."}
          </p>

          {/* Action Toolbar */}
          <div class="tv-details-actions" role="toolbar" aria-label="Actions de la série">
            <button
              id="btn-series-play-first"
              role="button"
              tabindex="-1"
              aria-label={`Lancer le premier épisode de ${title()}`}
              class={`tv-btn ${focusId() === 'btn-series-play-first' ? 'focused' : ''}`}
              onClick={handlePlayFirst}
            >
              ▶ {currentSeason() ? `Regarder S${currentSeason()!.season_num}:E1` : 'Lancer la lecture'}
            </button>

            <button
              id="btn-series-fav"
              role="button"
              tabindex="-1"
              aria-label={isFav() ? 'Retirer cette série des favoris' : 'Ajouter cette série aux favoris'}
              class={`tv-btn ${focusId() === 'btn-series-fav' ? 'focused' : ''}`}
              onClick={async () => {
                const next = await engine.toggleFavorite(props.item.id);
                setIsFav(next);
              }}
            >
              {isFav() ? '★ Retirer des favoris' : '☆ Favoris'}
            </button>

            <button
              id="btn-series-back"
              role="button"
              tabindex="-1"
              aria-label="Retourner au catalogue des séries"
              class={`tv-btn ${focusId() === 'btn-series-back' ? 'focused' : ''}`}
              onClick={() => props.onBack()}
            >
              ← Retour aux Séries
            </button>
          </div>
        </div>
      </div>

      {/* Season Selection Pills Bar */}
      <Show when={details() && details()!.seasons.length > 0}>
        <div class="tv-series-seasons-bar" role="tablist" aria-label="Saisons disponibles">
          <For each={details()!.seasons}>
            {(season) => {
              const isActive = () => selectedSeasonNum() === season.season_num;
              const isFocused = () => focusId() === `season-tab-${season.season_num}`;
              return (
                <button
                  id={`season-tab-${season.season_num}`}
                  role="tab"
                  tabindex="-1"
                  aria-selected={isActive()}
                  aria-label={`${season.name}, ${season.episodes.length} épisodes`}
                  class={`tv-season-pill ${isActive() ? 'active' : ''} ${isFocused() ? 'focused' : ''}`}
                  onClick={() => handleSelectSeason(season.season_num)}
                >
                  <span>{season.name}</span>
                  <span class="tv-season-count">({season.episodes.length})</span>
                </button>
              );
            }}
          </For>
        </div>
      </Show>

      {/* Episodes List */}
      <div
        class="tv-episodes-container"
        role="list"
        aria-label={`Épisodes de la ${currentSeason()?.name || 'Saison'}`}
      >
        <Show
          when={!loading()}
          fallback={
            <div class="tv-infinite-loader" style={{ padding: "40px 0" }}>
              <span class="tv-spinner-small" />
              <span>Chargement des saisons et épisodes...</span>
            </div>
          }
        >
          <Show
            when={currentSeason() && currentSeason()!.episodes.length > 0}
            fallback={
              <div style={{ padding: "40px", "text-align": "center", color: "var(--buntu-text-muted)", "font-size": "20px" }}>
                Aucun épisode disponible pour cette saison.
              </div>
            }
          >
            <For each={currentSeason()!.episodes}>
              {(ep) => {
                const isFocused = () => focusId() === `episode-${ep.id}`;
                return (
                  <div
                    id={`episode-${ep.id}`}
                    role="button"
                    tabindex="-1"
                    aria-label={`Épisode numéro ${ep.episode_num} : ${ep.title}. ${ep.duration || ''}. ${ep.plot || ''}. Appuyez pour regarder.`}
                    class={`tv-episode-row ${isFocused() ? 'focused' : ''}`}
                    onClick={() => handlePlayEpisode(ep)}
                  >
                    {/* Episode Number Badge */}
                    <div class="tv-episode-num">
                      E{ep.episode_num < 10 ? `0${ep.episode_num}` : ep.episode_num}
                    </div>

                    {/* Episode Thumbnail or Fallback */}
                    <div class="tv-episode-thumb">
                      <Show
                        when={ep.cover}
                        fallback={<span style={{ "font-size": "24px", opacity: "0.6" }}>🎬</span>}
                      >
                        <img
                          src={ep.cover}
                          alt=""
                          loading="lazy"
                          referrerpolicy="no-referrer"
                          crossOrigin="anonymous"
                          onError={(e) => {
                            const target = e.currentTarget as HTMLElement;
                            target.style.display = 'none';
                            if (target.parentElement) {
                              const fb = document.createElement('span');
                              fb.style.fontSize = '24px';
                              fb.style.opacity = '0.6';
                              fb.textContent = '🎬';
                              target.parentElement.appendChild(fb);
                            }
                          }}
                        />
                      </Show>
                    </div>

                    {/* Episode Info: Title, Duration & Synopsis */}
                    <div class="tv-episode-info">
                      <div class="tv-episode-title-row">
                        <span class="tv-episode-title">{ep.title}</span>
                        <Show when={ep.duration}>
                          <span class="tv-episode-duration">{ep.duration}</span>
                        </Show>
                      </div>
                      <div class="tv-episode-plot">
                        {ep.plot || `Épisode ${ep.episode_num} de la saison ${currentSeason()?.season_num || 1}.`}
                      </div>
                    </div>

                    {/* Action Pill on Focus */}
                    <div class="tv-episode-actions">
                      <Show when={isFocused()}>
                        <div class="tv-watch-pill">
                          <span>▶</span>
                          <span>REGARDER</span>
                        </div>
                      </Show>
                    </div>
                  </div>
                );
              }}
            </For>
          </Show>
        </Show>
      </div>
    </div>
  );
};
