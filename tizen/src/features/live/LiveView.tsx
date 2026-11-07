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

    const maxRows = Math.max(cats.length, list.length + (pages > 1 ? 1 : 0));
    const grid: FocusableItem[][] = [];

    for (let i = 0; i < maxRows; i++) {
      const row: FocusableItem[] = [];
      if (i < cats.length) {
        const cat = cats[i];
        row.push({
          id: `cat-${i}`,
          onSelect: () => {
            setSelectedCategory(cat);
            void loadChannels(cat, cats, 1);
          },
        });
      }

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

    if (!isNewCat && list.length > 0) {
      spatialNav.setFocusById(`channel-${list[0].id}`);
    }
  };

  return (
    <div class="tv-container">
      <div class="tv-header">
        <h2 style={{ "font-size": "32px", color: "var(--buntu-gold)" }}>Direct TV</h2>
        <div style={{ color: "var(--buntu-cyan)", "font-weight": "700" }}>
          {totalCount()} chaînes au total
        </div>
      </div>

      <Show
        when={channels().length > 0 || categories().length > 0}
        fallback={
          <div style={{ flex: 1, display: "flex", "flex-direction": "column", "align-items": "center", "justify-content": "center", gap: "24px" }}>
            <p style={{ "font-size": "24px", color: "var(--buntu-text-muted)" }}>
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
        <div style={{ display: "flex", gap: "32px", flex: 1, "overflow-y": "hidden" }}>
          {/* Categories Sidebar */}
          <div style={{
            width: "360px",
            display: "flex",
            "flex-direction": "column",
            gap: "8px",
            "overflow-y": "auto",
            "border-right": "1px solid var(--buntu-border)",
            "padding-right": "16px"
          }}>
            <For each={categories()}>
              {(cat, idx) => (
                <div
                  id={`cat-${idx()}`}
                  role="tab"
                  tabindex="-1"
                  aria-selected={selectedCategory() === cat}
                  aria-label={`Catégorie ${cat}`}
                  class={`tv-nav-item ${selectedCategory() === cat ? 'active' : ''} ${focusId() === `cat-${idx()}` ? 'focused' : ''}`}
                  onClick={() => {
                    setSelectedCategory(cat);
                    void loadChannels(cat, categories(), 1);
                  }}
                  style={{ cursor: "pointer" }}
                >
                  {cat}
                </div>
              )}
            </For>
          </div>

          {/* Channels List */}
          <div style={{ flex: 1, display: "flex", "flex-direction": "column", gap: "12px", "overflow-y": "auto" }} role="list" aria-label="Liste des chaînes en direct">
            <For each={channels()}>
              {(ch) => (
                <div
                  id={`channel-${ch.id}`}
                  role="button"
                  tabindex="-1"
                  aria-label={`Chaîne numéro ${ch.chno || ''} : ${ch.name}, catégorie ${ch.group_title || 'Général'}. Appuyez sur OK pour regarder en plein écran.`}
                  class={`tv-card ${focusId() === `channel-${ch.id}` ? 'focused' : ''}`}
                  style={{
                    padding: "16px 24px",
                    display: "flex",
                    "align-items": "center",
                    gap: "24px",
                    cursor: "pointer",
                  }}
                  onClick={() => props.onPlayChannel(ch)}
                >
                  <div style={{
                    "font-size": "24px",
                    "font-weight": "800",
                    color: "var(--buntu-cyan)",
                    width: "48px"
                  }}>
                    {ch.chno || '•'}
                  </div>
                  <div style={{ flex: 1 }}>
                    <div style={{ "font-size": "24px", "font-weight": "700" }}>{ch.name}</div>
                    <div style={{ "font-size": "18px", color: "var(--buntu-text-muted)", "margin-top": "4px" }}>
                      {ch.group_title || 'Général'}
                    </div>
                  </div>
                  <Show when={focusId() === `channel-${ch.id}`}>
                    <div style={{
                      background: "var(--buntu-gold)",
                      color: "#000000",
                      "font-weight": "800",
                      "font-size": "16px",
                      padding: "6px 16px",
                      "border-radius": "6px",
                      "letter-spacing": "1px",
                    }}>
                      ▶ REGARDER
                    </div>
                  </Show>
                  <div style={{ "font-size": "16px", color: "var(--buntu-gold)" }}>
                    {ch.catchup_days ? `Replay ${ch.catchup_days}j` : ''}
                  </div>
                </div>
              )}
            </For>

            {/* Pagination Controls in Channel Column */}
            <Show when={totalPages() > 1}>
              <div class="tv-pagination-bar" style={{ padding: "16px 0", "justify-content": "flex-start" }} role="navigation" aria-label="Pagination des chaînes">
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

                <div class="tv-page-indicator" style={{ "font-size": "18px", padding: "8px 20px" }}>
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
