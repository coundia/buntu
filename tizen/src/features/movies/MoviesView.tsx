import { Component, createSignal, createMemo, onMount, onCleanup, For, Show } from 'solid-js';
import { CndEngine } from '../../core/engine/CndEngine';
import { ItemRecord, FAVORITES_CATEGORY } from '../../core/storage/Database';
import { AVPlayerService } from '../../core/player/AVPlayerService';
import { FocusableItem, spatialNav } from '../../ui/design/SpatialNav';
import { createInfiniteScroller } from '../../core/pagination/InfiniteScrollController';
import { cleanMediaTitle } from '../../core/utils/titleCleaner';
import { detectChannelQuality, formatBuntuCount } from '../../core/utils/categoryMeta';
import { announce } from '../../ui/design/a11y';

export interface MoviesViewProps {
  onSelectMovie: (movie: ItemRecord) => void;
  onPlayMovie?: (movie: ItemRecord) => void;
}

export const MoviesView: Component<MoviesViewProps> = (props) => {
  const engine = CndEngine.getInstance();
  const player = AVPlayerService.getInstance();
  const PAGE_SIZE = 48;

  const [categories, setCategories] = createSignal<string[]>([]);
  const [catCounts, setCatCounts] = createSignal<Record<string, number>>({});
  const [totalCount, setTotalCount] = createSignal(0);
  const [favCount, setFavCount] = createSignal(0);

  const [selectedCat, setSelectedCat] = createSignal<string>('');
  const [catFilter, setCatFilter] = createSignal<string>('');
  const [showCats, setShowCats] = createSignal(true);
  const [viewMode, setViewMode] = createSignal<'grid' | 'list'>('grid');
  const [showInspector, setShowInspector] = createSignal(false);

  const [searchQuery, setSearchQuery] = createSignal<string>('');
  const [searchResults, setSearchResults] = createSignal<ItemRecord[]>([]);

  const [recentMovies, setRecentMovies] = createSignal<ItemRecord[]>([]);
  const [favMovies, setFavMovies] = createSignal<ItemRecord[]>([]);
  const [previewMovie, setPreviewMovie] = createSignal<ItemRecord | null>(null);
  const [focusId] = spatialNav.getFocusSignal();

  let gridRef: HTMLDivElement | undefined;
  let viewportRef: HTMLDivElement | undefined;
  let resizeHandler: (() => void) | null = null;

  const isSearchMode = () => searchQuery().trim().length > 0;
  const activeMovies = () => (isSearchMode() ? searchResults() : scroller.items());
  const showsShelves = () => !isSearchMode() && selectedCat() === '';

  const filteredCategories = createMemo(() => {
    const raw = categories().filter((c) => c !== FAVORITES_CATEGORY && c !== 'Favoris');
    const q = catFilter().trim().toLowerCase();
    if (!q) return raw;
    return raw.filter((c) => c.toLowerCase().includes(q));
  });

  const scroller = createInfiniteScroller<ItemRecord>({
    pageSize: PAGE_SIZE,
    threshold: 12,
    maxItems: 360,
    fetchBatch: async (offset, limit) => {
      const cat = selectedCat() || undefined;
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
          setPreviewMovie(list[0]);
        }
        scheduleRebuildGrid(true);
      }
    },
  });

  const syncAvPlayRect = () => {
    if (!showInspector() || !viewportRef) return;
    const rect = viewportRef.getBoundingClientRect();
    if (rect.width > 10 && rect.height > 10) {
      player.setDisplayArea({
        x: Math.round(rect.left),
        y: Math.round(rect.top),
        width: Math.round(rect.width),
        height: Math.round(rect.height),
      });
    }
  };

  const refreshShelvesAndCounts = async () => {
    const [countsData, recents, favs] = await Promise.all([
      engine.getCategoryCounts('movie'),
      engine.getRecentItems('movie', 10),
      engine.getFavoritesByKind('movie', 12),
    ]);
    setTotalCount(countsData.total);
    setFavCount(countsData.favCount);
    setCatCounts(countsData.counts);
    setRecentMovies(recents);
    setFavMovies(favs);
  };

  onMount(async () => {
    resizeHandler = () => {
      syncAvPlayRect();
      scheduleRebuildGrid(true);
    };
    window.addEventListener('resize', resizeHandler);

    const cats = await engine.getCategories('movie');
    setCategories(cats);
    await refreshShelvesAndCounts();

    await scroller.reset();
    const items = scroller.items();
    if (items.length > 0) {
      setPreviewMovie(items[0]);
    }
    scheduleRebuildGrid(false);
    if (items.length > 0) {
      const firstId = recentMovies().length > 0
        ? `recent-mv-${recentMovies()[0].id}`
        : favMovies().length > 0
          ? `fav-mv-${favMovies()[0].id}`
          : `movie-${items[0].id}`;
      spatialNav.setFocusById(firstId);
    } else if (cats.length > 0) {
      spatialNav.setFocusById('movie-cat-all');
    }
  });

  onCleanup(() => {
    if (resizeHandler) window.removeEventListener('resize', resizeHandler);
    document.querySelector('.app-root')?.classList.remove('preview-mode');
  });

  const toggleInspector = () => {
    const next = !showInspector();
    setShowInspector(next);
    if (next) {
      document.querySelector('.app-root')?.classList.add('preview-mode');
      requestAnimationFrame(() => syncAvPlayRect());
    } else {
      document.querySelector('.app-root')?.classList.remove('preview-mode');
      engine.stopPlayback();
    }
    scheduleRebuildGrid(true);
  };

  const handleSelectCategory = async (cat: string) => {
    if (cat === selectedCat() && !isSearchMode()) return;
    setSelectedCat(cat);
    if (isSearchMode()) {
      setSearchQuery('');
      setSearchResults([]);
    }
    await scroller.reset();
    const items = scroller.items();
    if (items.length > 0) {
      setPreviewMovie(items[0]);
    }
    scheduleRebuildGrid(false);
    if (items.length > 0) {
      spatialNav.setFocusById(`movie-${items[0].id}`);
    }
  };

  const handleCardActivate = (mv: ItemRecord) => {
    engine.recordRecent(mv);
    setPreviewMovie(mv);
    props.onSelectMovie(mv);
  };

  const handlePlayDirect = (mv: ItemRecord) => {
    engine.recordRecent(mv);
    if (props.onPlayMovie) {
      props.onPlayMovie(mv);
    } else {
      props.onSelectMovie(mv);
    }
  };

  const handleToggleFavorite = async (mv: ItemRecord, e?: MouseEvent) => {
    e?.stopPropagation();
    const next = await engine.toggleFavorite(mv.id);
    mv.is_favorite = next ? 1 : 0;
    announce(next ? 'Film ajouté aux favoris' : 'Film retiré des favoris');
    await refreshShelvesAndCounts();
    if (selectedCat() === FAVORITES_CATEGORY) {
      await scroller.reset();
    } else {
      setSearchResults((prev) => [...prev]);
    }
    scheduleRebuildGrid(true);
  };

  const handleSearch = async (query: string) => {
    setSearchQuery(query);
    if (!query.trim()) {
      setSearchResults([]);
      scheduleRebuildGrid(true);
      return;
    }
    const results = await engine.searchCatalog(query, 'movie', 100);
    setSearchResults(results);
    announce(`${results.length} films trouvés`);
    scheduleRebuildGrid(true);
  };

  const focusDomInput = (id: string) => {
    const el = document.getElementById(id) as HTMLInputElement | null;
    el?.focus();
  };

  const detectGridColumns = (): number => {
    if (viewMode() === 'list') return 1;
    if (!gridRef) return 5;
    const firstCard = gridRef.querySelector('.buntu-vod-card') as HTMLElement | null;
    if (firstCard && gridRef.clientWidth > 0 && firstCard.offsetWidth > 0) {
      return Math.max(1, Math.round(gridRef.clientWidth / (firstCard.offsetWidth + 16)));
    }
    if (gridRef.clientWidth > 0) {
      return Math.max(1, Math.floor((gridRef.clientWidth + 16) / 190));
    }
    return 5;
  };

  const scheduleRebuildGrid = (preserveFocus: boolean) => {
    if (typeof requestAnimationFrame === 'function') {
      requestAnimationFrame(() => rebuildGrid(preserveFocus));
    } else {
      rebuildGrid(preserveFocus);
    }
  };

  const rebuildGrid = (preserveFocus = false) => {
    const list = activeMovies();
    const cats = filteredCategories();

    const grid: FocusableItem[][] = [];

    // Row 0: Toolbar
    const toolbarRow: FocusableItem[] = [
      { id: 'mv-toggle-cats', onSelect: () => { setShowCats((v) => !v); scheduleRebuildGrid(true); } },
      { id: 'mv-mode-grid', onSelect: () => { setViewMode('grid'); scheduleRebuildGrid(true); } },
      { id: 'mv-mode-list', onSelect: () => { setViewMode('list'); scheduleRebuildGrid(true); } },
      { id: 'mv-toggle-inspector', onSelect: toggleInspector },
      { id: 'mv-search-input', onSelect: () => focusDomInput('mv-search-input') },
    ];
    if (searchQuery().trim()) {
      toolbarRow.push({ id: 'mv-search-clear', onSelect: () => void handleSearch('') });
    }
    grid.push(toolbarRow);

    // Left Category Column
    const catColItems: FocusableItem[] = [];
    if (showCats()) {
      catColItems.push({
        id: 'mv-cat-home',
        onSelect: () => {
          setCatFilter('');
          void handleSelectCategory('');
        },
      });
      catColItems.push({
        id: 'mv-cat-filter',
        onSelect: () => focusDomInput('mv-cat-filter'),
      });
      catColItems.push({
        id: 'movie-cat-all',
        onSelect: () => void handleSelectCategory(''),
      });
      catColItems.push({
        id: 'movie-cat-fav',
        onSelect: () => void handleSelectCategory(FAVORITES_CATEGORY),
      });
      cats.forEach((cat, idx) => {
        catColItems.push({
          id: `movie-cat-${idx}`,
          onSelect: () => void handleSelectCategory(cat),
        });
      });
    }

    // Content Rows
    const contentRows: FocusableItem[][] = [];

    if (showsShelves()) {
      const recents = recentMovies();
      if (recents.length > 0) {
        contentRows.push(
          recents.slice(0, 7).map((mv) => ({
            id: `recent-mv-${mv.id}`,
            onFocus: () => setPreviewMovie(mv),
            onSelect: () => handleCardActivate(mv),
          }))
        );
      }
      const favs = favMovies();
      if (favs.length > 0) {
        contentRows.push(
          favs.slice(0, 7).map((mv) => ({
            id: `fav-mv-${mv.id}`,
            onFocus: () => setPreviewMovie(mv),
            onSelect: () => handleCardActivate(mv),
          }))
        );
      }
    }

    const cols = detectGridColumns();
    for (let i = 0; i < list.length; i += cols) {
      const slice = list.slice(i, i + cols);
      contentRows.push(
        slice.map((mv, idx) => ({
          id: `movie-${mv.id}`,
          onFocus: () => {
            setPreviewMovie(mv);
            if (!isSearchMode()) {
              void scroller.checkTrigger(i + idx);
            }
          },
          onSelect: () => handleCardActivate(mv),
        }))
      );
    }

    const totalBodyRows = Math.max(catColItems.length, contentRows.length);
    for (let r = 0; r < totalBodyRows; r++) {
      const row: FocusableItem[] = [];
      if (catColItems.length > 0) {
        row.push(catColItems[Math.min(r, catColItems.length - 1)]);
      }
      if (contentRows.length > 0) {
        row.push(...contentRows[Math.min(r, contentRows.length - 1)]);
      }
      if (showInspector() && previewMovie()) {
        if (r === 0) {
          row.push({ id: 'mv-insp-play', onSelect: () => handlePlayDirect(previewMovie()!) });
        } else if (r === 1) {
          row.push({ id: 'mv-insp-details', onSelect: () => handleCardActivate(previewMovie()!) });
        } else if (r === 2) {
          row.push({ id: 'mv-insp-fav', onSelect: () => void handleToggleFavorite(previewMovie()!) });
        }
      }
      if (row.length > 0) grid.push(row);
    }

    spatialNav.setGrid(grid, 1, catColItems.length > 0 ? 1 : 0, preserveFocus);
  };

  const renderMovieCard = (mv: ItemRecord, cardId: string) => {
    const parsed = () => cleanMediaTitle(mv.name);
    const title = () => (mv.name_clean && mv.name_clean !== mv.name ? mv.name_clean : parsed().clean);
    const year = () => mv.year || parsed().year;
    const quality = () => detectChannelQuality(mv.name);

    return (
      <div
        id={cardId}
        role="button"
        tabindex="-1"
        aria-label={title()}
        class={`buntu-vod-card ${focusId() === cardId ? 'focused' : ''}`}
        onClick={() => handleCardActivate(mv)}
      >
        <div class="buntu-vod-poster">
          <Show
            when={mv.logo_url}
            fallback={
              <div class="buntu-vod-poster-fallback">
                <span style={{ 'font-size': '32px' }}>🎬</span>
                <span style={{ 'font-size': '11px', 'font-weight': '600' }}>{title()}</span>
              </div>
            }
          >
            <img
              src={mv.logo_url}
              alt=""
              loading="lazy"
              onError={(e) => {
                (e.currentTarget as HTMLImageElement).style.display = 'none';
              }}
            />
          </Show>

          <Show when={viewMode() === 'grid'}>
            <div class="buntu-vod-badge-top">
              <Show when={quality()}>
                <span class={`buntu-q-badge ${quality() === '4K' ? 'uhd' : ''}`}>{quality()}</span>
              </Show>
              <Show when={mv.imdb_rating && mv.imdb_rating > 0}>
                <span class="buntu-q-badge">★ {mv.imdb_rating!.toFixed(1)}</span>
              </Show>
            </div>
            <button
              type="button"
              tabindex="-1"
              class={`buntu-vod-star-overlay ${mv.is_favorite === 1 ? 'fav' : ''}`}
              title="Favori"
              onClick={(e) => void handleToggleFavorite(mv, e)}
            >
              {mv.is_favorite === 1 ? '★' : '☆'}
            </button>
          </Show>
        </div>

        <div class="buntu-vod-meta">
          <div class="buntu-vod-title">{title()}</div>
          <div class="buntu-vod-sub">
            <span style={{ overflow: 'hidden', 'text-overflow': 'ellipsis', 'white-space': 'nowrap' }}>
              {year() ? `${year()}${mv.group_title ? ' · ' + mv.group_title : ''}` : mv.group_title || 'VOD'}
            </span>
            <Show when={viewMode() === 'list'}>
              <button
                type="button"
                tabindex="-1"
                class={`buntu-ch-star ${mv.is_favorite === 1 ? 'fav' : ''}`}
                onClick={(e) => void handleToggleFavorite(mv, e)}
              >
                {mv.is_favorite === 1 ? '★' : '☆'}
              </button>
            </Show>
          </div>
        </div>
      </div>
    );
  };

  return (
    <div class={`buntu-page ${showInspector() ? 'with-preview' : ''}`}>
      {/* Top Toolbar */}
      <header class="buntu-toolbar">
        <div class="buntu-toolbar-left">
          <button
            id="mv-toggle-cats"
            type="button"
            tabindex="-1"
            class={`buntu-tool-btn ${showCats() ? 'active' : ''} ${focusId() === 'mv-toggle-cats' ? 'focused' : ''}`}
            onClick={() => {
              setShowCats((v) => !v);
              scheduleRebuildGrid(true);
            }}
          >
            ☰
          </button>
          <h1 class="buntu-toolbar-title">Films</h1>
          <Show when={totalCount() > 0}>
            <span class="buntu-toolbar-subtitle">{formatBuntuCount(totalCount())} films</span>
          </Show>
        </div>

        <div class="buntu-toolbar-right">
          <div class="buntu-seg-group">
            <button
              id="mv-mode-grid"
              type="button"
              tabindex="-1"
              class={`buntu-seg-btn ${viewMode() === 'grid' ? 'active' : ''} ${focusId() === 'mv-mode-grid' ? 'focused' : ''}`}
              onClick={() => {
                setViewMode('grid');
                scheduleRebuildGrid(true);
              }}
            >
              ⊞
            </button>
            <button
              id="mv-mode-list"
              type="button"
              tabindex="-1"
              class={`buntu-seg-btn ${viewMode() === 'list' ? 'active' : ''} ${focusId() === 'mv-mode-list' ? 'focused' : ''}`}
              onClick={() => {
                setViewMode('list');
                scheduleRebuildGrid(true);
              }}
            >
              ☰
            </button>
          </div>

          <button
            id="mv-toggle-inspector"
            type="button"
            tabindex="-1"
            class={`buntu-tool-btn ${showInspector() ? 'active' : ''} ${focusId() === 'mv-toggle-inspector' ? 'focused' : ''}`}
            onClick={toggleInspector}
          >
            ◫
          </button>

          <div class="buntu-search-wrap">
            <span class="buntu-search-icon">🔍</span>
            <input
              id="mv-search-input"
              type="text"
              value={searchQuery()}
              placeholder="Rechercher un film"
              class={`buntu-search-field ${focusId() === 'mv-search-input' ? 'focused' : ''}`}
              onInput={(e) => void handleSearch(e.currentTarget.value)}
            />
            <Show when={searchQuery().trim().length > 0}>
              <button
                id="mv-search-clear"
                type="button"
                tabindex="-1"
                class={`buntu-search-clear ${focusId() === 'mv-search-clear' ? 'focused' : ''}`}
                onClick={() => void handleSearch('')}
              >
                ✕
              </button>
            </Show>
          </div>
        </div>
      </header>

      {/* Split Body */}
      <div class="buntu-body-split">
        <Show when={showCats()}>
          <aside class="buntu-cat-pane" aria-label="Catégories Films">
            <div class="buntu-cat-filter-bar">
              <button
                id="mv-cat-home"
                type="button"
                tabindex="-1"
                class={`buntu-cat-home-btn ${focusId() === 'mv-cat-home' ? 'focused' : ''}`}
                onClick={() => {
                  setCatFilter('');
                  void handleSelectCategory('');
                }}
              >
                ⌂
              </button>
              <input
                id="mv-cat-filter"
                type="text"
                value={catFilter()}
                placeholder="Filtrer les catégories"
                class={`buntu-cat-filter-input ${focusId() === 'mv-cat-filter' ? 'focused' : ''}`}
                onInput={(e) => {
                  setCatFilter(e.currentTarget.value);
                  scheduleRebuildGrid(true);
                }}
              />
            </div>

            <div class="buntu-cat-list">
              <div
                id="movie-cat-all"
                role="button"
                tabindex="-1"
                class={`buntu-cat-row ${selectedCat() === '' && !isSearchMode() ? 'active' : ''} ${focusId() === 'movie-cat-all' ? 'focused' : ''}`}
                onClick={() => void handleSelectCategory('')}
              >
                <div class="buntu-cat-row-left">
                  <span class="buntu-cat-row-icon">⊞</span>
                  <span class="buntu-cat-row-title">Tous les films</span>
                </div>
                <span class="buntu-cat-count">{formatBuntuCount(totalCount())}</span>
              </div>

              <div
                id="movie-cat-fav"
                role="button"
                tabindex="-1"
                class={`buntu-cat-row ${selectedCat() === FAVORITES_CATEGORY && !isSearchMode() ? 'active' : ''} ${focusId() === 'movie-cat-fav' ? 'focused' : ''}`}
                onClick={() => void handleSelectCategory(FAVORITES_CATEGORY)}
              >
                <div class="buntu-cat-row-left">
                  <span class="buntu-cat-row-icon fav">★</span>
                  <span class="buntu-cat-row-title">Favoris</span>
                </div>
                <span class="buntu-cat-count">{formatBuntuCount(favCount())}</span>
              </div>

              <For each={filteredCategories()}>
                {(cat, idx) => (
                  <div
                    id={`movie-cat-${idx()}`}
                    role="button"
                    tabindex="-1"
                    class={`buntu-cat-row ${selectedCat() === cat && !isSearchMode() ? 'active' : ''} ${focusId() === `movie-cat-${idx()}` ? 'focused' : ''}`}
                    onClick={() => void handleSelectCategory(cat)}
                  >
                    <div class="buntu-cat-row-left">
                      <span class="buntu-cat-row-title">{cat}</span>
                    </div>
                    <span class="buntu-cat-count">{formatBuntuCount(catCounts()[cat] || 0)}</span>
                  </div>
                )}
              </For>
            </div>
          </aside>
        </Show>

        <section
          class="buntu-content-scroll"
          onScroll={(e) => {
            if (isSearchMode()) return;
            const el = e.currentTarget as HTMLElement;
            if (el.scrollTop + el.clientHeight >= el.scrollHeight - 360) {
              void scroller.loadMore();
            }
          }}
        >
          {/* Shelf 1: Reprendre / Récemment consultés */}
          <Show when={showsShelves() && recentMovies().length > 0}>
            <div class="buntu-section">
              <div class="buntu-section-header">
                <h2 class="buntu-section-title">
                  <span style={{ color: 'var(--buntu-accent)' }}>▶</span> Reprendre
                </h2>
              </div>
              <div class="buntu-vod-shelf">
                <For each={recentMovies().slice(0, 7)}>
                  {(mv) => renderMovieCard(mv, `recent-mv-${mv.id}`)}
                </For>
              </div>
            </div>
          </Show>

          {/* Shelf 2: Favoris */}
          <Show when={showsShelves() && favMovies().length > 0}>
            <div class="buntu-section">
              <div class="buntu-section-header">
                <h2 class="buntu-section-title">
                  <span style={{ color: 'var(--buntu-star)' }}>★</span> Favoris
                </h2>
              </div>
              <div class="buntu-vod-shelf">
                <For each={favMovies().slice(0, 7)}>
                  {(mv) => renderMovieCard(mv, `fav-mv-${mv.id}`)}
                </For>
              </div>
            </div>
          </Show>

          {/* Main Movies Grid */}
          <div class="buntu-section">
            <div class="buntu-section-header">
              <h2 class="buntu-section-title">
                {isSearchMode()
                  ? `Recherche : « ${searchQuery()} »`
                  : selectedCat() === FAVORITES_CATEGORY
                    ? 'Favoris'
                    : selectedCat() || 'Tous les films'}
              </h2>
              <span class="buntu-section-meta">
                {isSearchMode()
                  ? `${searchResults().length} résultats`
                  : `${formatBuntuCount(scroller.total())} films`}
              </span>
            </div>

            <div
              ref={gridRef}
              class={`buntu-vod-grid ${viewMode() === 'list' ? 'list-mode' : ''}`}
            >
              <For each={activeMovies()}>
                {(mv) => renderMovieCard(mv, `movie-${mv.id}`)}
              </For>
            </div>

            <Show when={!isSearchMode() && scroller.isLoading()}>
              <div class="tv-infinite-loader">
                <div class="tv-spinner-small" />
                <span>Chargement des films…</span>
              </div>
            </Show>
          </div>
        </section>

        {/* Optional Inspector Pane */}
        <Show when={showInspector() && previewMovie()}>
          <aside class="buntu-inspector-pane" aria-label="Aperçu film">
            <div ref={viewportRef} class="buntu-inspector-viewport" style={{ background: '#111318' }}>
              <Show when={previewMovie()?.logo_url} fallback={<div class="tv-mini-mock-screen">🎬</div>}>
                <img
                  src={previewMovie()!.logo_url}
                  alt=""
                  style={{ width: '100%', height: '100%', 'object-fit': 'cover' }}
                />
              </Show>
            </div>
            <h3 class="buntu-inspector-title">
              {previewMovie()!.name_clean || previewMovie()!.name}
            </h3>
            <p class="buntu-inspector-desc">
              {previewMovie()!.plot || previewMovie()!.group_title || 'Film VOD disponible en haute définition.'}
            </p>
            <div class="buntu-inspector-actions">
              <button
                id="mv-insp-play"
                type="button"
                tabindex="-1"
                class={`buntu-action-primary ${focusId() === 'mv-insp-play' ? 'focused' : ''}`}
                onClick={() => handlePlayDirect(previewMovie()!)}
              >
                ▶ Regarder
              </button>
              <button
                id="mv-insp-details"
                type="button"
                tabindex="-1"
                class={`buntu-action-secondary ${focusId() === 'mv-insp-details' ? 'focused' : ''}`}
                onClick={() => handleCardActivate(previewMovie()!)}
              >
                ℹ Fiche
              </button>
              <button
                id="mv-insp-fav"
                type="button"
                tabindex="-1"
                class={`buntu-action-secondary ${focusId() === 'mv-insp-fav' ? 'focused' : ''}`}
                onClick={() => void handleToggleFavorite(previewMovie()!)}
              >
                {previewMovie()!.is_favorite === 1 ? '★' : '☆'}
              </button>
            </div>
          </aside>
        </Show>
      </div>
    </div>
  );
};
