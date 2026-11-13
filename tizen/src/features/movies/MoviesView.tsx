import { aiSuggestions, mergeSuggestions, searchMode, searchModeLabel, toggleSearchMode } from '../../core/search/searchMode';
import { RemoteKeyHandler } from '../../core/input/RemoteKeyHandler';
import { registerYellowFavorite } from '../../ui/design/yellowFavorite';
import { Component, createSignal, createMemo, createEffect, onMount, onCleanup, For, Show, untrack } from 'solid-js';
import { CndEngine, MovieInfo } from '../../core/engine/CndEngine';
import { ItemRecord, FAVORITES_CATEGORY, RECENT_CATEGORY } from '../../core/storage/Database';
import { AVPlayerService } from '../../core/player/AVPlayerService';
import { FocusableItem, spatialNav } from '../../ui/design/SpatialNav';
import { screenState, isContentFocusId, revealItem, BrowseSnapshot } from '../../core/navigation/ScreenState';
import { createInfiniteScroller } from '../../core/pagination/InfiniteScrollController';
import { cleanMediaTitle } from '../../core/utils/titleCleaner';
import { detectChannelQuality, formatBuntuCount } from '../../core/utils/categoryMeta';
import { announce } from '../../ui/design/a11y';
import { createMiniPlayer } from '../../core/player/MiniPlayerController';
import { MiniPlayerPanel } from '../../ui/components/MiniPlayerPanel';
import { InfoChips, InfoSection, InfoProgress } from '../../ui/components/InfoParts';
import { formatDuration, formatRuntime, percentOf } from '../../core/utils/timeFormat';
import { panelFocusItems, panelItemsForRow, installPanelLeftReturn, PANEL_MIN_ROWS } from '../../ui/design/miniPlayerFocus';

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
  const [recentCount, setRecentCount] = createSignal(0);

  const [selectedCat, setSelectedCat] = createSignal<string>('');
  const [catFilter, setCatFilter] = createSignal<string>('');
  const [showCats, setShowCats] = createSignal(true);
  // False until the first load is over: the counts would read 0 and the lists look empty.
  const [loaded, setLoaded] = createSignal(false);
  const [viewMode, setViewMode] = createSignal<'grid' | 'list'>('grid');
  // Bumped when a favorite flag changes (the records are mutated in place).
  const [favTick, setFavTick] = createSignal(0);
  // Shared mini player (same experience as Live TV): play in the panel, details of the hovered film below.
  const mini = createMiniPlayer<ItemRecord>({
    engine,
    player,
    onFullscreen: (mv) => (props.onPlayMovie ? props.onPlayMovie(mv) : props.onSelectMovie(mv)),
    startTimeoutMs: 45000, // a film resolves its final address first, then buffers more than a channel
    timeoutMessage: 'Le serveur ne répond pas',
    // OK on a film plays it in the panel and moves the cursor there, to read its text; full screen is chosen in the panel.
    focusPanelOnActivate: () => {
      spatialNav.setFocusById('mv-insp-screen');
      setTimeout(() => {
        // The panel may only exist once the grid is rebuilt for the film: try again unless the cursor is already there.
        if (!spatialNav.getCurrentFocusId().startsWith('mv-insp-')) spatialNav.setFocusById('mv-insp-screen');
      }, 150);
    },
  });
  let unsubPanelKeys: (() => void) | null = null;

  const [searchQuery, setSearchQuery] = createSignal<string>('');
  const [searchResults, setSearchResults] = createSignal<ItemRecord[]>([]);

  const [recentMovies, setRecentMovies] = createSignal<ItemRecord[]>([]);
  const [favMovies, setFavMovies] = createSignal<ItemRecord[]>([]);
  const previewMovie = mini.focused; // the film under the cursor (details of the panel)
  const setPreviewMovie = mini.focus;
  const [focusId] = spatialNav.getFocusSignal();

  // Last card focused in the content area: restored when BACK returns here from details/player.
  let lastContentFocus = '';
  let lastScrollTop = 0;
  createEffect(() => {
    const f = focusId();
    if (isContentFocusId(f)) lastContentFocus = f;
  });

  let gridRef: HTMLDivElement | undefined;
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

  const refreshShelvesAndCounts = async () => {
    const [countsData, recents, favs, recentTotal] = await Promise.all([
      engine.getCategoryCounts('movie'),
      engine.getRecentItems('movie', 10),
      engine.getFavoritesByKind('movie', 12),
      engine.countCatalog('movie', RECENT_CATEGORY),
    ]);
    setTotalCount(countsData.total);
    setFavCount(countsData.favCount);
    setRecentCount(recentTotal);
    setCatCounts(countsData.counts);
    setRecentMovies(recents);
    setFavMovies(favs);
  };

  // What the provider says about the highlighted film (synopsis, genre, cast…): fetched once the cursor rests on it.
  const [movieInfos, setMovieInfos] = createSignal<Record<number, MovieInfo | null>>({});
  let infoTimer: ReturnType<typeof setTimeout> | undefined;
  createEffect(() => {
    const mv = mini.focused();
    clearTimeout(infoTimer);
    if (!mv || mv.id in untrack(movieInfos)) return;
    infoTimer = setTimeout(async () => {
      const info = await engine.getMovieInfo(mv).catch(() => null);
      setMovieInfos((prev) => ({ ...prev, [mv.id]: info }));
    }, 350);
  });
  onCleanup(() => clearTimeout(infoTimer));

  // Yellow button: add or remove the highlighted film from the favourites.
  onCleanup(
    registerYellowFavorite({
      isItemFocus: (id) => /^(?:movie|recent-mv|fav-mv)-\d+$/.test(id) || id.startsWith('mv-insp'),
      current: () => mini.focused(),
      toggle: (item) => handleToggleFavorite(item),
    })
  );

  onMount(async () => {
    try {
    resizeHandler = () => {
      mini.syncRect();
      scheduleRebuildGrid(true);
    };
    window.addEventListener('resize', resizeHandler);

    // LEFT from the panel goes back to the film the cursor came from (not to the first row).
    unsubPanelKeys = installPanelLeftReturn('mv-insp', () => focusId(), () => lastContentFocus);

    // BACK from the player/details: same category, view mode and focused card as before.
    const restored = screenState.restore('movies');
    const snap = restored?.snapshot as BrowseSnapshot<ItemRecord> | undefined;
    if (restored && snap) {
      // Instant return: show what was on screen, then refresh counts and shelves behind.
      setSelectedCat(restored.category);
      setViewMode(restored.viewMode);
      setCategories(snap.categories);
      setCatCounts(snap.catCounts);
      setFavCount(snap.favCount);
      setRecentMovies(snap.recent);
      setFavMovies(snap.favs);
      setTotalCount(snap.totalCount);
      scroller.setItems(snap.items, snap.total);
      rebuildGrid(false);
      if (restored.focusId && document.getElementById(restored.focusId)) {
        spatialNav.setFocusById(restored.focusId);
      }
      const scrollArea = document.querySelector('.buntu-content-scroll') as HTMLElement | null;
      if (scrollArea) scrollArea.scrollTop = snap.scrollTop;
      document.querySelector('.buntu-cat-row.active')?.scrollIntoView({ block: 'nearest' });
      void refreshShelvesAndCounts().then(() => scheduleRebuildGrid(true));
      return;
    }

    const cats = await engine.getCategories('movie');
    setCategories(cats);
    await refreshShelvesAndCounts();

    // (restored state read at the top of onMount)
    if (restored) {
      setSelectedCat(restored.category);
      setViewMode(restored.viewMode);
    }

    await scroller.reset();
    const items = scroller.items();
    if (items.length > 0) {
      setPreviewMovie(items[0]);
    }
    if (restored && restored.focusId) {
      await revealItem(scroller, restored.focusId);
      rebuildGrid(false);
      if (document.getElementById(restored.focusId)) {
        spatialNav.setFocusById(restored.focusId);
        document.querySelector('.buntu-cat-row.active')?.scrollIntoView({ block: 'nearest' });
        return;
      }
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
  
    } catch (error) {
      console.warn('Chargement initial impossible', error);
    } finally {
      setLoaded(true);
    }
  });

  onCleanup(() => {
    screenState.save('movies', {
      category: selectedCat(),
      viewMode: viewMode(),
      focusId: lastContentFocus,
      snapshot: {
        categories: categories(),
        catCounts: catCounts(),
        totalCount: totalCount(),
        favCount: favCount(),
        recent: recentMovies(),
        favs: favMovies(),
        items: scroller.items(),
        total: scroller.total(),
        scrollTop: lastScrollTop,
      },
    });
    unsubPanelKeys?.();
    if (resizeHandler) window.removeEventListener('resize', resizeHandler);
    // Leaving for another screen (not for the full-screen player) frees the stream.
    mini.dispose();
  });

  const toggleInspector = () => {
    mini.toggleVisible();
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

  // OK on a film: the first press plays it in the mini player, a second press on the one already
  // playing goes full screen (shared mini player controller). The "Fiche" button opens the details page.
  const handleCardActivate = (mv: ItemRecord) => {
    mini.activate(mv);
  };

  const openDetails = (mv: ItemRecord | null) => {
    if (!mv) return;
    engine.recordRecent(mv);
    props.onSelectMovie(mv);
  };

  const handleToggleFavorite = async (mv: ItemRecord, e?: MouseEvent) => {
    e?.stopPropagation();
    const next = await engine.toggleFavorite(mv.id);
    mv.is_favorite = next ? 1 : 0;
    setFavTick((t) => t + 1);
    announce(next ? 'Film ajouté aux favoris' : 'Film retiré des favoris');
    await refreshShelvesAndCounts();
    if (selectedCat() === FAVORITES_CATEGORY) {
      await scroller.reset();
    } else {
      setSearchResults((prev) => [...prev]);
    }
    scheduleRebuildGrid(true);
  };

  // The search engine (local / IA) is chosen with the button after the field. In IA mode, once typing pauses,
  // the assistant's suggestions are put in front of the local results.
  let aiTimer: ReturnType<typeof setTimeout> | undefined;
  onCleanup(() => clearTimeout(aiTimer));
  const scheduleAiRefine = (query: string) => {
    clearTimeout(aiTimer);
    if (searchMode() !== 'ai' || query.trim().length < 3) return;
    aiTimer = setTimeout(async () => {
      const extra = await aiSuggestions(engine, query, 'movie').catch(() => []);
      if (searchQuery() !== query || extra.length === 0) return;
      setSearchResults(mergeSuggestions(searchResults(), extra));
      announce(`L’assistant propose ${extra.length} résultat(s)`);
      scheduleRebuildGrid(true);
    }, 900);
  };
  const switchSearchEngine = async () => {
    const change = await toggleSearchMode();
    announce(change.message);
    if (searchQuery().trim()) void handleSearch(searchQuery());
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
    scheduleAiRefine(query);
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
      { id: 'mv-search-input', onSelect: () => focusDomInput('mv-search-input') },
      { id: 'mv-search-mode', onSelect: switchSearchEngine },
    ];
    grid.push(toolbarRow);

    // Left Category Column
    const catColItems: FocusableItem[] = [];
    if (showCats()) {
      catColItems.push({
        id: 'mv-cat-filter',
        onSelect: () => focusDomInput('mv-cat-filter'),
      });
      catColItems.push({
        id: 'movie-cat-recent',
        onSelect: () => void handleSelectCategory(RECENT_CATEGORY),
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

    const inspectorItems: FocusableItem[] =
      mini.visible() && previewMovie()
        ? panelFocusItems(mini, 'mv-insp', (mv) => void handleToggleFavorite(mv), [
            { id: 'mv-insp-details', label: 'ℹ Fiche', onSelect: () => openDetails(mini.focused()) },
          ])
        : [];

    const totalBodyRows = Math.max(catColItems.length, contentRows.length, inspectorItems.length > 0 ? PANEL_MIN_ROWS : 0);
    for (let r = 0; r < totalBodyRows; r++) {
      const row: FocusableItem[] = [];
      if (catColItems.length > 0) {
        row.push(catColItems[Math.min(r, catColItems.length - 1)]);
      }
      if (contentRows.length > 0) {
        row.push(...contentRows[Math.min(r, contentRows.length - 1)]);
      }
      // The panel is reachable with RIGHT from every row.
      row.push(...panelItemsForRow(inspectorItems, r));
      if (row.length > 0) grid.push(row);
    }

    spatialNav.setGrid(grid, 1, catColItems.length > 0 ? 1 : 0, preserveFocus);
  };

  const isFav = (mv: ItemRecord) => {
    favTick();
    return mv.is_favorite === 1;
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
              class={`buntu-vod-star-overlay ${isFav(mv) ? 'fav' : ''}`}
              title="Favori"
              onClick={(e) => void handleToggleFavorite(mv, e)}
            >
              {isFav(mv) ? '★' : '☆'}
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
                class={`buntu-ch-star ${isFav(mv) ? 'fav' : ''}`}
                onClick={(e) => void handleToggleFavorite(mv, e)}
              >
                {isFav(mv) ? '★' : '☆'}
              </button>
            </Show>
          </div>
        </div>
      </div>
    );
  };

  return (
    <div class={`buntu-page ${mini.status() === 'playing' ? 'with-preview' : ''}`}>
      {/* Top Toolbar */}
      <header class="buntu-toolbar">
        <div class="buntu-toolbar-left">
          <h1 class="buntu-toolbar-title">Films</h1>
          <Show when={totalCount() > 0}>
            <span class="buntu-toolbar-subtitle">{formatBuntuCount(totalCount())} films</span>
          </Show>
        </div>

        <div class="buntu-toolbar-right">
          <span class="buntu-key-hint"><i class="buntu-key-dot" />Favori</span>
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
          </div>
          <button
            id="mv-search-mode"
            type="button"
            tabindex="-1"
            class={`buntu-mode-btn ${searchMode() === 'ai' ? 'ai' : ''} ${focusId() === 'mv-search-mode' ? 'focused' : ''}`}
            aria-label={searchMode() === 'ai' ? 'Moteur de recherche : IA. OK pour passer en local' : 'Moteur de recherche : local. OK pour passer en IA'}
            onClick={switchSearchEngine}
          >
            {searchModeLabel(searchMode())}
          </button>
        </div>
      </header>

      {/* Split Body */}
      <div class="buntu-body-split">
        <Show when={showCats()}>
          <aside class="buntu-cat-pane" aria-label="Catégories Films">
            <div class="buntu-cat-filter-bar">
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
              {/* Récemment vus */}
              <div
                id="movie-cat-recent"
                role="button"
                tabindex="-1"
                class={`buntu-cat-row ${selectedCat() === RECENT_CATEGORY && !isSearchMode() ? 'active' : ''} ${focusId() === 'movie-cat-recent' ? 'focused' : ''}`}
                onClick={() => void handleSelectCategory(RECENT_CATEGORY)}
              >
                <div class="buntu-cat-row-left">
                  <span class="buntu-cat-row-icon">🕒</span>
                  <span class="buntu-cat-row-title">Récemment vus</span>
                </div>
                <Show when={loaded()}><span class="buntu-cat-count">{formatBuntuCount(recentCount())}</span></Show>
              </div>

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
                <Show when={loaded()}><span class="buntu-cat-count">{formatBuntuCount(totalCount())}</span></Show>
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
                <Show when={loaded()}><span class="buntu-cat-count">{formatBuntuCount(favCount())}</span></Show>
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
                    <Show when={loaded()}><span class="buntu-cat-count">{formatBuntuCount(catCounts()[cat] || 0)}</span></Show>
                  </div>
                )}
              </For>
            </div>
          </aside>
        </Show>

        <section
          class="buntu-content-scroll"
          onScroll={(e) => {
            lastScrollTop = (e.currentTarget as HTMLElement).scrollTop;
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
                  : selectedCat() === RECENT_CATEGORY
                    ? 'Récemment vus'
                    : selectedCat() === FAVORITES_CATEGORY
                    ? 'Favoris'
                    : selectedCat() || 'Tous les films'}
              </h2>
              <Show when={loaded()}>
              <span class="buntu-section-meta">
                {isSearchMode()
                  ? `${searchResults().length} résultats`
                  : `${formatBuntuCount(scroller.total())} films`}
              </span>
              </Show>
            </div>

            <Show when={!loaded()}>
              <div class="buntu-first-load" role="status" aria-live="polite">
                <div class="tv-spinner" />
                <span>Chargement des films…</span>
              </div>
            </Show>

            <div
              ref={gridRef}
              class={`buntu-vod-grid ${viewMode() === 'list' ? 'list-mode' : ''}`}
            >
              <For each={activeMovies()}>
                {(mv) => renderMovieCard(mv, `movie-${mv.id}`)}
              </For>
            </div>

            <Show
              when={
                !isSearchMode() &&
                !scroller.isLoading() &&
                scroller.items().length === 0 &&
                (selectedCat() === RECENT_CATEGORY || selectedCat() === FAVORITES_CATEGORY)
              }
            >
              <p class="buntu-empty-hint">
                {selectedCat() === RECENT_CATEGORY
                  ? 'Lancez un film : il apparaîtra ici.'
                  : 'Aucun favori pour l’instant : ajoutez-en avec ☆ Favori.'}
              </p>
            </Show>

            <Show when={!isSearchMode() && scroller.isLoading()}>
              <div class="tv-infinite-loader">
                <div class="tv-spinner-small" />
                <span>Chargement des films…</span>
              </div>
            </Show>
          </div>
        </section>

        {/* Shared mini player panel (preview, details of the focused film, actions) */}
        <MiniPlayerPanel
          ctl={mini}
          idPrefix="mv-insp"
          focusId={focusId}
          posterUrl={(mv) => mv.logo_url}
          titleOf={(mv) => mv.name_clean || cleanMediaTitle(mv.name).clean}
          fallbackIcon="🎬"
          idleHint="▶ Lecture"
          isFavorite={isFav}
          onToggleFavorite={(mv) => void handleToggleFavorite(mv)}
          extraActions={[{ id: 'mv-insp-details', label: 'ℹ Fiche', onSelect: () => openDetails(mini.focused()) }]}
          details={(mv) => {
            const parsed = cleanMediaTitle(mv.name);
            const year = mv.year || parsed.year;
            const quality = detectChannelQuality(mv.name);
            // The length is known from the catalog, or from the stream once this film plays.
            const total = () => (mv.duration_ms > 0 ? mv.duration_ms : info()?.durationMs ?? (mini.isPlaying(mv.id) ? mini.durationMs() : 0));
            const info = () => movieInfos()[mv.id] ?? null;
            const releaseYear = () => {
              const y = parseInt((info()?.releaseDate ?? '').slice(0, 4), 10);
              return Number.isFinite(y) && y > 1800 ? y : undefined;
            };
            const rating = () => (mv.imdb_rating && mv.imdb_rating > 0 ? mv.imdb_rating : info()?.rating);
            const plot = () => mv.plot || info()?.plot;
            const resumed = () => (mv.playback_position_ms > 0 ? percentOf(mv.playback_position_ms, total()) : 0);
            return (
              <>
                <div class="buntu-insp-heading">
                  <h3 class="buntu-inspector-title">
                    {mv.name_clean && mv.name_clean !== mv.name ? mv.name_clean : parsed.clean}
                  </h3>
                </div>
                <InfoChips
                  chips={[
                    quality ? { text: quality, tone: quality === '4K' ? 'uhd' : 'quality' } : null,
                    rating() ? { text: `★ ${rating()!.toFixed(1)}`, tone: 'rating' } : null,
                    year || releaseYear() ? { text: String(year || releaseYear()) } : null,
                    info()?.age ? { text: info()!.age! } : null,
                    total() > 0 ? { text: formatRuntime(total()) } : null,
                    mv.language ? { text: mv.language.toUpperCase() } : null,
                    mv.container_ext ? { text: mv.container_ext.toUpperCase() } : null,
                    info()?.genre ? { text: info()!.genre! } : null,
                    info()?.country ? { text: info()!.country! } : null,
                    mv.group_title ? { text: mv.group_title } : null,
                  ]}
                />

                <Show when={resumed() > 0 && resumed() < 95}>
                  <InfoSection label="REPRISE">
                    <div class="buntu-insp-epg-title">
                      Reprendre à {formatDuration(mv.playback_position_ms)} · {resumed()} %
                    </div>
                    <InfoProgress percent={resumed()} />
                  </InfoSection>
                </Show>

                <InfoSection label="SYNOPSIS">
                  <p class="buntu-inspector-desc buntu-insp-clamp buntu-insp-plot">
                    {plot() || 'Aucun résumé disponible pour ce film.'}
                  </p>
                </InfoSection>

                {/* Only what the provider gave: nothing is shown for a missing fact */}
                <Show when={info()?.director}>
                  <InfoSection label="RÉALISATION">
                    <p class="buntu-inspector-desc">{info()!.director}</p>
                  </InfoSection>
                </Show>
                <Show when={info()?.cast}>
                  <InfoSection label="DISTRIBUTION">
                    <p class="buntu-inspector-desc buntu-insp-clamp">{info()!.cast}</p>
                  </InfoSection>
                </Show>
                <Show when={info()?.releaseDate}>
                  <InfoSection label="SORTIE">
                    <p class="buntu-inspector-desc">{info()!.releaseDate}</p>
                  </InfoSection>
                </Show>
              </>
            );
          }}
        />
      </div>
    </div>
  );
};
