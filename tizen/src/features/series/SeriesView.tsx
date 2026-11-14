import { aiSuggestions, mergeSuggestions, searchMode, searchModeLabel, toggleSearchMode } from '../../core/search/searchMode';
import { RemoteKeyHandler } from '../../core/input/RemoteKeyHandler';
import { registerYellowFavorite } from '../../ui/design/yellowFavorite';
import { Component, createSignal, createMemo, createEffect, onMount, onCleanup, For, Show } from 'solid-js';
import { CndEngine } from '../../core/engine/CndEngine';
import { ItemRecord, FAVORITES_CATEGORY, RECENT_CATEGORY } from '../../core/storage/Database';
import { AVPlayerService } from '../../core/player/AVPlayerService';
import { FocusableItem, spatialNav } from '../../ui/design/SpatialNav';
import { screenState, isContentFocusId, revealItem, BrowseSnapshot } from '../../core/navigation/ScreenState';
import { createInfiniteScroller } from '../../core/pagination/InfiniteScrollController';
import { cleanMediaTitle } from '../../core/utils/titleCleaner';
import { detectChannelQuality, formatBuntuCount } from '../../core/utils/categoryMeta';
import { announce } from '../../ui/design/a11y';

export interface SeriesViewProps {
  onSelectSeries: (series: ItemRecord) => void;
  onHome?: () => void;
}

export const SeriesView: Component<SeriesViewProps> = (props) => {
  const goHome = () => {
    if (props.onHome) props.onHome();
    else window.dispatchEvent(new KeyboardEvent('keydown', { keyCode: 10009, bubbles: true }));
  };
  const engine = CndEngine.getInstance();
  const player = AVPlayerService.getInstance();
  const PAGE_SIZE = 40;

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
  const [showInspector, setShowInspector] = createSignal(false);

  const [searchQuery, setSearchQuery] = createSignal<string>('');
  const [searchResults, setSearchResults] = createSignal<ItemRecord[]>([]);

  const [recentSeries, setRecentSeries] = createSignal<ItemRecord[]>([]);
  const [favSeries, setFavSeries] = createSignal<ItemRecord[]>([]);
  const [previewSeries, setPreviewSeries] = createSignal<ItemRecord | null>(null);
  const [focusId] = spatialNav.getFocusSignal();

  // Last card focused in the content area: restored when BACK returns here from details/player.
  let lastContentFocus = '';
  let lastScrollTop = 0;
  createEffect(() => {
    const f = focusId();
    if (isContentFocusId(f)) lastContentFocus = f;
  });

  let gridRef: HTMLDivElement | undefined;
  let viewportRef: HTMLDivElement | undefined;
  let resizeHandler: (() => void) | null = null;

  const isSearchMode = () => searchQuery().trim().length > 0;
  const activeSeries = () => (isSearchMode() ? searchResults() : scroller.items());
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
        engine.getCatalog('series', cat, offset, limit),
        engine.countCatalog('series', cat),
      ]);
      return { items: list, total: count };
    },
    onBatchLoaded: (list, total) => {
      if (!isSearchMode()) {
        announce(`Séries, ${list.length} séries affichées sur ${total}`);
        if (!previewSeries() && list.length > 0) {
          setPreviewSeries(list[0]);
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
    const [countsData, recents, favs, recentTotal] = await Promise.all([
      engine.getCategoryCounts('series'),
      engine.getRecentItems('series', 10),
      engine.getFavoritesByKind('series', 12),
      engine.countCatalog('series', RECENT_CATEGORY),
    ]);
    setTotalCount(countsData.total);
    setFavCount(countsData.favCount);
    setRecentCount(recentTotal);
    setCatCounts(countsData.counts);
    setRecentSeries(recents);
    setFavSeries(favs);
  };

  // Yellow button: add or remove the highlighted série from the favourites.
  onCleanup(
    registerYellowFavorite({
      isItemFocus: (id) => /^(?:series|recent-s|fav-s)-\d+$/.test(id) || id.startsWith('s-insp'),
      current: () => previewSeries(),
      toggle: (item) => handleToggleFavorite(item),
    })
  );

  onMount(async () => {
    try {
    resizeHandler = () => {
      syncAvPlayRect();
      scheduleRebuildGrid(true);
    };
    window.addEventListener('resize', resizeHandler);

    // BACK from the player/details: same category, view mode and focused card as before.
    const restored = screenState.restore('series');
    const snap = restored?.snapshot as BrowseSnapshot<ItemRecord> | undefined;
    if (restored && snap) {
      // Instant return: show what was on screen, then refresh counts and shelves behind.
      setSelectedCat(restored.category);
      setViewMode(restored.viewMode);
      setCategories(snap.categories);
      setCatCounts(snap.catCounts);
      setFavCount(snap.favCount);
      setRecentSeries(snap.recent);
      setFavSeries(snap.favs);
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

    const cats = await engine.getCategories('series');
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
      setPreviewSeries(items[0]);
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
      const firstId = recentSeries().length > 0
        ? `recent-s-${recentSeries()[0].id}`
        : favSeries().length > 0
          ? `fav-s-${favSeries()[0].id}`
          : `series-${items[0].id}`;
      spatialNav.setFocusById(firstId);
    } else if (cats.length > 0) {
      spatialNav.setFocusById('series-cat-all');
    }
  
    } catch (error) {
      console.warn('Chargement initial impossible', error);
    } finally {
      setLoaded(true);
    }
  });

  onCleanup(() => {
    screenState.save('series', {
      category: selectedCat(),
      viewMode: viewMode(),
      focusId: lastContentFocus,
      snapshot: {
        categories: categories(),
        catCounts: catCounts(),
        totalCount: totalCount(),
        favCount: favCount(),
        recent: recentSeries(),
        favs: favSeries(),
        items: scroller.items(),
        total: scroller.total(),
        scrollTop: lastScrollTop,
      },
    });
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
      setPreviewSeries(items[0]);
    }
    scheduleRebuildGrid(false);
    if (items.length > 0) {
      spatialNav.setFocusById(`series-${items[0].id}`);
    }
  };

  const handleCardActivate = (s: ItemRecord) => {
    engine.recordRecent(s);
    setPreviewSeries(s);
    props.onSelectSeries(s);
  };

  const handleToggleFavorite = async (s: ItemRecord, e?: MouseEvent) => {
    e?.stopPropagation();
    const next = await engine.toggleFavorite(s.id);
    s.is_favorite = next ? 1 : 0;
    announce(next ? 'Série ajoutée aux favoris' : 'Série retirée des favoris');
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
      const extra = await aiSuggestions(engine, query, 'series').catch(() => []);
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
    const results = await engine.searchCatalog(query, 'series', 100);
    setSearchResults(results);
    announce(`${results.length} séries trouvées`);
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
    const list = activeSeries();
    const cats = filteredCategories();

    const grid: FocusableItem[][] = [];

    // Row 0: Toolbar
    const toolbarRow: FocusableItem[] = [
      { id: 's-brand-home', onSelect: goHome },
      { id: 's-search-input', onSelect: () => focusDomInput('s-search-input') },
      { id: 's-search-mode', onSelect: switchSearchEngine },
    ];
    grid.push(toolbarRow);

    // Left Category Column
    const catColItems: FocusableItem[] = [];
    if (showCats()) {
      catColItems.push({
        id: 's-cat-filter',
        onSelect: () => focusDomInput('s-cat-filter'),
      });
      catColItems.push({
        id: 'series-cat-recent',
        onSelect: () => void handleSelectCategory(RECENT_CATEGORY),
      });
      catColItems.push({
        id: 'series-cat-all',
        onSelect: () => void handleSelectCategory(''),
      });
      catColItems.push({
        id: 'series-cat-fav',
        onSelect: () => void handleSelectCategory(FAVORITES_CATEGORY),
      });
      cats.forEach((cat, idx) => {
        catColItems.push({
          id: `series-cat-${idx}`,
          onSelect: () => void handleSelectCategory(cat),
        });
      });
    }

    // Content Rows
    const contentRows: FocusableItem[][] = [];

    if (showsShelves()) {
      const recents = recentSeries();
      if (recents.length > 0) {
        contentRows.push(
          recents.slice(0, 7).map((s) => ({
            id: `recent-s-${s.id}`,
            onFocus: () => setPreviewSeries(s),
            onSelect: () => handleCardActivate(s),
          }))
        );
      }
      const favs = favSeries();
      if (favs.length > 0) {
        contentRows.push(
          favs.slice(0, 7).map((s) => ({
            id: `fav-s-${s.id}`,
            onFocus: () => setPreviewSeries(s),
            onSelect: () => handleCardActivate(s),
          }))
        );
      }
    }

    const cols = detectGridColumns();
    for (let i = 0; i < list.length; i += cols) {
      const slice = list.slice(i, i + cols);
      contentRows.push(
        slice.map((s, idx) => ({
          id: `series-${s.id}`,
          onFocus: () => {
            setPreviewSeries(s);
            if (!isSearchMode()) {
              void scroller.checkTrigger(i + idx);
            }
          },
          onSelect: () => handleCardActivate(s),
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
      if (showInspector() && previewSeries()) {
        if (r === 0) {
          row.push({ id: 's-insp-details', onSelect: () => handleCardActivate(previewSeries()!) });
        } else if (r === 1) {
          row.push({ id: 's-insp-fav', onSelect: () => void handleToggleFavorite(previewSeries()!) });
        }
      }
      if (row.length > 0) grid.push(row);
    }

    spatialNav.setGrid(grid, 1, catColItems.length > 0 ? 1 : 0, preserveFocus);
  };

  const renderSeriesCard = (s: ItemRecord, cardId: string) => {
    const parsed = () => cleanMediaTitle(s.name);
    const title = () => (s.name_clean && s.name_clean !== s.name ? s.name_clean : parsed().clean);
    const year = () => s.year || parsed().year;
    const quality = () => detectChannelQuality(s.name);

    return (
      <div
        id={cardId}
        role="button"
        tabindex="-1"
        aria-label={`Série ${title()}`}
        class={`buntu-vod-card ${focusId() === cardId ? 'focused' : ''}`}
        onClick={() => handleCardActivate(s)}
      >
        <div class="buntu-vod-poster">
          <Show
            when={s.logo_url}
            fallback={
              <div class="buntu-vod-poster-fallback">
                <span style={{ 'font-size': '32px' }}>🍿</span>
                <span style={{ 'font-size': '11px', 'font-weight': '600' }}>{title()}</span>
              </div>
            }
          >
            <img
              src={s.logo_url}
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
              <Show when={s.imdb_rating && s.imdb_rating > 0}>
                <span class="buntu-q-badge">★ {s.imdb_rating!.toFixed(1)}</span>
              </Show>
            </div>
            <button
              type="button"
              tabindex="-1"
              class={`buntu-vod-star-overlay ${s.is_favorite === 1 ? 'fav' : ''}`}
              title="Favori"
              onClick={(e) => void handleToggleFavorite(s, e)}
            >
              {s.is_favorite === 1 ? '★' : '☆'}
            </button>
          </Show>
        </div>

        <div class="buntu-vod-meta">
          <div class="buntu-vod-title">{title()}</div>
          <div class="buntu-vod-sub">
            <span style={{ overflow: 'hidden', 'text-overflow': 'ellipsis', 'white-space': 'nowrap' }}>
              {s.season_num ? `Saison ${s.season_num}` : (year() ? `${year()}${s.group_title ? ' · ' + s.group_title : ''}` : s.group_title || 'Série')}
            </span>
            <Show when={viewMode() === 'list'}>
              <button
                type="button"
                tabindex="-1"
                class={`buntu-ch-star ${s.is_favorite === 1 ? 'fav' : ''}`}
                onClick={(e) => void handleToggleFavorite(s, e)}
              >
                {s.is_favorite === 1 ? '★' : '☆'}
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
            id="s-brand-home"
            type="button"
            tabindex="-1"
            aria-label="Buntu — Retour à l'accueil"
            title="Retour à l'accueil"
            class={`buntu-toolbar-brand ${focusId() === 's-brand-home' ? 'focused' : ''}`}
            onClick={goHome}
          >
            <img src="./icon.png" alt="" class="buntu-toolbar-brand-logo" />
          </button>
          <h1 class="buntu-toolbar-title">Séries</h1>
          <Show when={totalCount() > 0}>
            <span class="buntu-toolbar-subtitle">{formatBuntuCount(totalCount())} séries</span>
          </Show>
        </div>

        <div class="buntu-toolbar-right">
          <span class="buntu-key-hint"><i class="buntu-key-dot" />Favori</span>
          <div class="buntu-search-wrap">
            <span class="buntu-search-icon">🔍</span>
            <input
              id="s-search-input"
              type="text"
              value={searchQuery()}
              placeholder="Rechercher une série"
              class={`buntu-search-field ${focusId() === 's-search-input' ? 'focused' : ''}`}
              onInput={(e) => void handleSearch(e.currentTarget.value)}
            />
          </div>
          <button
            id="s-search-mode"
            type="button"
            tabindex="-1"
            class={`buntu-mode-btn ${searchMode() === 'ai' ? 'ai' : ''} ${focusId() === 's-search-mode' ? 'focused' : ''}`}
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
          <aside class="buntu-cat-pane" aria-label="Catégories Séries">
            <div class="buntu-cat-filter-bar">
              <input
                id="s-cat-filter"
                type="text"
                value={catFilter()}
                placeholder="Filtrer les catégories"
                class={`buntu-cat-filter-input ${focusId() === 's-cat-filter' ? 'focused' : ''}`}
                onInput={(e) => {
                  setCatFilter(e.currentTarget.value);
                  scheduleRebuildGrid(true);
                }}
              />
            </div>

            <div class="buntu-cat-list">
              {/* Récemment vus */}
              <div
                id="series-cat-recent"
                role="button"
                tabindex="-1"
                class={`buntu-cat-row ${selectedCat() === RECENT_CATEGORY && !isSearchMode() ? 'active' : ''} ${focusId() === 'series-cat-recent' ? 'focused' : ''}`}
                onClick={() => void handleSelectCategory(RECENT_CATEGORY)}
              >
                <div class="buntu-cat-row-left">
                  <span class="buntu-cat-row-icon">🕒</span>
                  <span class="buntu-cat-row-title">Récemment vus</span>
                </div>
                <Show when={loaded()}><span class="buntu-cat-count">{formatBuntuCount(recentCount())}</span></Show>
              </div>

              <div
                id="series-cat-all"
                role="button"
                tabindex="-1"
                class={`buntu-cat-row ${selectedCat() === '' && !isSearchMode() ? 'active' : ''} ${focusId() === 'series-cat-all' ? 'focused' : ''}`}
                onClick={() => void handleSelectCategory('')}
              >
                <div class="buntu-cat-row-left">
                  <span class="buntu-cat-row-icon">⊞</span>
                  <span class="buntu-cat-row-title">Toutes les séries</span>
                </div>
                <Show when={loaded()}><span class="buntu-cat-count">{formatBuntuCount(totalCount())}</span></Show>
              </div>

              <div
                id="series-cat-fav"
                role="button"
                tabindex="-1"
                class={`buntu-cat-row ${selectedCat() === FAVORITES_CATEGORY && !isSearchMode() ? 'active' : ''} ${focusId() === 'series-cat-fav' ? 'focused' : ''}`}
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
                    id={`series-cat-${idx()}`}
                    role="button"
                    tabindex="-1"
                    class={`buntu-cat-row ${selectedCat() === cat && !isSearchMode() ? 'active' : ''} ${focusId() === `series-cat-${idx()}` ? 'focused' : ''}`}
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
          <Show when={showsShelves() && recentSeries().length > 0}>
            <div class="buntu-section">
              <div class="buntu-section-header">
                <h2 class="buntu-section-title">
                  <span style={{ color: 'var(--buntu-accent)' }}>▶</span> Reprendre
                </h2>
              </div>
              <div class="buntu-vod-shelf">
                <For each={recentSeries().slice(0, 7)}>
                  {(s) => renderSeriesCard(s, `recent-s-${s.id}`)}
                </For>
              </div>
            </div>
          </Show>

          {/* Shelf 2: Favoris */}
          <Show when={showsShelves() && favSeries().length > 0}>
            <div class="buntu-section">
              <div class="buntu-section-header">
                <h2 class="buntu-section-title">
                  <span style={{ color: 'var(--buntu-star)' }}>★</span> Favoris
                </h2>
              </div>
              <div class="buntu-vod-shelf">
                <For each={favSeries().slice(0, 7)}>
                  {(s) => renderSeriesCard(s, `fav-s-${s.id}`)}
                </For>
              </div>
            </div>
          </Show>

          {/* Main Series Grid */}
          <div class="buntu-section">
            <div class="buntu-section-header">
              <h2 class="buntu-section-title">
                {isSearchMode()
                  ? `Recherche : « ${searchQuery()} »`
                  : selectedCat() === RECENT_CATEGORY
                    ? 'Récemment vus'
                    : selectedCat() === FAVORITES_CATEGORY
                    ? 'Favoris'
                    : selectedCat() || 'Toutes les séries'}
              </h2>
              <Show when={loaded()}>
              <span class="buntu-section-meta">
                {isSearchMode()
                  ? `${searchResults().length} résultats`
                  : `${formatBuntuCount(scroller.total())} séries`}
              </span>
              </Show>
            </div>

            <Show when={!loaded()}>
              <div class="buntu-first-load" role="status" aria-live="polite">
                <div class="tv-spinner" />
                <span>Chargement des séries…</span>
              </div>
            </Show>

            <div
              ref={gridRef}
              class={`buntu-vod-grid ${viewMode() === 'list' ? 'list-mode' : ''}`}
            >
              <For each={activeSeries()}>
                {(s) => renderSeriesCard(s, `series-${s.id}`)}
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
                  ? 'Ouvrez une série : il apparaîtra ici.'
                  : 'Aucun favori pour l’instant : ajoutez-en avec ☆ Favori.'}
              </p>
            </Show>

            <Show when={!isSearchMode() && scroller.isLoading()}>
              <div class="tv-infinite-loader">
                <div class="tv-spinner-small" />
                <span>Chargement des séries…</span>
              </div>
            </Show>
          </div>
        </section>

        {/* Optional Inspector Pane */}
        <Show when={showInspector() && previewSeries()}>
          <aside class="buntu-inspector-pane" aria-label="Aperçu série">
            <div ref={viewportRef} class="buntu-inspector-viewport" style={{ background: '#111318' }}>
              <Show when={previewSeries()?.logo_url} fallback={<div class="tv-mini-mock-screen">🍿</div>}>
                <img
                  src={previewSeries()!.logo_url}
                  alt=""
                  style={{ width: '100%', height: '100%', 'object-fit': 'cover' }}
                />
              </Show>
            </div>
            <h3 class="buntu-inspector-title">
              {previewSeries()!.name_clean || previewSeries()!.name}
            </h3>
            <p class="buntu-inspector-desc">
              {previewSeries()!.plot || previewSeries()!.group_title || 'Série VOD complète avec saisons et épisodes.'}
            </p>
            <div class="buntu-inspector-actions">
              <button
                id="s-insp-details"
                type="button"
                tabindex="-1"
                class={`buntu-action-primary ${focusId() === 's-insp-details' ? 'focused' : ''}`}
                onClick={() => handleCardActivate(previewSeries()!)}
              >
                ▶ Voir les épisodes
              </button>
              <button
                id="s-insp-fav"
                type="button"
                tabindex="-1"
                class={`buntu-action-secondary ${focusId() === 's-insp-fav' ? 'focused' : ''}`}
                onClick={() => void handleToggleFavorite(previewSeries()!)}
              >
                {previewSeries()!.is_favorite === 1 ? '★' : '☆'}
              </button>
            </div>
          </aside>
        </Show>
      </div>
    </div>
  );
};
