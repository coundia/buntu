import { Component, createSignal, onMount, onCleanup, For, Show } from 'solid-js';
import { CndEngine } from '../../core/engine/CndEngine';
import { ItemRecord } from '../../core/storage/Database';
import { AVPlayerService } from '../../core/player/AVPlayerService';
import { FocusableItem, spatialNav } from '../../ui/design/SpatialNav';
import { createInfiniteScroller } from '../../core/pagination/InfiniteScrollController';
import { TvSearchBar } from '../../ui/components/TvSearchBar';
import { cleanMediaTitle } from '../../core/utils/titleCleaner';
import { getCategoryMeta, formatViewCount } from '../../core/utils/categoryMeta';
import { announce } from '../../ui/design/a11y';

export interface MoviesViewProps {
  onSelectMovie: (movie: ItemRecord) => void;
  onPlayMovie?: (movie: ItemRecord) => void;
}

export const MoviesView: Component<MoviesViewProps> = (props) => {
  const engine = CndEngine.getInstance();
  const player = AVPlayerService.getInstance();
  const PAGE_SIZE = 24; // 3 columns x 8 rows

  const [categories, setCategories] = createSignal<string[]>([]);
  const [selectedCat, setSelectedCat] = createSignal<string>('');
  const [searchQuery, setSearchQuery] = createSignal<string>('');
  const [searchResults, setSearchResults] = createSignal<ItemRecord[]>([]);
  const [previewMovie, setPreviewMovie] = createSignal<ItemRecord | null>(null);
  const [isFav, setIsFav] = createSignal(false);
  const [focusId] = spatialNav.getFocusSignal();

  const isSearchMode = () => searchQuery().trim().length > 0;
  const activeMovies = () => (isSearchMode() ? searchResults() : scroller.items());

  const activePreviewMovie = (): ItemRecord | null => {
    return previewMovie() || (activeMovies().length > 0 ? activeMovies()[0] : null);
  };

  const previewTitle = () => {
    const m = activePreviewMovie();
    if (!m) return 'Films & VOD';
    return m.name_clean && m.name_clean !== m.name ? m.name_clean : cleanMediaTitle(m.name).clean;
  };

  const scroller = createInfiniteScroller<ItemRecord>({
    pageSize: PAGE_SIZE,
    threshold: 8,
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
        if (!previewMovie() && list.length > 0) {
          updatePreview(list[0]);
        }
        rebuildGrid(categories(), list, true);
      }
    },
  });

  onMount(async () => {
    // 1. Configure AVPlay display area for the mini player window
    player.setDisplayArea({ x: 918, y: 84, width: 880, height: 495 });
    document.querySelector('.app-root')?.classList.add('preview-mode');

    // 2. Load categories & initial movies
    const cats = await engine.getCategories('movie');
    setCategories(cats);
    if (cats.length > 0) {
      setSelectedCat(cats[0]);
      await scroller.reset();
      const items = scroller.items();
      if (items.length > 0) {
        updatePreview(items[0]);
      }
      rebuildGrid(cats, items, false);
      if (items.length > 0) {
        spatialNav.setFocusById(`movie-${items[0].id}`);
      } else {
        spatialNav.setFocusById('movie-cat-0');
      }
    } else {
      rebuildGrid([], [], false);
    }
  });

  onCleanup(() => {
    document.querySelector('.app-root')?.classList.remove('preview-mode');
  });

  const updatePreview = (movie: ItemRecord) => {
    setPreviewMovie(movie);
    setIsFav(movie.is_favorite === 1);
  };

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
    if (results.length > 0) {
      updatePreview(results[0]);
    }
    announce(`${results.length} résultats pour la recherche ${query}`);
    rebuildSearchGrid(results);
  };

  const handleClearSearch = () => {
    setSearchQuery('');
    setSearchResults([]);
    rebuildGrid(categories(), scroller.items(), false);
  };

  const handlePlayMovie = (movie: ItemRecord) => {
    if (props.onPlayMovie) {
      props.onPlayMovie(movie);
    } else {
      props.onSelectMovie(movie);
    }
  };

  const handleFullscreen = () => {
    const m = activePreviewMovie();
    if (m) handlePlayMovie(m);
  };

  const handleMovieSelect = (movie: ItemRecord) => {
    if (previewMovie()?.id === movie.id) {
      // Second click on the same movie opens playback
      handlePlayMovie(movie);
    } else {
      updatePreview(movie);
    }
  };

  const handleToggleFav = async () => {
    const current = activePreviewMovie();
    if (!current) return;
    const next = await engine.toggleFavorite(current.id);
    setIsFav(next);
    announce(next ? 'Film ajouté aux favoris' : 'Film retiré des favoris');
    if (selectedCat().includes('Favoris')) {
      await scroller.reset();
      const items = scroller.items();
      if (items.length > 0) {
        updatePreview(items[0]);
      } else {
        setPreviewMovie(null);
      }
      rebuildGrid(categories(), items, false);
    }
  };

  const rebuildSearchGrid = (results: ItemRecord[]) => {
    const grid: FocusableItem[][] = [];

    // Row 0: Search bar
    const searchRow: FocusableItem[] = [
      { id: 'movie-search-input', onSelect: () => focusInput('movie-search-input') },
    ];
    if (searchQuery().trim()) {
      searchRow.push({ id: 'movie-search-input-clear', onSelect: handleClearSearch });
    }
    grid.push(searchRow);

    // 3 Movie cards per row + side action buttons
    const COLS = 3;
    let movieRowIndex = 0;
    for (let i = 0; i < results.length; i += COLS) {
      const slice = results.slice(i, i + COLS);
      const row: FocusableItem[] = slice.map((m) => ({
        id: `movie-${m.id}`,
        onFocus: () => updatePreview(m),
        onSelect: () => handleMovieSelect(m),
      }));

      // Side action buttons for mini player
      if (movieRowIndex === 0) {
        row.push({ id: 'btn-movie-mini-fullscreen', onSelect: handleFullscreen });
      } else if (movieRowIndex === 1) {
        row.push({ id: 'btn-movie-mini-play', onSelect: handleFullscreen });
      } else if (movieRowIndex === 2) {
        row.push({
          id: 'btn-movie-mini-details',
          onSelect: () => activePreviewMovie() && props.onSelectMovie(activePreviewMovie()!),
        });
      } else if (movieRowIndex === 3) {
        row.push({ id: 'btn-movie-mini-fav', onSelect: () => void handleToggleFav() });
      }

      movieRowIndex++;
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

    const maxRows = Math.max(cats.length, list.length);

    for (let i = 0; i < maxRows; i++) {
      const row: FocusableItem[] = [];

      // Column 0: Categories (vertical list)
      if (cats.length > 0) {
        const catIdx = Math.min(i, cats.length - 1);
        const cat = cats[catIdx];
        row.push({
          id: `movie-cat-${catIdx}`,
          onSelect: () => void handleSelectCategory(cat),
        });
      }

      // Column 1: Movies list
      if (list.length > 0) {
        const movieIdx = Math.min(i, list.length - 1);
        const m = list[movieIdx];
        row.push({
          id: `movie-${m.id}`,
          onFocus: () => {
            void scroller.checkTrigger(movieIdx);
            updatePreview(m);
          },
          onSelect: () => handleMovieSelect(m),
        });
      }

      // Column 2: Side action buttons for hero player
      if (i === 0) {
        row.push({ id: 'btn-movie-mini-play', onSelect: handleFullscreen });
      } else if (i === 1) {
        row.push({ id: 'btn-movie-mini-fav', onSelect: () => void handleToggleFav() });
      } else if (i === 2) {
        row.push({
          id: 'btn-movie-mini-details',
          onSelect: () => activePreviewMovie() && props.onSelectMovie(activePreviewMovie()!),
        });
      } else if (i === 3) {
        row.push({ id: 'btn-movie-mini-fullscreen', onSelect: handleFullscreen });
      }

      grid.push(row);
    }

    spatialNav.setGrid(grid, list.length > 0 ? 1 : 0, cats.length > 0 ? 1 : 0, preserveFocus);
  };

  const handleSelectCategory = async (cat: string) => {
    if (cat === selectedCat()) return;
    setSelectedCat(cat);
    await scroller.reset();
    const items = scroller.items();
    if (items.length > 0) {
      updatePreview(items[0]);
    }
    rebuildGrid(categories(), items, false);
    if (items.length > 0) {
      spatialNav.setFocusById(`movie-${items[0].id}`);
    }
  };

  const handleContainerScroll = (e: Event) => {
    const el = e.currentTarget as HTMLElement;
    if (el.scrollTop + el.clientHeight >= el.scrollHeight - 400) {
      void scroller.loadMore();
    }
  };

  return (
    <div style={{ width: "100%", height: "100%", overflow: "hidden" }}>
      <div class="tv-minimal-3col">
        {/* Column 1: Categories Sidebar */}
        <div class="tv-min-col-categories" role="tablist" aria-label="Catégories de films">
          <h1 class="tv-min-col-title">
            <span>Films & VOD</span>
          </h1>

          <div style={{ "margin-bottom": "14px" }}>
            <TvSearchBar
              id="movie-search-input"
              placeholder="Rechercher un film..."
              value={searchQuery()}
              onInput={handleSearch}
              onClear={handleClearSearch}
              focusId={focusId()}
            />
          </div>

          <div class="tv-min-cat-list">
            <For each={categories()}>
              {(cat, idx) => {
                const meta = getCategoryMeta(cat);
                const isSelected = () => selectedCat() === cat;
                return (
                  <div
                    id={`movie-cat-${idx()}`}
                    role="tab"
                    tabindex="-1"
                    aria-selected={isSelected()}
                    aria-label={`Catégorie ${cat}`}
                    class={`tv-min-cat-item ${isSelected() ? 'active' : ''} ${focusId() === `movie-cat-${idx()}` ? 'focused' : ''}`}
                    onClick={() => void handleSelectCategory(cat)}
                  >
                    <div class="tv-min-cat-badge">{meta.icon}</div>
                    <div class="tv-min-cat-info">
                      <div class="tv-min-cat-name">{cat}</div>
                      <div class="tv-min-cat-count">
                        {isSelected() ? `${scroller.total()} Films` : 'Films'}
                      </div>
                    </div>
                  </div>
                );
              }}
            </For>
          </div>
        </div>

        {/* Column 2: Cards List with Infinite Scroll */}
        <div
          class="tv-min-col-cards"
          role="list"
          aria-label="Catalogue des films"
          onScroll={handleContainerScroll}
        >
          <div class="tv-min-cards-scroll">
            <Show
              when={activeMovies().length > 0}
              fallback={
                <div style={{ padding: "48px 20px", "text-align": "center", color: "var(--buntu-text-muted)", "font-size": "18px" }}>
                  {isSearchMode()
                    ? `Aucun film ne correspond à "${searchQuery()}".`
                    : selectedCat().includes('Favoris')
                    ? 'Aucun film dans vos favoris. Appuyez sur ☆ Favori pour ajouter vos films préférés !'
                    : 'Aucun film dans cette catégorie.'}
                </div>
              }
            >
              <For each={activeMovies()}>
                {(movie) => {
                  const title = movie.name_clean && movie.name_clean !== movie.name
                    ? movie.name_clean
                    : cleanMediaTitle(movie.name).clean;
                  const is4k = title.toLowerCase().includes('4k') || title.toLowerCase().includes('uhd');
                  const isSelected = () => activePreviewMovie()?.id === movie.id;
                  return (
                    <div
                      id={`movie-${movie.id}`}
                      role="button"
                      tabindex="-1"
                      aria-label={`Film ${title}`}
                      class={`tv-min-media-card ${focusId() === `movie-${movie.id}` ? 'focused' : ''} ${isSelected() ? 'active' : ''}`}
                      onClick={() => handleMovieSelect(movie)}
                    >
                      <div class="tv-min-card-thumb">
                        <Show
                          when={movie.logo_url}
                          fallback={<span style={{ "font-size": "32px" }}>🎬</span>}
                        >
                          <img
                            src={movie.logo_url}
                            alt=""
                            loading="lazy"
                            referrerpolicy="no-referrer"
                            crossOrigin="anonymous"
                            onError={(e) => {
                              const target = e.currentTarget as HTMLElement;
                              target.style.display = 'none';
                              if (target.parentElement) {
                                target.parentElement.innerHTML = '<span style="font-size:32px;">🎬</span>';
                              }
                            }}
                          />
                        </Show>
                      </div>

                      <div class="tv-min-card-meta">
                        <div class="tv-min-card-title">{title}</div>
                        <div class="tv-min-card-views">
                          {movie.year ? `${movie.year} • ${formatViewCount(movie.id)}` : formatViewCount(movie.id)}
                        </div>
                        <div class="tv-min-card-tags">
                          <span class="tv-min-tag">{is4k ? '4K' : 'HD'}</span>
                          <span class="tv-min-tag">VOD</span>
                          <Show when={movie.imdb_rating}>
                            <span class="tv-min-tag">★ {movie.imdb_rating!.toFixed(1)}</span>
                          </Show>
                        </div>
                      </div>

                      <Show when={movie.is_favorite === 1}>
                        <div class="tv-min-card-fav">★</div>
                      </Show>
                    </div>
                  );
                }}
              </For>
            </Show>

            {/* Infinite Scroll Loader */}
            <Show when={scroller.isLoading()}>
              <div style={{ "text-align": "center", padding: "16px", color: "var(--buntu-text-muted)" }}>
                Chargement des films...
              </div>
            </Show>
          </div>
        </div>

        {/* Column 3: Hero Panel (16:9 Viewport + Details + Synopsis + Timeline + Actions) */}
        <div class="tv-min-col-hero" role="region" aria-label="Aperçu du film">
          <div id="tv-mini-viewport" class="tv-min-hero-viewport">
            <Show
              when={!(window as any).webapis?.avplay}
              fallback={
                <div class="tv-mini-tv-overlay">
                  <div class="tv-mini-live-tag" style={{ background: "rgba(0, 229, 255, 0.85)" }}>
                    <span>CINÉMA VOD</span>
                  </div>
                  <div class="tv-mini-hd-badge">4K ULTRA HD</div>
                </div>
              }
            >
              <div class="tv-mini-mock-screen">
                <div class="tv-mini-live-tag" style={{ background: "rgba(0, 229, 255, 0.85)" }}>
                  <span>CINÉMA VOD</span>
                </div>
                <div class="tv-mini-hd-badge">4K ULTRA HD</div>

                <div class="tv-mini-mock-art">
                  <Show
                    when={activePreviewMovie()?.logo_url}
                    fallback={<span style={{ "font-size": "48px" }}>🎬</span>}
                  >
                    <img
                      src={activePreviewMovie()!.logo_url}
                      alt=""
                      referrerpolicy="no-referrer"
                      crossOrigin="anonymous"
                      style={{ "max-width": "80px", "max-height": "80px", "object-fit": "contain" }}
                    />
                  </Show>
                </div>

                <div class="tv-mini-mock-title">{previewTitle()}</div>
              </div>
            </Show>
          </div>

          {/* Now Playing Metadata Section */}
          <div class="tv-min-hero-info">
            <div class="tv-min-now-label">SÉLECTION EN COURS...</div>
            <h2 class="tv-min-hero-title">{previewTitle()}</h2>
            <p class="tv-min-hero-desc">
              {activePreviewMovie()?.plot || (activePreviewMovie()?.group_title ? `Film disponible dans le catalogue ${activePreviewMovie()!.group_title}. Audio multicanal 5.1 et vidéo 1080p/4K.` : 'Film à la demande disponible en haute définition.')}
            </p>

            {/* Progress Bar Timeline */}
            <div class="tv-min-hero-progress">
              <span class="tv-min-time">00:00:00</span>
              <div class="tv-min-track">
                <div class="tv-min-fill" style={{ width: "35%" }}>
                  <div class="tv-min-knob" />
                </div>
              </div>
              <span class="tv-min-time">02:15:00</span>
            </div>

            {/* Hero Action Buttons */}
            <div class="tv-min-hero-actions">
              <button
                id="btn-movie-mini-play"
                role="button"
                tabindex="-1"
                aria-label={`Lancer la lecture de ${previewTitle()}`}
                class={`tv-min-btn-play ${focusId() === 'btn-movie-mini-play' ? 'focused' : ''}`}
                onClick={handleFullscreen}
              >
                ▶ Lancer le film
              </button>

              <button
                id="btn-movie-mini-fav"
                role="button"
                tabindex="-1"
                aria-label="Basculer favori"
                class={`tv-min-btn-secondary ${focusId() === 'btn-movie-mini-fav' ? 'focused' : ''}`}
                onClick={() => void handleToggleFav()}
              >
                {isFav() ? '★ Retirer Favori' : '☆ Favori'}
              </button>

              <button
                id="btn-movie-mini-details"
                role="button"
                tabindex="-1"
                aria-label="Fiche détaillée"
                class={`tv-min-btn-secondary ${focusId() === 'btn-movie-mini-details' ? 'focused' : ''}`}
                onClick={() => activePreviewMovie() && props.onSelectMovie(activePreviewMovie()!)}
              >
                ℹ Détails
              </button>

              <button
                id="btn-movie-mini-fullscreen"
                role="button"
                tabindex="-1"
                aria-label="Plein écran"
                class={`tv-min-btn-secondary ${focusId() === 'btn-movie-mini-fullscreen' ? 'focused' : ''}`}
                onClick={handleFullscreen}
              >
                ⛶ Plein écran
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
};
