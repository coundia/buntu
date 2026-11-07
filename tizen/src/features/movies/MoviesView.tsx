import { Component, createSignal, onMount, onCleanup, For, Show } from 'solid-js';
import { CndEngine } from '../../core/engine/CndEngine';
import { ItemRecord } from '../../core/storage/Database';
import { AVPlayerService } from '../../core/player/AVPlayerService';
import { FocusableItem, spatialNav } from '../../ui/design/SpatialNav';
import { createInfiniteScroller } from '../../core/pagination/InfiniteScrollController';
import { TvSearchBar } from '../../ui/components/TvSearchBar';
import { cleanMediaTitle } from '../../core/utils/titleCleaner';
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
    player.setDisplayArea({ x: 1084, y: 192, width: 756, height: 425 });
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

    // Rows 2+: 3 Movie cards per row + side action buttons
    const COLS = 3;
    let movieRowIndex = 0;
    for (let i = 0; i < list.length; i += COLS) {
      const slice = list.slice(i, i + COLS);
      const row: FocusableItem[] = slice.map((m, colIdx) => ({
        id: `movie-${m.id}`,
        onFocus: () => {
          void scroller.checkTrigger(i + colIdx);
          updatePreview(m);
        },
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

    spatialNav.setGrid(grid, list.length > 0 && visibleCats.length > 0 ? 2 : 1, 0, preserveFocus);
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
    <div class="tv-container">
      {/* Header with Title, In-Screen Search Bar & Horizontal Category Tabs */}
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

        {/* Category tabs */}
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

      {/* Split View: Left 3-Column Catalog + Right Mini Player Preview */}
      <div class="tv-movie-split-layout">
        {/* Left: Scrollable 3-Column Movie Grid */}
        <div
          class="tv-movie-catalog-col"
          role="list"
          aria-label="Catalogue des films"
          onScroll={handleContainerScroll}
        >
          <Show
            when={activeMovies().length > 0}
            fallback={
              <div style={{ width: "100%", padding: "48px 20px", "text-align": "center", color: "var(--buntu-text-muted)", "font-size": "20px" }}>
                {isSearchMode()
                  ? `Aucun film ne correspond à "${searchQuery()}".`
                  : selectedCat().includes('Favoris')
                  ? 'Aucun film dans vos favoris. Appuyez sur ☆ Favori pour ajouter vos films préférés !'
                  : 'Aucun film dans cette catégorie.'}
              </div>
            }
          >
            <div class="tv-movie-3col-grid">
              <For each={activeMovies()}>
                {(movie) => {
                  const title = movie.name_clean && movie.name_clean !== movie.name
                    ? movie.name_clean
                    : cleanMediaTitle(movie.name).clean;
                  const is4k = title.toLowerCase().includes('4k') || title.toLowerCase().includes('uhd');
                  const isSelected = () => activePreviewMovie()?.id === movie.id;
                  return (
                    <div class="tv-movie-3col-cell">
                      <div
                        id={`movie-${movie.id}`}
                        role="button"
                        tabindex="-1"
                        aria-label={`Film ${title}, ${movie.year || ''}, note ${movie.imdb_rating ? movie.imdb_rating.toFixed(1) + ' sur 10' : 'non noté'}`}
                        class={`tv-card tv-poster-card ${focusId() === `movie-${movie.id}` ? 'focused' : ''} ${isSelected() ? 'active' : ''}`}
                        onClick={() => handleMovieSelect(movie)}
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
                              referrerpolicy="no-referrer"
                              crossOrigin="anonymous"
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
                            <span>{movie.year || '2024'}</span>
                            <Show when={movie.imdb_rating}>
                              <span class="tv-poster-rating">★ {movie.imdb_rating!.toFixed(1)}</span>
                            </Show>
                          </div>
                        </div>
                      </div>
                    </div>
                  );
                }}
              </For>
            </div>
          </Show>

          {/* Infinite Scroll Loader & End Status */}
          <Show when={scroller.isLoading()}>
            <div class="tv-infinite-loader">
              <span class="tv-spinner-small" />
              <span>Chargement des films suivants...</span>
            </div>
          </Show>

          <Show when={!scroller.hasMore() && scroller.items().length > 0}>
            <div class="tv-infinite-end">
              • Fin du catalogue ({scroller.total()} films) •
            </div>
          </Show>
        </div>

        {/* Right: Movie Mini Player Preview Panel */}
        <div class="tv-movie-preview-col" role="region" aria-label="Aperçu et mini lecteur du film">
          <div class="tv-mini-player-card">
            {/* 16:9 Video Viewport */}
            <div id="tv-mini-movie-viewport" class="tv-live-preview-viewport">
              {/* Real TV hardware AVPlay cutout / Web Mock */}
              <Show
                when={!(window as any).webapis?.avplay}
                fallback={
                  <div class="tv-mini-tv-overlay">
                    <div class="tv-mini-live-tag" style={{ background: "rgba(245, 166, 35, 0.9)" }}>
                      <span>🎬 CINÉMA</span>
                    </div>
                    <div class="tv-mini-hd-badge">4K UHD</div>
                  </div>
                }
              >
                {/* Browser / Mock Preview Mode */}
                <div class="tv-mini-mock-screen">
                  <div class="tv-mini-live-tag" style={{ background: "rgba(245, 166, 35, 0.9)" }}>
                    <span>🎬 CINÉMA</span>
                  </div>
                  <div class="tv-mini-hd-badge">4K UHD</div>

                  {/* Centered Movie Poster / Art */}
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

                  <div class="tv-mini-mock-title">
                    {previewTitle()}
                  </div>
                </div>
              </Show>

              {/* Quick Play / Fullscreen overlay button */}
              <button
                id="btn-movie-mini-fullscreen"
                role="button"
                tabindex="-1"
                aria-label={`Lancer la lecture de ${previewTitle()} en plein écran`}
                class={`tv-mini-fs-btn ${focusId() === 'btn-movie-mini-fullscreen' ? 'focused' : ''}`}
                onClick={handleFullscreen}
              >
                <span>⛶</span>
                <span>Plein écran (OK)</span>
              </button>
            </div>

            {/* Movie Info Row */}
            <div class="tv-mini-channel-row">
              <div class="tv-mini-logo-box">
                <Show
                  when={activePreviewMovie()?.logo_url}
                  fallback={<span style={{ "font-size": "24px" }}>🎬</span>}
                >
                  <img
                    src={activePreviewMovie()!.logo_url}
                    alt=""
                    referrerpolicy="no-referrer"
                    crossOrigin="anonymous"
                  />
                </Show>
              </div>
              <div class="tv-mini-name-col">
                <div class="tv-mini-channel-name">{previewTitle()}</div>
                <div class="tv-mini-channel-cat">
                  {activePreviewMovie()?.group_title || selectedCat() || 'Films & VOD'}
                </div>
              </div>
              <Show when={activePreviewMovie()?.year}>
                <div class="tv-details-badge" style={{ "margin-left": "auto", color: "var(--buntu-gold)" }}>
                  {activePreviewMovie()!.year}
                </div>
              </Show>
            </div>

            {/* Meta badges: Rating, Year, Format */}
            <div class="tv-details-meta-bar" style={{ margin: "0" }}>
              <Show when={activePreviewMovie()?.imdb_rating}>
                <span class="tv-details-badge" style={{ color: "var(--buntu-gold)" }}>
                  ★ {activePreviewMovie()!.imdb_rating!.toFixed(1)} / 10
                </span>
              </Show>

              <span class="tv-details-pill">
                {activePreviewMovie()?.container_ext?.toUpperCase() || 'MKV'}
              </span>

              <span class="tv-details-pill" style={{ color: "var(--buntu-cyan)" }}>
                {activePreviewMovie()?.name.toLowerCase().includes('4k') ? '4K ULTRA HD' : '1080p FHD'}
              </span>
            </div>

            {/* Synopsis Box */}
            <div class="tv-movie-synopsis-box">
              {activePreviewMovie()?.plot ||
                "Aucun synopsis détaillé fourni par le serveur IPTV pour ce film. Appuyez sur 'Lancer la lecture' pour démarrer immédiatement avec décodage matériel AVPlay."}
            </div>

            {/* Action Bar */}
            <div class="tv-mini-actions-row">
              <button
                id="btn-movie-mini-play"
                role="button"
                tabindex="-1"
                aria-label={`Lancer la lecture de ${previewTitle()}`}
                class={`tv-btn tv-mini-action-btn ${focusId() === 'btn-movie-mini-play' ? 'focused' : ''}`}
                onClick={handleFullscreen}
              >
                ▶ Lancer
              </button>

              <button
                id="btn-movie-mini-details"
                role="button"
                tabindex="-1"
                aria-label="Voir la fiche détaillée du film"
                class={`tv-btn tv-mini-action-btn ${focusId() === 'btn-movie-mini-details' ? 'focused' : ''}`}
                onClick={() => activePreviewMovie() && props.onSelectMovie(activePreviewMovie()!)}
              >
                ℹ Détails
              </button>

              <button
                id="btn-movie-mini-fav"
                role="button"
                tabindex="-1"
                aria-label="Basculer film favori"
                class={`tv-btn tv-mini-action-btn ${focusId() === 'btn-movie-mini-fav' ? 'focused' : ''}`}
                onClick={() => void handleToggleFav()}
              >
                {isFav() ? '★ Favori' : '☆ Favori'}
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
};
