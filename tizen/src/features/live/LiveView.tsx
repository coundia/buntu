import { Component, createSignal, createMemo, createEffect, onMount, onCleanup, For, Show } from 'solid-js';
import { CndEngine } from '../../core/engine/CndEngine';
import { Database, EpgProgramRecord, ItemRecord, FAVORITES_CATEGORY } from '../../core/storage/Database';
import { AVPlayerService } from '../../core/player/AVPlayerService';
import { FocusableItem, spatialNav } from '../../ui/design/SpatialNav';
import { screenState, isContentFocusId, revealItem, BrowseSnapshot } from '../../core/navigation/ScreenState';
import { createInfiniteScroller } from '../../core/pagination/InfiniteScrollController';
import { cleanMediaTitle } from '../../core/utils/titleCleaner';
import { detectChannelQuality, formatBuntuCount } from '../../core/utils/categoryMeta';
import { announce } from '../../ui/design/a11y';

export interface LiveViewProps {
  onPlayChannel: (channel: ItemRecord) => void;
  onAddSource?: () => void;
}

export const LiveView: Component<LiveViewProps> = (props) => {
  const engine = CndEngine.getInstance();
  const db = Database.getInstance();
  const player = AVPlayerService.getInstance();
  const PAGE_SIZE = 60;

  const [categories, setCategories] = createSignal<string[]>([]);
  const [catCounts, setCatCounts] = createSignal<Record<string, number>>({});
  const [totalCount, setTotalCount] = createSignal(0);
  const [favCount, setFavCount] = createSignal(0);

  // '' means "Toutes les chaînes"; the default is FAVORITES_CATEGORY (set on mount when favorites exist)
  const [selectedCategory, setSelectedCategory] = createSignal<string>('');
  const [catFilter, setCatFilter] = createSignal<string>('');
  const [showCats, setShowCats] = createSignal(true);
  const [viewMode, setViewMode] = createSignal<'grid' | 'list'>('grid');
  const [showInspector, setShowInspector] = createSignal(false);

  const [searchQuery, setSearchQuery] = createSignal<string>('');
  const [searchResults, setSearchResults] = createSignal<ItemRecord[]>([]);

  const [recentChannels, setRecentChannels] = createSignal<ItemRecord[]>([]);
  const [favChannels, setFavChannels] = createSignal<ItemRecord[]>([]);
  const [epgMap, setEpgMap] = createSignal<Record<string, EpgProgramRecord | undefined>>({});

  const [previewChannel, setPreviewChannel] = createSignal<ItemRecord | null>(null);
  const [previewEpg, setPreviewEpg] = createSignal<{ now?: EpgProgramRecord; next?: EpgProgramRecord } | null>(null);
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
  const activeChannels = () => (isSearchMode() ? searchResults() : scroller.items());
  const showsShelves = () => !isSearchMode() && selectedCategory() === '';

  const filteredCategories = createMemo(() => {
    const raw = categories().filter((c) => c !== FAVORITES_CATEGORY && c !== 'Favoris');
    const q = catFilter().trim().toLowerCase();
    if (!q) return raw;
    return raw.filter((c) => c.toLowerCase().includes(q));
  });

  const scroller = createInfiniteScroller<ItemRecord>({
    pageSize: PAGE_SIZE,
    threshold: 12,
    maxItems: 420,
    fetchBatch: async (offset, limit) => {
      const cat = selectedCategory() || undefined;
      const [list, count] = await Promise.all([
        engine.getCatalog('live', cat, offset, limit),
        engine.countCatalog('live', cat),
      ]);
      return { items: list, total: count };
    },
    onBatchLoaded: (list, total) => {
      if (!isSearchMode()) {
        announce(`Live TV, ${list.length} chaînes affichées sur ${total}`);
        void hydrateEpgForList(list);
        if (!previewChannel() && list.length > 0) {
          void selectForPreview(list[0], false);
        }
        scheduleRebuildGrid(true);
      }
    },
  });

  const hydrateEpgForList = async (items: ItemRecord[]) => {
    const nowTs = Math.floor(Date.now() / 1000);
    const updates: Record<string, EpgProgramRecord | undefined> = {};
    let hasNew = false;
    const current = epgMap();
    for (const ch of items.slice(0, 40)) {
      if (ch.tvg_id && !(ch.tvg_id in current)) {
        try {
          const res = await db.getEpgNowNext(ch.tvg_id, nowTs);
          updates[ch.tvg_id] = res.now;
          hasNew = true;
        } catch {}
      }
    }
    if (hasNew) {
      setEpgMap((prev) => ({ ...prev, ...updates }));
    }
  };

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
      engine.getCategoryCounts('live'),
      engine.getRecentItems('live', 10),
      engine.getFavoritesByKind('live', 12),
    ]);
    setTotalCount(countsData.total);
    setFavCount(countsData.favCount);
    setCatCounts(countsData.counts);
    setRecentChannels(recents);
    setFavChannels(favs);
    void hydrateEpgForList([...recents, ...favs]);
  };

  onMount(async () => {
    resizeHandler = () => {
      syncAvPlayRect();
      scheduleRebuildGrid(true);
    };
    window.addEventListener('resize', resizeHandler);

    // BACK from the player/details: same category, view mode and focused card as before.
    const restored = screenState.restore('live');
    const snap = restored?.snapshot as BrowseSnapshot<ItemRecord> | undefined;
    if (restored && snap) {
      // Instant return: show what was on screen, then refresh counts and shelves behind.
      setSelectedCategory(restored.category);
      setViewMode(restored.viewMode);
      setCategories(snap.categories);
      setCatCounts(snap.catCounts);
      setFavCount(snap.favCount);
      setRecentChannels(snap.recent);
      setFavChannels(snap.favs);
      setEpgMap((snap.epg || {}) as Record<string, EpgProgramRecord | undefined>);
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

    const cats = await engine.getCategories('live');
    setCategories(cats);
    await refreshShelvesAndCounts();

    // (restored state read at the top of onMount)
    if (restored) {
      setSelectedCategory(restored.category);
      setViewMode(restored.viewMode);
    } else if (favCount() > 0) {
      // Favorites are the default view; fall back to all channels when there are none yet.
      setSelectedCategory(FAVORITES_CATEGORY);
    }

    await scroller.reset();
    const items = scroller.items();
    if (items.length > 0) {
      await selectForPreview(items[0], false);
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
      const firstId = showsShelves() && recentChannels().length > 0
        ? `recent-ch-${recentChannels()[0].id}`
        : showsShelves() && favChannels().length > 0
          ? `fav-ch-${favChannels()[0].id}`
          : `channel-${items[0].id}`;
      spatialNav.setFocusById(firstId);
    } else if (cats.length > 0) {
      spatialNav.setFocusById('cat-fav');
    }
  });

  onCleanup(() => {
    screenState.save('live', {
      category: selectedCategory(),
      viewMode: viewMode(),
      focusId: lastContentFocus,
      snapshot: {
        categories: categories(),
        catCounts: catCounts(),
        totalCount: totalCount(),
        favCount: favCount(),
        recent: recentChannels(),
        favs: favChannels(),
        items: scroller.items(),
        total: scroller.total(),
        scrollTop: lastScrollTop,
          epg: epgMap(),
      },
    });
    if (resizeHandler) window.removeEventListener('resize', resizeHandler);
    document.querySelector('.app-root')?.classList.remove('preview-mode');
  });

  const selectForPreview = async (ch: ItemRecord, startStream = false) => {
    setPreviewChannel(ch);
    if (ch.tvg_id) {
      try {
        const epg = await db.getEpgNowNext(ch.tvg_id, Math.floor(Date.now() / 1000));
        setPreviewEpg(epg);
      } catch {
        setPreviewEpg(null);
      }
    } else {
      setPreviewEpg(null);
    }
    if (startStream && showInspector()) {
      syncAvPlayRect();
      await engine.play(ch);
    }
  };

  const toggleInspector = () => {
    const next = !showInspector();
    setShowInspector(next);
    if (next) {
      document.querySelector('.app-root')?.classList.add('preview-mode');
      requestAnimationFrame(() => {
        syncAvPlayRect();
        const ch = previewChannel() || activeChannels()[0];
        if (ch) void selectForPreview(ch, true);
      });
    } else {
      document.querySelector('.app-root')?.classList.remove('preview-mode');
      engine.stopPlayback();
    }
    scheduleRebuildGrid(true);
  };

  const handleSelectCategory = async (cat: string) => {
    if (cat === selectedCategory() && !isSearchMode()) return;
    setSelectedCategory(cat);
    if (isSearchMode()) {
      setSearchQuery('');
      setSearchResults([]);
    }
    await scroller.reset();
    const items = scroller.items();
    if (items.length > 0) {
      void selectForPreview(items[0], false);
    }
    scheduleRebuildGrid(false);
    if (items.length > 0) {
      spatialNav.setFocusById(`channel-${items[0].id}`);
    }
  };

  const handleCardActivate = (ch: ItemRecord) => {
    engine.recordRecent(ch);
    if (showInspector()) {
      if (previewChannel()?.id === ch.id) {
        props.onPlayChannel(ch);
      } else {
        void selectForPreview(ch, true);
      }
    } else {
      props.onPlayChannel(ch);
    }
  };

  const handleToggleFavorite = async (ch: ItemRecord, e?: MouseEvent) => {
    e?.stopPropagation();
    const next = await engine.toggleFavorite(ch.id);
    ch.is_favorite = next ? 1 : 0;
    announce(next ? 'Ajouté aux favoris' : 'Retiré des favoris');
    await refreshShelvesAndCounts();
    if (selectedCategory() === FAVORITES_CATEGORY) {
      await scroller.reset();
    } else {
      // Trigger reactive refresh on list items
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
    const results = await engine.searchCatalog(query, 'live', 100);
    setSearchResults(results);
    void hydrateEpgForList(results);
    announce(`${results.length} chaînes trouvées`);
    scheduleRebuildGrid(true);
  };

  const focusDomInput = (id: string) => {
    const el = document.getElementById(id) as HTMLInputElement | null;
    el?.focus();
  };

  const detectGridColumns = (): number => {
    if (viewMode() === 'list') return 1;
    if (!gridRef) return 4;
    const firstCard = gridRef.querySelector('.buntu-ch-card') as HTMLElement | null;
    if (firstCard && gridRef.clientWidth > 0 && firstCard.offsetWidth > 0) {
      return Math.max(1, Math.round(gridRef.clientWidth / (firstCard.offsetWidth + 12)));
    }
    if (gridRef.clientWidth > 0) {
      return Math.max(1, Math.floor((gridRef.clientWidth + 12) / 252));
    }
    return 4;
  };

  const scheduleRebuildGrid = (preserveFocus: boolean) => {
    if (typeof requestAnimationFrame === 'function') {
      requestAnimationFrame(() => rebuildGrid(preserveFocus));
    } else {
      rebuildGrid(preserveFocus);
    }
  };

  const rebuildGrid = (preserveFocus = false) => {
    const list = activeChannels();
    const cats = filteredCategories();

    if (totalCount() === 0 && list.length === 0 && cats.length === 0) {
      if (props.onAddSource) {
        spatialNav.setGrid([[{ id: 'btn-live-add-source', onSelect: () => props.onAddSource?.() }]]);
      } else {
        spatialNav.setGrid([]);
      }
      return;
    }

    const grid: FocusableItem[][] = [];

    // Row 0: Top Toolbar
    const toolbarRow: FocusableItem[] = [
      { id: 'live-toggle-cats', onSelect: () => { setShowCats((v) => !v); scheduleRebuildGrid(true); } },
      { id: 'live-mode-grid', onSelect: () => { setViewMode('grid'); scheduleRebuildGrid(true); } },
      { id: 'live-mode-list', onSelect: () => { setViewMode('list'); scheduleRebuildGrid(true); } },
      { id: 'live-toggle-inspector', onSelect: toggleInspector },
      { id: 'live-search-input', onSelect: () => focusDomInput('live-search-input') },
    ];
    if (searchQuery().trim()) {
      toolbarRow.push({
        id: 'live-search-clear',
        onSelect: () => void handleSearch(''),
      });
    }
    grid.push(toolbarRow);

    // Build Left Category Column items
    const catColItems: FocusableItem[] = [];
    if (showCats()) {
      catColItems.push({
        id: 'live-cat-home',
        onSelect: () => {
          setCatFilter('');
          void handleSelectCategory('');
        },
      });
      catColItems.push({
        id: 'live-cat-filter',
        onSelect: () => focusDomInput('live-cat-filter'),
      });
      catColItems.push({
        id: 'cat-fav',
        onSelect: () => void handleSelectCategory(FAVORITES_CATEGORY),
      });
      catColItems.push({
        id: 'cat-all',
        onSelect: () => void handleSelectCategory(''),
      });
      cats.forEach((cat, idx) => {
        catColItems.push({
          id: `cat-${idx}`,
          onSelect: () => void handleSelectCategory(cat),
        });
      });
    }

    // Build Right Content Rows
    const contentRows: FocusableItem[][] = [];

    if (showsShelves()) {
      const recents = recentChannels();
      if (recents.length > 0) {
        contentRows.push(
          recents.slice(0, 6).map((ch) => ({
            id: `recent-ch-${ch.id}`,
            onFocus: () => void selectForPreview(ch, false),
            onSelect: () => handleCardActivate(ch),
          }))
        );
      }
      const favs = favChannels();
      if (favs.length > 0) {
        contentRows.push(
          favs.slice(0, 6).map((ch) => ({
            id: `fav-ch-${ch.id}`,
            onFocus: () => void selectForPreview(ch, false),
            onSelect: () => handleCardActivate(ch),
          }))
        );
      }
    }

    const cols = detectGridColumns();
    for (let i = 0; i < list.length; i += cols) {
      const slice = list.slice(i, i + cols);
      contentRows.push(
        slice.map((ch, idx) => ({
          id: `channel-${ch.id}`,
          onFocus: () => {
            void selectForPreview(ch, false);
            if (!isSearchMode()) {
              void scroller.checkTrigger(i + idx);
            }
          },
          onSelect: () => handleCardActivate(ch),
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
        const cRow = contentRows[Math.min(r, contentRows.length - 1)];
        row.push(...cRow);
      }
      if (showInspector() && previewChannel()) {
        if (r === 0) {
          row.push({ id: 'live-insp-play', onSelect: () => props.onPlayChannel(previewChannel()!) });
        } else if (r === 1) {
          row.push({ id: 'live-insp-fav', onSelect: () => void handleToggleFavorite(previewChannel()!) });
        }
      }
      if (row.length > 0) grid.push(row);
    }

    spatialNav.setGrid(grid, 1, catColItems.length > 0 ? 1 : 0, preserveFocus);
  };

  const epgRatio = (prog?: EpgProgramRecord): number => {
    if (!prog || prog.end_ts <= prog.start_ts) return 0;
    const now = Date.now() / 1000;
    return Math.min(100, Math.max(0, ((now - prog.start_ts) / (prog.end_ts - prog.start_ts)) * 100));
  };

  const renderChannelCard = (ch: ItemRecord, cardId: string, fallbackIdx: number) => {
    const cleanTitle = () => (ch.name_clean && ch.name_clean !== ch.name ? ch.name_clean : cleanMediaTitle(ch.name).clean);
    const quality = () => detectChannelQuality(ch.name);
    const nowProg = () => (ch.tvg_id ? epgMap()[ch.tvg_id] : undefined);
    const isPlaying = () => previewChannel()?.id === ch.id && showInspector();

    return (
      <div
        id={cardId}
        role="button"
        tabindex="-1"
        aria-label={`${cleanTitle()}, chaîne ${ch.chno || fallbackIdx + 1}`}
        class={`buntu-ch-card ${isPlaying() ? 'playing' : ''} ${focusId() === cardId ? 'focused' : ''}`}
        onClick={() => handleCardActivate(ch)}
      >
        <div class="buntu-ch-top">
          <div class="buntu-ch-logo">
            <Show when={ch.logo_url} fallback={<span class="buntu-ch-logo-fallback">📺</span>}>
              <img
                src={ch.logo_url}
                alt=""
                loading="lazy"
                onError={(e) => {
                  (e.currentTarget as HTMLImageElement).style.display = 'none';
                }}
              />
            </Show>
          </div>

          <div class="buntu-ch-info">
            <div class="buntu-ch-title-row">
              <span class="buntu-ch-num">{ch.chno || fallbackIdx + 1}</span>
              <span class="buntu-ch-name">{cleanTitle()}</span>
              <Show when={quality()}>
                <span class={`buntu-q-badge ${quality() === '4K' ? 'uhd' : ''}`}>{quality()}</span>
              </Show>
            </div>
            <Show when={ch.group_title}>
              <div class="buntu-ch-group">{ch.group_title}</div>
            </Show>
          </div>

          <button
            type="button"
            tabindex="-1"
            class={`buntu-ch-star ${ch.is_favorite === 1 ? 'fav' : ''}`}
            title="Favori"
            onClick={(e) => void handleToggleFavorite(ch, e)}
          >
            {ch.is_favorite === 1 ? '★' : '☆'}
          </button>
        </div>

        <div class="buntu-ch-epg">
          <Show
            when={nowProg()}
            fallback={
              <div class="buntu-epg-empty">
                {ch.tvg_id ? 'Guide indisponible' : 'Pas de guide'}
              </div>
            }
          >
            <div class="buntu-epg-title">{nowProg()!.title}</div>
            <div class="buntu-epg-bar">
              <div class="buntu-epg-fill" style={{ width: `${epgRatio(nowProg())}%` }} />
            </div>
          </Show>
        </div>
      </div>
    );
  };

  return (
    <div class={`buntu-page ${showInspector() ? 'with-preview' : ''}`}>
      {/* Top Buntu Toolbar */}
      <header class="buntu-toolbar">
        <div class="buntu-toolbar-left">
          <button
            id="live-toggle-cats"
            type="button"
            tabindex="-1"
            class={`buntu-tool-btn ${showCats() ? 'active' : ''} ${focusId() === 'live-toggle-cats' ? 'focused' : ''}`}
            title={showCats() ? 'Masquer les catégories' : 'Afficher les catégories'}
            onClick={() => {
              setShowCats((v) => !v);
              scheduleRebuildGrid(true);
            }}
          >
            ☰
          </button>
          <h1 class="buntu-toolbar-title">Live TV</h1>
          <Show when={totalCount() > 0}>
            <span class="buntu-toolbar-subtitle">{formatBuntuCount(totalCount())} chaînes</span>
          </Show>
        </div>

        <div class="buntu-toolbar-right">
          <div class="buntu-seg-group" role="group" aria-label="Mode d'affichage">
            <button
              id="live-mode-grid"
              type="button"
              tabindex="-1"
              class={`buntu-seg-btn ${viewMode() === 'grid' ? 'active' : ''} ${focusId() === 'live-mode-grid' ? 'focused' : ''}`}
              title="Grille"
              onClick={() => {
                setViewMode('grid');
                scheduleRebuildGrid(true);
              }}
            >
              ⊞
            </button>
            <button
              id="live-mode-list"
              type="button"
              tabindex="-1"
              class={`buntu-seg-btn ${viewMode() === 'list' ? 'active' : ''} ${focusId() === 'live-mode-list' ? 'focused' : ''}`}
              title="Liste"
              onClick={() => {
                setViewMode('list');
                scheduleRebuildGrid(true);
              }}
            >
              ☰
            </button>
          </div>

          <button
            id="live-toggle-inspector"
            type="button"
            tabindex="-1"
            class={`buntu-tool-btn ${showInspector() ? 'active' : ''} ${focusId() === 'live-toggle-inspector' ? 'focused' : ''}`}
            title="Aperçu mini-lecteur"
            onClick={toggleInspector}
          >
            ◫
          </button>

          <div class="buntu-search-wrap">
            <span class="buntu-search-icon">🔍</span>
            <input
              id="live-search-input"
              type="text"
              value={searchQuery()}
              placeholder="Rechercher une chaîne"
              class={`buntu-search-field ${focusId() === 'live-search-input' ? 'focused' : ''}`}
              onInput={(e) => void handleSearch(e.currentTarget.value)}
            />
            <Show when={searchQuery().trim().length > 0}>
              <button
                id="live-search-clear"
                type="button"
                tabindex="-1"
                class={`buntu-search-clear ${focusId() === 'live-search-clear' ? 'focused' : ''}`}
                onClick={() => void handleSearch('')}
              >
                ✕
              </button>
            </Show>
          </div>
        </div>
      </header>

      {/* Main Split Body */}
      <div class="buntu-body-split">
        {/* Column 1: Categories List */}
        <Show when={showCats()}>
          <aside class="buntu-cat-pane" aria-label="Catégories Live TV">
            <div class="buntu-cat-filter-bar">
              <button
                id="live-cat-home"
                type="button"
                tabindex="-1"
                class={`buntu-cat-home-btn ${focusId() === 'live-cat-home' ? 'focused' : ''}`}
                title="Toutes les catégories"
                onClick={() => {
                  setCatFilter('');
                  void handleSelectCategory('');
                }}
              >
                ⌂
              </button>
              <input
                id="live-cat-filter"
                type="text"
                value={catFilter()}
                placeholder="Filtrer les catégories"
                class={`buntu-cat-filter-input ${focusId() === 'live-cat-filter' ? 'focused' : ''}`}
                onInput={(e) => {
                  setCatFilter(e.currentTarget.value);
                  scheduleRebuildGrid(true);
                }}
              />
            </div>

            <div class="buntu-cat-list">
              {/* Favoris */}
              <div
                id="cat-fav"
                role="button"
                tabindex="-1"
                class={`buntu-cat-row ${selectedCategory() === FAVORITES_CATEGORY && !isSearchMode() ? 'active' : ''} ${focusId() === 'cat-fav' ? 'focused' : ''}`}
                onClick={() => void handleSelectCategory(FAVORITES_CATEGORY)}
              >
                <div class="buntu-cat-row-left">
                  <span class="buntu-cat-row-icon fav">★</span>
                  <span class="buntu-cat-row-title">Favoris</span>
                </div>
                <span class="buntu-cat-count">{formatBuntuCount(favCount())}</span>
              </div>

              {/* Toutes les chaînes */}
              <div
                id="cat-all"
                role="button"
                tabindex="-1"
                class={`buntu-cat-row ${selectedCategory() === '' && !isSearchMode() ? 'active' : ''} ${focusId() === 'cat-all' ? 'focused' : ''}`}
                onClick={() => void handleSelectCategory('')}
              >
                <div class="buntu-cat-row-left">
                  <span class="buntu-cat-row-icon">⊞</span>
                  <span class="buntu-cat-row-title">Toutes</span>
                </div>
                <span class="buntu-cat-count">{formatBuntuCount(totalCount())}</span>
              </div>

              {/* Provider Categories with Exact Counts */}
              <For each={filteredCategories()}>
                {(cat, idx) => (
                  <div
                    id={`cat-${idx()}`}
                    role="button"
                    tabindex="-1"
                    class={`buntu-cat-row ${selectedCategory() === cat && !isSearchMode() ? 'active' : ''} ${focusId() === `cat-${idx()}` ? 'focused' : ''}`}
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

        {/* Column 2: Main Scrollable Content (Shelves + Responsive Multi-Column Grid) */}
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
          <Show
            when={totalCount() > 0 || activeChannels().length > 0}
            fallback={
              <div class="tv-loader-card" style={{ margin: 'auto', 'max-width': '520px' }}>
                <div style={{ 'font-size': '44px' }}>📡</div>
                <h2 style={{ margin: 0, 'font-size': '24px' }}>Aucune chaîne disponible</h2>
                <p style={{ margin: 0, color: 'rgba(255,255,255,0.6)', 'font-size': '15px' }}>
                  Ajoutez une source IPTV M3U ou Xtream Codes pour charger vos chaînes en direct.
                </p>
                <Show when={props.onAddSource}>
                  <button
                    id="btn-live-add-source"
                    type="button"
                    tabindex="-1"
                    class={`buntu-action-primary ${focusId() === 'btn-live-add-source' ? 'focused' : ''}`}
                    onClick={() => props.onAddSource?.()}
                  >
                    + Ajouter une source IPTV
                  </button>
                </Show>
              </div>
            }
          >
            {/* Shelf 1: Récemment consultés */}
            <Show when={showsShelves() && recentChannels().length > 0}>
              <div class="buntu-section">
                <div class="buntu-section-header">
                  <h2 class="buntu-section-title">
                    <span style={{ opacity: 0.7 }}>🕒</span> Récemment consultés
                  </h2>
                </div>
                <div class="buntu-shelf-scroll">
                  <For each={recentChannels().slice(0, 6)}>
                    {(ch, idx) => renderChannelCard(ch, `recent-ch-${ch.id}`, idx())}
                  </For>
                </div>
              </div>
            </Show>

            {/* Shelf 2: Favoris */}
            <Show when={showsShelves() && favChannels().length > 0}>
              <div class="buntu-section">
                <div class="buntu-section-header">
                  <h2 class="buntu-section-title">
                    <span style={{ color: 'var(--buntu-star)' }}>★</span> Favoris
                  </h2>
                </div>
                <div class="buntu-shelf-scroll">
                  <For each={favChannels().slice(0, 6)}>
                    {(ch, idx) => renderChannelCard(ch, `fav-ch-${ch.id}`, idx())}
                  </For>
                </div>
              </div>
            </Show>

            {/* Main Multi-Column Channel Grid */}
            <div class="buntu-section">
              <div class="buntu-section-header">
                <h2 class="buntu-section-title">
                  {isSearchMode()
                    ? `Recherche : « ${searchQuery()} »`
                    : selectedCategory() === FAVORITES_CATEGORY
                      ? 'Favoris'
                      : selectedCategory() || 'Toutes les chaînes'}
                </h2>
                <span class="buntu-section-meta">
                  {isSearchMode()
                    ? `${searchResults().length} résultats`
                    : `${formatBuntuCount(scroller.total())} chaînes`}
                </span>
              </div>

              <div
                ref={gridRef}
                class={`buntu-channel-grid ${viewMode() === 'list' ? 'list-mode' : ''}`}
              >
                <For each={activeChannels()}>
                  {(ch, idx) => renderChannelCard(ch, `channel-${ch.id}`, idx())}
                </For>
              </div>

              <Show when={!isSearchMode() && scroller.isLoading()}>
                <div class="tv-infinite-loader">
                  <div class="tv-spinner-small" />
                  <span>Chargement des chaînes…</span>
                </div>
              </Show>
            </div>
          </Show>
        </section>

        {/* Optional Column 3: Mini-Player Inspector Drawer */}
        <Show when={showInspector() && previewChannel()}>
          <aside class="buntu-inspector-pane" aria-label="Aperçu chaîne">
            <div id="live-preview-viewport" ref={viewportRef} class="buntu-inspector-viewport">
              <Show when={typeof (window as any).webapis === 'undefined'}>
                <div class="tv-mini-mock-screen">
                  <div class="tv-mini-mock-art">
                    <Show when={previewChannel()?.logo_url} fallback={<span style={{ 'font-size': '34px' }}>📺</span>}>
                      <img src={previewChannel()!.logo_url} alt="" style={{ width: '100%', height: '100%', 'object-fit': 'contain' }} />
                    </Show>
                  </div>
                  <div class="tv-mini-equalizer">
                    <span class="eq-bar eq-1" />
                    <span class="eq-bar eq-2" />
                    <span class="eq-bar eq-3" />
                    <span class="eq-bar eq-4" />
                    <span class="eq-bar eq-5" />
                  </div>
                </div>
              </Show>
            </div>

            <h3 class="buntu-inspector-title">
              {previewChannel()!.name_clean || previewChannel()!.name}
            </h3>
            <p class="buntu-inspector-desc">
              {previewEpg()?.now?.title
                ? `${previewEpg()!.now!.title}${previewEpg()!.now!.description ? ' — ' + previewEpg()!.now!.description : ''}`
                : previewChannel()!.group_title || 'Diffusion en direct'}
            </p>

            <div class="buntu-inspector-actions">
              <button
                id="live-insp-play"
                type="button"
                tabindex="-1"
                class={`buntu-action-primary ${focusId() === 'live-insp-play' ? 'focused' : ''}`}
                onClick={() => props.onPlayChannel(previewChannel()!)}
              >
                ⛶ Plein écran
              </button>
              <button
                id="live-insp-fav"
                type="button"
                tabindex="-1"
                class={`buntu-action-secondary ${focusId() === 'live-insp-fav' ? 'focused' : ''}`}
                onClick={() => void handleToggleFavorite(previewChannel()!)}
              >
                {previewChannel()!.is_favorite === 1 ? '★ Favori' : '☆ Favori'}
              </button>
            </div>
          </aside>
        </Show>
      </div>
    </div>
  );
};
