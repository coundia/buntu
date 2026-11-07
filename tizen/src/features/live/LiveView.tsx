import { Component, createSignal, onMount, onCleanup, For, Show } from 'solid-js';
import { CndEngine } from '../../core/engine/CndEngine';
import { ItemRecord } from '../../core/storage/Database';
import { FocusableItem, spatialNav } from '../../ui/design/SpatialNav';
import { RemoteKeyHandler } from '../../core/input/RemoteKeyHandler';
import { announce } from '../../ui/design/a11y';

export interface LiveViewProps {
  onPlayChannel: (channel: ItemRecord) => void;
  onAddSource?: () => void;
}

export const LiveView: Component<LiveViewProps> = (props) => {
  const engine = CndEngine.getInstance();
  const PAGE_SIZE = 40;

  const [categories, setCategories] = createSignal<string[]>([]);
  const [selectedCategory, setSelectedCategory] = createSignal<string>('');
  const [channels, setChannels] = createSignal<ItemRecord[]>([]);
  const [currentPage, setCurrentPage] = createSignal(1);
  const [totalCount, setTotalCount] = createSignal(0);
  const [focusId] = spatialNav.getFocusSignal();

  const totalPages = () => Math.max(1, Math.ceil(totalCount() / PAGE_SIZE));

  let keyUnsub: (() => void) | null = null;

  onMount(async () => {
    const cats = await engine.getCategories('live');
    setCategories(cats);
    if (cats.length > 0) {
      setSelectedCategory(cats[0]);
      await loadChannels(cats[0], cats, 1);
    } else {
      rebuildGrid([], [], 1, 1);
    }

    keyUnsub = RemoteKeyHandler.getInstance().addListener((key) => {
      if (key === 'CHANNEL_UP' && currentPage() < totalPages()) {
        void loadChannels(selectedCategory(), categories(), currentPage() + 1);
        return true;
      }
      if (key === 'CHANNEL_DOWN' && currentPage() > 1) {
        void loadChannels(selectedCategory(), categories(), currentPage() - 1);
        return true;
      }
      return false;
    });
  });

  onCleanup(() => {
    if (keyUnsub) keyUnsub();
  });

  const rebuildGrid = (cats: string[], list: ItemRecord[], page: number, pages: number) => {
    if (cats.length === 0 && list.length === 0) {
      if (props.onAddSource) {
        spatialNav.setGrid([[{ id: 'btn-live-add-source', onSelect: () => props.onAddSource?.() }]]);
      } else {
        spatialNav.setGrid([]);
      }
      return;
    }

    const channelRows = list.length + (pages > 1 ? 1 : 0);
    const maxRows = Math.max(cats.length, channelRows);
    const grid: FocusableItem[][] = [];

    for (let i = 0; i < maxRows; i++) {
      const row: FocusableItem[] = [];

      // Column 0: Category (padded to bottom if channelRows > cats.length)
      if (cats.length > 0) {
        const catIdx = Math.min(i, cats.length - 1);
        const cat = cats[catIdx];
        row.push({
          id: `cat-${catIdx}`,
          onSelect: () => {
            void loadChannels(cat, cats, 1);
          },
        });
      }

      // Column 1+: Channel or pagination buttons
      if (i < list.length) {
        const ch = list[i];
        row.push({
          id: `channel-${ch.id}`,
          onSelect: () => props.onPlayChannel(ch),
        });
      } else if (i === list.length && pages > 1) {
        // Pagination buttons row on the channels column
        if (page > 1) {
          row.push({
            id: 'btn-live-prev',
            onSelect: () => void loadChannels(selectedCategory(), cats, page - 1),
          });
        }
        if (page < pages) {
          row.push({
            id: 'btn-live-next',
            onSelect: () => void loadChannels(selectedCategory(), cats, page + 1),
          });
        }
      } else if (list.length > 0) {
        // Padded row when categories > channels
        const lastCh = list[list.length - 1];
        row.push({
          id: `channel-${lastCh.id}`,
          onSelect: () => props.onPlayChannel(lastCh),
        });
      }

      if (row.length > 0) {
        grid.push(row);
      }
    }

    spatialNav.setGrid(grid, 0, list.length > 0 && cats.length > 0 ? 1 : 0);
  };

  const loadChannels = async (category: string, cats = categories(), page = 1) => {
    const isNewCat = category !== selectedCategory();
    const targetPage = isNewCat ? 1 : page;
    setSelectedCategory(category);
    setCurrentPage(targetPage);

    const offset = (targetPage - 1) * PAGE_SIZE;

    // Parallel execution: fetch channel slice + instant count
    const [list, count] = await Promise.all([
      engine.getCatalog('live', category, offset, PAGE_SIZE),
      engine.countCatalog('live', category),
    ]);

    setChannels(list);
    setTotalCount(count);

    const pages = Math.max(1, Math.ceil(count / PAGE_SIZE));
    announce(`Direct, catégorie ${category}, page ${targetPage} sur ${pages}, ${count} chaînes`);

    rebuildGrid(cats, list, targetPage, pages);

    if (list.length > 0) {
      spatialNav.setFocusById(`channel-${list[0].id}`);
    }
  };

  return (
    <div class="tv-container">
      {/* Header */}
      <div class="tv-live-header">
        <h1 class="tv-live-title">
          <span>Direct TV</span>
        </h1>
        <div class="tv-live-badge">
          <span>{totalCount()} chaînes</span>
          <span style={{ opacity: 0.5 }}>•</span>
          <span>Page {currentPage()} / {totalPages()}</span>
        </div>
      </div>

      <Show
        when={channels().length > 0 || categories().length > 0}
        fallback={
          <div style={{ flex: 1, display: "flex", "flex-direction": "column", "align-items": "center", "justify-content": "center", padding: "40px" }}>
            <p style={{ "font-size": "24px", color: "var(--buntu-text-muted)", "margin-bottom": "24px" }}>
              Aucune chaîne en direct disponible. Ajoutez un abonnement IPTV pour commencer.
            </p>
            <Show when={props.onAddSource}>
              <button
                class={`tv-btn ${focusId() === 'btn-live-add-source' ? 'focused' : ''}`}
                onClick={() => props.onAddSource?.()}
              >
                + Ajouter une source IPTV
              </button>
            </Show>
          </div>
        }
      >
        <div class="tv-live-layout">
          {/* Categories Sidebar */}
          <div class="tv-live-sidebar" role="tablist" aria-label="Catégories de chaînes">
            <For each={categories()}>
              {(cat, idx) => (
                <div
                  id={`cat-${idx()}`}
                  role="tab"
                  tabindex="-1"
                  aria-selected={selectedCategory() === cat}
                  aria-label={`Catégorie ${cat}`}
                  class={`tv-category-item ${selectedCategory() === cat ? 'active' : ''} ${focusId() === `cat-${idx()}` ? 'focused' : ''}`}
                  onClick={() => void loadChannels(cat, categories(), 1)}
                >
                  {cat}
                </div>
              )}
            </For>
          </div>

          {/* Channels List */}
          <div class="tv-live-channels" role="list" aria-label="Liste des chaînes en direct">
            <For each={channels()}>
              {(ch) => (
                <div
                  id={`channel-${ch.id}`}
                  role="button"
                  tabindex="-1"
                  aria-label={`Chaîne numéro ${ch.chno || ''} : ${ch.name}, catégorie ${ch.group_title || 'Général'}. Appuyez sur OK pour regarder en plein écran.`}
                  class={`tv-channel-row ${focusId() === `channel-${ch.id}` ? 'focused' : ''}`}
                  onClick={() => props.onPlayChannel(ch)}
                >
                  {/* Channel Number Badge */}
                  <div class="tv-channel-num">
                    {ch.chno || '•'}
                  </div>

                  {/* Channel Logo / Fallback */}
                  <div class="tv-channel-logo">
                    <Show
                      when={ch.logo_url}
                      fallback={<span class="tv-channel-logo-fallback">📺</span>}
                    >
                      <img
                        src={ch.logo_url}
                        alt=""
                        loading="lazy"
                        onError={(e) => {
                          const target = e.currentTarget as HTMLElement;
                          target.style.display = 'none';
                          if (target.parentElement) {
                            const fallback = document.createElement('span');
                            fallback.className = 'tv-channel-logo-fallback';
                            fallback.textContent = '📺';
                            target.parentElement.appendChild(fallback);
                          }
                        }}
                      />
                    </Show>
                  </div>

                  {/* Channel Name & Category Subtitle */}
                  <div class="tv-channel-info">
                    <div class="tv-channel-name">{ch.name}</div>
                    <div class="tv-channel-meta">
                      {ch.group_title || 'Général'}
                    </div>
                  </div>

                  {/* Channel Badges & Action Pill */}
                  <div class="tv-channel-actions">
                    <Show when={ch.catchup_days}>
                      <div class="tv-channel-catchup">
                        Replay {ch.catchup_days}j
                      </div>
                    </Show>

                    <Show when={focusId() === `channel-${ch.id}`}>
                      <div class="tv-watch-pill">
                        <span>▶</span>
                        <span>REGARDER</span>
                      </div>
                    </Show>
                  </div>
                </div>
              )}
            </For>

            {/* Pagination Controls */}
            <Show when={totalPages() > 1}>
              <div class="tv-pagination-bar" role="navigation" aria-label="Pagination des chaînes">
                <button
                  id="btn-live-prev"
                  role="button"
                  tabindex="-1"
                  aria-label="Page précédente de chaînes"
                  class={`tv-btn ${currentPage() <= 1 ? 'disabled' : ''} ${focusId() === 'btn-live-prev' ? 'focused' : ''}`}
                  onClick={() => void loadChannels(selectedCategory(), categories(), currentPage() - 1)}
                >
                  ◀ Précédent
                </button>

                <div class="tv-page-indicator">
                  Page {currentPage()} sur {totalPages()} ({totalCount()} chaînes)
                </div>

                <button
                  id="btn-live-next"
                  role="button"
                  tabindex="-1"
                  aria-label="Page suivante de chaînes"
                  class={`tv-btn ${currentPage() >= totalPages() ? 'disabled' : ''} ${focusId() === 'btn-live-next' ? 'focused' : ''}`}
                  onClick={() => void loadChannels(selectedCategory(), categories(), currentPage() + 1)}
                >
                  Suivant ▶
                </button>
              </div>
            </Show>
          </div>
        </div>
      </Show>
    </div>
  );
};
