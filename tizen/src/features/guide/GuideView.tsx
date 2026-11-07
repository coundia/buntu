import { Component, createSignal, onMount, onCleanup, For, Show } from 'solid-js';
import { CndEngine } from '../../core/engine/CndEngine';
import { Database, EpgProgramRecord, ItemRecord } from '../../core/storage/Database';
import { FocusableItem, spatialNav } from '../../ui/design/SpatialNav';
import { createInfiniteScroller } from '../../core/pagination/InfiniteScrollController';
import { TvSearchBar } from '../../ui/components/TvSearchBar';

export interface GuideViewProps {
  onPlayChannel: (channel: ItemRecord) => void;
}

export const GuideView: Component<GuideViewProps> = (props) => {
  const engine = CndEngine.getInstance();
  const db = Database.getInstance();
  const PAGE_SIZE = 30;

  const [epgMap, setEpgMap] = createSignal<Record<string, { now?: EpgProgramRecord; next?: EpgProgramRecord }>>({});
  const [searchQuery, setSearchQuery] = createSignal<string>('');
  const [searchResults, setSearchResults] = createSignal<ItemRecord[]>([]);
  const [currentTime, setCurrentTime] = createSignal(
    new Date().toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit' })
  );
  const [focusId] = spatialNav.getFocusSignal();

  let timerId: any = null;

  const isSearchMode = () => searchQuery().trim().length > 0;
  const activeChannels = () => isSearchMode() ? searchResults() : scroller.items();

  const scroller = createInfiniteScroller<ItemRecord>({
    pageSize: PAGE_SIZE,
    threshold: 6,
    maxItems: 300,
    fetchBatch: async (offset, limit) => {
      const [list, count] = await Promise.all([
        engine.getCatalog('live', undefined, offset, limit),
        engine.countCatalog('live', undefined),
      ]);

      // Load EPG for new channels in parallel
      const nowTs = Math.floor(Date.now() / 1000);
      const newEpgEntries: Record<string, { now?: EpgProgramRecord; next?: EpgProgramRecord }> = {};
      await Promise.all(
        list.map(async (ch) => {
          if (ch.tvg_id) {
            newEpgEntries[ch.tvg_id] = await db.getEpgNowNext(ch.tvg_id, nowTs);
          }
        })
      );

      setEpgMap((prev) => ({ ...prev, ...newEpgEntries }));
      return { items: list, total: count };
    },
    onBatchLoaded: (list) => {
      if (!isSearchMode()) {
        rebuildGrid(list, true);
      }
    },
  });

  onMount(async () => {
    timerId = setInterval(() => {
      setCurrentTime(new Date().toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit' }));
    }, 10000);

    await scroller.reset();
    rebuildGrid(scroller.items(), false);
  });

  onCleanup(() => {
    if (timerId) clearInterval(timerId);
  });

  const focusInput = (id: string) => {
    const el = document.getElementById(id);
    if (el) (el as HTMLInputElement).focus();
  };

  const handleSearch = async (query: string) => {
    setSearchQuery(query);
    if (!query.trim()) {
      setSearchResults([]);
      rebuildGrid(scroller.items(), false);
      return;
    }
    const results = await engine.searchCatalog(query, 'live', 50);
    setSearchResults(results);

    // Also fetch EPG for newly found channels
    const nowTs = Math.floor(Date.now() / 1000);
    const newEpgEntries: Record<string, { now?: EpgProgramRecord; next?: EpgProgramRecord }> = {};
    await Promise.all(
      results.map(async (ch) => {
        if (ch.tvg_id && !epgMap()[ch.tvg_id]) {
          newEpgEntries[ch.tvg_id] = await db.getEpgNowNext(ch.tvg_id, nowTs);
        }
      })
    );
    if (Object.keys(newEpgEntries).length > 0) {
      setEpgMap((prev) => ({ ...prev, ...newEpgEntries }));
    }

    rebuildSearchGrid(results);
  };

  const handleClearSearch = () => {
    setSearchQuery('');
    setSearchResults([]);
    rebuildGrid(scroller.items(), false);
  };

  const rebuildSearchGrid = (results: ItemRecord[]) => {
    const grid: FocusableItem[][] = [];

    // Search bar row
    const searchRow: FocusableItem[] = [
      { id: 'guide-search-input', onSelect: () => focusInput('guide-search-input') },
    ];
    if (searchQuery().trim()) {
      searchRow.push({ id: 'guide-search-input-clear', onSelect: handleClearSearch });
    }
    grid.push(searchRow);

    // Results rows
    for (const ch of results) {
      grid.push([
        {
          id: `guide-channel-${ch.id}`,
          onSelect: () => props.onPlayChannel(ch),
        },
      ]);
    }

    spatialNav.setGrid(grid, 0, 0, false);
  };

  const rebuildGrid = (list: ItemRecord[], preserveFocus = false) => {
    const grid: FocusableItem[][] = [];

    // Search bar row
    const searchRow: FocusableItem[] = [
      { id: 'guide-search-input', onSelect: () => focusInput('guide-search-input') },
    ];
    if (searchQuery().trim()) {
      searchRow.push({ id: 'guide-search-input-clear', onSelect: handleClearSearch });
    }
    grid.push(searchRow);

    // Channel rows
    for (let i = 0; i < list.length; i++) {
      const ch = list[i];
      grid.push([
        {
          id: `guide-channel-${ch.id}`,
          onFocus: () => void scroller.checkTrigger(i),
          onSelect: () => props.onPlayChannel(ch),
        },
      ]);
    }

    spatialNav.setGrid(grid, list.length > 0 ? 1 : 0, 0, preserveFocus);
  };

  const handleContainerScroll = (e: Event) => {
    if (isSearchMode()) return;
    const el = e.currentTarget as HTMLElement;
    if (el.scrollTop + el.clientHeight >= el.scrollHeight - 350) {
      void scroller.loadMore();
    }
  };

  return (
    <div class="tv-container">
      {/* Header with Title, In-Screen Search Bar & Clock */}
      <div class="tv-live-header">
        <h1 class="tv-live-title">
          <span>Guide des programmes (EPG)</span>
        </h1>

        <TvSearchBar
          id="guide-search-input"
          placeholder="🔍 Filtrer les chaînes ou programmes..."
          value={searchQuery()}
          onInput={handleSearch}
          onClear={handleClearSearch}
          focusId={focusId()}
        />

        <div class="tv-live-badge">
          <span>🕒 {currentTime()}</span>
          <span style={{ opacity: 0.5 }}>•</span>
          <span>
            {isSearchMode()
              ? `${searchResults().length} résultats`
              : `${scroller.items().length} / ${scroller.total()} chaînes`}
          </span>
        </div>
      </div>

      {/* Guide Rows List with Infinite Scroll or Search Results */}
      <div
        role="list"
        aria-label="Liste des chaînes et programmes"
        class="tv-live-channels"
        onScroll={handleContainerScroll}
      >
        <Show
          when={activeChannels().length > 0}
          fallback={
            <div style={{ padding: "48px 0", "text-align": "center", color: "var(--buntu-text-muted)", "font-size": "20px" }}>
              Aucune chaîne ne correspond à "{searchQuery()}".
            </div>
          }
        >
          <For each={activeChannels()}>
            {(ch) => {
              const epg = ch.tvg_id ? epgMap()[ch.tvg_id] : undefined;
              const nowTitle = epg?.now?.title || 'Programme en cours';
              const nextTitle = epg?.next?.title || 'À suivre';
              return (
                <div
                  id={`guide-channel-${ch.id}`}
                  role="button"
                  tabindex="-1"
                  aria-label={`Chaîne ${ch.name}. En ce moment: ${nowTitle}. Suivant: ${nextTitle}. Appuyez pour regarder.`}
                  class={`tv-guide-row ${focusId() === `guide-channel-${ch.id}` ? 'focused' : ''}`}
                  onClick={() => props.onPlayChannel(ch)}
                >
                  {/* Channel Column: Number + Name */}
                  <div class="tv-guide-channel-col">
                    <div class="tv-guide-num">
                      {ch.chno || '•'}
                    </div>
                    <div class="tv-guide-channel-text">
                      <div class="tv-guide-channel-name">{ch.name}</div>
                      <div class="tv-guide-channel-cat">{ch.group_title || 'Direct TV'}</div>
                    </div>
                  </div>

                  {/* Now Programme */}
                  <div class="tv-guide-now-box">
                    <div class="tv-guide-now-header">
                      <span class="tv-guide-live-pill">
                        <span class="tv-guide-live-dot" />
                        DIRECT
                      </span>
                      <span class="tv-guide-now-title">{nowTitle}</span>
                    </div>
                    <div class="tv-guide-now-desc">
                      {epg?.now?.description || 'Aucune information détaillée sur le programme'}
                    </div>
                  </div>

                  {/* Next Programme */}
                  <div class="tv-guide-next-box">
                    <div class="tv-guide-next-label">À SUIVRE</div>
                    <div class="tv-guide-next-title">{nextTitle}</div>
                  </div>

                  {/* Focused Action Pill */}
                  <Show when={focusId() === `guide-channel-${ch.id}`}>
                    <div class="tv-watch-pill">
                      <span>▶</span>
                      <span>REGARDER</span>
                    </div>
                  </Show>
                </div>
              );
            }}
          </For>
        </Show>

        {/* Infinite Scroll Loader & End Status (Only in standard mode) */}
        <Show when={!isSearchMode() && scroller.isLoading()}>
          <div class="tv-infinite-loader">
            <span class="tv-spinner-small" />
            <span>Chargement des programmes suivants...</span>
          </div>
        </Show>

        <Show when={!isSearchMode() && !scroller.hasMore() && scroller.items().length > 0}>
          <div class="tv-infinite-end">
            • Fin du guide ({scroller.total()} chaînes) •
          </div>
        </Show>
      </div>
    </div>
  );
};
