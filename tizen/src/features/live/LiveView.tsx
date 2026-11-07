import { Component, createSignal, onMount, For, Show } from 'solid-js';
import { CndEngine } from '../../core/engine/CndEngine';
import { ItemRecord } from '../../core/storage/Database';
import { FocusableItem, spatialNav } from '../../ui/design/SpatialNav';

export interface LiveViewProps {
  onPlayChannel: (channel: ItemRecord) => void;
  onAddSource?: () => void;
}

export const LiveView: Component<LiveViewProps> = (props) => {
  const engine = CndEngine.getInstance();
  const [categories, setCategories] = createSignal<string[]>([]);
  const [selectedCategory, setSelectedCategory] = createSignal<string>('');
  const [channels, setChannels] = createSignal<ItemRecord[]>([]);
  const [focusId] = spatialNav.getFocusSignal();

  onMount(async () => {
    const cats = await engine.getCategories('live');
    setCategories(cats);
    if (cats.length > 0) {
      setSelectedCategory(cats[0]);
      await loadChannels(cats[0], cats);
    } else {
      rebuildGrid([], []);
    }
  });

  const rebuildGrid = (cats: string[], list: ItemRecord[]) => {
    if (cats.length === 0 && list.length === 0) {
      if (props.onAddSource) {
        spatialNav.setGrid([[{ id: 'btn-live-add-source', onSelect: () => props.onAddSource?.() }]]);
      } else {
        spatialNav.setGrid([]);
      }
      return;
    }

    const maxRows = Math.max(cats.length, list.length);
    const grid: FocusableItem[][] = [];
    for (let i = 0; i < maxRows; i++) {
      const row: FocusableItem[] = [];
      if (i < cats.length) {
        const cat = cats[i];
        row.push({
          id: `cat-${i}`,
          onSelect: () => {
            setSelectedCategory(cat);
            void loadChannels(cat, cats);
          },
        });
      }
      if (i < list.length) {
        const ch = list[i];
        row.push({
          id: `channel-${ch.id}`,
          onSelect: () => props.onPlayChannel(ch),
        });
      }
      if (row.length > 0) {
        grid.push(row);
      }
    }
    spatialNav.setGrid(grid, 0, list.length > 0 && cats.length > 0 ? 1 : 0);
  };

  const loadChannels = async (category: string, cats = categories()) => {
    const list = await engine.getCatalog('live', category, 0, 50);
    setChannels(list);
    rebuildGrid(cats, list);
  };

  return (
    <div class="tv-container">
      <div class="tv-header">
        <h2 style={{ "font-size": "32px", color: "var(--buntu-gold)" }}>Direct TV</h2>
        <div style={{ color: "var(--buntu-cyan)", "font-weight": "700" }}>
          {channels().length} chaînes disponibles
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
                    void loadChannels(cat);
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
          </div>
        </div>
      </Show>
    </div>
  );
};
